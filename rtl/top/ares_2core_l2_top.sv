//=============================================================================
// ARES - two-hart bring-up top with a shared L2
//-----------------------------------------------------------------------------
// Two ares_core_top instances (HART_ID 0/1) share one l2_top through its two
// core ports.  The FE contract remains external (C5 is still pending), so this
// top is the structural 2-core/L2 integration point; a testbench drives both
// FE ports with fe_model.
//
// MMIO is intentionally a tiny always-ready stub here.  CLINT/PLIC/Mailbox and
// the real MMIO xbar belong to the next 2-core SoC integration step; this top
// lets the shared-L2 data path be verified without inventing that fabric.
//=============================================================================
module ares_2core_l2_top #(
    parameter logic [31:0] RESET_MTVEC = ares_pkg::RESET_PC,
    parameter int unsigned L2_SETS     = 128
) (
    input logic clk,
    input logic rst,

    //---- core0 FE contract --------------------------------------------------
    input  logic              [1:0] c0_iq_valid,
    input  fe_pkg::iq_entry_t       c0_iq_inst        [2],
    output logic              [1:0] c0_iq_accept_count,
    output logic                    c0_backend_redirect_valid,
    output logic              [31:0] c0_backend_redirect_pc,
    output fe_pkg::fe_redirect_kind_t c0_backend_redirect_kind,
    output logic [fe_pkg::GHR_WIDTH-1:0] c0_backend_redirect_ghr_before,
    output logic                    c0_backend_redirect_actual_taken,
    input  logic              [1:0] c0_bpu_update_credit,
    output logic              [1:0] c0_bpu_update_valid,
    output fe_pkg::bpu_update_t     c0_bpu_update       [2],
    input  logic                    c0_timer_irq,
    input  logic                    c0_software_irq,
    input  logic                    c0_external_irq,
    output logic                    c0_fence_i_valid,

    //---- core1 FE contract --------------------------------------------------
    input  logic              [1:0] c1_iq_valid,
    input  fe_pkg::iq_entry_t       c1_iq_inst        [2],
    output logic              [1:0] c1_iq_accept_count,
    output logic                    c1_backend_redirect_valid,
    output logic              [31:0] c1_backend_redirect_pc,
    output fe_pkg::fe_redirect_kind_t c1_backend_redirect_kind,
    output logic [fe_pkg::GHR_WIDTH-1:0] c1_backend_redirect_ghr_before,
    output logic                    c1_backend_redirect_actual_taken,
    input  logic              [1:0] c1_bpu_update_credit,
    output logic              [1:0] c1_bpu_update_valid,
    output fe_pkg::bpu_update_t     c1_bpu_update       [2],
    input  logic                    c1_timer_irq,
    input  logic                    c1_software_irq,
    input  logic                    c1_external_irq,
    output logic                    c1_fence_i_valid,

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
    output logic [1:0]         c0_retire_valid,
    output logic [1:0]         c0_retire_rd_wen,
    output logic [4:0]         c0_retire_rd [2],
    output logic [31:0]        c0_retire_wdata [2],
    output logic [1:0]         c0_retire_is_ebreak,
    output logic [1:0]         c1_retire_valid,
    output logic [1:0]         c1_retire_rd_wen,
    output logic [4:0]         c1_retire_rd [2],
    output logic [31:0]        c1_retire_wdata [2],
    output logic [1:0]         c1_retire_is_ebreak
);
    /* verilator lint_off UNUSEDSIGNAL */  // 2-core top does not use the I port yet
    logic i_rd_ready, i_rsp_valid, i1_rd_ready, i1_rsp_valid;
    logic [127:0] i_rsp_data, i1_rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

    // Core-to-L2 buses.
    logic c0_mem_rd_valid, c0_mem_rd_ready, c0_mem_rsp_valid, c0_mem_rsp_ready;
    logic [31:0] c0_mem_rd_addr;
    logic [127:0] c0_mem_rsp_data;
    logic c0_mem_wr_valid, c0_mem_wr_ready;
    logic [31:0] c0_mem_wr_addr;
    logic [127:0] c0_mem_wr_data;
    logic [15:0] c0_mem_wr_be;

    logic c1_mem_rd_valid, c1_mem_rd_ready, c1_mem_rsp_valid, c1_mem_rsp_ready;
    logic [31:0] c1_mem_rd_addr;
    logic [127:0] c1_mem_rsp_data;
    logic c1_mem_wr_valid, c1_mem_wr_ready;
    logic [31:0] c1_mem_wr_addr;
    logic [127:0] c1_mem_wr_data;
    logic [15:0] c1_mem_wr_be;

    // MMIO stub (no MMIO is used by the bring-up programs).
    /* verilator lint_off UNUSEDSIGNAL */  // stub only observes req_valid
    logic c0_mmio_req_valid, c0_mmio_req_ready, c0_mmio_write;
    logic [31:0] c0_mmio_addr, c0_mmio_wdata;
    logic [3:0] c0_mmio_wstrb;
    logic c0_mmio_rsp_valid, c0_mmio_rsp_ready;
    logic [31:0] c0_mmio_rsp_data;

    logic c1_mmio_req_valid, c1_mmio_req_ready, c1_mmio_write;
    logic [31:0] c1_mmio_addr, c1_mmio_wdata;
    logic [3:0] c1_mmio_wstrb;
    logic c1_mmio_rsp_valid, c1_mmio_rsp_ready;
    logic [31:0] c1_mmio_rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off UNUSEDSIGNAL */
    logic c0_fence_i_unused, c1_fence_i_unused;
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off PINCONNECTEMPTY */  // debug/observation pins are intentionally open
    ares_core_top #(
        .RESET_MTVEC(RESET_MTVEC),
        .HART_ID(32'd0)
    ) u_core0 (
        .clk(clk), .rst(rst),
        .iq_valid(c0_iq_valid), .iq_inst(c0_iq_inst), .iq_accept_count(c0_iq_accept_count),
        .backend_redirect_valid(c0_backend_redirect_valid),
        .backend_redirect_pc(c0_backend_redirect_pc),
        .backend_redirect_kind(c0_backend_redirect_kind),
        .backend_redirect_ghr_before(c0_backend_redirect_ghr_before),
        .backend_redirect_actual_taken(c0_backend_redirect_actual_taken),
        .backend_redirect_info(),
        .bpu_update_credit(c0_bpu_update_credit),
        .bpu_update_valid(c0_bpu_update_valid),
        .bpu_update(c0_bpu_update),
        .timer_irq(c0_timer_irq), .software_irq(c0_software_irq), .external_irq(c0_external_irq),
        .fence_i_valid(c0_fence_i_unused),
        .mem_rd_valid(c0_mem_rd_valid), .mem_rd_ready(c0_mem_rd_ready), .mem_rd_addr(c0_mem_rd_addr),
        .mem_rsp_valid(c0_mem_rsp_valid), .mem_rsp_ready(c0_mem_rsp_ready), .mem_rsp_data(c0_mem_rsp_data),
        .mem_wr_valid(c0_mem_wr_valid), .mem_wr_ready(c0_mem_wr_ready), .mem_wr_addr(c0_mem_wr_addr),
        .mem_wr_data(c0_mem_wr_data), .mem_wr_be(c0_mem_wr_be),
        .mmio_req_valid(c0_mmio_req_valid), .mmio_req_ready(c0_mmio_req_ready),
        .mmio_write(c0_mmio_write), .mmio_addr(c0_mmio_addr), .mmio_wdata(c0_mmio_wdata),
        .mmio_wstrb(c0_mmio_wstrb),
        .mmio_rsp_valid(c0_mmio_rsp_valid), .mmio_rsp_ready(c0_mmio_rsp_ready),
        .mmio_rsp_data(c0_mmio_rsp_data),
        .retire_valid(c0_retire_valid), .retire_pc(),
        .retire_pc_next(), .retire_rd_wen(c0_retire_rd_wen),
        .retire_rd(c0_retire_rd), .retire_wdata(c0_retire_wdata),
        .retire_is_ebreak(c0_retire_is_ebreak),
        .irq_redirect_valid(), .irq_redirect_pc(),
        .decode_err(), .decode_err_pc(), .decode_err_inst(), .dep_error(),
        .dbg_occupancy(), .dbg_arch_next_pc(), .dbg_lq_used(), .dbg_sq_used()
    );

    ares_core_top #(
        .RESET_MTVEC(RESET_MTVEC),
        .HART_ID(32'd1)
    ) u_core1 (
        .clk(clk), .rst(rst),
        .iq_valid(c1_iq_valid), .iq_inst(c1_iq_inst), .iq_accept_count(c1_iq_accept_count),
        .backend_redirect_valid(c1_backend_redirect_valid),
        .backend_redirect_pc(c1_backend_redirect_pc),
        .backend_redirect_kind(c1_backend_redirect_kind),
        .backend_redirect_ghr_before(c1_backend_redirect_ghr_before),
        .backend_redirect_actual_taken(c1_backend_redirect_actual_taken),
        .backend_redirect_info(),
        .bpu_update_credit(c1_bpu_update_credit),
        .bpu_update_valid(c1_bpu_update_valid),
        .bpu_update(c1_bpu_update),
        .timer_irq(c1_timer_irq), .software_irq(c1_software_irq), .external_irq(c1_external_irq),
        .fence_i_valid(c1_fence_i_unused),
        .mem_rd_valid(c1_mem_rd_valid), .mem_rd_ready(c1_mem_rd_ready), .mem_rd_addr(c1_mem_rd_addr),
        .mem_rsp_valid(c1_mem_rsp_valid), .mem_rsp_ready(c1_mem_rsp_ready), .mem_rsp_data(c1_mem_rsp_data),
        .mem_wr_valid(c1_mem_wr_valid), .mem_wr_ready(c1_mem_wr_ready), .mem_wr_addr(c1_mem_wr_addr),
        .mem_wr_data(c1_mem_wr_data), .mem_wr_be(c1_mem_wr_be),
        .mmio_req_valid(c1_mmio_req_valid), .mmio_req_ready(c1_mmio_req_ready),
        .mmio_write(c1_mmio_write), .mmio_addr(c1_mmio_addr), .mmio_wdata(c1_mmio_wdata),
        .mmio_wstrb(c1_mmio_wstrb),
        .mmio_rsp_valid(c1_mmio_rsp_valid), .mmio_rsp_ready(c1_mmio_rsp_ready),
        .mmio_rsp_data(c1_mmio_rsp_data),
        .retire_valid(c1_retire_valid), .retire_pc(),
        .retire_pc_next(), .retire_rd_wen(c1_retire_rd_wen),
        .retire_rd(c1_retire_rd), .retire_wdata(c1_retire_wdata),
        .retire_is_ebreak(c1_retire_is_ebreak),
        .irq_redirect_valid(), .irq_redirect_pc(),
        .decode_err(), .decode_err_pc(), .decode_err_inst(), .dep_error(),
        .dbg_occupancy(), .dbg_arch_next_pc(), .dbg_lq_used(), .dbg_sq_used()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // One-cycle MMIO stub.  The bring-up programs only touch memory, so this is
    // deliberately minimal; replace with the real MMIO xbar in the SoC step.
    assign c0_mmio_req_ready = 1'b1;
    assign c0_mmio_rsp_ready = 1'b1;
    assign c0_mmio_rsp_data  = 32'h0;
    always_ff @(posedge clk) begin
        if (rst) c0_mmio_rsp_valid <= 1'b0;
        else     c0_mmio_rsp_valid <= c0_mmio_req_valid;
    end

    assign c1_mmio_req_ready = 1'b1;
    assign c1_mmio_rsp_ready = 1'b1;
    assign c1_mmio_rsp_data  = 32'h0;
    always_ff @(posedge clk) begin
        if (rst) c1_mmio_rsp_valid <= 1'b0;
        else     c1_mmio_rsp_valid <= c1_mmio_req_valid;
    end

    l2_top #(
        .SETS(L2_SETS),
        .WAYS(4)
    ) u_l2 (
        .clk(clk), .rst(rst),
        .c0_rd_valid(c0_mem_rd_valid), .c0_rd_ready(c0_mem_rd_ready), .c0_rd_addr(c0_mem_rd_addr),
        .c0_rsp_valid(c0_mem_rsp_valid), .c0_rsp_ready(c0_mem_rsp_ready), .c0_rsp_data(c0_mem_rsp_data),
        .c0_wr_valid(c0_mem_wr_valid), .c0_wr_ready(c0_mem_wr_ready), .c0_wr_addr(c0_mem_wr_addr),
        .c0_wr_data(c0_mem_wr_data), .c0_wr_be(c0_mem_wr_be),
        .c1_rd_valid(c1_mem_rd_valid), .c1_rd_ready(c1_mem_rd_ready), .c1_rd_addr(c1_mem_rd_addr),
        .c1_rsp_valid(c1_mem_rsp_valid), .c1_rsp_ready(c1_mem_rsp_ready), .c1_rsp_data(c1_mem_rsp_data),
        .c1_wr_valid(c1_mem_wr_valid), .c1_wr_ready(c1_mem_wr_ready), .c1_wr_addr(c1_mem_wr_addr),
        .c1_wr_data(c1_mem_wr_data), .c1_wr_be(c1_mem_wr_be),
        .i_rd_valid(1'b0), .i_rd_ready(i_rd_ready), .i_rd_addr(32'h0),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(1'b0), .i_rsp_data(i_rsp_data),
        .i1_rd_valid(1'b0), .i1_rd_ready(i1_rd_ready), .i1_rd_addr(32'h0),
        .i1_rsp_valid(i1_rsp_valid), .i1_rsp_ready(1'b0), .i1_rsp_data(i1_rsp_data),
        .mem_rd_valid(l2_mem_rd_valid), .mem_rd_ready(l2_mem_rd_ready), .mem_rd_addr(l2_mem_rd_addr),
        .mem_rsp_valid(l2_mem_rsp_valid), .mem_rsp_ready(l2_mem_rsp_ready), .mem_rsp_data(l2_mem_rsp_data),
        .mem_wr_valid(l2_mem_wr_valid), .mem_wr_ready(l2_mem_wr_ready), .mem_wr_addr(l2_mem_wr_addr),
        .mem_wr_data(l2_mem_wr_data), .mem_wr_be(l2_mem_wr_be),
        .l2_idle(l2_idle), .hit_count(l2_hit_count), .miss_count(l2_miss_count)
    );

    assign c0_fence_i_valid = c0_fence_i_unused;
    assign c1_fence_i_valid = c1_fence_i_unused;

endmodule
