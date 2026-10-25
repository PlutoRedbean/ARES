//=============================================================================
// ARES - real frontend + legacy adapter + core + shared L2 (C5 bring-up)
//-----------------------------------------------------------------------------
// Single-hart integration of the existing rtl/frontend with the current
// backend contract.  The frontend's AXI ICache master is bridged to the L2 I
// read port; the core D side uses L2 core port 0.  Core port 1 is tied off in
// this single-hart top.
//
// FE contract details:
//   * IQ/redirect are adapted combinationally;
//   * BPU updates use fe_legacy_adapter's 4-entry 2-push/1-pop FIFO;
//   * the frontend itself is unchanged.
//
// MMIO is a one-cycle stub; CoreMark does not use it.
//=============================================================================
module ares_frontend_l2_top #(
    parameter logic [31:0] RESET_MTVEC = ares_pkg::RESET_PC,
    parameter logic [31:0] RESET_VEC   = ares_pkg::RESET_PC,
    parameter int unsigned L2_SETS     = 128
) (
    input logic clk,
    input logic rst,

    //---- shared L2 memory port ---------------------------------------------
    output logic         l2_mem_rd_valid,
    input  logic         l2_mem_rd_ready,
    output logic [ 31:0] l2_mem_rd_addr,
    input  logic         l2_mem_rsp_valid,
    output logic         l2_mem_rsp_ready,
    input  logic [127:0] l2_mem_rsp_data,
    output logic         l2_mem_wr_valid,
    input  logic         l2_mem_wr_ready,
    output logic [ 31:0] l2_mem_wr_addr,
    output logic [127:0] l2_mem_wr_data,
    output logic [ 15:0] l2_mem_wr_be,

    //---- observation --------------------------------------------------------
    output logic         l2_idle,
    output logic [ 31:0] l2_hit_count,
    output logic [ 31:0] l2_miss_count,
    output logic [ 31:0] fe_fetch_pc,
    output logic [ 1:0]  retire_valid,
    output logic [ 1:0]  retire_rd_wen,
    output logic [ 4:0]  retire_rd [2],
    output logic [31:0]  retire_wdata [2],
    output logic [31:0]  retire_pc [2],
    output logic [ 1:0]  retire_is_ebreak
);
    axi_if ifu_axi();

    // Legacy frontend contract.
    logic [1:0] fe_iq_rvalid;
    fe_pkg::iq_entry_t fe_iq_rbits [2];
    logic [1:0] fe_iq_raccept_cnt;
    logic fe_redirect_valid;
    logic [31:0] fe_redirect_pc;
    fe_pkg::fe_redirect_kind_t fe_redirect_kind;
    logic fe_bpu_update_en;
    fe_pkg::bpu_update_t fe_bpu_update_meta;

    // New backend contract.
    logic [1:0] be_iq_valid;
    fe_pkg::iq_entry_t be_iq_inst [2];
    logic [1:0] be_iq_accept_count;
    logic be_redirect_valid;
    logic [31:0] be_redirect_pc;
    fe_pkg::fe_redirect_kind_t be_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] be_redirect_ghr_before;
    logic be_redirect_actual_taken;
    logic [1:0] be_bpu_update_credit;
    logic [1:0] be_bpu_update_valid;
    fe_pkg::bpu_update_t be_bpu_update [2];

    frontend #(
        .RESET_VEC(RESET_VEC)
    ) u_fe (
        .clk(clk), .rst(rst),
        .iq_rvalid(fe_iq_rvalid), .iq_rbits(fe_iq_rbits),
        .iq_raccept_cnt(fe_iq_raccept_cnt),
        .backend_redirect_valid(fe_redirect_valid),
        .backend_redirect_pc(fe_redirect_pc),
        .backend_redirect_kind(fe_redirect_kind),
        .bpu_update_en(fe_bpu_update_en),
        .bpu_update_meta(fe_bpu_update_meta),
        .ifu_axi_bus(ifu_axi),
        .fetch_pc_out(fe_fetch_pc),
        .iq_occupancy(), .iq_enq_count(), .iq_deq_count(),
        .ftq_occupancy(), .ftq_alloc(), .ftq_pop(),
        .icache_refill(), .icache_req_fire()
    );

    fe_legacy_adapter u_adapter (
        .clk(clk), .rst(rst),
        .fe_iq_rvalid(fe_iq_rvalid), .fe_iq_rbits(fe_iq_rbits),
        .fe_iq_raccept_cnt(fe_iq_raccept_cnt),
        .fe_redirect_valid(fe_redirect_valid), .fe_redirect_pc(fe_redirect_pc),
        .fe_redirect_kind(fe_redirect_kind),
        .fe_bpu_update_en(fe_bpu_update_en), .fe_bpu_update_meta(fe_bpu_update_meta),
        .be_iq_valid(be_iq_valid), .be_iq_inst(be_iq_inst),
        .be_iq_accept_count(be_iq_accept_count),
        .be_redirect_valid(be_redirect_valid), .be_redirect_pc(be_redirect_pc),
        .be_redirect_kind(be_redirect_kind),
        .be_redirect_ghr_before(be_redirect_ghr_before),
        .be_redirect_actual_taken(be_redirect_actual_taken),
        .be_bpu_update_credit(be_bpu_update_credit),
        .be_bpu_update_valid(be_bpu_update_valid),
        .be_bpu_update(be_bpu_update)
    );

    // L2 instruction read port.
    logic         l2_i_rd_valid, l2_i_rd_ready;
    logic [31:0]  l2_i_rd_addr;
    logic         l2_i_rsp_valid, l2_i_rsp_ready;
    logic [127:0] l2_i_rsp_data;

    axi_l2_bridge u_ibridge (
        .clk(clk), .rst(rst),
        .axi(ifu_axi),
        .l2_rd_valid(l2_i_rd_valid), .l2_rd_ready(l2_i_rd_ready), .l2_rd_addr(l2_i_rd_addr),
        .l2_rsp_valid(l2_i_rsp_valid), .l2_rsp_ready(l2_i_rsp_ready), .l2_rsp_data(l2_i_rsp_data)
    );

    // Core D side.
    logic c0_mem_rd_valid, c0_mem_rd_ready, c0_mem_rsp_valid, c0_mem_rsp_ready;
    logic [31:0] c0_mem_rd_addr;
    logic [127:0] c0_mem_rsp_data;
    logic c0_mem_wr_valid, c0_mem_wr_ready;
    logic [31:0] c0_mem_wr_addr;
    logic [127:0] c0_mem_wr_data;
    logic [15:0] c0_mem_wr_be;

    // MMIO stub.
    /* verilator lint_off UNUSEDSIGNAL */
    logic mmio_req_valid, mmio_req_ready, mmio_write;
    logic [31:0] mmio_addr, mmio_wdata;
    logic [3:0] mmio_wstrb;
    logic mmio_rsp_valid, mmio_rsp_ready;
    logic [31:0] mmio_rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

    assign mmio_req_ready = 1'b1;
    assign mmio_rsp_ready = 1'b1;
    assign mmio_rsp_data  = 32'h0;
    always_ff @(posedge clk) begin
        if (rst) mmio_rsp_valid <= 1'b0;
        else     mmio_rsp_valid <= mmio_req_valid;
    end

    ares_core_top #(
        .RESET_MTVEC(RESET_MTVEC),
        .HART_ID(32'd0)
    ) u_core (
        .clk(clk), .rst(rst),
        .iq_valid(be_iq_valid), .iq_inst(be_iq_inst), .iq_accept_count(be_iq_accept_count),
        .backend_redirect_valid(be_redirect_valid), .backend_redirect_pc(be_redirect_pc),
        .backend_redirect_kind(be_redirect_kind),
        .backend_redirect_ghr_before(be_redirect_ghr_before),
        .backend_redirect_actual_taken(be_redirect_actual_taken),
        .bpu_update_credit(be_bpu_update_credit),
        .bpu_update_valid(be_bpu_update_valid), .bpu_update(be_bpu_update),
        .timer_irq(1'b0), .software_irq(1'b0), .external_irq(1'b0),
        .fence_i_valid(),
        .mem_rd_valid(c0_mem_rd_valid), .mem_rd_ready(c0_mem_rd_ready), .mem_rd_addr(c0_mem_rd_addr),
        .mem_rsp_valid(c0_mem_rsp_valid), .mem_rsp_ready(c0_mem_rsp_ready), .mem_rsp_data(c0_mem_rsp_data),
        .mem_wr_valid(c0_mem_wr_valid), .mem_wr_ready(c0_mem_wr_ready), .mem_wr_addr(c0_mem_wr_addr),
        .mem_wr_data(c0_mem_wr_data), .mem_wr_be(c0_mem_wr_be),
        .mmio_req_valid(mmio_req_valid), .mmio_req_ready(mmio_req_ready),
        .mmio_write(mmio_write), .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_wstrb(mmio_wstrb),
        .mmio_rsp_valid(mmio_rsp_valid), .mmio_rsp_ready(mmio_rsp_ready),
        .mmio_rsp_data(mmio_rsp_data),
        .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_pc_next(),
        .retire_rd_wen(retire_rd_wen), .retire_rd(retire_rd),
        .retire_wdata(retire_wdata), .retire_is_ebreak(retire_is_ebreak),
        .irq_redirect_valid(), .irq_redirect_pc(),
        .decode_err(), .decode_err_pc(), .decode_err_inst(), .dep_error(),
        .dbg_occupancy(), .dbg_arch_next_pc(), .dbg_lq_used(), .dbg_sq_used()
    );

    logic c1_rd_ready, c1_rsp_valid;
    logic [127:0] c1_rsp_data;
    logic c1_wr_ready;

    l2_top #(
        .SETS(L2_SETS), .WAYS(4)
    ) u_l2 (
        .clk(clk), .rst(rst),
        .c0_rd_valid(c0_mem_rd_valid), .c0_rd_ready(c0_mem_rd_ready), .c0_rd_addr(c0_mem_rd_addr),
        .c0_rsp_valid(c0_mem_rsp_valid), .c0_rsp_ready(c0_mem_rsp_ready), .c0_rsp_data(c0_mem_rsp_data),
        .c0_wr_valid(c0_mem_wr_valid), .c0_wr_ready(c0_mem_wr_ready), .c0_wr_addr(c0_mem_wr_addr),
        .c0_wr_data(c0_mem_wr_data), .c0_wr_be(c0_mem_wr_be),
        .c1_rd_valid(1'b0), .c1_rd_ready(c1_rd_ready), .c1_rd_addr(32'h0),
        .c1_rsp_valid(c1_rsp_valid), .c1_rsp_ready(1'b0), .c1_rsp_data(c1_rsp_data),
        .c1_wr_valid(1'b0), .c1_wr_ready(c1_wr_ready), .c1_wr_addr(32'h0),
        .c1_wr_data(128'h0), .c1_wr_be(16'h0),
        .i_rd_valid(l2_i_rd_valid), .i_rd_ready(l2_i_rd_ready), .i_rd_addr(l2_i_rd_addr),
        .i_rsp_valid(l2_i_rsp_valid), .i_rsp_ready(l2_i_rsp_ready), .i_rsp_data(l2_i_rsp_data),
        .mem_rd_valid(l2_mem_rd_valid), .mem_rd_ready(l2_mem_rd_ready), .mem_rd_addr(l2_mem_rd_addr),
        .mem_rsp_valid(l2_mem_rsp_valid), .mem_rsp_ready(l2_mem_rsp_ready), .mem_rsp_data(l2_mem_rsp_data),
        .mem_wr_valid(l2_mem_wr_valid), .mem_wr_ready(l2_mem_wr_ready), .mem_wr_addr(l2_mem_wr_addr),
        .mem_wr_data(l2_mem_wr_data), .mem_wr_be(l2_mem_wr_be),
        .l2_idle(l2_idle), .hit_count(l2_hit_count), .miss_count(l2_miss_count)
    );

endmodule
