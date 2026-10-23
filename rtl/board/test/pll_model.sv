// Explicit functional PLL fixture, never included in FPGA sources. Models
// 250/50MHz output clocks, initial lock delay and a test-only lock-loss input.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
`timescale 1ns/1ps
module pll (
    input logic clk_in1_p, clk_in1_n,
    output logic clk_out1, clk_out2, locked
);
    bit fault = 0;
    int lock_count;
    initial begin clk_out1 = 0; clk_out2 = 0; lock_count = 0; end
    always #10 clk_out1 = ~clk_out1;
    always #2 clk_out2 = ~clk_out2;
    always @(posedge clk_in1_p) begin
        if (fault) lock_count <= 0;
        else if (lock_count < 20) lock_count <= lock_count + 1;
    end
    assign locked = (lock_count == 20) && !fault;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
