//=============================================================================
// ARES pipeline SoC - legacy AMP top name (compatibility wrapper)
//-----------------------------------------------------------------------------
// Phase 1 shipped this top as pipeline_coremark_amp_top.  Phase 2 made the
// shared/replicated IROM explicit in soc/amp/pipeline_amp_top.sv; this wrapper
// keeps the old module name for existing testbenches and out-of-tree users.
//=============================================================================
module pipeline_coremark_amp_top #(
    parameter integer CORES       = 2,
    parameter integer DATA_STRIDE = 32'h0000_8000,
    parameter integer USE_ICACHE  = 1
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire [CORES-1:0]         core_en,

    output wire [CORES-1:0]         retire_valid,
    output wire [CORES-1:0][31:0]   retire_pc,
    output wire [CORES-1:0][31:0]   retire_pc_next,
    output wire [CORES-1:0]         retire_rd_wen,
    output wire [CORES-1:0][ 4:0]   retire_rd,
    output wire [CORES-1:0][31:0]   retire_wdata,
    output wire [CORES-1:0]         retire_is_ebreak
);
    pipeline_amp_top #(
        .CORES       (CORES),
        .DATA_STRIDE (DATA_STRIDE),
        .USE_ICACHE  (USE_ICACHE)
    ) u_amp (
        .clk             (clk),
        .rst             (rst),
        .core_en         (core_en),
        .retire_valid    (retire_valid),
        .retire_pc       (retire_pc),
        .retire_pc_next  (retire_pc_next),
        .retire_rd_wen   (retire_rd_wen),
        .retire_rd       (retire_rd),
        .retire_wdata    (retire_wdata),
        .retire_is_ebreak(retire_is_ebreak),
        .uart_tx(), .led(), .periph_clk(1'b0), .periph_rst(1'b0),
        .uart_rx(1'b1), .rx_full(), .rx_overflow(),
        .pixel_clk(1'b0), .pixel_rst(1'b1), .pixel_vsync(1'b0),
        .pixel_de(1'b0), .pixel_rgb565(16'b0)
    );
endmodule
