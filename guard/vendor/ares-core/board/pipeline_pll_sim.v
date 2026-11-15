//=============================================================================
// ARES pipeline SoC - behavioral PLL model for Verilator
//-----------------------------------------------------------------------------
// Same module name/ports as pipeline_pll.v (Pango GTP_GPLL).  The simulation
// file list picks this file; PDS picks pipeline_pll.v.
//=============================================================================
`timescale 1ns / 1ps

module pipeline_pll (
    output reg  clkout0,   // 100 MHz CPU
    output reg  clkout1,   //  50 MHz peripheral
    input  wire clkin1,    //  27 MHz board clock
    output reg  lock
);

    initial begin
        clkout0 = 1'b0;
        clkout1 = 1'b0;
        lock    = 1'b0;
    end

    // 100 MHz -> period 10 ns; 50 MHz -> period 20 ns.
    always #5.0  clkout0 = ~clkout0;
    always #10.0 clkout1 = ~clkout1;

    reg [3:0] lock_cnt;
    initial lock_cnt = 4'd0;

    always @(posedge clkin1) begin
        if (lock_cnt != 4'hF) begin
            lock_cnt <= lock_cnt + 4'd1;
        end else begin
            lock <= 1'b1;
        end
    end
endmodule
