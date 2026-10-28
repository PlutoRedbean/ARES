// ---------------------------------------------------------------------------
// video_ip_pll behavioral model for Verilator.
//
// Synthesis uses rtl/video/video_ip_pll.v (GTP_GPLL).  Both files define the
// same module name; the simulation file list picks this one.
//
// 27 MHz in -> 37.125 / 10.0 / 24.75 MHz out.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module video_ip_pll (
    input  wire clkin1,
    output reg  clkout0,
    output reg  clkout1,
    output reg  clkout2,
    output reg  lock
);

    initial begin
        clkout0 = 1'b0;
        clkout1 = 1'b0;
        clkout2 = 1'b0;
        lock    = 1'b0;
    end

    // 37.125 MHz -> period 26.936 ns
    always #13.468 clkout0 = ~clkout0;
    // 10.0 MHz -> period 100 ns
    always #50.000 clkout1 = ~clkout1;
    // 24.75 MHz -> period 40.404 ns
    always #20.202 clkout2 = ~clkout2;

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
