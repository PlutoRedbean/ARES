/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
`timescale 1ns/1ps
module tb_bpu_contract;
    import fe_pkg::*;
    logic clk=0, rst=1;
    always #5 clk=~clk;
    logic [1:0] valid=0, credit;
    bpu_update_t updates [2], trained;
    logic ready=0, train_valid;
    logic [GHR_WIDTH-1:0] committed_next;
    bpu_commit_queue queue_dut (.clk(clk),.rst(rst),.train_ready(ready),.update_valid(valid),.update(updates),
        .credit(credit),.train_valid(train_valid),.train(trained),.ghr_commit_next(committed_next));
    bpu_update_t expected[$];
    bpu_update_t item;
    logic [GHR_WIDTH-1:0] history=0;
    int checks=0, serial=0, seen_credit[3];
    int unsigned rng=32'hc5bad123;
    function automatic int unsigned random_word();
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng;
    endfunction
    always @(posedge clk) if (!rst) begin
        seen_credit[credit]++;
        if (train_valid && ready) begin
            if (expected.size()==0) $fatal(1,"unexpected training event");
            item=expected.pop_front();
            if (trained !== item) $fatal(1,"training loss/reorder/metadata change");
            checks++;
        end
        for(int l=0;l<2;l++) if(valid[l]) begin
            expected.push_back(updates[l]);
            history=(history<<1)|GHR_WIDTH'(updates[l].actual_taken);
        end
        if (committed_next !== history) $fatal(1,"commit history delayed or lane order wrong");
        checks++;
    end
    task automatic send(input int count);
        valid=2'(count==2 ? 3 : count==1 ? 1 : 0);
        for(int l=0;l<2;l++) begin
            updates[l]='0; updates[l].update_pc=32'h80000100+32'(serial*4);
            updates[l].actual_taken=1'(serial); updates[l].actual_target=32'(serial*20);
            updates[l].actual_cfi_type=CFI_COND_BRANCH;
            updates[l].pred_meta.ghr_before=GHR_WIDTH'(serial^123);
            serial++;
        end
    endtask
    initial begin
        updates[0]='0; updates[1]='0;
        repeat(3) @(negedge clk); rst=0;
        // Stall training to reach every occupancy, including genuine credit=0.
        repeat(4) begin send(2); @(negedge clk); end
        if(credit!=0) $fatal(1,"full FIFO credit");
        send(0); repeat(3) @(negedge clk);
        for(int i=0;i<1200;i++) begin
            ready=1'(random_word());
            send(int'(random_word()%3)<=int'(credit) ? int'(rng%3) : 0);
            @(negedge clk);
        end
        valid=0; ready=1;
        while(expected.size()!=0) @(negedge clk);
        repeat(2) @(negedge clk);
        for(int i=0;i<3;i++) if(seen_credit[i]==0) $fatal(1,"credit coverage");
        ready=0; send(2); @(negedge clk); valid=0;
        if(!train_valid) $fatal(1,"missing pending reset fixture");
        rst=1; expected.delete(); history=0;
        @(negedge clk); rst=0;
        if(train_valid || credit!=2 || committed_next!=0) $fatal(1,"cold reset leaked pending training");
        send(1); @(negedge clk); valid=0; ready=1;
        while(expected.size()!=0) @(negedge clk);
        $display("ALL TESTS PASSED: bpu commit FIFO %0d checks, credit 0/1/2, full/wrap/dual-in/stalls/reset",checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule

/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
