//=============================================================================
// ARES - real frontend + C5 contract + core + shared L2 (C5 bring-up)
//-----------------------------------------------------------------------------
// Single-hart integration of the existing rtl/frontend with the current
// backend contract.  The frontend's AXI ICache master is bridged to the L2 I
// read port; the core D side uses L2 core port 0.  Core port 1 is tied off in
// this single-hart top.
//
// FE contract details:
//   * IQ consumes a contiguous prefix by count;
//   * redirects carry independent history and predictor checkpoints;
//   * two-lane BPU updates use the frontend's native credit interface.
//
// MMIO includes the matrix/state engines, a cycle counter and an RTL UART.
//=============================================================================
module ares_frontend_l2_top #(
    parameter logic [31:0] RESET_MTVEC = ares_pkg::RESET_PC,
    parameter logic [31:0] RESET_VEC   = ares_pkg::RESET_PC,
    parameter int unsigned L2_SETS     = 128,
    parameter int unsigned CLK_HZ      = 100_000_000,
    parameter int unsigned UART_BAUD   = 115_200
) (
    input logic clk,
    input logic rst,
    output logic uart_tx, uart_busy,

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

    logic [1:0] be_iq_valid, be_iq_accept_count;
    fe_pkg::iq_entry_t be_iq_inst [2];
    logic be_redirect_valid, be_redirect_actual_taken;
    logic [31:0] be_redirect_pc;
    fe_pkg::fe_redirect_kind_t be_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] be_redirect_ghr_before;
    fe_pkg::bpu_update_t be_redirect_info;
    logic [1:0] be_bpu_update_credit, be_bpu_update_valid;
    fe_pkg::bpu_update_t be_bpu_update [2];

    frontend #(.RESET_VEC(RESET_VEC)) u_fe (
        .clk(clk), .rst(rst),
        .iq_rvalid(be_iq_valid), .iq_rbits(be_iq_inst), .iq_raccept_cnt(be_iq_accept_count),
        .backend_redirect_valid(be_redirect_valid), .backend_redirect_pc(be_redirect_pc),
        .backend_redirect_kind(be_redirect_kind),
        .backend_redirect_ghr_before(be_redirect_ghr_before),
        .backend_redirect_actual_taken(be_redirect_actual_taken),
        .backend_redirect_info(be_redirect_info),
        .bpu_update_credit(be_bpu_update_credit),
        .bpu_update_valid(be_bpu_update_valid), .bpu_update(be_bpu_update),
        .ifu_axi_bus(ifu_axi), .fetch_pc_out(fe_fetch_pc),
        .iq_occupancy(), .iq_enq_count(), .iq_deq_count(),
        .ftq_occupancy(), .ftq_alloc(), .ftq_pop(), .icache_refill(), .icache_req_fire()
    );

    // L2 instruction read port.
    logic         l2_i_rd_valid, l2_i_rd_ready;
    logic [31:0]  l2_i_rd_addr;
    logic         l2_i_rsp_valid, l2_i_rsp_ready;
    logic [127:0] l2_i_rsp_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic         i1_rd_ready, i1_rsp_valid;
    logic [127:0] i1_rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

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

    // MMIO accelerators: matrix at 0xA000_1000, state at 0xA000_2000.
    localparam logic [31:0] MTX_BASE   = 32'hA000_1000;
    localparam logic [31:0] STATE_BASE = 32'hA000_2000;
    localparam logic [31:0] ACCEL_MASK = 32'hFFFF_F000;

    logic mmio_req_valid, mmio_req_ready, mmio_write;
    logic [31:0] mmio_addr, mmio_wdata;
    logic [3:0] mmio_wstrb;
    logic mmio_rsp_valid, mmio_rsp_ready;
    logic [31:0] mmio_rsp_data;

    wire mmio_mtx_sel   = ((mmio_addr & ACCEL_MASK) == MTX_BASE);
    wire mmio_state_sel = ((mmio_addr & ACCEL_MASK) == STATE_BASE);
    wire [1:0] mmio_dev_sel = mmio_mtx_sel ? 2'd1 :
                              mmio_state_sel ? 2'd2 : 2'd0;
    logic [1:0] mmio_dev_sel_q;
    logic mmio_io_rsp_valid, mmio_io_req_ready, mmio_mtx_rsp_valid, mmio_state_rsp_valid;
    logic [31:0] mmio_io_rsp_data;
    logic [31:0] mmio_mtx_rsp_data, mmio_state_rsp_data;

    assign mmio_req_ready = (mmio_dev_sel == 2'd0) ? mmio_io_req_ready : 1'b1;

    ares_benchmark_io #(.CLK_HZ(CLK_HZ), .UART_BAUD(UART_BAUD)) u_io (
        .clk(clk), .rst(rst),
        .host_req_valid(mmio_req_valid && (mmio_dev_sel == 2'd0)),
        .host_req_ready(mmio_io_req_ready), .host_write(mmio_write),
        .host_addr(mmio_addr), .host_wdata(mmio_wdata), .host_wstrb(mmio_wstrb),
        .host_rsp_valid(mmio_io_rsp_valid), .host_rsp_ready(mmio_rsp_ready),
        .host_rsp_data(mmio_io_rsp_data), .uart_tx(uart_tx), .uart_busy(uart_busy)
    );

    always_ff @(posedge clk) begin
        if (rst) mmio_dev_sel_q <= 2'd0;
        else if (mmio_req_valid && mmio_req_ready) mmio_dev_sel_q <= mmio_dev_sel;
    end

    always_comb begin
        case (mmio_dev_sel_q)
            2'd1: begin
                mmio_rsp_valid = mmio_mtx_rsp_valid;
                mmio_rsp_data  = mmio_mtx_rsp_data;
            end
            2'd2: begin
                mmio_rsp_valid = mmio_state_rsp_valid;
                mmio_rsp_data  = mmio_state_rsp_data;
            end
            default: begin
                mmio_rsp_valid = mmio_io_rsp_valid;
                mmio_rsp_data  = mmio_io_rsp_data;
            end
        endcase
    end

    mtx9_engine u_mtx (
        .clk(clk), .rst(rst),
        .host_req_valid(mmio_req_valid && mmio_mtx_sel),
        .host_req_ready(),
        .host_write(mmio_write),
        .host_addr(mmio_addr),
        .host_wdata(mmio_wdata),
        .host_wstrb(mmio_wstrb),
        .host_rsp_valid(mmio_mtx_rsp_valid),
        .host_rsp_data(mmio_mtx_rsp_data)
    );

    state9_engine u_state (
        .clk(clk), .rst(rst),
        .host_req_valid(mmio_req_valid && mmio_state_sel),
        .host_req_ready(),
        .host_write(mmio_write),
        .host_addr(mmio_addr),
        .host_wdata(mmio_wdata),
        .host_wstrb(mmio_wstrb),
        .host_rsp_valid(mmio_state_rsp_valid),
        .host_rsp_data(mmio_state_rsp_data)
    );

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
        .backend_redirect_info(be_redirect_info),
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


    l2_top #(
        .SETS(L2_SETS), .WAYS(4)
    ) u_l2 (
        .clk(clk), .rst(rst),
        .c0_rd_valid(c0_mem_rd_valid), .c0_rd_ready(c0_mem_rd_ready), .c0_rd_addr(c0_mem_rd_addr),
        .c0_rsp_valid(c0_mem_rsp_valid), .c0_rsp_ready(c0_mem_rsp_ready), .c0_rsp_data(c0_mem_rsp_data),
        .c0_wr_valid(c0_mem_wr_valid), .c0_wr_ready(c0_mem_wr_ready), .c0_wr_addr(c0_mem_wr_addr),
        .c0_wr_data(c0_mem_wr_data), .c0_wr_be(c0_mem_wr_be),
        .c1_rd_valid(1'b0), .c1_rd_ready(), .c1_rd_addr(32'h0),
        .c1_rsp_valid(), .c1_rsp_ready(1'b0), .c1_rsp_data(),
        .c1_wr_valid(1'b0), .c1_wr_ready(), .c1_wr_addr(32'h0),
        .c1_wr_data(128'h0), .c1_wr_be(16'h0),
        .i_rd_valid(l2_i_rd_valid), .i_rd_ready(l2_i_rd_ready), .i_rd_addr(l2_i_rd_addr),
        .i_rsp_valid(l2_i_rsp_valid), .i_rsp_ready(l2_i_rsp_ready), .i_rsp_data(l2_i_rsp_data),
        .i1_rd_valid(1'b0), .i1_rd_ready(i1_rd_ready), .i1_rd_addr(32'h0),
        .i1_rsp_valid(i1_rsp_valid), .i1_rsp_ready(1'b0), .i1_rsp_data(i1_rsp_data),
        .mem_rd_valid(l2_mem_rd_valid), .mem_rd_ready(l2_mem_rd_ready), .mem_rd_addr(l2_mem_rd_addr),
        .mem_rsp_valid(l2_mem_rsp_valid), .mem_rsp_ready(l2_mem_rsp_ready), .mem_rsp_data(l2_mem_rsp_data),
        .mem_wr_valid(l2_mem_wr_valid), .mem_wr_ready(l2_mem_wr_ready), .mem_wr_addr(l2_mem_wr_addr),
        .mem_wr_data(l2_mem_wr_data), .mem_wr_be(l2_mem_wr_be),
        .l2_idle(l2_idle), .hit_count(l2_hit_count), .miss_count(l2_miss_count)
    );

endmodule
