// TAGE conditional-branch direction predictor (docs/tage-design.md).
//
// Two-cycle predictor used as the BPU S2 precise direction, aligned with the
// two-cycle mBTB response:
//   s0  : index/tag hash from block PC + folded history, drive the tagged-table
//         SRAM read ports, push history checkpoint
//   s1  : capture the SRAM read data and the request state
//   s2  : tag match -> provider/alt select -> use-alt -> per-slot direction/meta,
//         using the S2 CFI list (the merged uBTB/mBTB CFI list)
//
// req_valid may be asserted every cycle; resp_valid is asserted two cycles later
// (s2).  History is advanced speculatively on the S1 fast-path edge (spec_*).  If
// the S2 TAGE result changes the directions/CFI coverage seen in S1, the BPU
// restarts the stream and asserts corr_valid so the history is rebuilt from the
// block-before checkpoint with the corrected path.
//
// Implementation notes / deliberate simplifications vs. docs/tage-design.md:
//   * The T0 base table is banked by the *instruction slot* rather than the
//     conditional-branch ordinal, and its index is the branch PC (fetch_pc +
//     slot*INST_BYTES); with FETCH_WIDTH == TAGE_BASE_NUM_BANKS == 4 this is
//     equivalent to "the s-th conditional branch reads bank s" and reads cleanly
//     in s1.  meta.slot_id carries that instruction slot (T0 bank); the tagged
//     slot of a branch is its cond_prefix.
//   * Allocation fires when TAGE's own direction is wrong and either the alt
//     disagrees or there is no tagged provider (the doc's literal
//     `tage_pred != alt_pred` would deadlock a predictor that never allocates).
//   * wr_bypass (§10.5) is replaced by the port-B combinational read-back: the
//     update always uses the current SRAM value when the {idx,tag} still matches,
//     which serialises back-to-back updates to the same entry the same way.
//   * REDIRECT_ARCH recomputes the folded histories from ghv_commit (§7.3);
//     REDIRECT_BRANCH restores them from the checkpoint.

`include "ares_autoconf.vh"
`ifdef CONFIG_FE_TAGE
module tage (
    input logic clk,
    input logic rst,

    // ---------------- predict: 2-stage pipeline (s0 -> s1 -> s2) ----------------
    input logic                          req_valid,
    input logic [fe_pkg::ADDR_WIDTH-1:0] fetch_pc,

    // Final (S2) result, aligned with the mBTB response.
    output logic                                         resp_valid,
    output logic               [ fe_pkg::ADDR_WIDTH-1:0] resp_pc,
    // CFI list of the S2 block (union of uBTB and mBTB).
    input  logic               [fe_pkg::FETCH_WIDTH-1:0] pred_cfi_valid,
    input  fe_pkg::cfi_type_t  [fe_pkg::FETCH_WIDTH-1:0] pred_cfi_type,
    output logic               [fe_pkg::FETCH_WIDTH-1:0] pred_taken_slots,
    output fe_pkg::tage_meta_t [fe_pkg::FETCH_WIDTH-1:0] tage_meta,

    // Provisional (S1) result from the same read data, using the uBTB CFI
    // list.  It drives the S1 fast path so TAGE's speculative history is
    // self-consistent; the S2 result above then refines it with mBTB coverage.
    output logic                                         s1_resp_valid,
    input  logic               [fe_pkg::FETCH_WIDTH-1:0] s1_cfi_valid,
    input  fe_pkg::cfi_type_t  [fe_pkg::FETCH_WIDTH-1:0] s1_cfi_type,
    // S1 fast/base direction (the 1-cycle tournament/bimodal prediction).
    // uTAGE overrides it on a tagged hit.
    input  logic               [fe_pkg::FETCH_WIDTH-1:0] s1_fast_dir,
    output logic               [fe_pkg::FETCH_WIDTH-1:0] s1_pred_taken_slots,
    output fe_pkg::tage_meta_t [fe_pkg::FETCH_WIDTH-1:0] s1_tage_meta,

    // ---------------- speculative history ----------------
    input logic                           spec_valid,
    input logic [fe_pkg::FETCH_WIDTH-1:0] spec_branch,
    input logic [fe_pkg::FETCH_WIDTH-1:0] spec_on_path,
    input logic [fe_pkg::FETCH_WIDTH-1:0] spec_pred_taken,

    // ---------------- redirect recovery ----------------
    input logic                      flush,
    input fe_pkg::fe_redirect_kind_t redirect_kind,
    input logic                      redirect_actual_taken,
    input logic                      update_en,

    // ---------------- S2 internal direction correction (BPU) --------------
    // When the S2 merge (TAGE over S1) changes the predicted direction, the
    // speculative history must follow the corrected path exactly like a branch
    // redirect, otherwise the history keeps S1's (less accurate) directions and
    // TAGE degrades.  `corr_meta` is the first-taken CFI of the corrected
    // block; `corr_cond_prefix` is the number of on-path conditional branches
    // before it (all not-taken).  When the block has no taken CFI, `is_cond=0`
    // and `corr_cond_prefix` is the total on-path conditional-branch count.
    input logic                                      corr_valid,
    input logic [   fe_pkg::TAGE_CKPT_PTR_WIDTH-1:0] corr_ckpt_ptr,
    input logic [fe_pkg::TAGE_COND_PREFIX_WIDTH-1:0] corr_cond_prefix,
    input logic                                      corr_is_cond,
    input logic                                      corr_taken,

    // ---------------- update ----------------
    input logic                                        is_branch,
    input logic               [fe_pkg::ADDR_WIDTH-1:0] update_pc,
    input logic                                        actual_taken,
    input fe_pkg::tage_meta_t                          update_meta
);
    import fe_pkg::*;
    import tage_pkg::*;

    localparam int unsigned BANK_W = $clog2(TAGE_NUM_BANKS);

    // ==================================================================
    // History layer
    // ==================================================================
    tage_hist_t hist_r;  // speculative history
    logic [TAGE_GHV_WIDTH-1:0] ghr_commit;  // committed history (REDIRECT_ARCH)

    // Checkpoints store only the raw GHV.  The folded histories are a pure
    // function of the GHV (`tage_hist_collapse`), so keeping them out of the
    // checkpoint array cuts its width by ~2x with no behavioural change.
    logic [TAGE_GHV_WIDTH-1:0] ckpt_mem[TAGE_CKPT_DEPTH];
    logic [TAGE_CKPT_PTR_WIDTH-1:0] ckpt_wptr;

    // ==================================================================
    // Storage: 4 tagged tables + base table + use_alt_on_na + epoch
    // ==================================================================
    logic tbl_rd_en;
    logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] tbl_rd_idx;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0] tbl_rd_valid;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_TAG_WIDTH-1:0] tbl_rd_tag;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_CTR_WIDTH-1:0] tbl_rd_ctr;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_USEFUL_WIDTH-1:0] tbl_rd_useful;

    logic [TAGE_NUM_TABLES-1:0] tbl_wr_en;
    logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] tbl_wr_idx;
    logic [TAGE_NUM_TABLES-1:0][TAGE_SLOT_WIDTH-1:0] tbl_wr_slot;
    logic [TAGE_NUM_TABLES-1:0] tbl_wr_valid;
    logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0] tbl_wr_tag;
    logic [TAGE_NUM_TABLES-1:0][TAGE_CTR_WIDTH-1:0] tbl_wr_ctr;
    logic [TAGE_NUM_TABLES-1:0][TAGE_USEFUL_WIDTH-1:0] tbl_wr_useful;

    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0] tbl_up_valid;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_TAG_WIDTH-1:0] tbl_up_tag;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_CTR_WIDTH-1:0] tbl_up_ctr;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_USEFUL_WIDTH-1:0] tbl_up_useful;

    generate
        for (genvar t = 0; t < TAGE_NUM_TABLES; t++) begin : g_tag
            tage_tag_array u_tag (
                .clk(clk),
                .rst(rst),
                .rd_en(tbl_rd_en),
                .rd_idx(tbl_rd_idx[t]),
                .rd_valid(tbl_rd_valid[t]),
                .rd_tag(tbl_rd_tag[t]),
                .rd_ctr(tbl_rd_ctr[t]),
                .rd_useful(tbl_rd_useful[t]),
                .up_idx(update_meta.idx[t]),
                .up_valid(tbl_up_valid[t]),
                .up_tag(tbl_up_tag[t]),
                .up_ctr(tbl_up_ctr[t]),
                .up_useful(tbl_up_useful[t]),
                .wr_en(tbl_wr_en[t]),
                .wr_idx(tbl_wr_idx[t]),
                .wr_slot(tbl_wr_slot[t]),
                .wr_valid(tbl_wr_valid[t]),
                .wr_tag(tbl_wr_tag[t]),
                .wr_ctr(tbl_wr_ctr[t]),
                .wr_useful(tbl_wr_useful[t])
            );
        end
    endgenerate

    logic [  TAGE_BASE_NUM_BANKS-1:0][1:0] base_ctr_rd;
    logic                                  t0_wr_en;
    logic [   TAGE_SLOT_ID_WIDTH-1:0]      t0_wr_bank;
    logic [TAGE_BASE_INDEX_WIDTH-1:0]      t0_wr_idx;
    logic [                      1:0]      t0_wr_ctr;

    tage_base_array u_base (
        .clk(clk),
        .rst(rst),
        .rd_en(tbl_rd_en),
        .rd_idx(base_idx_s0),
        .rd_ctr(base_ctr_rd),
        .wr_en(t0_wr_en),
        .wr_bank(t0_wr_bank),
        .wr_idx(t0_wr_idx),
        .wr_ctr(t0_wr_ctr)
    );

    // Global adaptive policy (native `TageDirection.v`): use the alternate
    // prediction when the provider is weak and this has been more accurate.
    logic [3:0] use_alt_na;

    logic [TAGE_NUM_BANKS-1:0] useful_epoch;
    logic [11:0] useful_reset_ctr;

    // ==================================================================
    // s0 : hash from block PC + folded history
    // ==================================================================
    logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] idx_s0;
    logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0] tag_s0;
    logic [TAGE_BASE_NUM_BANKS-1:0][TAGE_BASE_INDEX_WIDTH-1:0] base_idx_s0;

    // History forwarding: the request being hashed this cycle is the *next*
    // block, so its history must include the block currently in s1 (the one
    // whose prediction is being produced right now).  Using the registered
    // `hist_r` leaves a one-block lag; the native predictor advances
    // `global_history` into the next request at the same edge and has no lag.
    // The push uses the unrolled fast fold form; the same value is reused for
    // the speculative `hist_r` update below.
    tage_hist_t hist_fwd;
    always_comb begin
        logic [ADDR_WIDTH-1:0] bpc;
        hist_fwd = spec_valid ?
            tage_hist_push_block_fast(hist_r, spec_branch & spec_on_path, spec_pred_taken) : hist_r;
        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            idx_s0[t] = tage_index(fetch_pc, hist_fwd.fold_idx[t], t);
            tag_s0[t] = tage_tag(fetch_pc, hist_fwd.fold_tag1[t], hist_fwd.fold_tag2[t], t);
        end
        for (int s = 0; s < TAGE_BASE_NUM_BANKS; s++) begin
            bpc = fetch_pc + ADDR_WIDTH'(s * INST_BYTES);
            base_idx_s0[s] = bpc[TAGE_BASE_INDEX_WIDTH+1:2];
        end
    end

    // ==================================================================
    // Two-cycle pipeline: s0 hashes the block PC and drives the SRAM read
    // ports, s1 captures the read data + request state, s2 performs the
    // provider/selection using the S2 (merged uBTB/mBTB) CFI list.
    //
    // The S2 CFI list is required because TAGE must know which fetch slots are
    // conditional branches and their ordinal inside the block.  mBTB provides
    // the same two-cycle latency as TAGE, so the two results are merged in S2.
    // ==================================================================
    logic s1_valid;
    logic [ADDR_WIDTH-1:0] s1_pc;
    logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] s1_idx;
    logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0] s1_tag;
    logic [TAGE_BASE_NUM_BANKS-1:0][TAGE_BASE_INDEX_WIDTH-1:0] s1_base_idx;
    logic [TAGE_CKPT_PTR_WIDTH-1:0] s1_ckpt_ptr;

    logic s2_valid;
    logic [ADDR_WIDTH-1:0] s2_pc;
    logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] s2_idx;
    logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0] s2_tag;
    logic [TAGE_BASE_NUM_BANKS-1:0][TAGE_BASE_INDEX_WIDTH-1:0] s2_base_idx;
    logic [TAGE_BASE_NUM_BANKS-1:0][1:0] s2_base_ctr;
    logic [TAGE_CKPT_PTR_WIDTH-1:0] s2_ckpt_ptr;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0] s2_rd_valid;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_TAG_WIDTH-1:0] s2_rd_tag;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_CTR_WIDTH-1:0] s2_rd_ctr;
    logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_USEFUL_WIDTH-1:0] s2_rd_useful;

`ifdef CONFIG_FE_UTAGE
    // uTAGE (S1 fast predictor) outputs and their S1->S2 pipeline copy.
    logic        [FETCH_WIDTH-1:0] utage_pred_taken_c;
    utage_meta_t [FETCH_WIDTH-1:0] utage_meta_c;
    utage_meta_t [FETCH_WIDTH-1:0] s2_utage_meta;
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s1_pc <= '0;
            s1_idx <= '0;
            s1_tag <= '0;
            s1_base_idx <= '0;
            s1_ckpt_ptr <= '0;
            s2_valid <= 1'b0;
            s2_pc <= '0;
            s2_idx <= '0;
            s2_tag <= '0;
            s2_base_idx <= '0;
            s2_base_ctr <= '0;
            s2_ckpt_ptr <= '0;
            s2_rd_valid <= '0;
            s2_rd_tag <= '0;
            s2_rd_ctr <= '0;
            s2_rd_useful <= '0;
`ifdef CONFIG_FE_UTAGE
            s2_utage_meta <= '0;
`endif
        end else begin
            s1_valid <= req_valid && !flush;
            if (req_valid && !flush) begin
                s1_pc       <= fetch_pc;
                s1_idx      <= idx_s0;
                s1_tag      <= tag_s0;
                s1_base_idx <= base_idx_s0;
                s1_ckpt_ptr <= ckpt_wptr;
            end

            // s1 captures the array output registered in the previous cycle,
            // which is the request issued two cycles ago.
            s2_valid     <= s1_valid;
            s2_rd_valid  <= tbl_rd_valid;
            s2_rd_tag    <= tbl_rd_tag;
            s2_rd_ctr    <= tbl_rd_ctr;
            s2_rd_useful <= tbl_rd_useful;
            s2_base_ctr  <= base_ctr_rd;
`ifdef CONFIG_FE_UTAGE
            s2_utage_meta <= utage_meta_c;
`endif
            if (s1_valid) begin
                s2_pc       <= s1_pc;
                s2_idx      <= s1_idx;
                s2_tag      <= s1_tag;
                s2_base_idx <= s1_base_idx;
                s2_ckpt_ptr <= s1_ckpt_ptr;
            end
        end
    end

    // s0 drives the SRAM read ports; the arrays register the response for s1.
    always_comb begin
        tbl_rd_en = req_valid && !flush;
        for (int t = 0; t < TAGE_NUM_TABLES; t++) tbl_rd_idx[t] = idx_s0[t];
    end

    // ==================================================================
    // s1 : provisional direction from the read data now available.  It uses
    // the uBTB CFI list (the only CFI source known in S1) and drives the fast
    // path, keeping the speculative history aligned with TAGE's own result.
    // ==================================================================
    logic           [           FETCH_WIDTH-1:0] s1_pred_taken_c;
    tage_meta_t     [           FETCH_WIDTH-1:0] s1_meta_c;
    logic           [TAGE_COND_PREFIX_WIDTH-1:0] s1_cond_prefix_c  [FETCH_WIDTH];
    logic           [TAGE_COND_PREFIX_WIDTH-1:0] s1_cond_acc_c;
    tage_slot_out_t                              s1_slot_out_c;
    logic                                        s1_slot_use_alt_c;

    always_comb begin
        s1_cond_acc_c = '0;
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            s1_cond_prefix_c[s] = s1_cond_acc_c;
            if (s1_cfi_valid[s] && (s1_cfi_type[s] == CFI_COND_BRANCH))
                s1_cond_acc_c = s1_cond_acc_c + 1'b1;
        end

        for (int s = 0; s < FETCH_WIDTH; s++) begin
            s1_slot_use_alt_c = TAGE_USE_ALT_ON_NA ? use_alt_na[3] : 1'b0;

            s1_slot_out_c = tage_predict_slot(
                tbl_rd_valid,
                tbl_rd_tag,
                tbl_rd_ctr,
                tbl_rd_useful,
                s1_idx,
                s1_tag,
                useful_epoch,
                s1_cond_prefix_c[s],
                s1_ckpt_ptr,
                TAGE_SLOT_ID_WIDTH'(s),
                s1_base_idx[TAGE_BASE_NUM_BANKS'(s%TAGE_BASE_NUM_BANKS)],
                base_ctr_rd[TAGE_BASE_NUM_BANKS'(s%TAGE_BASE_NUM_BANKS)],
                (base_ctr_rd[TAGE_BASE_NUM_BANKS'(s%TAGE_BASE_NUM_BANKS)] >= 2'b10),
                s1_slot_use_alt_c,
                s1_cfi_valid[s] && (s1_cfi_type[s] == CFI_COND_BRANCH)
            );

            s1_pred_taken_c[s] = s1_slot_out_c.pred;
            s1_meta_c[s] = s1_slot_out_c.meta;
        end

`ifdef CONFIG_FE_UTAGE
        // The S1 fast direction comes from uTAGE; the full-TAGE S1 result is
        // kept only as metadata for training fallback and is off the fetch loop.
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            s1_pred_taken_c[s] = utage_pred_taken_c[s];
            s1_meta_c[s].utage = utage_meta_c[s];
        end
`endif
    end

`ifdef CONFIG_FE_UTAGE
    // uTAGE: small tagged tables with folded histories, trained at commit.
    utage utage_u (
        .clk         (clk),
        .rst         (rst),
        .req_valid   (req_valid && !flush),
        .fetch_pc    (fetch_pc),
        .fold_idx    (hist_fwd.fold_idx_u),
        .fold_tag    (hist_fwd.fold_tag_u),
        .cfi_valid   (s1_cfi_valid),
        .cfi_type    (s1_cfi_type),
        .base_pred   (s1_fast_dir),
        .pred_taken  (utage_pred_taken_c),
        .meta        (utage_meta_c),
        .update_en   (update_en),
        .is_branch   (is_branch),
        .update_pc   (update_pc),
        .actual_taken(actual_taken),
        .update_meta (update_meta.utage)
    );
`endif

    assign s1_resp_valid       = s1_valid;
    assign s1_pred_taken_slots = s1_pred_taken_c;
    assign s1_tage_meta        = s1_meta_c;

    // ==================================================================
    // s2 : provider / alt selection and direction
    // ==================================================================
    logic           [           FETCH_WIDTH-1:0] pred_taken_c;
    tage_meta_t     [           FETCH_WIDTH-1:0] meta_c;
    logic           [TAGE_COND_PREFIX_WIDTH-1:0] cond_prefix_c  [FETCH_WIDTH];

    // All combinational temporaries are module-level and assigned on every
    // path, so no latches are inferred; the per-slot work is in the pure
    // function tage_predict_slot.
    logic           [TAGE_COND_PREFIX_WIDTH-1:0] cond_acc_c;
    tage_slot_out_t                              slot_out_c;
    logic                                        slot_use_alt_c;

    always_comb begin
        cond_acc_c = '0;
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            cond_prefix_c[s] = cond_acc_c;
            if (pred_cfi_valid[s] && (pred_cfi_type[s] == CFI_COND_BRANCH))
                cond_acc_c = cond_acc_c + 1'b1;
        end

        for (int s = 0; s < FETCH_WIDTH; s++) begin
            slot_use_alt_c = TAGE_USE_ALT_ON_NA ? use_alt_na[3] : 1'b0;

            slot_out_c = tage_predict_slot(
                s2_rd_valid,
                s2_rd_tag,
                s2_rd_ctr,
                s2_rd_useful,
                s2_idx,
                s2_tag,
                useful_epoch,
                cond_prefix_c[s],
                s2_ckpt_ptr,
                TAGE_SLOT_ID_WIDTH'(s),
                s2_base_idx[TAGE_BASE_NUM_BANKS'(s%TAGE_BASE_NUM_BANKS)],
                s2_base_ctr[TAGE_BASE_NUM_BANKS'(s%TAGE_BASE_NUM_BANKS)],
                (s2_base_ctr[TAGE_BASE_NUM_BANKS'(s%TAGE_BASE_NUM_BANKS)] >= 2'b10),
                slot_use_alt_c,
                pred_cfi_valid[s] && (pred_cfi_type[s] == CFI_COND_BRANCH)
            );

            pred_taken_c[s] = slot_out_c.pred;
            meta_c[s] = slot_out_c.meta;
`ifdef CONFIG_FE_UTAGE
            meta_c[s].utage = s2_utage_meta[s];
`endif
        end
    end

    assign resp_valid       = s2_valid;
    assign resp_pc          = s2_pc;
    assign pred_taken_slots = pred_taken_c;
    assign tage_meta        = meta_c;

    // ==================================================================
    // Training layer (combinational decision, synchronous write)
    // ==================================================================
    logic                      alloc_trig_c;
    logic                      alloc_found_c;
    logic         [BANK_W-1:0] alloc_bank_c;
    tage_update_t              upd_c;

    always_comb begin
        upd_c = tage_update_compute(
            update_en,
            is_branch,
            actual_taken,
            update_meta,
            tbl_up_valid,
            tbl_up_tag,
            tbl_up_ctr,
            tbl_up_useful,
            useful_epoch
        );

        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            tbl_wr_en[t]     = upd_c.wr_en[t];
            tbl_wr_idx[t]    = upd_c.wr_idx[t];
            tbl_wr_slot[t]   = upd_c.wr_slot[t];
            tbl_wr_valid[t]  = upd_c.wr_valid[t];
            tbl_wr_tag[t]    = upd_c.wr_tag[t];
            tbl_wr_ctr[t]    = upd_c.wr_ctr[t];
            tbl_wr_useful[t] = upd_c.wr_useful[t];
        end
        t0_wr_en      = upd_c.t0_en;
        t0_wr_bank    = upd_c.t0_bank;
        t0_wr_idx     = upd_c.t0_idx;
        t0_wr_ctr     = upd_c.t0_ctr;
        alloc_trig_c  = upd_c.alloc_trig;
        alloc_found_c = upd_c.alloc_found;
        alloc_bank_c  = upd_c.alloc_bank;

    end

    // ==================================================================
    // History + checkpoint sequential state
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            hist_r     <= '0;
            ghr_commit <= '0;
            ckpt_wptr  <= '0;
            // ckpt_mem stores history data; only the write pointer tracks
            // validity, so the array is not reset (it can infer as RAM).
        end else begin
            if (update_en && is_branch)
                ghr_commit <= {ghr_commit[TAGE_GHV_WIDTH-2:0], actual_taken};

            // Speculative history: flush > S2 correction > S1 fast-path advance.
            // A S2 direction correction is treated exactly like a branch
            // redirect so the history follows the corrected (TAGE) path instead
            // of the S1 fast-path directions.
            if (flush) begin
                // Only the S2-backfilled metadata carries a usable checkpoint.
                // A branch whose FTQ entry was consumed before the backfill
                // leaves `meta_valid=0`; restoring from its (zero) ckpt_ptr
                // would corrupt the history, so fall back to the committed
                // history instead.
                if (redirect_kind == REDIRECT_BRANCH && update_meta.meta_valid) begin
                    tage_hist_t h;
                    h = tage_hist_collapse(ckpt_mem[update_meta.ckpt_ptr]);
                    for (int i = 0; i < FETCH_WIDTH; i++)
                    if (i < update_meta.cond_prefix) h = tage_hist_push(h, 1'b0);
                    if (is_branch) h = tage_hist_push(h, redirect_actual_taken);
                    hist_r <= h;
                    ckpt_wptr <= update_meta.ckpt_ptr;
                end else begin
                    hist_r <= tage_hist_collapse(ghr_commit);
                end
            end else if (corr_valid) begin
                tage_hist_t h;
                h = tage_hist_collapse(ckpt_mem[corr_ckpt_ptr]);
                for (int i = 0; i < FETCH_WIDTH; i++)
                if (i < corr_cond_prefix) h = tage_hist_push(h, 1'b0);
                if (corr_is_cond) h = tage_hist_push(h, corr_taken);
                hist_r <= h;
                ckpt_wptr <= corr_ckpt_ptr;
            end else if (spec_valid) begin
                // `hist_fwd` is exactly this push (computed for the S0 hash and
                // the checkpoint), so reuse it instead of building a second
                // identical push chain on the register D input.
                hist_r <= hist_fwd;
            end


            // checkpoint push (flush / correction win).  Store the *forwarded*
            // history that was used to hash this block, i.e. including the
            // immediately preceding block (hist_r alone is one block behind).
            if (!flush && !corr_valid && req_valid) begin
                ckpt_mem[ckpt_wptr] <= hist_fwd.ghr;
                ckpt_wptr <= ckpt_wptr + 1'b1;
            end
        end
    end

    // ==================================================================
    // useful-reset counter + epoch, and use_alt_on_na counters
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            useful_epoch     <= '0;
            useful_reset_ctr <= '0;
            use_alt_na       <= 4'b1000;
        end else begin
            if (update_en && update_meta.valid && update_meta.provided && alloc_trig_c) begin
                if (alloc_found_c) begin
                    if (useful_reset_ctr == 12'hFFF) begin
                        useful_epoch[alloc_bank_c] <= ~useful_epoch[alloc_bank_c];
                        useful_reset_ctr <= '0;
                    end else begin
                        useful_reset_ctr <= useful_reset_ctr + 1'b1;
                    end
                end else if (useful_reset_ctr != '0) begin
                    useful_reset_ctr <= useful_reset_ctr - 1'b1;
                end
            end

            // Global use_alt_on_na training, matching native TageDirection.v.
            if (TAGE_USE_ALT_ON_NA && update_en && is_branch && update_meta.valid
                && update_meta.provided
                && ((update_meta.provider_ctr == '0)
                    || (&update_meta.provider_ctr))
                && (update_meta.provider_pred != update_meta.alt_pred)) begin
                if ((update_meta.provider_pred != actual_taken) && !use_alt_na[3])
                    use_alt_na <= use_alt_na + 1'b1;
                else if ((update_meta.alt_pred != actual_taken) && (|use_alt_na))
                    use_alt_na <= use_alt_na - 1'b1;
            end
        end
    end

endmodule
`endif

