//=============================================================================
// ARES SoC integration top - JYD platform + miniTensor (S02/S09)
//-----------------------------------------------------------------------------
// Wraps the migrated JYD subsystem (student_top: real ares_core_top Core + the
// JYD memory/peripheral bridges) and connects the documented miniTensor MMIO
// control seam to a real mini_tensor_top through the ARES CV-X-IF host adapter
// ares_mt_host_adapter.
//
// Boundary / scope
//   * Control path: CPU MMIO -> perip_bridge mt_* -> ares_mt_host_adapter ->
//     CV-X-IF issue/register/commit/result -> mini_tensor_top.  The adapter's
//     level mt_irq (need_work/done/error) is routed into student_top and becomes
//     the core's external_irq / mip.MEIP.  This is the adaptation requested
//     before the in-core XIF path (SPEC-M6) is owned by the FE/BE teams.
//   * Data path: miniTensor's 128-bit uncached DMA master is exported here as
//     mt_mem_* so it can be attached to the future Fabric / shared-memory
//     arbitration (SPEC-M7/M20/M21).  No CPU/DMA arbitration or cache-coherency
//     policy is invented here; software must still use uncached addresses.
//   * student_top keeps the FE contract and the platform-level mt_* seam
//     external; it now also accepts mt_irq so the platform can route a device
//     interrupt to the core without owning the tensor adapter.
//
// Reset/clock: single CPU clock w_cpu_clk, synchronous active-high w_clk_rst,
// identical to student_top and mini_tensor_top.
//=============================================================================
/* verilator lint_off PINCONNECTEMPTY */  // UB debug port is observation-only
module ares_soc_top (
    input logic w_cpu_clk,
    w_clk_50Mhz,
    w_clk_rst,
    input logic [7:0] virtual_key,
    input logic [63:0] virtual_sw,
    input logic [7:0] uart_rx_data,
    input logic uart_rx_ready,
    uart_tx_busy,
    output logic [7:0] uart_tx_data,
    output logic uart_tx_start,
    output logic [31:0] virtual_led,
    output logic [39:0] virtual_seg,

    // Synchronous 32 KiB IROM seam for the future real frontend (C5).
    input  logic [31:0] ifetch_addr,
    output logic [63:0] ifetch_data,

    // FE contract (external until C5).
    input  logic                      [                  1:0] iq_valid,
    input  fe_pkg::iq_entry_t                                 iq_inst                      [2],
    output logic                      [                  1:0] iq_accept_count,
    output logic                                              backend_redirect_valid,
    output logic                      [                 31:0] backend_redirect_pc,
    output fe_pkg::fe_redirect_kind_t                         backend_redirect_kind,
    output logic                      [fe_pkg::GHR_WIDTH-1:0] backend_redirect_ghr_before,
    output logic                                              backend_redirect_actual_taken,
    input  logic                      [                  1:0] bpu_update_credit,
    output logic                      [                  1:0] bpu_update_valid,
    output fe_pkg::bpu_update_t                               bpu_update                   [2],

    // miniTensor 128-bit uncached DMA master (future Fabric boundary).
    output logic         mt_mem_rd_valid,
    input  logic         mt_mem_rd_ready,
    output logic [ 31:0] mt_mem_rd_addr,
    input  logic         mt_mem_rsp_valid,
    output logic         mt_mem_rsp_ready,
    input  logic [127:0] mt_mem_rsp_data,
    output logic         mt_mem_wr_valid,
    input  logic         mt_mem_wr_ready,
    output logic [ 31:0] mt_mem_wr_addr,
    output logic [127:0] mt_mem_wr_data,
    output logic [ 15:0] mt_mem_wr_be,
    output logic         mt_dma_busy
);
    // JYD platform emits the miniTensor control seam; the adapter consumes it.
    logic        mt_wr_en;
    logic [ 2:0] mt_wr_idx;
    logic [31:0] mt_wr_data;
    logic        mt_status_rd;
    logic [31:0] mt_status;
    logic [31:0] mt_result;
    logic        mt_irq;

    core_v_xif mt_xif ();

    student_top u_platform (
        .w_cpu_clk(w_cpu_clk),
        .w_clk_50Mhz(w_clk_50Mhz),
        .w_clk_rst(w_clk_rst),
        .virtual_key(virtual_key),
        .virtual_sw(virtual_sw),
        .uart_rx_data(uart_rx_data),
        .uart_rx_ready(uart_rx_ready),
        .uart_tx_busy(uart_tx_busy),
        .uart_tx_data(uart_tx_data),
        .uart_tx_start(uart_tx_start),
        .virtual_led(virtual_led),
        .virtual_seg(virtual_seg),
        .ifetch_addr(ifetch_addr),
        .ifetch_data(ifetch_data),
        .mt_wr_en(mt_wr_en),
        .mt_wr_idx(mt_wr_idx),
        .mt_wr_data(mt_wr_data),
        .mt_status_rd(mt_status_rd),
        .mt_status(mt_status),
        .mt_result(mt_result),
        .mt_irq(mt_irq),
        .iq_valid(iq_valid),
        .iq_inst(iq_inst),
        .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(backend_redirect_valid),
        .backend_redirect_pc(backend_redirect_pc),
        .backend_redirect_kind(backend_redirect_kind),
        .backend_redirect_ghr_before(backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .bpu_update_credit(bpu_update_credit),
        .bpu_update_valid(bpu_update_valid),
        .bpu_update(bpu_update)
    );

    ares_mt_host_adapter #(
        .HART_ID(1'b0)
    ) u_mt_host (
        .clk(w_cpu_clk),
        .rst(w_clk_rst),
        .reg_wr_en(mt_wr_en),
        .reg_wr_idx(mt_wr_idx),
        .reg_wr_data(mt_wr_data),
        .status_rd(mt_status_rd),
        .status(mt_status),
        .result_data(mt_result),
        .mt_irq(mt_irq),
        .xif(mt_xif)
    );

    mini_tensor_top u_mt (
        .clk(w_cpu_clk),
        .rst(w_clk_rst),
        .xif(mt_xif),
        .mem_rd_valid(mt_mem_rd_valid),
        .mem_rd_ready(mt_mem_rd_ready),
        .mem_rd_addr(mt_mem_rd_addr),
        .mem_rsp_valid(mt_mem_rsp_valid),
        .mem_rsp_ready(mt_mem_rsp_ready),
        .mem_rsp_data(mt_mem_rsp_data),
        .mem_wr_valid(mt_mem_wr_valid),
        .mem_wr_ready(mt_mem_wr_ready),
        .mem_wr_addr(mt_mem_wr_addr),
        .mem_wr_data(mt_mem_wr_data),
        .mem_wr_be(mt_mem_wr_be),
        // Observation-only UB port; the SoC does not own it.
        .ub_rd_en(1'b0),
        .ub_rd_addr('0),
        .ub_rd_valid(),
        .ub_rd_data(),
        .dma_busy(mt_dma_busy)
    );
endmodule
/* verilator lint_on PINCONNECTEMPTY */
