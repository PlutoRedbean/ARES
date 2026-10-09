// Next-prediction-PC generator for the front-end.
//
// The BPU uses this to walk the (speculative) fetch stream: `ena` advances the
// PC to `dnpc`, while `flush` forces a restart at `redirect_pc`.  Keeping the
// PC in a dedicated unit lets the BPU later be pipelined without touching the
// IFU.
module gen_pc #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned RESET_VEC  = 32'h8000_0000
) (
    input logic clk,
    input logic rst,
    input logic flush,
    input logic [ADDR_WIDTH - 1:0] redirect_pc,
    input logic ena,
    input logic [ADDR_WIDTH - 1:0] dnpc,
    output logic [ADDR_WIDTH - 1:0] pc
);

    always_ff @(posedge clk) begin
        if (rst) pc <= RESET_VEC;
        else if (flush) pc <= redirect_pc;
        else if (ena) pc <= dnpc;
    end

endmodule
