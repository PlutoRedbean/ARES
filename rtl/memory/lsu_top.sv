//=============================================================================
// ARES LSU - subsystem top (L01), C2 M2b DCache path
//-----------------------------------------------------------------------------
// Backend-visible LSU boundary of backend.md 9.6 / plan 5.10 with the full
// memory subsystem behind it:
//
//   lsu_agu      (L02)  address generation, size/mask, MMIO classification
//   lq           (L03)  4-entry load queue (+ store_forward per entry)
//   sq           (L04)  8-entry unified SQ (SPEC + COMMITTED)
//   dcache_top   (L06)  C2/C3 pipeline, arrays/port arbitration, pending write
//   dcache_arrays(L07)  per-way 1R1W data RAM + Tag/Valid/Dirty/LRU
//   mshr         (L08)  2-entry miss tracking, refill, overlay, WAKE
//   wb_buffer    (L09)  dirty victim capture + beat writeback
//   line_adapter (L10)  cache line <-> 16B beat on the 128-bit bus
//   mmio_bridge  (L11)  single-outstanding device channel (load + store)
//   lsu_completion(L12) fast path + 2-entry completion FIFO
//
// M2b wiring (LSU_INTERFACES.md 13):
//   * LQ lookup -> dcache_top;  SQ oldest COMMITTED drain -> dcache_top (cache-
//     able) or mmio_bridge (MMIO);
//   * the single LQ fill port is shared: C3 hit first, then MSHR wake (one per
//     cycle); the MSHR itself drops stale waiters via the LQ index/tag/epoch
//     token (D-M2b-04/05);
//   * mshr refill -> line_adapter refill, mshr capture data -> wb_buffer,
//     wb_buffer -> line_adapter writeback, wb visibility -> dcache_top;
//   * lsu_mmio_order_idle = !mmio_busy && !sq_mmio_store_pending (cycle-start
//     registered state, memory.md 3.1 / plan 5.14).
//
// Spec sources: backend.md 9.6, memory.md 3-8, plan 5.10-5.14, LSU_INTERFACES
//   sections 7 and 13.
// FREE items: FREE-02 (subsystem file), FREE-11 (internal pipeline registers).
//=============================================================================
module lsu_top #(
    parameter logic [31:0] MMIO_BASE = 32'hA000_0000,
    parameter bit JYD_UNCACHED_WINDOWS = 1'b0,
    parameter logic [31:0] MMIO_MASK = 32'hFF00_0000
) (
    input  logic                             clk,
    input  logic                             rst,

    //---- Issue port (backend.md 9.6.1) -------------------------------------
    output logic                             lsu_can_accept,
    output logic [2:0]                       load_credit,
    output logic [3:0]                       store_credit,
    input  logic                             issue_valid,
    input  ares_pkg::fu_req_t                issue_req,

    //---- Completion port ---------------------------------------------------
    output logic                             completion_valid,
    output ares_pkg::fu_completion_t         completion,

    //---- Commit / flush ----------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    input  logic                             load_head_valid,
    input  ares_pkg::tag_t                   load_head_tag,
    input  logic [1:0]                       store_commit_valid,
    input  ares_pkg::tag_t                   store_commit_tag [2],
    output logic [1:0]                       store_commit_ok,
    input  logic [1:0]                       commit_fire,
    output logic                             lsu_mmio_order_idle,
    output logic                             lsu_fence_idle,

    //---- 128-bit memory bus (memory.md 6.7) --------------------------------
    output logic                             mem_rd_valid,
    input  logic                             mem_rd_ready,
    output logic [31:0]                      mem_rd_addr,
    input  logic                             mem_rsp_valid,
    output logic                             mem_rsp_ready,
    input  logic [127:0]                     mem_rsp_data,
    output logic                             mem_wr_valid,
    input  logic                             mem_wr_ready,
    output logic [31:0]                      mem_wr_addr,
    output logic [127:0]                     mem_wr_data,
    output logic [15:0]                      mem_wr_be,

    //---- MMIO device channel (memory.md 3.1) -------------------------------
    output logic                             mmio_req_valid,
    input  logic                             mmio_req_ready,
    output logic                             mmio_write,
    output logic [31:0]                      mmio_addr,
    output logic [31:0]                      mmio_wdata,
    output logic [3:0]                       mmio_wstrb,
    input  logic                             mmio_rsp_valid,
    output logic                             mmio_rsp_ready,
    input  logic [31:0]                      mmio_rsp_data,

    //---- TB visibility (not architectural state) ---------------------------
    output logic [2:0]                       dbg_lq_used,
    output logic [3:0]                       dbg_sq_used
);
    import ares_pkg::*;
    import lsu_pkg::*;

    //-------------------------------------------------------------------------
    // Issue classification and queue allocation
    //-------------------------------------------------------------------------
    wire issue_is_load  = lsu_op_is_load(issue_req.op);
    wire issue_is_store = lsu_op_is_store(issue_req.op);

    wire issue_killed = issue_valid && kill_mask[issue_req.tag.slot_index];
    wire alloc_valid  = issue_valid && !issue_killed;

    wire lq_full_w, sq_full_w;
    wire [1:0] lq_alloc_idx_w;
    wire [2:0] sq_alloc_idx_w;

    // can_accept must be a function of REGISTERED state only (backend.md 9.6.1);
    // the operation type is not inspected here (no combinational loop through
    // the backend issue mux).  The scheduler checks the type-specific credit.
    wire lsu_can_accept_w = (load_credit != 3'd0) || (store_credit != 4'd0);

    wire [2:0] lq_issue_qidx = {1'b0, lq_alloc_idx_w};
    wire [2:0] issue_qidx_w  = issue_is_load ? lq_issue_qidx : sq_alloc_idx_w;

    //-------------------------------------------------------------------------
    // L02 AGU
    //-------------------------------------------------------------------------
    logic        agu_valid_w;
    tag_t        agu_tag_w;
    logic [2:0]  agu_qidx_w;
    logic        agu_is_load_w, agu_is_store_w;
    logic [31:0] agu_addr_w;
    lsu_size_t   agu_size_w;
    logic [3:0]  agu_byte_mask_w;
    logic [31:0] agu_store_data_w;
    logic        agu_is_unsigned_w, agu_is_mmio_w;

    lsu_agu #(
        .JYD_UNCACHED_WINDOWS (JYD_UNCACHED_WINDOWS),
        .MMIO_BASE (MMIO_BASE),
        .MMIO_MASK (MMIO_MASK)
    ) u_agu (
        .clk            (clk),
        .rst            (rst),
        .issue_valid    (issue_valid),
        .issue_req      (issue_req),
        .issue_qidx     (issue_qidx_w),
        .issue_kill     (issue_killed),
        .out_valid      (agu_valid_w),
        .out_tag        (agu_tag_w),
        .out_qidx       (agu_qidx_w),
        .out_is_load    (agu_is_load_w),
        .out_is_store   (agu_is_store_w),
        .out_addr       (agu_addr_w),
        .out_size       (agu_size_w),
        .out_byte_mask  (agu_byte_mask_w),
        .out_store_data (agu_store_data_w),
        .out_is_unsigned(agu_is_unsigned_w),
        .out_is_mmio    (agu_is_mmio_w)
    );

    //-------------------------------------------------------------------------
    // L04 SQ
    //-------------------------------------------------------------------------
    logic        sq_exec_valid_w, sq_exec_ready_w;
    tag_t        sq_exec_tag_w;
    logic        sq_drain_valid_w;
    logic [2:0]  sq_drain_idx_w;
    tag_t        sq_drain_tag_w;
    logic [31:0] sq_drain_addr_w, sq_drain_data_w;
    logic [3:0]  sq_drain_mask_w;
    logic        sq_drain_is_mmio_w;
    logic        sq_drain_start_w, sq_drain_takeover_w;
    logic [7:0]  sq_occupied_w, sq_takeover_w, sq_addr_valid_w, sq_is_mmio_w;
    logic [7:0][31:0] sq_addr_w, sq_data_w;
    logic [7:0][3:0]  sq_byte_mask_w;
    logic [2:0]  sq_head_ptr_w;
    logic [3:0]  sq_occupancy_w;
    logic        sq_mmio_store_pending_w;

    sq u_sq (
        .clk                (clk),
        .rst                (rst),
        .alloc_valid        (alloc_valid && issue_is_store),
        .alloc_tag          (issue_req.tag),
        .alloc_idx          (sq_alloc_idx_w),
        .agu_valid          (agu_valid_w && agu_is_store_w),
        .agu_qidx           (agu_qidx_w),
        .agu_tag            (agu_tag_w),
        .agu_addr           (agu_addr_w),
        .agu_byte_mask      (agu_byte_mask_w),
        .agu_store_data     (agu_store_data_w),
        .agu_is_mmio        (agu_is_mmio_w),
        .exec_valid         (sq_exec_valid_w),
        .exec_ready         (sq_exec_ready_w),
        .exec_tag           (sq_exec_tag_w),
        .store_commit_valid (store_commit_valid),
        .store_commit_tag   (store_commit_tag),
        .store_commit_ok    (store_commit_ok),
        .commit_fire        (commit_fire),
        .drain_valid        (sq_drain_valid_w),
        .drain_idx          (sq_drain_idx_w),
        .drain_tag          (sq_drain_tag_w),
        .drain_addr         (sq_drain_addr_w),
        .drain_data         (sq_drain_data_w),
        .drain_mask         (sq_drain_mask_w),
        .drain_is_mmio      (sq_drain_is_mmio_w),
        .drain_start        (sq_drain_start_w),
        .drain_takeover     (sq_drain_takeover_w),
        .sq_occupied        (sq_occupied_w),
        .sq_takeover        (sq_takeover_w),
        .sq_addr_valid      (sq_addr_valid_w),
        .sq_addr            (sq_addr_w),
        .sq_data            (sq_data_w),
        .sq_byte_mask       (sq_byte_mask_w),
        .sq_is_mmio         (sq_is_mmio_w),
        .sq_head_ptr        (sq_head_ptr_w),
        .sq_occupancy       (sq_occupancy_w),
        .sq_mmio_store_pending (sq_mmio_store_pending_w),
        .kill_mask          (kill_mask),
        .store_credit       (store_credit),
        .sq_full            (sq_full_w)
    );

    assign dbg_sq_used = sq_occupancy_w;

    //-------------------------------------------------------------------------
    // L03 LQ
    //-------------------------------------------------------------------------
    logic        lq_lookup_valid_w, lq_lookup_ready_w;
    logic [1:0]  lq_lookup_idx_w;
    tag_t        lq_lookup_tag_w;
    logic [31:0] lq_lookup_addr_w;
    logic        lq_fill_valid_w;
    logic [1:0]  lq_fill_idx_w;
    logic [31:0] lq_fill_word_w;
    logic        lq_mmio_req_valid_w, lq_mmio_req_ready_w;
    logic [31:0] lq_mmio_req_addr_w;
    logic        lq_mmio_rsp_valid_w;
    logic        lq_compl_valid_w, lq_compl_ready_w;
    tag_t        lq_compl_tag_w;
    logic [31:0] lq_compl_result_w;
    logic [2:0]  lq_used_w;
    logic [LQ_ENTRIES-1:0] lq_wait_pending_w;
    tag_t        lq_wait_tag_w [LQ_ENTRIES];
    logic [7:0]  lq_wait_epoch_w [LQ_ENTRIES];

    lq u_lq (
        .clk                (clk),
        .rst                (rst),
        .alloc_valid        (alloc_valid && issue_is_load),
        .alloc_idx          (lq_alloc_idx_w),
        .alloc_tag          (issue_req.tag),
        .agu_valid          (agu_valid_w && agu_is_load_w),
        .agu_qidx           (agu_qidx_w),
        .agu_tag            (agu_tag_w),
        .agu_addr           (agu_addr_w),
        .agu_size           (agu_size_w),
        .agu_byte_mask      (agu_byte_mask_w),
        .agu_is_unsigned    (agu_is_unsigned_w),
        .agu_is_mmio        (agu_is_mmio_w),
        .sq_occupied        (sq_occupied_w),
        .sq_takeover        (sq_takeover_w),
        .sq_addr_valid      (sq_addr_valid_w),
        .sq_addr            (sq_addr_w),
        .sq_data            (sq_data_w),
        .sq_byte_mask       (sq_byte_mask_w),
        .sq_is_mmio         (sq_is_mmio_w),
        .sq_head_ptr        (sq_head_ptr_w),
        .sq_occupancy       (sq_occupancy_w),
        .lookup_valid       (lq_lookup_valid_w),
        .lookup_ready       (lq_lookup_ready_w),
        .lookup_idx         (lq_lookup_idx_w),
        .lookup_tag         (lq_lookup_tag_w),
        .lookup_addr        (lq_lookup_addr_w),
        .fill_valid         (lq_fill_valid_w),
        .fill_idx           (lq_fill_idx_w),
        .fill_word          (lq_fill_word_w),
        .load_head_valid    (load_head_valid),
        .load_head_tag      (load_head_tag),
        .mmio_req_valid     (lq_mmio_req_valid_w),
        .mmio_req_ready     (lq_mmio_req_ready_w),
        .mmio_req_addr      (lq_mmio_req_addr_w),
        .mmio_rsp_valid     (lq_mmio_rsp_valid_w),
        .mmio_rsp_data      (mmio_rsp_data),
        .compl_valid        (lq_compl_valid_w),
        .compl_ready        (lq_compl_ready_w),
        .compl_tag          (lq_compl_tag_w),
        .compl_result       (lq_compl_result_w),
        .kill_mask          (kill_mask),
        .lq_alloc_idx       (lq_alloc_idx_w),
        .lq_used            (lq_used_w),
        .lq_full            (lq_full_w),
        .lq_wait_pending    (lq_wait_pending_w),
        .lq_wait_tag        (lq_wait_tag_w),
        .lq_wait_epoch      (lq_wait_epoch_w)
    );

    assign load_credit = 3'd4 - lq_used_w;
    assign dbg_lq_used = lq_used_w;

//-------------------------------------------------------------------------
    // L06 DCache pipeline + L07 arrays
    //-------------------------------------------------------------------------
    logic                    dc_hit_fill_valid_w;
    logic [1:0]              dc_hit_fill_idx_w;
    logic [31:0]             dc_hit_fill_word_w;
    logic                    dc_store_start_w, dc_store_takeover_w;
    logic                    dc_lq_lookup_ready_w;

    logic [MSHR_ENTRIES-1:0]        mshr_lock_valid_w;
    logic [MSHR_ENTRIES-1:0][31:0]  mshr_lock_line_addr_w;
    logic [MSHR_ENTRIES-1:0][1:0]   mshr_lock_way_w;
    logic [31:0]                    mshr_match_line_addr_w;
    logic [MSHR_ENTRIES-1:0]        mshr_match_hit_w;
    logic                           mshr_resv_valid_w, mshr_resv_ready_w;
    logic [31:0]                    mshr_resv_line_addr_w;
    logic [1:0]                     mshr_resv_way_w;
    logic                           mshr_resv_victim_dirty_w;
    logic [1:0]                     mshr_resv_wb_idx_w;
    logic                           mshr_resv_is_store_w;
    logic [1:0]                     mshr_resv_lq_idx_w;
    tag_t                           mshr_resv_lq_tag_w;
    logic [7:0]                     mshr_resv_lq_epoch_w;
    logic [DCACHE_OFFSET_BITS-3:0]  mshr_resv_word_idx_w;
    logic [3:0]                     mshr_resv_store_mask_w;
    logic [31:0]                    mshr_resv_store_data_w;
    logic [DCACHE_OFFSET_BITS-3:0]  mshr_resv_store_widx_w;
    logic                           mshr_merge_valid_w, mshr_merge_ready_w;
    logic [MSHR_ENTRIES-1:0]        mshr_merge_sel_w;
    logic                           mshr_merge_is_store_w;
    logic [1:0]                     mshr_merge_lq_idx_w;
    tag_t                           mshr_merge_lq_tag_w;
    logic [7:0]                     mshr_merge_lq_epoch_w;
    logic [DCACHE_OFFSET_BITS-3:0]  mshr_merge_word_idx_w;
    logic [3:0]                     mshr_merge_store_mask_w;
    logic [31:0]                    mshr_merge_store_data_w;
    logic [DCACHE_OFFSET_BITS-3:0]  mshr_merge_store_widx_w;
    logic                           mshr_ovl_valid_w, mshr_ovl_ready_w;
    logic [MSHR_ENTRIES-1:0]        mshr_ovl_sel_w;
    logic [DCACHE_OFFSET_BITS-3:0]  mshr_ovl_widx_w;
    logic [3:0]                     mshr_ovl_mask_w;
    logic [31:0]                    mshr_ovl_data_w;
    logic [MSHR_ENTRIES-1:0]        mshr_cap_req_valid_w;
    logic [MSHR_ENTRIES-1:0][1:0]   mshr_cap_req_way_w;
    logic [MSHR_ENTRIES-1:0][$clog2(ROWS_PER_LINE)-1:0] mshr_cap_req_row_w;
    logic [MSHR_ENTRIES-1:0]        mshr_cap_gnt_w;
    logic                           dc_cap_rsp_valid_w;
    logic [DCACHE_INDEX_BITS-1:0]   dc_cap_rsp_set_w;
    logic [$clog2(ROWS_PER_LINE)-1:0] dc_cap_rsp_row_w;
    logic [1:0]                     dc_cap_rsp_way_w;
    logic [63:0]                    dc_cap_rsp_data_w;
    logic [MSHR_ENTRIES-1:0]        mshr_inst_valid_w, mshr_inst_last_w, mshr_inst_gnt_w;
    logic [MSHR_ENTRIES-1:0][1:0]   mshr_inst_way_w;
    logic [MSHR_ENTRIES-1:0][DCACHE_INDEX_BITS-1:0] mshr_inst_set_w;
    logic [MSHR_ENTRIES-1:0][$clog2(ROWS_PER_LINE)-1:0] mshr_inst_row_w;
    logic [MSHR_ENTRIES-1:0][63:0]  mshr_inst_data_w;
    logic [MSHR_ENTRIES-1:0][7:0]   mshr_inst_be_w;
    logic [MSHR_ENTRIES-1:0]        mshr_pub_valid_w;
    logic [MSHR_ENTRIES-1:0][1:0]   mshr_pub_way_w;
    logic [MSHR_ENTRIES-1:0][DCACHE_TAG_BITS-1:0] mshr_pub_tag_w;
    logic [MSHR_ENTRIES-1:0]        mshr_pub_dirty_w;
    logic [MSHR_ENTRIES-1:0]        mshr_wake_valid_w;
    logic [MSHR_ENTRIES-1:0][1:0]   mshr_wake_lq_idx_w;
    logic [MSHR_ENTRIES-1:0][31:0]  mshr_wake_word_w;
    logic [MSHR_ENTRIES-1:0]        mshr_wake_ready_w;
    logic                           mshr_refill_req_ready_w;
    logic                           mshr_refill_rsp_valid_w;
    logic [8*LINE_BYTES-1:0]        mshr_refill_line_data_w;
    logic [LINE_BEATS-1:0]          mshr_refill_beat_valid_w;
    logic                           dc_wb_alloc_valid_w;
    logic [1:0]                     dc_wb_alloc_idx_w;
    logic [31:0]                    dc_wb_alloc_line_addr_w;
    logic [31:0]                    dc_wb_vis_query_w;
    logic [WB_ENTRIES-1:0]          wb_free_mask_w;
    logic                           wb_vis_block_w;

    wire sq_high_water_w = (sq_occupancy_w >= 4'd4);

    dcache_top u_dcache (
        .clk                      (clk),
        .rst                      (rst),
        .lq_lookup_valid          (lq_lookup_valid_w),
        .lq_lookup_ready          (dc_lq_lookup_ready_w),
        .lq_lookup_idx            (lq_lookup_idx_w),
        .lq_lookup_tag            (lq_lookup_tag_w),
        .lq_lookup_addr           (lq_lookup_addr_w),
        .lq_wait_epoch            (lq_wait_epoch_w),
        .hit_fill_valid           (dc_hit_fill_valid_w),
        .hit_fill_idx             (dc_hit_fill_idx_w),
        .hit_fill_word            (dc_hit_fill_word_w),
        .sq_drain_valid           (sq_drain_valid_w && !sq_drain_is_mmio_w),
        .sq_drain_idx             (sq_drain_idx_w),
        .sq_drain_tag             (sq_drain_tag_w),
        .sq_drain_addr            (sq_drain_addr_w),
        .sq_drain_data            (sq_drain_data_w),
        .sq_drain_mask            (sq_drain_mask_w),
        .sq_high_water            (sq_high_water_w),
        .store_start              (dc_store_start_w),
        .store_takeover           (dc_store_takeover_w),
        .kill_mask                (kill_mask),
        .mshr_lock_valid          (mshr_lock_valid_w),
        .mshr_lock_line_addr      (mshr_lock_line_addr_w),
        .mshr_lock_way            (mshr_lock_way_w),
        .mshr_match_line_addr     (mshr_match_line_addr_w),
        .mshr_match_hit           (mshr_match_hit_w),
        .mshr_resv_valid          (mshr_resv_valid_w),
        .mshr_resv_ready          (mshr_resv_ready_w),
        .mshr_resv_line_addr      (mshr_resv_line_addr_w),
        .mshr_resv_way            (mshr_resv_way_w),
        .mshr_resv_victim_dirty   (mshr_resv_victim_dirty_w),
        .mshr_resv_wb_idx         (mshr_resv_wb_idx_w),
        .mshr_resv_is_store       (mshr_resv_is_store_w),
        .mshr_resv_lq_idx         (mshr_resv_lq_idx_w),
        .mshr_resv_lq_tag         (mshr_resv_lq_tag_w),
        .mshr_resv_lq_epoch       (mshr_resv_lq_epoch_w),
        .mshr_resv_word_idx       (mshr_resv_word_idx_w),
        .mshr_resv_store_mask     (mshr_resv_store_mask_w),
        .mshr_resv_store_data     (mshr_resv_store_data_w),
        .mshr_resv_store_widx     (mshr_resv_store_widx_w),
        .mshr_merge_valid         (mshr_merge_valid_w),
        .mshr_merge_sel           (mshr_merge_sel_w),
        .mshr_merge_ready         (mshr_merge_ready_w),
        .mshr_merge_is_store      (mshr_merge_is_store_w),
        .mshr_merge_lq_idx        (mshr_merge_lq_idx_w),
        .mshr_merge_lq_tag        (mshr_merge_lq_tag_w),
        .mshr_merge_lq_epoch      (mshr_merge_lq_epoch_w),
        .mshr_merge_word_idx      (mshr_merge_word_idx_w),
        .mshr_merge_store_mask    (mshr_merge_store_mask_w),
        .mshr_merge_store_data    (mshr_merge_store_data_w),
        .mshr_merge_store_widx    (mshr_merge_store_widx_w),
        .mshr_ovl_valid           (mshr_ovl_valid_w),
        .mshr_ovl_sel             (mshr_ovl_sel_w),
        .mshr_ovl_ready           (mshr_ovl_ready_w),
        .mshr_ovl_widx            (mshr_ovl_widx_w),
        .mshr_ovl_mask            (mshr_ovl_mask_w),
        .mshr_ovl_data            (mshr_ovl_data_w),
        .mshr_cap_req_valid       (mshr_cap_req_valid_w),
        .mshr_cap_req_way         (mshr_cap_req_way_w),
        .mshr_cap_req_row         (mshr_cap_req_row_w),
        .mshr_cap_gnt             (mshr_cap_gnt_w),
        .cap_rsp_valid            (dc_cap_rsp_valid_w),
        .cap_rsp_set              (dc_cap_rsp_set_w),
        .cap_rsp_row              (dc_cap_rsp_row_w),
        .cap_rsp_way              (dc_cap_rsp_way_w),
        .cap_rsp_data             (dc_cap_rsp_data_w),
        .mshr_inst_valid          (mshr_inst_valid_w),
        .mshr_inst_way            (mshr_inst_way_w),
        .mshr_inst_set            (mshr_inst_set_w),
        .mshr_inst_row            (mshr_inst_row_w),
        .mshr_inst_data           (mshr_inst_data_w),
        .mshr_inst_be             (mshr_inst_be_w),
        .mshr_inst_last           (mshr_inst_last_w),
        .mshr_inst_gnt            (mshr_inst_gnt_w),
        .mshr_pub_valid           (mshr_pub_valid_w),
        .mshr_pub_way             (mshr_pub_way_w),
        .mshr_pub_tag             (mshr_pub_tag_w),
        .mshr_pub_dirty           (mshr_pub_dirty_w),
        .wb_free_mask             (wb_free_mask_w),
        .wb_alloc_valid           (dc_wb_alloc_valid_w),
        .wb_alloc_idx             (dc_wb_alloc_idx_w),
        .wb_alloc_line_addr       (dc_wb_alloc_line_addr_w),
        .wb_vis_query             (dc_wb_vis_query_w),
        .wb_vis_block             (wb_vis_block_w)
    );

    assign lq_lookup_ready_w = dc_lq_lookup_ready_w;

    //-------------------------------------------------------------------------
    // L08 MSHR
    //-------------------------------------------------------------------------
    logic                           mshr_refill_req_valid_w;
    logic [31:0]                    mshr_refill_line_addr_w;
    logic                           mshr_refill_rsp_ready_w;
    logic [MSHR_ENTRIES-1:0]        mshr_wb_wr_valid_w;
    logic [MSHR_ENTRIES-1:0][1:0]   mshr_wb_wr_idx_w;
    logic [MSHR_ENTRIES-1:0][$clog2(ROWS_PER_LINE)-1:0] mshr_wb_wr_row_w;
    logic [MSHR_ENTRIES-1:0][63:0]  mshr_wb_wr_data_w;
    logic [MSHR_ENTRIES-1:0]        mshr_wb_wr_last_w;
    logic [MSHR_ENTRIES-1:0]        mshr_busy_w;
    logic [WB_ENTRIES-1:0]          wb_busy_w_unused;

    mshr u_mshr (
        .clk                (clk),
        .rst                (rst),
        .lock_valid         (mshr_lock_valid_w),
        .lock_line_addr     (mshr_lock_line_addr_w),
        .lock_way           (mshr_lock_way_w),
        .busy               (mshr_busy_w),
        .match_line_addr    (mshr_match_line_addr_w),
        .match_hit          (mshr_match_hit_w),
        .resv_valid         (mshr_resv_valid_w),
        .resv_ready         (mshr_resv_ready_w),
        .resv_line_addr     (mshr_resv_line_addr_w),
        .resv_way           (mshr_resv_way_w),
        .resv_victim_dirty  (mshr_resv_victim_dirty_w),
        .resv_wb_idx        (mshr_resv_wb_idx_w),
        .resv_is_store      (mshr_resv_is_store_w),
        .resv_lq_idx        (mshr_resv_lq_idx_w),
        .resv_lq_tag        (mshr_resv_lq_tag_w),
        .resv_lq_epoch      (mshr_resv_lq_epoch_w),
        .resv_word_idx      (mshr_resv_word_idx_w),
        .resv_store_mask    (mshr_resv_store_mask_w),
        .resv_store_data    (mshr_resv_store_data_w),
        .resv_store_widx    (mshr_resv_store_widx_w),
        .merge_valid        (mshr_merge_valid_w),
        .merge_sel          (mshr_merge_sel_w),
        .merge_ready        (mshr_merge_ready_w),
        .merge_is_store     (mshr_merge_is_store_w),
        .merge_lq_idx       (mshr_merge_lq_idx_w),
        .merge_lq_tag       (mshr_merge_lq_tag_w),
        .merge_lq_epoch     (mshr_merge_lq_epoch_w),
        .merge_word_idx     (mshr_merge_word_idx_w),
        .merge_store_mask   (mshr_merge_store_mask_w),
        .merge_store_data   (mshr_merge_store_data_w),
        .merge_store_widx   (mshr_merge_store_widx_w),
        .cap_req_valid      (mshr_cap_req_valid_w),
        .cap_req_way        (mshr_cap_req_way_w),
        .cap_req_row        (mshr_cap_req_row_w),
        .cap_gnt            (mshr_cap_gnt_w),
        .cap_rsp_valid      (dc_cap_rsp_valid_w),
        .cap_rsp_set        (dc_cap_rsp_set_w),
        .cap_rsp_row        (dc_cap_rsp_row_w),
        .cap_rsp_way        (dc_cap_rsp_way_w),
        .cap_rsp_data       (dc_cap_rsp_data_w),
        .wb_wr_valid        (mshr_wb_wr_valid_w),
        .wb_wr_idx          (mshr_wb_wr_idx_w),
        .wb_wr_row          (mshr_wb_wr_row_w),
        .wb_wr_data         (mshr_wb_wr_data_w),
        .wb_wr_last         (mshr_wb_wr_last_w),
        .ovl_valid          (mshr_ovl_valid_w),
        .ovl_sel            (mshr_ovl_sel_w),
        .ovl_ready          (mshr_ovl_ready_w),
        .ovl_widx           (mshr_ovl_widx_w),
        .ovl_mask           (mshr_ovl_mask_w),
        .ovl_data           (mshr_ovl_data_w),
        .refill_req_valid   (mshr_refill_req_valid_w),
        .refill_req_ready   (mshr_refill_req_ready_w),
        .refill_line_addr   (mshr_refill_line_addr_w),
        .refill_rsp_valid   (mshr_refill_rsp_valid_w),
        .refill_rsp_ready   (mshr_refill_rsp_ready_w),
        .refill_line_data   (mshr_refill_line_data_w),
        .refill_beat_valid  (mshr_refill_beat_valid_w),
        .inst_valid         (mshr_inst_valid_w),
        .inst_way           (mshr_inst_way_w),
        .inst_set           (mshr_inst_set_w),
        .inst_row           (mshr_inst_row_w),
        .inst_data          (mshr_inst_data_w),
        .inst_be            (mshr_inst_be_w),
        .inst_last          (mshr_inst_last_w),
        .inst_gnt           (mshr_inst_gnt_w),
        .pub_valid          (mshr_pub_valid_w),
        .pub_way            (mshr_pub_way_w),
        .pub_tag            (mshr_pub_tag_w),
        .pub_dirty          (mshr_pub_dirty_w),
        .wake_valid         (mshr_wake_valid_w),
        .wake_lq_idx        (mshr_wake_lq_idx_w),
        .wake_word          (mshr_wake_word_w),
        .wake_ready         (mshr_wake_ready_w),
        .lq_wait_pending    (lq_wait_pending_w),
        .lq_wait_tag        (lq_wait_tag_w),
        .lq_wait_epoch      (lq_wait_epoch_w)
    );

    //-------------------------------------------------------------------------
    // LQ fill port arbitration: C3 hit first, then MSHR wake (D-M2b-05)
    //-------------------------------------------------------------------------
    wire hit_fill_w = dc_hit_fill_valid_w;
    wire wake0_w    = mshr_wake_valid_w[0];
    wire wake1_w    = mshr_wake_valid_w[1] && !wake0_w;
    wire wake_sel_w = !hit_fill_w && (wake0_w || wake1_w);

    assign lq_fill_valid_w = hit_fill_w || wake_sel_w;
    assign lq_fill_idx_w   = hit_fill_w ? dc_hit_fill_idx_w
                         : (wake0_w ? mshr_wake_lq_idx_w[0] : mshr_wake_lq_idx_w[1]);
    assign lq_fill_word_w  = hit_fill_w ? dc_hit_fill_word_w
                         : (wake0_w ? mshr_wake_word_w[0] : mshr_wake_word_w[1]);
    assign mshr_wake_ready_w = {wake_sel_w && wake1_w, wake_sel_w && wake0_w};
//-------------------------------------------------------------------------
    // L09 Writeback buffer
    //-------------------------------------------------------------------------
    logic                    wb_cap_valid_w;
    logic [1:0]              wb_cap_idx_w;
    logic [$clog2(ROWS_PER_LINE)-1:0] wb_cap_row_w;
    logic [63:0]             wb_cap_data_w;
    logic                    wb_cap_last_w;
    logic                    wb_wb_req_valid_w;
    logic                    wb_wb_req_ready_w;
    logic [31:0]             wb_wb_line_addr_w;
    logic [8*LINE_BYTES-1:0] wb_wb_line_data_w;
    logic                    wb_done_w;
    /* verilator lint_off UNUSEDSIGNAL */  // busy is checked by the alloc assertion
    logic [WB_ENTRIES-1:0]   wb_busy_w;
    /* verilator lint_on UNUSEDSIGNAL */

    assign wb_cap_valid_w = mshr_wb_wr_valid_w[0] || mshr_wb_wr_valid_w[1];
    assign wb_cap_idx_w   = mshr_wb_wr_valid_w[0] ? mshr_wb_wr_idx_w[0] : mshr_wb_wr_idx_w[1];
    assign wb_cap_row_w   = mshr_wb_wr_valid_w[0] ? mshr_wb_wr_row_w[0] : mshr_wb_wr_row_w[1];
    assign wb_cap_data_w  = mshr_wb_wr_valid_w[0] ? mshr_wb_wr_data_w[0] : mshr_wb_wr_data_w[1];
    assign wb_cap_last_w  = mshr_wb_wr_valid_w[0] ? mshr_wb_wr_last_w[0] : mshr_wb_wr_last_w[1];

    wb_buffer u_wb (
        .clk                 (clk),
        .rst                 (rst),
        .alloc_valid         (dc_wb_alloc_valid_w),
        .alloc_idx           (dc_wb_alloc_idx_w),
        .alloc_line_addr     (dc_wb_alloc_line_addr_w),
        .free_mask           (wb_free_mask_w),
        .cap_wr_valid        (wb_cap_valid_w),
        .cap_wr_idx          (wb_cap_idx_w),
        .cap_wr_row          (wb_cap_row_w),
        .cap_wr_data         (wb_cap_data_w),
        .cap_wr_last         (wb_cap_last_w),
        .wb_req_valid        (wb_wb_req_valid_w),
        .wb_req_ready        (wb_wb_req_ready_w),
        .wb_line_addr        (wb_wb_line_addr_w),
        .wb_line_data        (wb_wb_line_data_w),
        .wb_done             (wb_done_w),
        .vis_query_line_addr (dc_wb_vis_query_w),
        .vis_query_block     (wb_vis_block_w),
        .busy                (wb_busy_w)
    );

    //-------------------------------------------------------------------------
    // L10 line adapter (refill + writeback; the M2a single-beat ports are idle)
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic        unused_beat_rd_rsp_valid, unused_beat_wr_done;
    logic        unused_beat_rd_req_ready, unused_beat_wr_req_ready;
    logic [127:0] unused_beat_rd_rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

    line_adapter u_line_adapter (
        .clk               (clk),
        .rst               (rst),
        .refill_req_valid  (mshr_refill_req_valid_w),
        .refill_req_ready  (mshr_refill_req_ready_w),
        .refill_line_addr  (mshr_refill_line_addr_w),
        .refill_rsp_valid  (mshr_refill_rsp_valid_w),
        .refill_rsp_ready  (mshr_refill_rsp_ready_w),
        .refill_line_data  (mshr_refill_line_data_w),
        .refill_beat_valid (mshr_refill_beat_valid_w),
        .beat_rd_req_valid (1'b0),
        .beat_rd_req_ready (unused_beat_rd_req_ready),
        .beat_rd_req_addr  (32'd0),
        .beat_rd_rsp_valid (unused_beat_rd_rsp_valid),
        .beat_rd_rsp_ready (1'b0),
        .beat_rd_rsp_data  (unused_beat_rd_rsp_data),
        .wb_req_valid      (wb_wb_req_valid_w),
        .wb_req_ready      (wb_wb_req_ready_w),
        .wb_line_addr      (wb_wb_line_addr_w),
        .wb_line_data      (wb_wb_line_data_w),
        .wb_done           (wb_done_w),
        .beat_wr_req_valid (1'b0),
        .beat_wr_req_ready (unused_beat_wr_req_ready),
        .beat_wr_req_addr  (32'd0),
        .beat_wr_req_data  (128'd0),
        .beat_wr_req_be    (16'd0),
        .beat_wr_done      (unused_beat_wr_done),
        .mem_rd_valid      (mem_rd_valid),
        .mem_rd_ready      (mem_rd_ready),
        .mem_rd_addr       (mem_rd_addr),
        .mem_rsp_valid     (mem_rsp_valid),
        .mem_rsp_ready     (mem_rsp_ready),
        .mem_rsp_data      (mem_rsp_data),
        .mem_wr_valid      (mem_wr_valid),
        .mem_wr_ready      (mem_wr_ready),
        .mem_wr_addr       (mem_wr_addr),
        .mem_wr_data       (mem_wr_data),
        .mem_wr_be         (mem_wr_be)
    );

    //-------------------------------------------------------------------------
    // L11 MMIO bridge (single outstanding device transaction)
    //-------------------------------------------------------------------------
    logic        mmio_sq_req_ready_w, mmio_sq_req_ack_w;
    logic        mmio_busy_w;
    logic        mmio_req_valid_w, mmio_write_w;
    logic [31:0] mmio_addr_w, mmio_wdata_w;
    logic [3:0]  mmio_wstrb_w;

    wire sq_mmio_w = sq_drain_valid_w && sq_drain_is_mmio_w;

    mmio_bridge u_mmio (
        .clk           (clk),
        .rst           (rst),
        .lq_req_valid  (lq_mmio_req_valid_w),
        .lq_req_ready  (lq_mmio_req_ready_w),
        .lq_req_addr   (lq_mmio_req_addr_w),
        .lq_rsp_valid  (lq_mmio_rsp_valid_w),
        .lq_rsp_data   (mmio_rsp_data),
        .sq_req_valid  (sq_mmio_w),
        .sq_req_ready  (mmio_sq_req_ready_w),
        .sq_req_ack    (mmio_sq_req_ack_w),
        .sq_req_addr   (sq_drain_addr_w),
        .sq_req_data   (sq_drain_data_w),
        .sq_req_strb   (sq_drain_mask_w),
        .mmio_req_valid(mmio_req_valid_w),
        .mmio_req_ready(mmio_req_ready),
        .mmio_write    (mmio_write_w),
        .mmio_addr     (mmio_addr_w),
        .mmio_wdata    (mmio_wdata_w),
        .mmio_wstrb    (mmio_wstrb_w),
        .mmio_rsp_valid(mmio_rsp_valid),
        .mmio_rsp_ready(mmio_rsp_ready),
        .mmio_rsp_data (mmio_rsp_data),
        .busy          (mmio_busy_w)
    );

    assign mmio_req_valid = mmio_req_valid_w;
    assign mmio_write     = mmio_write_w;
    assign mmio_addr      = mmio_addr_w;
    assign mmio_wdata     = mmio_wdata_w;
    assign mmio_wstrb     = mmio_wstrb_w;

    // SQ drain ownership handshakes (cacheable vs MMIO are mutually exclusive)
    assign sq_drain_start_w    = (sq_drain_valid_w && !sq_drain_is_mmio_w && dc_store_start_w)
                              || (sq_mmio_w && mmio_sq_req_ready_w);
    assign sq_drain_takeover_w = dc_store_takeover_w || mmio_sq_req_ack_w;

    //-------------------------------------------------------------------------
    // L12 completion (fast path = load result, FIFO = store execute result)
    //-------------------------------------------------------------------------
    logic [1:0] unused_fifo_count;
    logic       unused_fifo_empty;

    lsu_completion u_completion (
        .clk             (clk),
        .rst             (rst),
        .fast_valid      (lq_compl_valid_w),
        .fast_tag        (lq_compl_tag_w),
        .fast_result     (lq_compl_result_w),
        .fast_take       (lq_compl_ready_w),
        .push_valid      (sq_exec_valid_w),
        .push_tag        (sq_exec_tag_w),
        .push_result     (32'd0),
        .push_ready      (sq_exec_ready_w),
        .completion_valid(completion_valid),
        .completion      (completion),
        .kill_mask       (kill_mask),
        .fifo_count      (unused_fifo_count),
        .fifo_empty      (unused_fifo_empty)
    );

    //-------------------------------------------------------------------------
    // Backend-visible accepted / ordering outputs
    //-------------------------------------------------------------------------
    assign lsu_can_accept      = lsu_can_accept_w;
    assign lsu_mmio_order_idle = !mmio_busy_w && !sq_mmio_store_pending_w;

    // FENCE/FENCE.I may only execute after every older cacheable/MMIO access
    // has left the load and store queues.  Waiting for SQ occupancy (not just
    // MMIO) is what makes FENCE order ordinary stores as well.
    assign lsu_fence_idle      = !mmio_busy_w && !sq_mmio_store_pending_w
                              && (sq_occupancy_w == 4'd0) && (lq_used_w == 3'd0);

`ifdef CONFIG_SIMULATION
    // Only load/store operations reach the LSU port.
    a_issue_op: assert property (@(posedge clk) disable iff (rst)
        issue_valid |-> (issue_is_load || issue_is_store));

    // Credits are the start-of-cycle free capacity of the two queues.
    a_lq_credit_full: assert property (@(posedge clk) disable iff (rst)
        lq_full_w == (load_credit == 3'd0));
    a_sq_credit_full: assert property (@(posedge clk) disable iff (rst)
        sq_full_w == (store_credit == 4'd0));

    // Queue drain candidates are NATURALLY aligned (memory.md 1).
    a_drain_mask_legal: assert property (@(posedge clk) disable iff (rst)
        sq_drain_valid_w |-> (
            (sq_drain_mask_w == (4'h1 << sq_drain_addr_w[1:0]))
         || ((sq_drain_mask_w == (4'h3 << sq_drain_addr_w[1:0])) && !sq_drain_addr_w[0])
         || ((sq_drain_mask_w == 4'hF) && (sq_drain_addr_w[1:0] == 2'b00))));

    // The single LQ fill port has exactly one source per cycle; a wake that
    // lost the port to a C3 hit is deferred (not acknowledged) this cycle.
    a_fill_one_source: assert property (@(posedge clk) disable iff (rst)
        !(dc_hit_fill_valid_w && wake_sel_w));
    a_wake_deferred: assert property (@(posedge clk) disable iff (rst)
        (dc_hit_fill_valid_w && (|mshr_wake_valid_w)) |-> (mshr_wake_ready_w == '0));

    // An MSHR wake is always acknowledged (handed over or dropped).
    a_wake_acked: assert property (@(posedge clk) disable iff (rst)
        (|mshr_wake_valid_w) |-> (|mshr_wake_ready_w) || dc_hit_fill_valid_w);

    // Device address is word aligned (memory.md 3.1).
    a_mmio_align: assert property (@(posedge clk) disable iff (rst)
        mmio_req_valid_w |-> (mmio_addr_w[1:0] == 2'b00));

    // A device transaction is only outstanding after it was accepted.
    a_mmio_rsp_owned: assert property (@(posedge clk) disable iff (rst)
        mmio_rsp_valid |-> mmio_busy_w);

    // The busy/lock views stay consistent (MSHR) and allocation only uses a
    // free WB entry.
    a_mshr_busy_lock: assert property (@(posedge clk) disable iff (rst)
        mshr_busy_w == mshr_lock_valid_w);
    a_wb_alloc_free: assert property (@(posedge clk) disable iff (rst)
        dc_wb_alloc_valid_w |-> !wb_busy_w[dc_wb_alloc_idx_w[0]]);

    // SQ drain ownership is only taken for the currently presented store.
    a_drain_start_src: assert property (@(posedge clk) disable iff (rst)
        sq_drain_start_w |-> sq_drain_valid_w || mmio_busy_w);

    // MMIO and cacheable paths never own the same SQ store at once.
    a_mmio_cache_excl: assert property (@(posedge clk) disable iff (rst)
        !(dc_store_takeover_w && mmio_sq_req_ack_w));
`endif

endmodule


