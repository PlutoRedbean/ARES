//=============================================================================
// ScreenSense - minimal board smoke test
//-----------------------------------------------------------------------------
// led0 (A20): ~0.7 Hz square from the 27 MHz clock  -> proves the bitstream ran
// led1 (C18): constant 1                           -> proves the pin mapping
// Nothing else. No DDR, no HDMI, no clock wizard.
//=============================================================================
`timescale 1ns / 1ps

module blink_top (
    input  wire clk_27m,
    input  wire rst_n,
    output wire led0,
    output wire led1
);
    reg [24:0] cnt;
    always @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) cnt <= 25'd0;
        else        cnt <= cnt + 25'd1;
    end
    assign led0 = cnt[24];   // 27e6 / 2^25 = 0.80 Hz
    assign led1 = 1'b1;
endmodule
