// The banked two-slot uBTB has different replacement/capacity from the legacy
// fully-associative reference. Check its public contract and accepted updates.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
`timescale 1ns/1ps
module tb_ubtb_equiv;
    import fe_pkg::*;
    logic clk;
    logic rst=1, req_valid=0, update_en=0, actual_taken=0, update_pred_taken=0;
    logic update_ready, resp_valid;
    logic [ADDR_WIDTH-1:0] fetch_pc=0, update_pc=0, resp_pc;
    btb_target_info_t update_target;
    logic [FETCH_WIDTH-1:0] pred_cfi_valid;
    cfi_type_t [FETCH_WIDTH-1:0] pred_cfi_type;
    logic [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target;
    int checks=0, stalls=0;
    localparam logic [31:0] A=32'h80000100;
    initial clk=0;
    always #5 clk=~clk;
    ubtb dut(.*);
    task automatic check(input bit ok, input string why);
        checks++;
        if(!ok) $fatal(1,"uBTB: %s",why);
    endtask
    task automatic train(input logic[31:0] pc, target, input cfi_type_t kind,
                         input bit taken, predicted);
        @(negedge clk);
        while(!update_ready) begin stalls++; @(negedge clk); end
        update_pc=pc; update_target='0; update_target.target_pc=target;
        update_target.cfi_type=kind;
        actual_taken=taken; update_pred_taken=predicted; update_en=1;
        @(negedge clk); update_en=0;
    endtask
    task automatic drain;
        repeat(10) @(negedge clk);
    endtask
    task automatic lookup(input logic[31:0] pc);
        @(negedge clk); fetch_pc=pc; req_valid=1;
        @(posedge clk); #1;
        check(resp_valid && resp_pc==pc,"one-cycle response and PC");
        @(negedge clk); req_valid=0;
    endtask
    initial begin
        update_target='0;
        repeat(4) @(negedge clk); rst=0;
        lookup(A); check(pred_cfi_valid==0,"reset invalidates slots");
        // Three consecutive same-bank events exceed the pending capacity unless
        // the caller observes readiness. All must survive in program order.
        train(A, A+32'h80, CFI_COND_BRANCH,1,0);
        train(A+4,A+32'h100,CFI_CALL,1,0);
        train(A+32'(UBTB_BANKS*UBTB_REGION_BYTES),A+32'h200,CFI_DIRECT_JUMP,1,0);
        drain();
        lookup(A);
        check(pred_cfi_valid==FETCH_WIDTH'(3),"both same-region CFI slots survive bank hazards");
        check(pred_target[0]==A+32'h80 && pred_target[1]==A+32'h100,"training targets");
        check(pred_cfi_type[0]==CFI_COND_BRANCH && pred_cfi_type[1]==CFI_CALL,"CFI types");
        lookup(A+32'(UBTB_BANKS*UBTB_REGION_BYTES));
        check(pred_cfi_valid[0] && pred_target[0]==A+32'h200,"pending event not lost");
        lookup(A+4);
        check(pred_cfi_valid==FETCH_WIDTH'(1) && pred_target[0]==A+32'h100,"unaligned window");
        // Stall the read port while targets are trained in the background.
        begin
            logic [FETCH_WIDTH-1:0] saved_valid;
            logic [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] saved_target;
            saved_valid=pred_cfi_valid; saved_target=pred_target;
            train(A+4,A+32'h300,CFI_CALL,1,1); drain();
            check(!resp_valid && resp_pc==A+4 && pred_cfi_valid==saved_valid && pred_target==saved_target,
                  "stalled response holds while training");
        end
        lookup(A+4); check(pred_target[0]==A+32'h300,"accepted replacement target");
        // One weak entry decays only when the raw predictor had said taken.
        train(A,A+32'h80,CFI_COND_BRANCH,0,1); drain();
        lookup(A); check(!pred_cfi_valid[0] && pred_cfi_valid[1],"not-taken decay is slot-local");
        train(A+28,A+32'h400,CFI_RETURN,1,0);
        train(A+32,A+32'h500,CFI_INDIRECT_JUMP,1,0); drain();
        lookup(A+28);
        check(pred_cfi_valid[0] && pred_cfi_valid[1],"cross-region prediction");
        check(pred_target[0]==A+32'h400 && pred_target[1]==A+32'h500,"cross-region targets");
        check(stalls>0,"same-bank backpressure exercised");
        @(negedge clk); rst=1; repeat(2) @(negedge clk); rst=0;
        lookup(A); check(pred_cfi_valid==0,"runtime reset invalidates trained slots");
        $display("ALL TESTS PASSED: banked uBTB %0d checks, %0d stalled cycles, pending/hold/decay/unaligned/cross-region/reset",checks,stalls);
        $finish;
    end
    initial begin #20000; $fatal(1,"uBTB timeout"); end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
