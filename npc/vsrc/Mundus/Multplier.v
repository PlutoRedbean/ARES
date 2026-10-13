module Multiplier(
    input         CLK   ,
    input         CE    ,
    input  [32:0] A     ,
    input  [32:0] B     ,
    output [63:0] P
);

    mult u_mult(
        .CLK 	( CLK  ),
        .CE  	( CE   ),
        .A   	( A    ),
        .B   	( B    ),
        .P   	( P    )
    );

endmodule

// This boundary is intentionally a separate synthesis module.  DONT_TOUCH
// prevents Vivado from absorbing the local operand registers into a DSP input
// cone, while the following multiplier IP keeps its three internal stages.
(* DONT_TOUCH = "yes" *)
module MultiplierInputCapture(
    input         CLK,
    input         reset,
    input         CE,
    input  [32:0] A,
    input  [32:0] B,
    output [32:0] A_CAPTURE,
    output [32:0] B_CAPTURE
);
    (* DONT_TOUCH = "yes", KEEP = "yes" *) reg [32:0] a_capture_reg;
    (* DONT_TOUCH = "yes", KEEP = "yes" *) reg [32:0] b_capture_reg;

    always @(posedge CLK) begin
        if (reset) begin
            a_capture_reg <= 33'b0;
            b_capture_reg <= 33'b0;
        end else if (CE) begin
            a_capture_reg <= A;
            b_capture_reg <= B;
        end
    end

    assign A_CAPTURE = a_capture_reg;
    assign B_CAPTURE = b_capture_reg;
endmodule
