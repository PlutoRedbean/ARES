// Return address stack (RAS).
//
// A call pushes its return address (pc+4), a return pops the top and uses it
// as the predicted target.  The top of the stack is exposed combinationally so
// the BPU can override a return's target.
//
// Speculation
// -----------
// The front-end predicts far ahead of the back-end, so the stack is updated
// *speculatively* when a call/return is predicted (at most one per predicted
// fetch block).  A redirect repairs the speculative pointer to the committed
// pointer, which is advanced only when the call/return resolves at EXU (this
// mirrors the gem5 ReturnAddrStack).  Stack contents above the committed
// pointer do not need restoring: they are overwritten by the correct path.
/* verilator lint_off UNUSEDSIGNAL */
module ras (
    input logic clk,
    input logic rst,

    // combinational top of the speculative stack (return target)
    output logic                           top_valid,
    output logic [fe_pkg::ADDR_WIDTH-1:0] top_addr,

    // speculative update along the predicted path (at most one per block)
    input logic                           spec_push,  // predicted call
    input logic                           spec_pop,   // predicted return
    input logic [fe_pkg::ADDR_WIDTH-1:0] spec_addr,  // call return address

    // redirect: drop speculative changes and resync to the committed stack
    input logic flush,

    // committed update when the call/return resolves
    input logic                           update_en,
    input logic                           update_push,
    input logic                           update_pop,
    input logic [fe_pkg::ADDR_WIDTH-1:0] update_addr
);
    import fe_pkg::*;
    localparam int unsigned IDX_W = (RAS_ENTRIES > 1) ? $clog2(RAS_ENTRIES) : 1;
    localparam int unsigned CNT_W = $clog2(RAS_ENTRIES + 1);

    logic [ADDR_WIDTH-1:0] ras_mem   [RAS_ENTRIES];
    logic [     CNT_W-1:0] sp_spec;
    logic [     CNT_W-1:0] sp_commit;

    // top of the speculative stack
    always_comb begin
        top_valid = (sp_spec != '0);
        top_addr  = ras_mem[0];
        for (int i = 0; i < RAS_ENTRIES; i++) begin
            if (sp_spec == CNT_W'(i + 1)) begin
                top_addr = ras_mem[i];
            end
        end
    end

    // next committed pointer (also used to resync on a redirect in the same
    // cycle the resolving call/return commits)
    logic [CNT_W-1:0] sp_commit_next;
    always_comb begin
        sp_commit_next = sp_commit;
        if (update_en) begin
            if (update_push && (sp_commit != CNT_W'(RAS_ENTRIES))) begin
                sp_commit_next = sp_commit + 1'b1;
            end else if (update_pop && (sp_commit != '0)) begin
                sp_commit_next = sp_commit - 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sp_spec   <= '0;
            sp_commit <= '0;
            for (int i = 0; i < RAS_ENTRIES; i++) begin
                ras_mem[i] <= '0;
            end
        end else begin
            // committed update (architecturally correct even if a redirect
            // happens in the same cycle)
            if (update_en && update_push && (sp_commit != CNT_W'(RAS_ENTRIES))) begin
                ras_mem[sp_commit[IDX_W-1:0]] <= update_addr;
            end
            sp_commit <= sp_commit_next;

            // speculative update along the predicted path
            if (flush) begin
                sp_spec <= sp_commit_next;
            end else if (spec_push && (sp_spec != CNT_W'(RAS_ENTRIES))) begin
                ras_mem[sp_spec[IDX_W-1:0]] <= spec_addr;
                sp_spec <= sp_spec + 1'b1;
            end else if (spec_pop && (sp_spec != '0)) begin
                sp_spec <= sp_spec - 1'b1;
            end
        end
    end
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
