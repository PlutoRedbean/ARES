//=============================================================================
// ARES - legacy frontend contract adapter unit test
//-----------------------------------------------------------------------------
// Checks the zero-cycle IQ/redirect mapping and the 2-push/1-pop BPU update
// FIFO (no training-event loss).
//=============================================================================
`timescale 1ns/1ps
module tb_fe_legacy_adapter;
    import fe_pkg::*;

    logic clk, rst;
    initial begin clk = 1'b0; rst = 1'b1; end
    always #5 clk = ~clk;

    logic [1:0] fe_iq_rvalid;
    iq_entry_t fe_iq_rbits [2];
    logic [1:0] fe_iq_raccept_cnt;
    logic fe_redirect_valid;
    logic [31:0] fe_redirect_pc;
    fe_redirect_kind_t fe_redirect_kind;
    logic fe_bpu_update_en;
    /* verilator lint_off UNUSEDSIGNAL */  // only update_pc is checked
    bpu_update_t fe_bpu_update_meta;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [1:0] be_iq_valid;
    iq_entry_t be_iq_inst [2];
    logic [1:0] be_iq_accept_count;
    logic be_redirect_valid;
    logic [31:0] be_redirect_pc;
    fe_redirect_kind_t be_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] be_redirect_ghr_before;
    logic be_redirect_actual_taken;
    logic [1:0] be_bpu_update_credit;
    logic [1:0] be_bpu_update_valid;
    bpu_update_t be_bpu_update [2];

    fe_legacy_adapter dut (
        .clk(clk), .rst(rst),
        .fe_iq_rvalid(fe_iq_rvalid), .fe_iq_rbits(fe_iq_rbits),
        .fe_iq_raccept_cnt(fe_iq_raccept_cnt),
        .fe_redirect_valid(fe_redirect_valid), .fe_redirect_pc(fe_redirect_pc),
        .fe_redirect_kind(fe_redirect_kind),
        .fe_bpu_update_en(fe_bpu_update_en), .fe_bpu_update_meta(fe_bpu_update_meta),
        .be_iq_valid(be_iq_valid), .be_iq_inst(be_iq_inst),
        .be_iq_accept_count(be_iq_accept_count),
        .be_redirect_valid(be_redirect_valid), .be_redirect_pc(be_redirect_pc),
        .be_redirect_kind(be_redirect_kind),
        .be_redirect_ghr_before(be_redirect_ghr_before),
        .be_redirect_actual_taken(be_redirect_actual_taken),
        .be_bpu_update_credit(be_bpu_update_credit),
        .be_bpu_update_valid(be_bpu_update_valid),
        .be_bpu_update(be_bpu_update)
    );

    int unsigned checks, errors;
    int unsigned seen;
    logic [31:0] expected [0:7];

    task automatic check(input logic cond, input string name);
        begin
            checks++;
            if (!cond) begin
                /* verilator lint_off BLKSEQ */
                errors = errors + 1;
                /* verilator lint_on BLKSEQ */
                $display("FAIL: %s", name);
            end
        end
    endtask

    // Capture the order in which the legacy BPU sees updates.
    always_ff @(posedge clk) begin
        if (!rst && fe_bpu_update_en) begin
            if (seen < 8) begin
                check(fe_bpu_update_meta.update_pc == expected[seen],
                      $sformatf("BPU update order [%0d]", seen));
            end
            seen <= seen + 1;
        end
    end

    task automatic push(input logic [31:0] pc0, input logic [31:0] pc1,
                        input logic v0, input logic v1);
        begin
            @(negedge clk);
            be_bpu_update_valid = {v1, v0};
            be_bpu_update[0] = '0;
            be_bpu_update[1] = '0;
            be_bpu_update[0].update_pc = pc0;
            be_bpu_update[1].update_pc = pc1;
            @(posedge clk); #1;
            be_bpu_update_valid = 2'd0;
        end
    endtask

    initial begin
        fe_iq_rvalid = 2'b00;
        fe_iq_rbits[0] = '0;
        fe_iq_rbits[1] = '0;
        be_iq_accept_count = 2'd0;
        be_redirect_valid = 1'b0;
        be_redirect_pc = 32'h0;
        be_redirect_kind = REDIRECT_ARCH;
        be_redirect_ghr_before = '0;
        be_redirect_actual_taken = 1'b0;
        be_bpu_update_valid = 2'd0;
        be_bpu_update[0] = '0;
        be_bpu_update[1] = '0;
        checks = 0; errors = 0; seen = 0;
        expected[0] = 32'h1000; expected[1] = 32'h1004;
        expected[2] = 32'h1008; expected[3] = 32'h100c;

        repeat (2) @(posedge clk);
        #1; rst = 1'b0;
        repeat (2) @(posedge clk); #1;

        // IQ/redirect are pure wiring.
        fe_iq_rvalid = 2'b11;
        fe_iq_rbits[0].pc = 32'h8000_0000;
        fe_iq_rbits[0].inst = 32'h0000_0013;
        fe_iq_rbits[1].pc = 32'h8000_0004;
        fe_iq_rbits[1].inst = 32'h0000_0013;
        be_iq_accept_count = 2'd2;
        be_redirect_valid = 1'b1;
        be_redirect_pc = 32'h8000_0100;
        be_redirect_kind = REDIRECT_BRANCH;
        #1;
        check(be_iq_valid == 2'b11 && be_iq_inst[0].pc == 32'h8000_0000
              && be_iq_inst[1].pc == 32'h8000_0004, "IQ mapping");
        check(fe_iq_raccept_cnt == 2'd2, "accept mapping");
        check(fe_redirect_valid && fe_redirect_pc == 32'h8000_0100
              && fe_redirect_kind == REDIRECT_BRANCH, "redirect mapping");
        fe_iq_rvalid = 2'b00;
        be_iq_accept_count = 2'd0;
        be_redirect_valid = 1'b0;

        // Two updates in one cycle must both survive; legacy sees one/cycle.
        push(32'h1000, 32'h1004, 1'b1, 1'b1);
        #1;
        check(be_bpu_update_credit == 2'd2, "credit after two pushes");
        check(fe_bpu_update_en, "FIFO drains first update");
        @(posedge clk); #1;
        check(fe_bpu_update_en && fe_bpu_update_meta.update_pc == 32'h1004,
              "second update preserved");
        @(posedge clk); #1;
        check(!fe_bpu_update_en, "FIFO empty");

        // Fill the 4-entry queue, then drain it without loss.
        push(32'h1008, 32'h100c, 1'b1, 1'b1);
        #1;
        check(fe_bpu_update_en && fe_bpu_update_meta.update_pc == 32'h1008,
              "filled queue head");
        @(posedge clk); #1;
        check(fe_bpu_update_en && fe_bpu_update_meta.update_pc == 32'h100c,
              "filled queue second");
        @(posedge clk); #1;
        check(!fe_bpu_update_en, "filled queue drained");

        if (errors == 0)
            $display("ALL TESTS PASSED: %0d checks - legacy FE adapter IQ/redirect/BPU queue", checks);
        else
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        $finish;
    end

    initial begin
        #100000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
