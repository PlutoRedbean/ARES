//=============================================================================
// ARES LSU - subsystem top, C2 M2a minimal read/write loop
//-----------------------------------------------------------------------------
// Backend-visible LSU boundary of backend.md 9.6 / plan 5.10 plus the internal
// convergence of the C2 M2a modules:
//
//   lsu_agu          (L02)  address generation, size/mask, is_mmio
//   lq               (L03)  4-entry load queue + store_forward snapshot
//   store_forward    (L05)  byte-wise closest-older-store selection (inside lq)
//   sq               (L04)  8-entry unified SQ (SPEC + COMMITTED)
//   lsu_completion   (L12)  fast path + 2-entry completion FIFO
//   line_adapter     (L10)  16B beat channel to the 128-bit memory bus
//
// STAGING NOTE (C2 M2a): dcache_top / mshr / wb_buffer / mmio_bridge (L06-L09,
// L11) are the M2b deliverables.  Until then a cacheable load is served by one
// 16-byte beat read and a cacheable store by one 16-byte beat write through
// line_adapter's single-beat port, and the MMIO single-outstanding sequencing
// logic lives here (it becomes mmio_bridge.sv in M2b).  This staging path only
// changes where the data comes from: every backend-visible contract
// (can_accept / credits / exactly-one completion / store commit handshake /
// kill priority / lsu_mmio_order_idle) is the final one.
//
// Spec sources: backend.md 9.6, memory.md 3 / 3.1 / 4 / 5 / 6.7 / 7 / 8,
// implementation_plan.md 5.10 / 5.11 / 5.14 / 6.3.
// FREE items: FREE-02 (subsystem file), FREE-11 (internal pipeline registers).
//=============================================================================
module lsu_top #(
    parameter logic [31:0] MMIO_BASE = 32'hA000_0000,
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

    // Allocation happens at the issue edge; a killed operation is accepted but
    // never enters a queue (it owes no completion).
    wire issue_killed = issue_valid && kill_mask[issue_req.tag.slot_index];
    wire alloc_valid  = issue_valid && !issue_killed;

    wire lq_full_w, sq_full_w;
    wire [1:0] lq_alloc_idx_w;
    wire [2:0] sq_alloc_idx_w;

    // "This cycle can guarantee to latch one request" (backend.md 9.6.1).
    //
    // IMPORTANT: this must be a function of REGISTERED state only.  The type of
    // the incoming operation is *not* inspected here: deriving can_accept from
    // issue_req.op would close a combinational loop through the backend, whose
    // issue_valid -> issue_req mux is itself gated by can_accept.  The
    // scheduler checks the type-specific load_credit / store_credit before it
    // raises issue_valid, exactly as memory.md 3 requires.
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
    // L04 SQ (also feeds the LQ forwarding path)
    //-------------------------------------------------------------------------
    logic        sq_exec_valid_w, sq_exec_ready_w;
    tag_t        sq_exec_tag_w;
    logic        sq_drain_valid_w;
    /* verilator lint_off UNUSEDSIGNAL */  // M2a direct path only needs addr/data/mask
    logic [2:0]  sq_drain_idx_w;
    tag_t        sq_drain_tag_w;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] sq_drain_addr_w, sq_drain_data_w;
    logic [3:0]  sq_drain_mask_w;
    logic        sq_drain_is_mmio_w;
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
    // L03 LQ  (+ store_forward instance inside)
    //-------------------------------------------------------------------------
    logic        lq_lookup_valid_w, lq_lookup_ready_w;
    logic [1:0]  lq_lookup_idx_w;
    tag_t        lq_lookup_tag_w;
    /* verilator lint_off UNUSEDSIGNAL */  // byte lane is selected inside the LQ
    logic [31:0] lq_lookup_addr_w;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        lq_fill_valid_w;
    logic [1:0]  lq_fill_idx_w;
    logic [31:0] lq_fill_word_w;
    logic        lq_mmio_req_valid_w;
    logic        lq_mmio_req_ready_w;
    logic [31:0] lq_mmio_req_addr_w;
    logic        lq_mmio_rsp_valid_w;
    logic        lq_compl_valid_w, lq_compl_ready_w;
    tag_t        lq_compl_tag_w;
    logic [31:0] lq_compl_result_w;
    logic [2:0]  lq_used_w;

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
        .lq_full            (lq_full_w)
    );

    assign load_credit  = 3'd4 - lq_used_w;
    assign dbg_lq_used  = lq_used_w;

    // The LQ exposes the lowest free slot it computed this cycle (start-of-cycle
    // state); the AGU carries the same index so the entry is registered later.

    //-------------------------------------------------------------------------
    // L10 line adapter (single-beat channel used by the M2a staging path)
    //-------------------------------------------------------------------------
    logic        ba_rd_req_valid_w, ba_rd_req_ready_w;
    logic [31:0] ba_rd_req_addr_w;
    logic        ba_rd_rsp_valid_w, ba_rd_rsp_ready_w;
    logic [127:0] ba_rd_rsp_data_w;
    logic        ba_wr_req_valid_w, ba_wr_req_ready_w;
    logic [31:0] ba_wr_req_addr_w;
    logic [127:0] ba_wr_req_data_w;
    logic [15:0] ba_wr_req_be_w;
    logic        ba_wr_done_w;


    // M2b (MSHR / WB buffer) is the only consumer of the line-level ports; in
    // M2a they are tied off, so their outputs are intentionally unconnected.
    /* verilator lint_off UNUSEDSIGNAL */
    logic        unused_refill_req_ready, unused_refill_rsp_valid, unused_wb_req_ready, unused_wb_done;
    logic [8*LINE_BYTES-1:0] unused_refill_line_data;
    logic [LINE_BEATS-1:0]   unused_refill_beat_valid;
    /* verilator lint_on UNUSEDSIGNAL */

    line_adapter u_line_adapter (
        .clk              (clk),
        .rst              (rst),
        .refill_req_valid (1'b0),
        .refill_req_ready (unused_refill_req_ready),
        .refill_line_addr (32'd0),
        .refill_rsp_valid (unused_refill_rsp_valid),
        .refill_rsp_ready (1'b0),
        .refill_line_data (unused_refill_line_data),
        .refill_beat_valid(unused_refill_beat_valid),
        .beat_rd_req_valid (ba_rd_req_valid_w),
        .beat_rd_req_ready (ba_rd_req_ready_w),
        .beat_rd_req_addr  (ba_rd_req_addr_w),
        .beat_rd_rsp_valid (ba_rd_rsp_valid_w),
        .beat_rd_rsp_ready (ba_rd_rsp_ready_w),
        .beat_rd_rsp_data  (ba_rd_rsp_data_w),
        .wb_req_valid      (1'b0),
        .wb_req_ready      (unused_wb_req_ready),
        .wb_line_addr      (32'd0),
        .wb_line_data      ('0),
        .wb_done           (unused_wb_done),
        .beat_wr_req_valid (ba_wr_req_valid_w),
        .beat_wr_req_ready (ba_wr_req_ready_w),
        .beat_wr_req_addr  (ba_wr_req_addr_w),
        .beat_wr_req_data  (ba_wr_req_data_w),
        .beat_wr_req_be    (ba_wr_req_be_w),
        .beat_wr_done      (ba_wr_done_w),
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
    // Cacheable load service: one 16B beat read per lookup request
    //-------------------------------------------------------------------------
    logic       rd_busy;
    logic [1:0] rd_idx;
    tag_t       rd_tag;
    logic [1:0] rd_word_sel;

    wire rd_fire = !rd_busy && lq_lookup_valid_w && ba_rd_req_ready_w;

    assign ba_rd_req_valid_w = !rd_busy && lq_lookup_valid_w;
    assign ba_rd_req_addr_w  = {lq_lookup_addr_w[31:4], 4'b0};
    assign lq_lookup_ready_w = !rd_busy && ba_rd_req_ready_w;

    // The 32-bit word that contains the requested address.
    wire [31:0] rd_word = ba_rd_rsp_data_w[32*rd_word_sel +: 32];

    // A response for a killed entry is consumed but never delivered.
    assign lq_fill_valid_w = ba_rd_rsp_valid_w && !kill_mask[rd_tag.slot_index];
    assign lq_fill_idx_w   = rd_idx;
    assign lq_fill_word_w  = rd_word;
    assign ba_rd_rsp_ready_w = 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_busy     <= 1'b0;
            rd_idx      <= 2'd0;
            rd_tag      <= '0;
            rd_word_sel <= 2'd0;
        end else begin
            if (rd_fire) begin
                rd_busy     <= 1'b1;
                rd_idx      <= lq_lookup_idx_w;
                rd_tag      <= lq_lookup_tag_w;
                rd_word_sel <= lq_lookup_addr_w[3:2];
            end else if (ba_rd_rsp_valid_w) begin
                rd_busy     <= 1'b0;
            end
        end
    end


    //-------------------------------------------------------------------------
    // MMIO single-outstanding sequencing (becomes mmio_bridge.sv in M2b)
    //-------------------------------------------------------------------------
    logic mmio_pending;       // a device transaction is outstanding
    logic mmio_owner_store;   // 1 = SQ store drain, 0 = LQ load

    wire lq_mmio_req = lq_mmio_req_valid_w && !mmio_pending;
    wire sq_mmio_req = sq_drain_valid_w && sq_drain_is_mmio_w && !mmio_pending;
    wire mmio_sel_store = sq_mmio_req && !lq_mmio_req;   // the LQ (older) wins

    assign mmio_req_valid = lq_mmio_req || sq_mmio_req;
    assign lq_mmio_req_ready_w = mmio_req_ready && lq_mmio_req && !mmio_sel_store;
    assign mmio_write = mmio_sel_store;
    assign mmio_addr  = mmio_sel_store ? {sq_drain_addr_w[31:2], 2'b00}
                                       : lq_mmio_req_addr_w;
    assign mmio_wdata = sq_drain_data_w;
    assign mmio_wstrb = mmio_sel_store ? sq_drain_mask_w : 4'h0;
    assign mmio_rsp_ready = 1'b1;

    wire mmio_fire           = mmio_req_valid && mmio_req_ready;
    wire mmio_rsp_store_fire = mmio_rsp_valid && mmio_pending && mmio_owner_store;
    assign lq_mmio_rsp_valid_w = mmio_rsp_valid && mmio_pending && !mmio_owner_store;

    always_ff @(posedge clk) begin
        if (rst) begin
            mmio_pending     <= 1'b0;
            mmio_owner_store <= 1'b0;
        end else begin
            if (mmio_fire) begin
                mmio_pending     <= 1'b1;
                mmio_owner_store <= mmio_sel_store;
            end else if (mmio_rsp_valid && mmio_pending) begin
                mmio_pending     <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Cacheable store drain: one 16B beat write with byte enables
    //-------------------------------------------------------------------------
    wire [15:0] drain_word_sel = 16'h000F << {sq_drain_addr_w[3:2], 2'b00};

    assign ba_wr_req_valid_w = sq_drain_valid_w && !sq_drain_is_mmio_w;
    assign ba_wr_req_addr_w  = {sq_drain_addr_w[31:4], 4'b0};
    assign ba_wr_req_data_w  = {4{sq_drain_data_w}};
    assign ba_wr_req_be_w    = {4{sq_drain_mask_w}} & drain_word_sel;

    wire sq_drain_start_w = (sq_drain_valid_w && !sq_drain_is_mmio_w && ba_wr_req_ready_w)
                         || (mmio_sel_store && mmio_req_ready);
    wire sq_drain_takeover_w = ba_wr_done_w || mmio_rsp_store_fire;

    //-------------------------------------------------------------------------
    // L12 completion (fast path = load result, FIFO = store execute result)
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // completion FIFO status is TB-only
    logic [1:0] unused_fifo_count;
    logic       unused_fifo_empty;
    /* verilator lint_on UNUSEDSIGNAL */

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
    assign lsu_can_accept     = lsu_can_accept_w;
    assign lsu_mmio_order_idle = !mmio_pending && !sq_mmio_store_pending_w;

`ifdef CONFIG_SIMULATION
    // Only load/store operations reach the LSU port.
    a_issue_op: assert property (@(posedge clk) disable iff (rst)
        issue_valid |-> (issue_is_load || issue_is_store));

    // Credits are the start-of-cycle free capacity of the two queues: the full
    // flag and "credit == 0" must be the same condition (memory.md 3).
    a_lq_credit_full: assert property (@(posedge clk) disable iff (rst)
        lq_full_w == (load_credit == 3'd0));
    a_sq_credit_full: assert property (@(posedge clk) disable iff (rst)
        sq_full_w == (store_credit == 4'd0));

    // Queue drain candidates are NATURALLY aligned (memory.md 1): the byte
    // enables of an N-byte store are the N contiguous lanes starting at
    // addr[1:0], i.e. SB/SH/SW keep their own alignment, not the word one.
    a_drain_mask_legal: assert property (@(posedge clk) disable iff (rst)
        sq_drain_valid_w |-> (
            (sq_drain_mask_w == (4'h1 << sq_drain_addr_w[1:0]))
         || ((sq_drain_mask_w == (4'h3 << sq_drain_addr_w[1:0])) && !sq_drain_addr_w[0])
         || ((sq_drain_mask_w == 4'hF) && (sq_drain_addr_w[1:0] == 2'b00))));

    // One outstanding cacheable read (memory.md 6.7 single outstanding read).
    a_single_read: assert property (@(posedge clk) disable iff (rst)
        ba_rd_req_valid_w |-> !rd_busy);

    // A device response always belongs to a registered transaction.
    a_mmio_rsp_owned: assert property (@(posedge clk) disable iff (rst)
        mmio_rsp_valid |-> mmio_pending);

    // Device address is word aligned (memory.md 3.1).
    a_mmio_align: assert property (@(posedge clk) disable iff (rst)
        mmio_req_valid |-> (mmio_addr[1:0] == 2'b00));

    // A beat write only happens for a COMMITTED SQ head that is not inflight.
    a_wr_from_head: assert property (@(posedge clk) disable iff (rst)
        ba_wr_req_valid_w |-> sq_drain_valid_w);
`endif

endmodule
