//=============================================================================
// ARES - two real-frontend harts + shared L2 (AMP bring-up)
//-----------------------------------------------------------------------------
// Two ares_frontend_hart instances (each: real frontend + native C5 interface + ICache AXI
// bridge + core) share one l2_top:
//   hart0 D -> L2 c0, I -> L2 i0
//   hart1 D -> L2 c1, I -> L2 i1
//
// hart1's D-side address is offset by C1_DATA_OFFSET so two CoreMark images
// can use the same code addresses but private data/stack regions.  Interrupts
// and MMIO xbar are still stubs; this top is the AMP CoreMark data path.
//=============================================================================
module ares_2core_frontend_l2_top #(
    parameter logic [31:0] RESET_MTVEC    = ares_pkg::RESET_PC,
    parameter logic [31:0] RESET_VEC      = ares_pkg::RESET_PC,
    parameter int unsigned L2_SETS        = 128,
    parameter logic [31:0] C1_DATA_OFFSET = 32'h0010_0000,
    parameter bit          HART1_ENABLE   = 1'b1
) (
    input logic clk,
    input logic rst,
    // Runtime hart1 enable (bring-up / debug).  ANDed with HART1_ENABLE so a
    // simulation can compare "hart0 alone" against "both harts" with the same
    // hardware configuration.
    input logic hart1_en,

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

    //---- observation hart0 --------------------------------------------------
    output logic [31:0] c0_fetch_pc,
    output logic [ 1:0] c0_retire_valid,
    output logic [ 1:0] c0_retire_rd_wen,
    output logic [ 4:0] c0_retire_rd [2],
    output logic [31:0] c0_retire_wdata [2],
    output logic [31:0] c0_retire_pc [2],
    output logic [ 1:0] c0_retire_is_ebreak,

    //---- observation hart1 --------------------------------------------------
    output logic [31:0] c1_fetch_pc,
    output logic [ 1:0] c1_retire_valid,
    output logic [ 1:0] c1_retire_rd_wen,
    output logic [ 4:0] c1_retire_rd [2],
    output logic [31:0] c1_retire_wdata [2],
    output logic [31:0] c1_retire_pc [2],
    output logic [ 1:0] c1_retire_is_ebreak,

    //---- observation L2 -----------------------------------------------------
    output logic         l2_idle,
    output logic [ 31:0] l2_hit_count,
    output logic [ 31:0] l2_miss_count,

    //---- MMIO request observation (board console; no protocol change) -------
    output logic        c0_mmio_req_valid,
    output logic        c0_mmio_write,
    output logic [31:0] c0_mmio_addr,
    output logic [31:0] c0_mmio_wdata,
    output logic [ 3:0] c0_mmio_wstrb,
    output logic        c1_mmio_req_valid,
    output logic        c1_mmio_write,
    output logic [31:0] c1_mmio_addr,
    output logic [31:0] c1_mmio_wdata,
    output logic [ 3:0] c1_mmio_wstrb
);
    // hart0 L2 ports.
    logic c0_i_rd_valid, c0_i_rd_ready;
    logic [31:0] c0_i_rd_addr;
    logic c0_i_rsp_valid, c0_i_rsp_ready;
    logic [127:0] c0_i_rsp_data;

    logic c0_rd_valid, c0_rd_ready, c0_rsp_valid, c0_rsp_ready;
    logic [31:0] c0_rd_addr;
    logic [127:0] c0_rsp_data;
    logic c0_wr_valid, c0_wr_ready;
    logic [31:0] c0_wr_addr;
    logic [127:0] c0_wr_data;
    logic [15:0] c0_wr_be;

    // hart1 L2 ports.
    logic c1_i_rd_valid, c1_i_rd_ready;
    logic [31:0] c1_i_rd_addr;
    logic c1_i_rsp_valid, c1_i_rsp_ready;
    logic [127:0] c1_i_rsp_data;

    logic c1_rd_valid, c1_rd_ready, c1_rsp_valid, c1_rsp_ready;
    logic [31:0] c1_rd_addr;
    logic [127:0] c1_rsp_data;
    logic c1_wr_valid, c1_wr_ready;
    logic [31:0] c1_wr_addr;
    logic [127:0] c1_wr_data;
    logic [15:0] c1_wr_be;

    ares_frontend_hart #(
        .RESET_MTVEC(RESET_MTVEC), .RESET_VEC(RESET_VEC),
        .HART_ID(32'd0), .DATA_OFFSET(32'h0)
    ) u_hart0 (
        .clk(clk), .rst(rst),
        .i_rd_valid(c0_i_rd_valid), .i_rd_ready(c0_i_rd_ready), .i_rd_addr(c0_i_rd_addr),
        .i_rsp_valid(c0_i_rsp_valid), .i_rsp_ready(c0_i_rsp_ready), .i_rsp_data(c0_i_rsp_data),
        .mem_rd_valid(c0_rd_valid), .mem_rd_ready(c0_rd_ready), .mem_rd_addr(c0_rd_addr),
        .mem_rsp_valid(c0_rsp_valid), .mem_rsp_ready(c0_rsp_ready), .mem_rsp_data(c0_rsp_data),
        .mem_wr_valid(c0_wr_valid), .mem_wr_ready(c0_wr_ready), .mem_wr_addr(c0_wr_addr),
        .mem_wr_data(c0_wr_data), .mem_wr_be(c0_wr_be),
        .fetch_pc(c0_fetch_pc),
        .retire_valid(c0_retire_valid), .retire_rd_wen(c0_retire_rd_wen),
        .retire_rd(c0_retire_rd), .retire_wdata(c0_retire_wdata),
        .retire_pc(c0_retire_pc), .retire_is_ebreak(c0_retire_is_ebreak),
        .o_mmio_req_valid(c0_mmio_req_valid), .o_mmio_write(c0_mmio_write),
        .o_mmio_addr(c0_mmio_addr), .o_mmio_wdata(c0_mmio_wdata),
        .o_mmio_wstrb(c0_mmio_wstrb)
    );

    wire rst1 = rst | ~(HART1_ENABLE && hart1_en);
    ares_frontend_hart #(
        .RESET_MTVEC(RESET_MTVEC), .RESET_VEC(RESET_VEC),
        .HART_ID(32'd1), .DATA_OFFSET(C1_DATA_OFFSET)
    ) u_hart1 (
        .clk(clk), .rst(rst1),
        .i_rd_valid(c1_i_rd_valid), .i_rd_ready(c1_i_rd_ready), .i_rd_addr(c1_i_rd_addr),
        .i_rsp_valid(c1_i_rsp_valid), .i_rsp_ready(c1_i_rsp_ready), .i_rsp_data(c1_i_rsp_data),
        .mem_rd_valid(c1_rd_valid), .mem_rd_ready(c1_rd_ready), .mem_rd_addr(c1_rd_addr),
        .mem_rsp_valid(c1_rsp_valid), .mem_rsp_ready(c1_rsp_ready), .mem_rsp_data(c1_rsp_data),
        .mem_wr_valid(c1_wr_valid), .mem_wr_ready(c1_wr_ready), .mem_wr_addr(c1_wr_addr),
        .mem_wr_data(c1_wr_data), .mem_wr_be(c1_wr_be),
        .fetch_pc(c1_fetch_pc),
        .retire_valid(c1_retire_valid), .retire_rd_wen(c1_retire_rd_wen),
        .retire_rd(c1_retire_rd), .retire_wdata(c1_retire_wdata),
        .retire_pc(c1_retire_pc), .retire_is_ebreak(c1_retire_is_ebreak),
        .o_mmio_req_valid(c1_mmio_req_valid), .o_mmio_write(c1_mmio_write),
        .o_mmio_addr(c1_mmio_addr), .o_mmio_wdata(c1_mmio_wdata),
        .o_mmio_wstrb(c1_mmio_wstrb)
    );

    l2_top #(
        .SETS(L2_SETS), .WAYS(4)
    ) u_l2 (
        .clk(clk), .rst(rst),
        .c0_rd_valid(c0_rd_valid), .c0_rd_ready(c0_rd_ready), .c0_rd_addr(c0_rd_addr),
        .c0_rsp_valid(c0_rsp_valid), .c0_rsp_ready(c0_rsp_ready), .c0_rsp_data(c0_rsp_data),
        .c0_wr_valid(c0_wr_valid), .c0_wr_ready(c0_wr_ready), .c0_wr_addr(c0_wr_addr),
        .c0_wr_data(c0_wr_data), .c0_wr_be(c0_wr_be),
        .c1_rd_valid(c1_rd_valid), .c1_rd_ready(c1_rd_ready), .c1_rd_addr(c1_rd_addr),
        .c1_rsp_valid(c1_rsp_valid), .c1_rsp_ready(c1_rsp_ready), .c1_rsp_data(c1_rsp_data),
        .c1_wr_valid(c1_wr_valid), .c1_wr_ready(c1_wr_ready), .c1_wr_addr(c1_wr_addr),
        .c1_wr_data(c1_wr_data), .c1_wr_be(c1_wr_be),
        .i_rd_valid(c0_i_rd_valid), .i_rd_ready(c0_i_rd_ready), .i_rd_addr(c0_i_rd_addr),
        .i_rsp_valid(c0_i_rsp_valid), .i_rsp_ready(c0_i_rsp_ready), .i_rsp_data(c0_i_rsp_data),
        .i1_rd_valid(c1_i_rd_valid), .i1_rd_ready(c1_i_rd_ready), .i1_rd_addr(c1_i_rd_addr),
        .i1_rsp_valid(c1_i_rsp_valid), .i1_rsp_ready(c1_i_rsp_ready), .i1_rsp_data(c1_i_rsp_data),
        .mem_rd_valid(l2_mem_rd_valid), .mem_rd_ready(l2_mem_rd_ready), .mem_rd_addr(l2_mem_rd_addr),
        .mem_rsp_valid(l2_mem_rsp_valid), .mem_rsp_ready(l2_mem_rsp_ready), .mem_rsp_data(l2_mem_rsp_data),
        .mem_wr_valid(l2_mem_wr_valid), .mem_wr_ready(l2_mem_wr_ready), .mem_wr_addr(l2_mem_wr_addr),
        .mem_wr_data(l2_mem_wr_data), .mem_wr_be(l2_mem_wr_be),
        .l2_idle(l2_idle), .hit_count(l2_hit_count), .miss_count(l2_miss_count)
    );

endmodule
