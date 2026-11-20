`timescale 1ns/1ps

// Functional model for board simulation. Global reset is applied at startup.
module GTP_DFF #(parameter INIT = 1'b0) (
    input  wire CLK,
    input  wire D,
    output reg  Q
);
    initial Q = INIT;
    always @(posedge CLK)
        Q <= D;
endmodule
