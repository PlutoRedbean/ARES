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
//     CV-X-IF issue/register/commit/result -> mini_tensor_top.  This is the
//     adaptation requested before the in-core XIF path (SPEC-M6) is owned by the
//     FE/BE teams.
//   * Data path: miniTensor's 128-bit uncached DMA master is exported here as
//     mt_mem_* so it can be attached to the future Fabric / shared-memory
//     arbitration (SPEC-M7/M20/M21).  No CPU/DMA arbitration or cache-coherency
//     policy is invented here; software must still use uncached addresses.
//   * student_top contains the real CPU and IROM; its platform mt_* seam
//     is connected here as documented in
//     docs/jyd_soc_integration.md.
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
        .mt_wr_en(mt_wr_en),
        .mt_wr_idx(mt_wr_idx),
        .mt_wr_data(mt_wr_data),
        .mt_status_rd(mt_status_rd),
        .mt_status(mt_status),
        .mt_result(mt_result)
    );

    ares_mt_host_adapter u_mt_host (
        .clk(w_cpu_clk),
        .rst(w_clk_rst),
        .reg_wr_en(mt_wr_en),
        .reg_wr_idx(mt_wr_idx),
        .reg_wr_data(mt_wr_data),
        .status_rd(mt_status_rd),
        .status(mt_status),
        .result_data(mt_result),
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
