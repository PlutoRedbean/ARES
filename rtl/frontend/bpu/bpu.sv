// Branch prediction unit wrapper (two-stage, 1 block/cycle).
//
// Per docs/ubtb-mbtb-refactor-plan.md (P0):
//
//   * The BPU runs its own speculative fetch stream.  It no longer uses
//     `gen_pc`: the next request PC is computed combinationally from the
//     prediction of the block requested in the previous cycle
//       fetch_pc_s0 = override_valid ? override_pc : dnpc(pred_s1_r)
//     so the loop (predictor output reg -> merge -> dnpc -> predictor input)
//     closes in one cycle and the FTQ can be written every cycle.
//   * `busy` marks a prediction whose FTQ write has not been accepted yet.
//     issue = !flush && (!busy || ftq_wready); w_fire = busy && ftq_wready.
//     On backpressure the whole loop stalls and the predictors hold.
//   * `flush` (or `reset`) restarts the loop through `override_pc`.
//
// Predictor selection uses the CONFIG_FE_* macros directly, split into two
// classes (mirroring the bpu/direction and bpu/target folders):
//   * Direction: CONFIG_FE_TAGE (S1 provisional + S2 precise direction).  The
//     1-cycle CONFIG_FE_BIMODAL / CONFIG_FE_TOURNAMENT predictor is only
//     compiled when TAGE is disabled (it is then the S1 direction) or when
//     uTAGE is enabled (it supplies uTAGE's base direction); otherwise it is
//     dead logic.
//   * Target:    CONFIG_FE_UBTB / CONFIG_FE_MBTB.
// CONFIG_FE_RAS and CONFIG_FE_LOOP_PRED are independent overrides.
module bpu (
    input logic clk,
    input logic rst,

    // redirect from the back-end / front-end
    input logic                            flush,
    input logic [fe_pkg::ADDR_WIDTH - 1:0] redirect_pc,

    input fe_pkg::fe_redirect_kind_t redirect_kind,

    // predict request / response
    input  logic                                          ftq_wready,
    output logic                                          ftq_wvalid,
    output logic               [fe_pkg::ADDR_WIDTH - 1:0] bpu_resp_pc,
    output fe_pkg::ftq_entry_t                            ftq_wdata,

    // Recovery belongs to the redirecting instruction, independently of training.
    input logic [fe_pkg::GHR_WIDTH-1:0] redirect_ghr_before,
    input logic redirect_actual_taken,
    input logic local_repair_valid,
    input logic [fe_pkg::GHR_WIDTH-1:0] local_repair_ghr,
    /* verilator lint_off UNUSEDSIGNAL */ // only recovery fields of the shared event type are read
    input fe_pkg::bpu_update_t redirect_info,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [1:0] bpu_update_valid,
    input fe_pkg::bpu_update_t bpu_update [2],
    output logic [1:0] bpu_update_credit,

    // mbtb correction (P3).  ftq_widx is the FTQ write index (one-hot).
    input logic [fe_pkg::FTQ_NUM_ENTRIES-1:0] ftq_widx,
    input logic ftq_corr_hit,  // target entry still in FTQ
    output logic bpu_corr_valid,
    output logic [fe_pkg::FTQ_NUM_ENTRIES-1:0] bpu_corr_idx,
    output logic bpu_corr_wr_en,
    output logic [fe_pkg::FTQ_NUM_ENTRIES-1:0] bpu_corr_wr_idx,
    output fe_pkg::ftq_entry_t bpu_corr_wr_data,
    output logic [fe_pkg::ADDR_WIDTH-1:0] bpu_corr_start_pc
);
    import fe_pkg::*;

    localparam int unsigned BLOCK_BYTES = FETCH_WIDTH * INST_BYTES;
    localparam logic [ADDR_WIDTH-1:0] BLOCK_MASK = ADDR_WIDTH'(BLOCK_BYTES - 1);

    // The S2 correction stage and the S1 speculation signals are needed when
    // either the target side (mBTB) or the direction side (TAGE) uses them.
`ifdef CONFIG_FE_MBTB
    `define FE_S2_STAGE 1
`else
`ifdef CONFIG_FE_TAGE
    `define FE_S2_STAGE 1
`endif
`endif
`ifdef CONFIG_FE_LOOP_PRED
    `define FE_S1_SPEC 1
`else
`ifdef CONFIG_FE_TAGE
    `define FE_S1_SPEC 1
`endif
`endif

    // The 1-cycle bimodal/tournament is the S1 direction only when TAGE is
    // disabled.  With TAGE enabled it is dead logic, unless uTAGE uses it as
    // its base direction.
`ifndef CONFIG_FE_TAGE
    `define FE_S1_FAST_DIR 1
`elsif CONFIG_FE_UTAGE
    `define FE_S1_FAST_DIR 1
`endif

    logic train_valid, train_ready, update_en;
    logic ubtb_update_ready, mbtb_update_ready;
    assign train_ready = ubtb_update_ready && mbtb_update_ready;
    bpu_update_t update_meta;
    logic [GHR_WIDTH-1:0] ghr_spec, ghr_at_lookup, ghr_commit_next;
    logic [GHR_WIDTH-1:0] block_ghr_next, predict_ghr, corrected_ghr;
    bpu_commit_queue commit_queue (
        .clk(clk), .rst(rst), .train_ready(train_ready),
        .update_valid(bpu_update_valid), .update(bpu_update),
        .credit(bpu_update_credit), .train_valid(train_valid), .train(update_meta),
        .ghr_commit_next(ghr_commit_next)
    );
    assign update_en = train_valid && train_ready;

    wire              is_branch_meta = (update_meta.actual_cfi_type == CFI_COND_BRANCH);
    btb_target_info_t update_target_info;

    always_comb begin
        update_target_info.start_pc = update_meta.update_pc & ~BLOCK_MASK;
        update_target_info.target_pc = update_meta.actual_target;
        update_target_info.cfi_type = update_meta.actual_cfi_type;
        update_target_info.cfi_offset = CFI_OFFSET_WIDTH'((update_meta.update_pc & BLOCK_MASK) >> 2);
    end

    // -----------------------
    // loop control
    // -----------------------
    logic [ADDR_WIDTH - 1:0] fetch_pc_s0;
    logic [ADDR_WIDTH - 1:0] resp_pc_r;
    logic [ADDR_WIDTH - 1:0] snpc;
    logic [ADDR_WIDTH - 1:0] dnpc;
    logic                    busy;  // pending prediction
    logic                    override_valid;
    logic [ADDR_WIDTH - 1:0] override_pc;

    // mbtb correction request (driven later; zero when CONFIG_FE_MBTB is off)
    logic                    corr_needed;  // we want to correct
    logic                    corr_fire;  // ... and the FTQ entry is still there
    logic [ADDR_WIDTH - 1:0] merged_npc;

    // a correction restarts the stream like a flush: the pending (wrong-path)
    // response is dropped (no FTQ write, no RAS spec update) and no request is
    // issued that cycle
    wire                     drop_resp = flush || corr_fire;
    wire                     w_fire = busy && ftq_wready && !drop_resp;
    wire                     issue = !flush && !corr_fire && (!busy || ftq_wready);
    // Forward the accepted block's history to the next lookup in the same cycle.
    assign predict_ghr = w_fire ? block_ghr_next : ghr_spec;
    always_ff @(posedge clk) begin
        if (rst) begin ghr_spec <= '0; ghr_at_lookup <= '0; end
        else begin
            if (issue) ghr_at_lookup <= predict_ghr;
            if (flush) begin
                if (local_repair_valid) ghr_spec <= local_repair_ghr;
                else if (redirect_kind == REDIRECT_BRANCH)
                    ghr_spec <= (redirect_ghr_before << 1) | GHR_WIDTH'(redirect_actual_taken);
                else ghr_spec <= ghr_commit_next;
            end else if (corr_fire) ghr_spec <= corrected_ghr;
            else if (w_fire) ghr_spec <= block_ghr_next;
        end
    end

    assign ftq_wvalid  = busy && !drop_resp;
    assign bpu_resp_pc = resp_pc_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy           <= 1'b0;
            override_valid <= 1'b1;
            override_pc    <= RESET_VEC;
        end else if (flush) begin
            busy           <= 1'b0;
            override_valid <= 1'b1;
            override_pc    <= redirect_pc;
        end else begin
            // issue sets busy; w_fire consumes it; otherwise hold (backpressure)
            if (corr_fire) begin
                busy <= 1'b0;  // drop the pending wrong-path response
            end else if (issue) begin
                busy <= 1'b1;
            end else if (w_fire) begin
                busy <= 1'b0;
            end
            // mbtb correction restarts the stream at the merged next PC
            if (corr_fire) begin
                override_valid <= 1'b1;
                override_pc    <= merged_npc;
            end else if (issue) begin
                override_valid <= 1'b0;
            end
        end
    end

    // per-slot prediction
    logic       [FETCH_WIDTH-1:0]                 pred_cfi_valid;
    cfi_type_t  [FETCH_WIDTH-1:0]                 pred_cfi_type;
    logic       [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] raw_pred_target;
    logic       [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target;
    logic       [FETCH_WIDTH-1:0]                 pred_taken;
    logic       [FETCH_WIDTH-1:0]                 dir_taken_slots;
    pred_meta_t [FETCH_WIDTH-1:0]                 pred_meta;

    logic       [FETCH_WIDTH-1:0]                 base_dir_taken_slots;
    logic       [FETCH_WIDTH-1:0]                 hw_dir_taken_slots;
    logic                                         tage_aligned;

`ifdef CONFIG_FE_TAGE
    logic                         tage_resp_valid;
    logic       [ ADDR_WIDTH-1:0] tage_resp_pc;
    logic       [FETCH_WIDTH-1:0] tage_taken_slots;
    tage_meta_t [FETCH_WIDTH-1:0] tage_meta_slots;
    logic       [FETCH_WIDTH-1:0] s1_tage_taken_slots;
    tage_meta_t [FETCH_WIDTH-1:0] s1_tage_meta_slots;
`endif

`ifdef CONFIG_FE_TOURNAMENT
    chooser_meta_t [FETCH_WIDTH-1:0] chooser_meta_slots;
`endif
`ifdef CONFIG_FE_LOOP_PRED
    logic [FETCH_WIDTH-1:0] loop_override_slots;
`endif

    logic                  bpu_predicted_taken;
    logic [ADDR_WIDTH-1:0] predicted_pc;

    // a conditional branch takes the direction predictor, a jump is always taken
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            pred_taken[i] = pred_cfi_valid[i] && ((pred_cfi_type[i] != CFI_COND_BRANCH) || dir_taken_slots[i]);
        end
    end

    // S1 fast-path conditional-branch speculation, shared by the loop
    // predictor and TAGE (docs/tage-design.md §11.2): the on-path conditional
    // branches up to the first predicted-taken CFI, with their final direction.
`ifdef FE_S1_SPEC
    logic [FETCH_WIDTH-1:0] spec_branch_slots;
    logic [FETCH_WIDTH-1:0] spec_on_path_slots;

    always_comb begin
        logic reached_taken;
        reached_taken = 1'b0;
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            spec_branch_slots[s]  = pred_cfi_valid[s] && (pred_cfi_type[s] == CFI_COND_BRANCH);
            spec_on_path_slots[s] = ~reached_taken;
            if (pred_cfi_valid[s] && pred_taken[s]) begin
                reached_taken = 1'b1;
            end
        end
    end
`endif

    /* verilator lint_off UNUSEDSIGNAL */ // S2 repair fields are unused when RAS is disabled
    logic corr_ras_push, corr_ras_pop;
    logic [ADDR_WIDTH-1:0] corr_ras_addr;
    /* verilator lint_on UNUSEDSIGNAL */

    // -----------------------
    // Return address stack
    // -----------------------
`ifdef CONFIG_FE_RAS
    logic                  ras_top_valid;
    logic [ADDR_WIDTH-1:0] ras_top_addr;
    logic                  block_push;
    logic                  block_pop;
    logic [ADDR_WIDTH-1:0] block_ret_addr;

    logic [PRED_CKPT_W-1:0] ras_ckpt_index, ras_ckpt_r;
    always_ff @(posedge clk) begin
        if (rst) ras_ckpt_r <= '0;
        else if (issue) ras_ckpt_r <= ras_ckpt_index;
    end

    always_comb begin
        logic taken_found;
        taken_found    = 1'b0;
        block_push     = 1'b0;
        block_pop      = 1'b0;
        block_ret_addr = '0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            if (!taken_found && pred_taken[i]) begin
                taken_found    = 1'b1;
                block_push     = (pred_cfi_type[i] == CFI_CALL);
                block_pop      = (pred_cfi_type[i] == CFI_RETURN);
                block_ret_addr = resp_pc_r + ADDR_WIDTH'((i + 1) * INST_BYTES);
            end
        end
    end

    ras ras_u (
        .clk(clk),
        .rst(rst),
        .top_valid(ras_top_valid),
        .top_addr(ras_top_addr),
        .spec_push(w_fire && block_push),
        .spec_pop(w_fire && block_pop),
        .spec_addr(block_ret_addr),
        .req_valid(issue),
        .flush(flush),
        .restore_valid(flush && ((redirect_kind == REDIRECT_BRANCH) || local_repair_valid)),
        .restore_ptr(redirect_info.pred_meta.ras_ckpt_ptr),
        .corr(corr_fire),
`ifdef FE_S2_STAGE
        .corr_ptr(shadow1_meta[0].ras_ckpt_ptr),
`else
        .corr_ptr('0),
`endif
        .ckpt_index(ras_ckpt_index),
        .corr_push(corr_ras_push),
        .corr_pop(corr_ras_pop),
        .corr_addr(corr_ras_addr),
        .commit_valid(bpu_update_valid), .commit_update(bpu_update),
        .restore_push(redirect_info.actual_cfi_type == CFI_CALL),
        .restore_pop(redirect_info.actual_cfi_type == CFI_RETURN),
        .restore_addr(redirect_info.update_pc + INST_BYTES)
    );
`endif

    // final per-slot target: a valid RAS entry overrides the BTB for returns
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
`ifdef CONFIG_FE_RAS
            if ((pred_cfi_type[i] == CFI_RETURN) && ras_top_valid) begin
                pred_target[i] = ras_top_addr;
            end else begin
                pred_target[i] = raw_pred_target[i];
            end
`else
            pred_target[i] = raw_pred_target[i];
`endif
        end
    end

    // next PC: target of the first CFI predicted taken, else sequential
    always_comb begin
        bpu_predicted_taken = 1'b0;
        predicted_pc        = '0;
        for (int i = FETCH_WIDTH - 1; i >= 0; i--) begin
            if (pred_taken[i]) begin
                bpu_predicted_taken = 1'b1;
                predicted_pc        = pred_target[i];
            end
        end
    end

    assign snpc        = resp_pc_r + BLOCK_BYTES;
    assign dnpc        = bpu_predicted_taken ? predicted_pc : snpc;
    assign fetch_pc_s0 = override_valid ? override_pc : dnpc;

    // count how many CFIs precede each slot
    logic [$clog2(FETCH_WIDTH+1)-1:0] cfi_prefix_slots[FETCH_WIDTH];
    always_comb begin
        logic [$clog2(FETCH_WIDTH+1)-1:0] cfi_prefix;
        cfi_prefix = '0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            cfi_prefix_slots[i] = cfi_prefix;
            if (pred_cfi_valid[i]) cfi_prefix = cfi_prefix + 1'b1;
        end
    end

    always_comb begin
        logic [GHR_WIDTH-1:0] h;
        h = ghr_at_lookup;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            pred_meta[i] = '0;
`ifdef CONFIG_FE_RAS
            pred_meta[i].ras_ckpt_ptr = ras_ckpt_r;
`endif
            pred_meta[i].pred_type = pred_cfi_valid[i] ? pred_cfi_type[i] : CFI_NONE;
            pred_meta[i].ghr_before = h;
            if (pred_cfi_valid[i]) h = (h << 1) | GHR_WIDTH'(pred_taken[i]);
            pred_meta[i].pred_target = pred_target[i];
            pred_meta[i].pred_taken = pred_taken[i];
            pred_meta[i].cfi_prefix = cfi_prefix_slots[i];
`ifdef CONFIG_FE_TOURNAMENT
            pred_meta[i].chooser_meta = chooser_meta_slots[i];
`endif
`ifdef CONFIG_FE_LOOP_PRED
            pred_meta[i].loop_override = loop_override_slots[i];
            pred_meta[i].loop_taken = loop_taken_slots[i];
`endif
`ifdef CONFIG_FE_TAGE
            // Provisional S1 TAGE metadata; the S2 stage backfills the final
            // state (and the FTQ read mux gives the S2 write priority).
            pred_meta[i].tage_meta = s1_tage_meta_slots[i];
`endif
        end
        block_ghr_next = h;
    end

    assign ftq_wdata = '{
            start_pc: resp_pc_r,
            pred_cfi_valid: pred_cfi_valid,
            pred_cfi_type: pred_cfi_type,
            pred_meta: pred_meta
        };

    // ==================================================================
    // S2 correction stage (P2/P3 + TAGE): a 2-cycle precise source layered on
    // the S1 fast path.  mBTB (target) and TAGE (conditional direction) both
    // return two cycles after `issue`, aligned with `shadow1`.
    //
    //   * merge is slot-wise: RAS > mbtb > ubtb for the target, and
    //     TAGE > S1 fast (S1 already includes the loop override) for the
    //     direction of conditional branches.
    //   * when the merged first predicted-taken differs from the S1 fast path
    //     the target FTQ entry is corrected in place (tail-invalidate + poison)
    //     and the stream restarts via `override_pc`.
    //   * the entry is also rewritten (meta backfill) when only the prediction
    //     metadata changes, so the back-end trains TAGE / the loop predictor
    //     with the exact state they predicted with (docs/tage-design.md §11.2).
    // ==================================================================
`ifdef FE_S2_STAGE
    logic                                        mbtb_pred_valid;
    logic      [ ADDR_WIDTH-1:0]                 mbtb_pred_pc;
    logic      [FETCH_WIDTH-1:0]                 mbtb_cfi_valid;
    cfi_type_t [FETCH_WIDTH-1:0]                 mbtb_cfi_type;
    logic      [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] mbtb_target;

`ifdef CONFIG_FE_MBTB
    mbtb mbtb_u (
        .clk            (clk),
        .rst            (rst),
        .req_valid      (issue),
        .fetch_pc       (fetch_pc_s0),
        .pred_valid     (mbtb_pred_valid),
        .pred_pc        (mbtb_pred_pc),
        .pred_cfi_valid (mbtb_cfi_valid),
        .pred_cfi_type  (mbtb_cfi_type),
        .pred_target    (mbtb_target),
        .update_ready   (mbtb_update_ready),
        .update_en      (update_en),
        .update_pc      (update_meta.update_pc),
        .update_cfi_type(update_meta.actual_cfi_type),
        .update_target  (update_meta.actual_target)
    );
`else
    assign mbtb_update_ready = 1'b1;
    assign mbtb_pred_valid = 1'b0;
    assign mbtb_pred_pc    = '0;
    assign mbtb_cfi_valid  = '0;
    assign mbtb_cfi_type   = '0;
    assign mbtb_target     = '0;
`endif

    // The shadow mirrors the 2-cycle source pipeline: stage 0 at issue, stage 1 at
    // the response cycle (where the fast prediction and the FTQ write are
    // known).  It is compared with the mbtb response one cycle after stage 1,
    // exactly when mbtb emits its result.
    logic                                             shadow0_valid;
    logic       [     ADDR_WIDTH-1:0]                 shadow0_start_pc;

    logic                                             shadow1_valid;
    logic                                             shadow1_accepted;
    logic       [     ADDR_WIDTH-1:0]                 shadow1_start_pc;
    logic       [     ADDR_WIDTH-1:0]                 shadow1_fast_npc;
    logic       [FTQ_NUM_ENTRIES-1:0]                 shadow1_widx;
    logic       [    FETCH_WIDTH-1:0]                 shadow1_cfi_valid;
    cfi_type_t  [    FETCH_WIDTH-1:0]                 shadow1_cfi_type;
    logic       [    FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] shadow1_target;
    logic       [    FETCH_WIDTH-1:0]                 shadow1_dir;
    pred_meta_t [    FETCH_WIDTH-1:0]                 shadow1_meta;
    logic                                             shadow1_ras_valid;
    logic       [     ADDR_WIDTH-1:0]                 shadow1_ras_addr;

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            shadow0_valid <= 1'b0;
        end else begin
            shadow0_valid <= issue;
            if (issue) shadow0_start_pc <= fetch_pc_s0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            shadow1_valid <= 1'b0;
        end else begin
            shadow1_valid <= shadow0_valid;
            if (shadow0_valid) begin
                shadow1_start_pc  <= shadow0_start_pc;
                shadow1_fast_npc  <= dnpc;
                shadow1_widx      <= ftq_widx;
                shadow1_cfi_valid <= pred_cfi_valid;
                shadow1_cfi_type  <= pred_cfi_type;
                shadow1_target    <= pred_target;
                shadow1_dir       <= dir_taken_slots;
                shadow1_meta      <= pred_meta;
                shadow1_accepted  <= w_fire;
`ifdef CONFIG_FE_RAS
                shadow1_ras_valid <= ras_top_valid;
                shadow1_ras_addr  <= ras_top_addr;
`else
                shadow1_ras_valid <= 1'b0;
                shadow1_ras_addr  <= '0;
`endif
            end
        end
    end

    logic [FETCH_WIDTH-1:0] merged_cfi_valid;
    cfi_type_t [FETCH_WIDTH-1:0] merged_cfi_type;
    logic [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] merged_target;
    logic [FETCH_WIDTH-1:0] merged_taken;
    logic [FETCH_WIDTH-1:0] merged_dir;
    logic [FETCH_WIDTH-1:0] merged_on_path;
    logic [FETCH_WIDTH-1:0] s1_on_path;
    logic [FETCH_WIDTH-1:0] s1_taken;
    logic hist_diff;

    // The mbtb response is only meaningful when it describes the same block as
    // shadow1; otherwise its (stale) CFI output must not be merged in.
    wire mbtb_aligned = mbtb_pred_valid && shadow1_valid && (mbtb_pred_pc == shadow1_start_pc);
    // TAGE and mBTB share the same two-cycle latency, so their responses must
    // describe shadow1's block.  If the pipeline was disturbed, fall back to the
    // S1 fast-path direction rather than merging a stale TAGE result.
`ifdef CONFIG_FE_TAGE
    assign tage_aligned = tage_resp_valid && (tage_resp_pc == shadow1_start_pc);
`else
    assign tage_aligned = 1'b0;
`endif

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            merged_cfi_valid[i] = shadow1_cfi_valid[i] | (mbtb_aligned && mbtb_cfi_valid[i]);
            // Do not let mBTB override a CFI uBTB already predicted: the S1
            // fast path already used the uBTB target, and a target-only
            // difference would restart fetch for no branch-direction gain.
            // mBTB is used to add CFIs/targets that uBTB missed.
            if (shadow1_cfi_valid[i]) begin
                merged_cfi_type[i] = shadow1_cfi_type[i];
                merged_target[i]   = shadow1_target[i];
            end else if (mbtb_aligned && mbtb_cfi_valid[i]) begin
                merged_cfi_type[i] = mbtb_cfi_type[i];
                merged_target[i]   = mbtb_target[i];
            end else begin
                merged_cfi_type[i] = shadow1_cfi_type[i];
                merged_target[i]   = shadow1_target[i];
            end
            // a return's target comes from the RAS, never from mbtb's stored one
            if ((merged_cfi_type[i] == CFI_RETURN) && shadow1_ras_valid) begin
                merged_target[i] = shadow1_ras_addr;
            end
            if (merged_cfi_type[i] == CFI_COND_BRANCH) begin
                // TAGE owns the S2 conditional direction.  The loop predictor
                // (selected by its per-PC confidence) keeps priority where it
                // has proved better, matching the S1 fast-path selection.
`ifdef CONFIG_FE_TAGE
`ifdef CONFIG_FE_LOOP_PRED
                if (use_loop_s2_slots[i]) begin
                    merged_dir[i] = shadow1_meta[i].loop_taken;
                end else if (tage_aligned) begin
                    merged_dir[i] = tage_taken_slots[i];
                end else begin
                    merged_dir[i] = shadow1_dir[i];
                end
`else
                merged_dir[i] = tage_aligned ? tage_taken_slots[i] : shadow1_dir[i];
`endif
`else
                merged_dir[i] = shadow1_dir[i];
`endif
                merged_taken[i] = merged_cfi_valid[i] && merged_dir[i];
            end else begin
                merged_dir[i]   = 1'b1;
                merged_taken[i] = merged_cfi_valid[i];
            end
        end

        merged_npc = shadow1_start_pc + BLOCK_BYTES;
        for (int i = FETCH_WIDTH - 1; i >= 0; i--) begin
            if (merged_taken[i]) merged_npc = merged_target[i];
        end
    end

    // On-path masks for the history-spec comparison.  The taken branch itself
    // is on-path (it ends the block after being executed).
    always_comb begin
        logic reached_taken;
        reached_taken = 1'b0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            s1_taken[i]       = shadow1_cfi_valid[i]
                             && ((shadow1_cfi_type[i] != CFI_COND_BRANCH) || shadow1_dir[i]);
            s1_on_path[i] = ~reached_taken;
            if (s1_taken[i]) reached_taken = 1'b1;
        end
    end

    always_comb begin
        logic reached_taken;
        reached_taken = 1'b0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            merged_on_path[i] = ~reached_taken;
            if (merged_taken[i]) reached_taken = 1'b1;
        end
    end

    // The speculative history was advanced with the S1 fast-path CFI list and
    // directions.  If the S2 merge changes any on-path conditional branch
    // (including CFI coverage: an mBTB-only branch that uBTB missed), the
    // history must be rebuilt from the block-before checkpoint.  Without this
    // repair the TAGE hashes keep the fast-path's errors and lose accuracy.
    always_comb begin
        logic s1_spec, m_spec;
        hist_diff = 1'b0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            s1_spec = s1_on_path[i] && shadow1_cfi_valid[i] && (shadow1_cfi_type[i] == CFI_COND_BRANCH);
            m_spec  = merged_on_path[i] && merged_cfi_valid[i] && (merged_cfi_type[i] == CFI_COND_BRANCH);
            if (s1_spec != m_spec) hist_diff = 1'b1;
            else if (s1_spec && (shadow1_dir[i] != merged_dir[i])) hist_diff = 1'b1;
        end
    end

    // After a correction the FTQ tail-invalidates and drops writes for 2 cycles;
    // suppress further corrections in the same window.
    logic [1:0] corr_hold;
    always_ff @(posedge clk) begin
        if (rst || flush) corr_hold <= '0;
        else if (corr_fire) corr_hold <= 2'b10;
        else if (corr_hold != '0) corr_hold <= corr_hold - 1'b1;
    end

    // Restart S1 whenever the S2 (mBTB + TAGE) merged prediction differs from
    // the fast path that was sent to fetch.  A pure CFI/direction difference
    // (same next PC) also restarts so the next block is re-fetched with the
    // repaired history.
    assign corr_needed = !flush && shadow1_valid && shadow1_accepted
                      && (corr_hold == '0)
                      && ((merged_npc != shadow1_fast_npc) || hist_diff);
    // only act if the target FTQ entry is still allocated (else the stream has
    // moved on and the correction must be dropped)
    assign corr_fire = corr_needed && ftq_corr_hit;

    // Metadata backfill is decoupled from the tail-invalidating correction: the
    // entry of every accepted block is rewritten so the back-end sees the S2
    // (TAGE / loop) metadata even when the direction/target did not change.
    // This must NOT wait for `corr_hold`: blocks accepted around a correction
    // still need their TAGE metadata for training.
    wire corr_wr_valid = !flush && shadow1_valid && shadow1_accepted;

    // When the S2 result changes the path, rewrite the entry with the merged
    // prediction and restart the stream (corr_fire).  Otherwise keep the S1
    // CFI list/targets/directions (so the FTQ stays consistent with the fetch
    // the BPU already made) and only backfill the S2 TAGE metadata.  The write
    // always happens so an entry that is popped in the same cycle still sends
    // its TAGE metadata to the IFU read mux (which gives the write priority).
    ftq_entry_t corr_entry;
    always_comb begin
        logic [$clog2(FETCH_WIDTH+1)-1:0] prefix;
        logic [GHR_WIDTH-1:0] h;
        h = shadow1_meta[0].ghr_before;
        prefix                    = '0;
        corr_entry.start_pc       = shadow1_start_pc;
        corr_entry.pred_cfi_valid = corr_fire ? merged_cfi_valid : shadow1_cfi_valid;
        corr_entry.pred_cfi_type  = corr_fire ? merged_cfi_type : shadow1_cfi_type;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            corr_entry.pred_meta[i] = shadow1_meta[i];
`ifdef CONFIG_FE_TAGE
            // S2 TAGE state is the only state the back-end may train with.
            corr_entry.pred_meta[i].tage_meta = tage_meta_slots[i];
`endif
            if (corr_fire) begin
                corr_entry.pred_meta[i].pred_taken = merged_taken[i];
                corr_entry.pred_meta[i].pred_target = merged_target[i];
                corr_entry.pred_meta[i].pred_type = merged_cfi_valid[i] ? merged_cfi_type[i] : CFI_NONE;
                corr_entry.pred_meta[i].ghr_before = h;
                corr_entry.pred_meta[i].cfi_prefix = prefix;
            end
            if (corr_entry.pred_cfi_valid[i]) begin
                prefix = prefix + 1'b1;
                h = (h << 1) | GHR_WIDTH'(corr_entry.pred_meta[i].pred_taken);
            end
        end
        corrected_ghr = h;
    end

    assign bpu_corr_valid    = corr_needed;
    assign bpu_corr_idx      = shadow1_widx;
    assign bpu_corr_wr_en    = corr_wr_valid;
    assign bpu_corr_wr_idx   = shadow1_widx;
    assign bpu_corr_wr_data  = corr_entry;
    assign bpu_corr_start_pc = shadow1_start_pc;

    // S2 correction information for TAGE's history repair.
    logic [$clog2(FETCH_WIDTH+1)-1:0] corr_cond_prefix;
    logic                             corr_is_cond;
    logic                             corr_taken;
    always_comb begin
        logic found_taken;
        found_taken      = 1'b0;
        corr_cond_prefix = '0;
        corr_is_cond     = 1'b0;
        corr_taken       = 1'b0;
        corr_ras_push    = 1'b0;
        corr_ras_pop     = 1'b0;
        corr_ras_addr    = '0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            if (!found_taken && merged_cfi_valid[i] && merged_taken[i]) begin
                found_taken = 1'b1;
                if (merged_cfi_type[i] == CFI_COND_BRANCH) begin
                    corr_is_cond = 1'b1;
                    corr_taken   = merged_dir[i];
                end
                if (merged_cfi_type[i] == CFI_CALL) begin
                    corr_ras_push = 1'b1;
                    corr_ras_addr = shadow1_start_pc + ADDR_WIDTH'((i + 1) * INST_BYTES);
                end else if (merged_cfi_type[i] == CFI_RETURN) begin
                    corr_ras_pop = 1'b1;
                end
            end else if (!found_taken && merged_cfi_valid[i]
                         && (merged_cfi_type[i] == CFI_COND_BRANCH)) begin
                corr_cond_prefix = corr_cond_prefix + 1'b1;
            end
        end
    end
`else
    assign mbtb_update_ready = 1'b1;
    assign corr_needed       = 1'b0;
    assign corr_fire         = 1'b0;
    assign merged_npc        = '0;
    assign corrected_ghr     = '0;
    assign tage_aligned      = 1'b0;
    assign bpu_corr_valid    = 1'b0;
    assign bpu_corr_idx      = '0;
    assign bpu_corr_wr_en    = 1'b0;
    assign bpu_corr_wr_idx   = '0;
    assign bpu_corr_wr_data  = '0;
    assign bpu_corr_start_pc = '0;
`endif

    // -----------------------------------------------------------------------
    // Loop predictor
    // -----------------------------------------------------------------------
`ifdef CONFIG_FE_LOOP_PRED
    logic [FETCH_WIDTH-1:0] loop_taken_slots;
    logic [FETCH_WIDTH-1:0] loop_pred_valid;
    logic [FETCH_WIDTH-1:0] loop_high_conf;
    logic                   loop_resp_valid;
    logic [FETCH_WIDTH-1:0] loop_s2_branch;
    logic [FETCH_WIDTH-1:0] loop_s2_taken;

`ifdef CONFIG_FE_TAGE
    // Per-index loop/TAGE selector (mirrors native `TageDirection.v`
    // loop_select): a 2-bit confidence per PC hash choosing the loop result
    // when it disagrees with TAGE and has been more accurate there.
    localparam int unsigned LOOP_SEL_WIDTH = 8;
    localparam int unsigned LOOP_SEL_NUM   = 1 << LOOP_SEL_WIDTH;
    logic [1:0] loop_select[LOOP_SEL_NUM];
    logic [FETCH_WIDTH-1:0] use_loop_slots;
    logic [FETCH_WIDTH-1:0] use_loop_s2_slots;

    function automatic logic [LOOP_SEL_WIDTH-1:0] loop_sel_index(input logic [ADDR_WIDTH-1:0] pc);
        loop_sel_index = '0;
        for (int b = 2; b < ADDR_WIDTH; b += LOOP_SEL_WIDTH)
        loop_sel_index = loop_sel_index ^ pc[b+:LOOP_SEL_WIDTH];
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int j = 0; j < LOOP_SEL_NUM; j++) loop_select[j] <= 2'b00;
        end else if (update_en && is_branch_meta && update_meta.pred_meta.loop_override
                     && (update_meta.pred_meta.loop_taken
                         != update_meta.pred_meta.tage_meta.tage_pred)) begin
            logic [LOOP_SEL_WIDTH-1:0] idx;
            idx = loop_sel_index(update_meta.update_pc);
            if (update_meta.pred_meta.loop_taken == update_meta.actual_taken) begin
                if (loop_select[idx] != 2'b11) loop_select[idx] <= loop_select[idx] + 1'b1;
            end else if (update_meta.pred_meta.tage_meta.tage_pred == update_meta.actual_taken) begin
                if (loop_select[idx] != 2'b00) loop_select[idx] <= loop_select[idx] - 1'b1;
            end
        end
    end

    // S2 loop/TAGE selector, aligned with shadow1 (the S1 fast-path metadata
    // that was sent to fetch).  TAGE's S2 direction yields to the loop result
    // exactly where the S1 fast path chose the loop predictor.
    always_comb begin
        logic [ADDR_WIDTH-1:0] pc;
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            pc = shadow1_start_pc + ADDR_WIDTH'(s * INST_BYTES);
            // S2 must honour the same loop/TAGE choice the S1 fast path made;
            // otherwise TAGE silently overrides a loop prediction that the
            // selector had already learned is better on this PC.
            use_loop_s2_slots[s] = shadow1_meta[s].loop_override
                                && loop_select[loop_sel_index(pc)][1];
        end
    end

    // The loop cursor is advanced at S2 with the final released direction (not
    // the S1 fast direction), matching the native BPU.  Only loop-overridden
    // conditional branches move the cursor.
    always_comb begin
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            loop_s2_branch[s] = merged_on_path[s] && merged_cfi_valid[s]
                             && (merged_cfi_type[s] == CFI_COND_BRANCH)
                             && shadow1_meta[s].loop_override;
            loop_s2_taken[s] = merged_dir[s];
        end
    end
`endif

    /* verilator lint_off PINCONNECTEMPTY */
    loop_predictor loop_predictor_u (
        .clk            (clk),
        .rst            (rst),
        .req_valid      (issue),
        .resp_valid     (loop_resp_valid),
        .fetch_pc       (fetch_pc_s0),
        .pred_taken     (loop_taken_slots),
        .pred_valid     (loop_pred_valid),
        .pred_high_conf (loop_high_conf),
`ifdef CONFIG_FE_TAGE
        .spec_valid(1'b0), .spec_branch('0), .spec_on_path('0), .spec_pred_taken('0),
`else
        .spec_valid(w_fire), .spec_branch(spec_branch_slots),
        .spec_on_path(spec_on_path_slots), .spec_pred_taken(pred_taken),
`endif
        .flush          (flush),
        .corr           (corr_fire),
`ifdef CONFIG_FE_TAGE
        .s2_spec_valid(!flush && shadow1_valid && shadow1_accepted && tage_aligned),
        .s2_fetch_pc(shadow1_start_pc), .s2_loop_branch(loop_s2_branch), .s2_taken(loop_s2_taken),
`else
        .s2_spec_valid(1'b0), .s2_fetch_pc('0), .s2_loop_branch('0), .s2_taken('0),
`endif
        .update_en      (update_en),
        .update_pc      (update_meta.update_pc),
        .update_target  (update_meta.actual_target),
        .actual_taken   (update_meta.actual_taken),
        .is_branch      (is_branch_meta),
        .commit_valid(bpu_update_valid), .commit_update(bpu_update)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    always_comb begin
        logic [ADDR_WIDTH-1:0] slot_pc;
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            slot_pc = resp_pc_r + ADDR_WIDTH'(s * INST_BYTES);
            loop_override_slots[s] = loop_resp_valid && loop_pred_valid[s] && loop_high_conf[s];
`ifdef CONFIG_FE_TAGE
            // loop > TAGE only where the per-index selector has learned the
            // loop result is better (native `loop_select`).
            use_loop_slots[s] = loop_override_slots[s] && loop_select[loop_sel_index(slot_pc)][1];
            if (use_loop_slots[s]) begin
                dir_taken_slots[s] = loop_taken_slots[s];
            end else begin
                dir_taken_slots[s] = base_dir_taken_slots[s];
            end
`else
            if (loop_override_slots[s]) begin
                dir_taken_slots[s] = loop_taken_slots[s];
            end else begin
                dir_taken_slots[s] = base_dir_taken_slots[s];
            end
`endif
        end
    end
`else
    assign dir_taken_slots = base_dir_taken_slots;
`endif

    // ==================================================================
    // 1-cycle fast direction predictor: only compiled when it is actually on
    // the S1 path (TAGE disabled) or when uTAGE uses it as its base.
    // ==================================================================
`ifdef FE_S1_FAST_DIR
`ifdef CONFIG_FE_BIMODAL
    // Bimodal PHT, one direction per window slot
    bimodal #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .PHT_WIDTH (PHT_WIDTH)
    ) bimodal_u (
        .clk             (clk),
        .rst             (rst),
        .req_valid       (issue),
        .fetch_pc        (fetch_pc_s0),
        .resp_valid      (),
        .pred_taken_slots(hw_dir_taken_slots),
        .update_en       (update_en && is_branch_meta),
        .update_pc       (update_meta.update_pc),
        .actual_taken    (update_meta.actual_taken)
    );
`elsif CONFIG_FE_TOURNAMENT
    chooser_meta_t [          FETCH_WIDTH-1:0] tour_meta;

    /* verilator lint_off PINCONNECTEMPTY */
    tournament tournament_u (
        .clk                  (clk),
        .rst                  (rst),
        .req_valid            (issue),
        .fetch_pc             (fetch_pc_s0),
        .resp_valid           (),
        .resp_pc              (),
        .pred_taken_slots     (hw_dir_taken_slots),
        .chooser_meta         (tour_meta),
        .predict_ghr          (predict_ghr),
        .update_en            (update_en),
        .is_branch            (is_branch_meta),
        .update_pc            (update_meta.update_pc),
        .actual_taken         (update_meta.actual_taken),
        .update_gshare_taken  (update_meta.pred_meta.chooser_meta.update_gshare_taken),
        .update_bimodal_taken (update_meta.pred_meta.chooser_meta.update_bimodal_taken),
        .update_ghr           (update_meta.pred_meta.chooser_meta.pred_ghr)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    assign chooser_meta_slots = tour_meta;
`else
    assign hw_dir_taken_slots = '0;
`endif
`else
    assign hw_dir_taken_slots = '0;
`endif

    // Keep the metadata field driven even when the tournament is not built.
`ifdef CONFIG_FE_TOURNAMENT
`ifndef FE_S1_FAST_DIR
    assign chooser_meta_slots = '0;
`endif
`ifdef CONFIG_FE_BIMODAL
    assign chooser_meta_slots = '0;
`endif
`endif

    // ==================================================================
    // TAGE direction.  TAGE is a two-cycle predictor aligned with mBTB: S1
    // uses TAGE's provisional result (or uTAGE / the fast predictor when TAGE
    // is off), while S2 merges TAGE over the union of uBTB/mBTB CFIs.  When the
    // S2 result differs from what S1 sent to fetch, `corr_fire` restarts the
    // fetch stream and TAGE rebuilds its speculative history from the
    // block-before checkpoint.
    // ==================================================================
`ifdef CONFIG_FE_TAGE
    /* verilator lint_off PINCONNECTEMPTY */
    tage tage_u (
        .clk(clk),
        .rst(rst),
        .req_valid(issue),
        .fetch_pc(fetch_pc_s0),
        .resp_valid(tage_resp_valid),
        .resp_pc(tage_resp_pc),
        .pred_cfi_valid(merged_cfi_valid),
        .pred_cfi_type(merged_cfi_type),
        .pred_taken_slots(tage_taken_slots),
        .tage_meta(tage_meta_slots),
        .s1_resp_valid(),
        .s1_cfi_valid(pred_cfi_valid),
        .s1_cfi_type(pred_cfi_type),
        .s1_fast_dir(hw_dir_taken_slots),
        .s1_pred_taken_slots(s1_tage_taken_slots),
        .s1_tage_meta(s1_tage_meta_slots),
        .spec_valid(w_fire),
        .spec_branch(spec_branch_slots),
        .spec_on_path(spec_on_path_slots),
        .spec_pred_taken(pred_taken),
        .flush(flush),
        .redirect_kind(local_repair_valid ? REDIRECT_BRANCH : redirect_kind),
        .redirect_actual_taken(local_repair_valid ? redirect_info.actual_taken : redirect_actual_taken),
        .redirect_meta(redirect_info.pred_meta.tage_meta),
        .redirect_is_branch(redirect_info.actual_cfi_type == CFI_COND_BRANCH),
        .commit_valid(bpu_update_valid), .commit_update(bpu_update),
        .update_en(update_en),
        .is_branch(is_branch_meta),
        .update_pc(update_meta.update_pc),
        .actual_taken(update_meta.actual_taken),
        .update_meta(update_meta.pred_meta.tage_meta),
        .corr_valid(corr_fire),
        .corr_ckpt_ptr        (tage_aligned ? tage_meta_slots[0].ckpt_ptr
                                            : shadow1_meta[0].tage_meta.ckpt_ptr),
        .corr_cond_prefix(corr_cond_prefix),
        .corr_is_cond(corr_is_cond),
        .corr_taken(corr_taken)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    assign base_dir_taken_slots = s1_tage_taken_slots;
`else
    assign base_dir_taken_slots = hw_dir_taken_slots;
`endif

    // ==================================================================
    // Target predictor: CONFIG_FE_UBTB / CONFIG_FE_MBTB
    // (CONFIG_FE_MBTB is not wired into the BPU yet, so it falls back to a
    //  sequential next-PC with no CFI information for now)
    // ==================================================================
`ifdef CONFIG_FE_UBTB
    /* verilator lint_off PINCONNECTEMPTY */
    ubtb ubtb_u (
        .clk              (clk),
        .rst              (rst),
        .req_valid        (issue),
        .fetch_pc         (fetch_pc_s0),
        .resp_valid       (),
        .resp_pc          (resp_pc_r),
        .pred_cfi_valid   (pred_cfi_valid),
        .pred_cfi_type    (pred_cfi_type),
        .pred_target      (raw_pred_target),
        .update_en        (update_en),
        .update_ready     (ubtb_update_ready),
        .update_pc        (update_meta.update_pc),
        .update_target    (update_target_info),
        .actual_taken     (update_meta.actual_taken),
        .update_pred_taken(update_meta.pred_meta.pred_taken)
    );
`else
    /* verilator lint_on PINCONNECTEMPTY */
    assign ubtb_update_ready = 1'b1;
    always_ff @(posedge clk) begin
        if (rst) resp_pc_r <= '0;
        else if (issue) resp_pc_r <= fetch_pc_s0;
    end
    assign pred_cfi_valid  = '0;
    assign pred_cfi_type   = '0;
    assign raw_pred_target = '0;
`endif
`ifdef CONFIG_FE_TAGE
`ifdef DPIC
    // TAGE own-direction accuracy probe (one call per committed conditional
    // branch carrying valid TAGE metadata).
    import "DPI-C" function void branch_difftest_on_ares_tage(
        input int valid,
        input int provided,
        input int correct
    );
    always_ff @(posedge clk) begin
        if (!rst) begin
            branch_difftest_on_ares_tage(
                int'(update_en && is_branch_meta && update_meta.pred_meta.tage_meta.valid),
                int'(update_en && is_branch_meta && update_meta.pred_meta.tage_meta.valid
                     && update_meta.pred_meta.tage_meta.provided),
                int'(update_meta.pred_meta.tage_meta.tage_pred == update_meta.actual_taken));
        end
    end
`endif
`endif

`ifdef FE_S1_FAST_DIR
`undef FE_S1_FAST_DIR
`endif
`ifdef FE_S1_SPEC
`undef FE_S1_SPEC
`endif
`ifdef FE_S2_STAGE
`undef FE_S2_STAGE
`endif
endmodule
