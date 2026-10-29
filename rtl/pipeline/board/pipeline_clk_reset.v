//=============================================================================
// ARES pipeline SoC - PLL and per-domain reset
//-----------------------------------------------------------------------------
// Pango board profile: 27 MHz input, 100 MHz CPU, 50 MHz peripheral.
// Reset policy: asynchronous assert, synchronous release per clock domain.
// Both domains stay in reset until the board reset is released and the PLL
// has locked.
//
// Verilog-2001.
//=============================================================================
`timescale 1ns / 1ps

module pipeline_clk_reset (
    input  wire clk_27m,
    input  wire rst_n,
    output wire cpu_clk,
    output wire periph_clk,
    output wire pll_lock,
    output wire cpu_rst,
    output wire periph_rst
);
    wire lock_i;

    pipeline_pll u_pll (
        .clkin1  (clk_27m),
        .clkout0 (cpu_clk),
        .clkout1 (periph_clk),
        .lock    (lock_i)
    );

    assign pll_lock = lock_i;

    // Active-high asynchronous reset source: board button is active low.
    wire rst_src = ~(rst_n & lock_i);

    pipeline_cdc_reset_sync u_cpu_rst (
        .clk    (cpu_clk),
        .rst_in (rst_src),
        .rst_out(cpu_rst)
    );

    pipeline_cdc_reset_sync u_periph_rst (
        .clk    (periph_clk),
        .rst_in (rst_src),
        .rst_out(periph_rst)
    );
endmodule
