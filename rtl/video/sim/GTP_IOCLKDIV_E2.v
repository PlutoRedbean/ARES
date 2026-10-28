// ---------------------------------------------------------------------------
// GTP_IOCLKDIV_E2 behavioral model for Verilator.
//
// The vendor cmos_8_16bit uses the Pango IO clock divider to produce
// pixel_clk = pclk / 2.  This model implements the divide-by-2 case only.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module GTP_IOCLKDIV_E2 #(
    parameter DIV_FACTOR = "2"
) (
    input  wire CLKIN,
    input  wire RST_N,
    input  wire CE,
    output reg  CLKDIVOUT
);

    initial CLKDIVOUT = 1'b0;

    always @(posedge CLKIN or negedge RST_N) begin
        if (!RST_N) begin
            CLKDIVOUT <= 1'b0;
        end else if (CE) begin
            CLKDIVOUT <= ~CLKDIVOUT;
        end
    end

endmodule
