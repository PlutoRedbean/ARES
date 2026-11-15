//=============================================================================
// ARES pipeline SoC - 2/4-hart AMP full-accelerated CoreMark board top
//-----------------------------------------------------------------------------
// Board: Pangu 200Pro+ / PG2L200H-6IFBB676
//   clk_27m  D18   27 MHz input
//   rst_n    C22   active-low board reset
//   uart_tx  C24   115200 8N1, hart 0 console
//   led[7:0] A20/C18/C19/E18/A17/A18/C17/B17
//
// Clocking: 27 MHz -> 100 MHz CPU + 50 MHz peripheral.  The AMP core and its
// private MMIO/UART run in the 100 MHz domain; the 50 MHz domain is kept for
// the board PLL/reset structure but is not used by the AMP datapath.
//
// The per-hart private DRAM is the inferred BRAM inside student_top.  Its
// initialization file must contain the AMP image's 32 KiB data region
// replicated at each hart's DATA_OFFSET (0x0000/0x8000/0x10000/0x18000).
// `make pipeline-amp-image` generates that file.
//
// Verilog-2001.
//=============================================================================
`timescale 1ns / 1ps

module pipeline_amp_board_top #(
    // Harts in the AMP SoC (2 or 4).  Only hart 0's UART reaches the pin.
    parameter integer CORES          = 2,
    // Per-hart private DRAM geometry.  The AMP linker gives every hart one
    // 32 KiB window (DATA_STRIDE 0x8000), so the board build defaults to
    // 8192 x 32-bit per hart instead of the single-hart 256 KiB:
    // 4 harts x 8 DRAM36K = 32 of 415 on the device instead of 256.
    // Set DRAM_AW = 16 (and DRAM_INIT_FILE = "build/pipeline/dram.hex") to
    // build the old 256 KiB per-hart geometry for an A/B comparison.
    parameter integer DRAM_AW        = 13,
    parameter         DRAM_INIT_FILE = "build/pipeline/dram_amp.hex"
) (
    input  wire       clk_27m,
    input  wire       rst_n,
    output wire       uart_tx,
    output wire [7:0] led
);
    wire cpu_clk;
    wire periph_clk;
    wire pll_lock;
    wire cpu_rst;
    wire periph_rst;

    pipeline_clk_reset u_clk_reset (
        .clk_27m   (clk_27m),
        .rst_n     (rst_n),
        .cpu_clk   (cpu_clk),
        .periph_clk(periph_clk),
        .pll_lock  (pll_lock),
        .cpu_rst   (cpu_rst),
        .periph_rst(periph_rst)
    );

    wire [31:0] soc_led;

    pipeline_amp_top #(
        .CORES             (CORES),
        .DATA_STRIDE       (32'h0000_8000),
        .USE_ICACHE        (1),
        .ICACHE_LINES      (512),
        .ICACHE_LINE_BYTES (64),
        .DRAM_AW           (DRAM_AW),
        .DRAM_INIT_FILE    (DRAM_INIT_FILE)
    ) u_soc (
        .clk             (cpu_clk),
        .rst             (cpu_rst),
        .core_en         ({CORES{1'b1}}),

        .retire_valid    (),
        .retire_pc       (),
        .retire_pc_next  (),
        .retire_rd_wen   (),
        .retire_rd       (),
        .retire_wdata    (),
        .retire_is_ebreak(),

        .uart_tx         (uart_tx),
        .led             (soc_led)
    );

    // LED[0] = PLL lock, LED[1] = heartbeat, LED[7:2] = hart 0 LED register.
    reg [25:0] heartbeat_q;
    always @(posedge cpu_clk) begin
        heartbeat_q <= heartbeat_q + 26'd1;
    end

    assign led = {soc_led[5:0], heartbeat_q[25], pll_lock};

    // The 50 MHz domain is not used by the AMP datapath.  Keep the reset
    // output referenced so the PLL/CDC structure is not optimized away.
    wire unused_periph = periph_clk | periph_rst;
endmodule
