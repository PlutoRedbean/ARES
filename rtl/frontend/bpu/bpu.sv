// Branch prediction unit wrapper.
//
// The BPU is decoupled from the IFU: it walks the speculative fetch stream on
// its own using `gen_pc` and emits one prediction per cycle (when it is not
// responding to the previous request).  A prediction describes a Fetch Block
// starting at `start_pc`.
//
// The BTB is keyed by the FETCH_WIDTH aligned block and holds up to
// FETCH_WIDTH CFI slots.  It already returns one target per window slot, so the
// BPU simply combines that with the per-slot direction of the bimodal
// predictor and derives the next PC from the first CFI predicted taken.
//
// DIR_TYPE (fe_pkg::DIR_TYPE) selects the direction predictor:
//   0 : always-not-taken (kept for A/B testing the integration)
//   1 : Bimodal direction predictor + uBTB target predictor
//   2 : Tournament (Gshare + Bimodal) direction predictor + uBTB
// Both predictors of a real configuration are 1-cycle pipelined; a taken
// direction only redirects the fetch stream when the BTB also knows a target.
//
// The RAS (RAS_ON) and the loop predictor (LOOP_PRED_ON) are independent of the
// direction predictor choice: the loop predictor sits beside either Bimodal or
// Tournament and only overrides a slot when it reports a high-confidence hit.
module bpu (
    input logic clk,
    input logic rst,

    // redirect from the back-end
    input logic                            flush,
    input logic [fe_pkg::ADDR_WIDTH - 1:0] redirect_pc,

    input fe_pkg::fe_redirect_kind_t redirect_kind,
    input logic [fe_pkg::GHR_WIDTH-1:0] redirect_ghr_before,
    input logic redirect_actual_taken,
    input logic local_repair_valid,
    input logic [fe_pkg::GHR_WIDTH-1:0] local_repair_ghr,

    // predict request / response
    input  logic                                          ftq_wready,
    output logic                                          ftq_wvalid,
    output logic               [fe_pkg::ADDR_WIDTH - 1:0] bpu_resp_pc,
    output fe_pkg::ftq_entry_t                            ftq_wdata,

    input logic [1:0] bpu_update_valid,
    input fe_pkg::bpu_update_t bpu_update [2],
    output logic [1:0] bpu_update_credit
);
    import fe_pkg::*;

    localparam int unsigned BLOCK_BYTES = FETCH_WIDTH * INST_BYTES;
    localparam logic [ADDR_WIDTH-1:0] BLOCK_MASK = ADDR_WIDTH'(BLOCK_BYTES - 1);

    logic update_en;
    bpu_update_t update_meta;
    logic [GHR_WIDTH-1:0] ghr_spec, ghr_at_lookup, ghr_commit_next, block_ghr_next;
    bpu_commit_queue commit_queue (
        .clk(clk), .rst(rst), .train_ready(1'b1), .update_valid(bpu_update_valid), .update(bpu_update),
        .credit(bpu_update_credit), .train_valid(update_en), .train(update_meta),
        .ghr_commit_next(ghr_commit_next)
    );
    always_ff @(posedge clk) begin
        if (rst) begin ghr_spec <= '0; ghr_at_lookup <= '0; end
        else begin
            if (issue) ghr_at_lookup <= ghr_spec;
            if (flush) begin
                if (local_repair_valid) ghr_spec <= local_repair_ghr;
                else if (redirect_kind == REDIRECT_BRANCH)
                    ghr_spec <= (redirect_ghr_before << 1) | GHR_WIDTH'(redirect_actual_taken);
                else ghr_spec <= ghr_commit_next;
            end else if (ftq_wvalid && ftq_wready) ghr_spec <= block_ghr_next;
        end
    end

    wire              is_branch_meta = (update_meta.actual_cfi_type == CFI_COND_BRANCH);
    btb_target_info_t update_target_info;

    always_comb begin
        update_target_info.start_pc   = update_meta.update_pc & ~BLOCK_MASK;
        update_target_info.target_pc  = update_meta.actual_target;
        update_target_info.cfi_type   = update_meta.actual_cfi_type;
        update_target_info.cfi_offset = FETCH_WIDTH'((update_meta.update_pc & BLOCK_MASK) >> 2);
    end

    logic       [ADDR_WIDTH - 1:0]                 fetch_pc;
    logic       [ADDR_WIDTH - 1:0]                 resp_pc_r;
    logic       [ADDR_WIDTH - 1:0]                 snpc;
    logic       [ADDR_WIDTH - 1:0]                 dnpc;

    // per-slot prediction
    logic       [ FETCH_WIDTH-1:0]                 pred_cfi_valid;  // BTB knows a CFI here
    cfi_type_t  [ FETCH_WIDTH-1:0]                 pred_cfi_type;
    logic       [ FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] raw_pred_target;  // from the BTB
    logic       [ FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target;  // BTB + RAS
    logic       [ FETCH_WIDTH-1:0]                 pred_taken;
    logic       [ FETCH_WIDTH-1:0]                 dir_taken_slots;
    pred_meta_t [ FETCH_WIDTH-1:0]                 pred_meta;

    // Direction of the DIR_TYPE-selected predictor, before the (optional) loop
    // predictor override is applied.
    logic       [ FETCH_WIDTH-1:0]                 base_dir_taken_slots;

`ifdef TOURNAMENT_ON
    chooser_meta_t [FETCH_WIDTH-1:0] chooser_meta_slots;
`endif
`ifdef LOOP_PRED_ON
    logic [FETCH_WIDTH-1:0] loop_override_slots;
`endif


    logic                  bpu_predicted_taken;
    logic [ADDR_WIDTH-1:0] predicted_pc;

    // one prediction every other cycle: never issue while the previous one is
    // being returned (keeps the 1-cycle predictor/FTQ write hazard-free)
    wire                   issue = ftq_wready && !ftq_wvalid && !flush;

    gen_pc #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .RESET_VEC (RESET_VEC)
    ) gen_pc_u (
        .clk        (clk),
        .rst        (rst),
        .flush      (flush),
        .redirect_pc(redirect_pc),
        .ena        (ftq_wvalid && !flush),
        .dnpc       (dnpc),
        .pc         (fetch_pc)
    );

    // a conditional branch takes the direction predictor, a jump is always taken
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            pred_taken[i] = pred_cfi_valid[i] && ((pred_cfi_type[i] != CFI_COND_BRANCH) || dir_taken_slots[i]);
        end
    end

    // -----------------------
    // Return address stack 
    // -----------------------
`ifdef RAS_ON
    logic                  ras_top_valid;
    logic [ADDR_WIDTH-1:0] ras_top_addr;
    logic                  block_push;
    logic                  block_pop;
    logic [ADDR_WIDTH-1:0] block_ret_addr;

    // one speculative push/pop per predicted block, taken from its first
    // CFI predicted taken (a call/return is always taken and ends the block)
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
        .clk        (clk),
        .rst        (rst),
        .top_valid  (ras_top_valid),
        .top_addr   (ras_top_addr),
        .spec_push  (ftq_wvalid && block_push),
        .spec_pop   (ftq_wvalid && block_pop),
        .spec_addr  (block_ret_addr),
        .flush      (flush),
        .commit_valid(bpu_update_valid),
        .commit_update(bpu_update)
    );
`endif

    // final per-slot target: a valid RAS entry overrides the BTB for returns
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
`ifdef RAS_ON
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
        // Traverse in reverse order, so pred_target will choose the first CFI
        // predicted taken
        for (int i = FETCH_WIDTH - 1; i >= 0; i--) begin
            if (pred_taken[i]) begin
                bpu_predicted_taken = 1'b1;
                predicted_pc        = pred_target[i];
            end
        end
    end

    assign snpc = resp_pc_r + BLOCK_BYTES;
    assign dnpc = bpu_predicted_taken ? predicted_pc : snpc;
    assign bpu_resp_pc = resp_pc_r;

    // Materialize full recovery snapshots before the FTQ. Predictor lookup
    // history remains separately captured in chooser_meta for exact training.
    always_comb begin
        logic [GHR_WIDTH-1:0] h;
        logic on_path;
        h = ghr_at_lookup;
        on_path = 1'b1;
        for (int i=0; i<FETCH_WIDTH; i++) begin
            pred_meta[i] = '0;
            pred_meta[i].pred_target = pred_target[i];
            pred_meta[i].pred_taken = pred_taken[i];
            pred_meta[i].pred_type = pred_cfi_valid[i] ? pred_cfi_type[i] : CFI_NONE;
            pred_meta[i].ghr_before = h;
`ifdef TOURNAMENT_ON
            pred_meta[i].chooser_meta = chooser_meta_slots[i];
`endif
`ifdef LOOP_PRED_ON
            pred_meta[i].loop_override = loop_override_slots[i];
`endif
            if (on_path && pred_cfi_valid[i]) begin
                h = (h << 1) | GHR_WIDTH'(pred_taken[i]);
                if (pred_taken[i]) on_path = 1'b0;
            end
        end
        block_ghr_next = h;
    end

    assign ftq_wdata = '{
            start_pc: resp_pc_r,
            pred_cfi_valid: pred_cfi_valid,
            pred_cfi_type: pred_cfi_type,
            pred_meta: pred_meta
        };

    // -----------------------------------------------------------------------
    // Loop predictor.  It sits beside the DIR_TYPE-selected direction predictor
    // and only overrides a slot when it reports a high-confidence hit, so it can
    // be enabled independently of Bimodal/Tournament.
    // -----------------------------------------------------------------------
`ifdef LOOP_PRED_ON
    logic [FETCH_WIDTH-1:0] loop_taken_slots;
    logic [FETCH_WIDTH-1:0] loop_pred_valid;
    logic [FETCH_WIDTH-1:0] loop_high_conf;
    logic                   loop_resp_valid;

    // on-path conditional branches of the block being predicted: used by
    // the loop predictor to advance its speculative iteration counters
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

    /* verilator lint_off PINCONNECTEMPTY */
    loop_predictor loop_predictor_u (
        .clk            (clk),
        .rst            (rst),
        .req_valid      (issue),
        .resp_valid     (loop_resp_valid),
        .fetch_pc       (fetch_pc),
        .pred_taken     (loop_taken_slots),
        .pred_valid     (loop_pred_valid),
        .pred_high_conf (loop_high_conf),
        .spec_valid     (ftq_wvalid),
        .spec_branch    (spec_branch_slots),
        .spec_on_path   (spec_on_path_slots),
        .spec_pred_taken(pred_taken),
        .flush          (flush),
        .update_en      (update_en),
        .update_pc      (update_meta.update_pc),
        .actual_taken   (update_meta.actual_taken),
        .is_branch      (is_branch_meta),
        .commit_valid(bpu_update_valid), .commit_update(bpu_update)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // selector: only a confident loop prediction overrides the base direction
    always_comb begin
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            loop_override_slots[s] = loop_resp_valid && loop_pred_valid[s] && loop_high_conf[s];
            if (loop_override_slots[s]) begin
                dir_taken_slots[s] = loop_taken_slots[s];
            end else begin
                dir_taken_slots[s] = base_dir_taken_slots[s];
            end
        end
    end
`else
    assign dir_taken_slots = base_dir_taken_slots;
`endif

    if (DIR_TYPE == 1) begin : g_bimodal_btb
        logic dir_resp_valid;
        logic btb_resp_valid;

        // direction predictor (Bimodal PHT), one direction per window slot.
        // Like the reference model, only conditional branches train it.
        bimodal #(
            .ADDR_WIDTH(ADDR_WIDTH),
            .PHT_WIDTH (PHT_WIDTH)
        ) bimodal_u (
            .clk             (clk),
            .rst             (rst),
            .req_valid       (issue),
            .fetch_pc        (fetch_pc),
            .resp_valid      (dir_resp_valid),
            .pred_taken_slots(base_dir_taken_slots),
            .update_en       (update_en && is_branch_meta),
            .update_pc       (update_meta.update_pc),
            .actual_taken    (update_meta.actual_taken)
        );

        // target predictor (multi-target BTB, per-slot targets)
        ubtb ubtb_u (
            .clk           (clk),
            .rst           (rst),
            .req_valid     (issue),
            .fetch_pc      (fetch_pc),
            .resp_valid    (btb_resp_valid),
            .resp_pc       (resp_pc_r),
            .pred_cfi_valid(pred_cfi_valid),
            .pred_cfi_type (pred_cfi_type),
            .pred_target   (raw_pred_target),
            .update_en     (update_en),
            .update_pc     (update_meta.update_pc),
            .update_target (update_target_info),
            .actual_taken  (update_meta.actual_taken)
        );

        // both predictors are 1-cycle pipelined, so their responses line up
        assign ftq_wvalid = dir_resp_valid && btb_resp_valid;
    end else if (DIR_TYPE == 2) begin : g_tournament_btb
`ifdef TOURNAMENT_ON
        logic                                      dir_resp_valid;
        logic                                      btb_resp_valid;

        chooser_meta_t [          FETCH_WIDTH-1:0] tour_meta;

        // direction predictor (Tournament = Gshare + Bimodal)
        /* verilator lint_off PINCONNECTEMPTY */
        tournament tournament_u (
            .clk                  (clk),
            .rst                  (rst),
            .req_valid            (issue),
            .fetch_pc             (fetch_pc),
            .resp_valid           (dir_resp_valid),
            .resp_pc              (),
            .pred_taken_slots     (base_dir_taken_slots),
            .chooser_meta         (tour_meta),
            .predict_ghr          (ghr_spec),
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

        // target predictor (multi-target BTB, per-slot targets)
        ubtb ubtb_u (
            .clk           (clk),
            .rst           (rst),
            .req_valid     (issue),
            .fetch_pc      (fetch_pc),
            .resp_valid    (btb_resp_valid),
            .resp_pc       (resp_pc_r),
            .pred_cfi_valid(pred_cfi_valid),
            .pred_cfi_type (pred_cfi_type),
            .pred_target   (raw_pred_target),
            .update_en     (update_en),
            .update_pc     (update_meta.update_pc),
            .update_target (update_target_info),
            .actual_taken  (update_meta.actual_taken)
        );

        // both predictors are 1-cycle pipelined, so their responses line up
        assign ftq_wvalid = dir_resp_valid && btb_resp_valid;
`endif
    end else begin : g_always_not_taken
        logic req_valid_q;

        always_ff @(posedge clk) begin
            if (rst) begin
                req_valid_q <= 1'b0;
                resp_pc_r   <= '0;
            end else begin
                req_valid_q <= issue;
                resp_pc_r   <= fetch_pc;
            end
        end

        assign ftq_wvalid           = req_valid_q;
        assign pred_cfi_valid       = '0;
        assign pred_cfi_type        = '0;
        assign raw_pred_target      = '0;
        assign base_dir_taken_slots = '0;
`ifdef TOURNAMENT_ON
        assign chooser_meta_slots = '0;
`endif
    end
endmodule
