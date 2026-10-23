// Board reset conditioner: asynchronous assertion, three destination edges
// before release. Only this small chain has an asynchronous reset; consumers
// retain synchronous, active-high reset. INIT holds reset before PLL startup.
module ares_reset_sync (
    input  logic clk,
    input  logic async_rst,
    output logic rst
);
    // FPGA INIT is essential when no board reset pin exists.
    /* verilator lint_off PROCASSINIT */
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [2:0] release_pipe = 3'b111;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge clk or posedge async_rst) begin
        if (async_rst) release_pipe <= 3'b111;
        else           release_pipe <= {release_pipe[1:0], 1'b0};
    end
    assign rst = release_pipe[2];
endmodule
