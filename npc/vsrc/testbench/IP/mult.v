`include "common_para.vh"
module mult #(
    parameter PIPELINE_STAGES = (`CONFIG_MUL_LATENCY - 1)
)(
    input         CLK   ,
    input         CE    ,
    input  [32:0] A     ,
    input  [32:0] B     ,
    output [63:0] P
);

    reg  [63:0] pipe [0:PIPELINE_STAGES-1];
    wire signed [32:0] a_signed = A;
    wire signed [32:0] b_signed = B;
    wire signed [65:0] product  = a_signed * b_signed;

    integer i;

    initial begin
        for (i = 0; i < PIPELINE_STAGES; i = i + 1) begin
            pipe[i] = 64'b0;
        end
    end

    always @(posedge CLK) begin
        if (CE) begin
            pipe[0] <= product[63:0];
            for (i = 1; i < PIPELINE_STAGES; i = i + 1) begin
                pipe[i] <= pipe[i - 1];
            end
        end
    end

    assign P = pipe[PIPELINE_STAGES - 1];

endmodule
