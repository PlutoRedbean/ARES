/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
`timescale 1ns/1ps
module tb_bpu_history;
    import fe_pkg::*;
    logic clk=0,rst=1,flush=0,local_valid=0,taken=0,ftq_ready=0,ftq_valid;
    always #5 clk=~clk;
    logic [31:0] pc=32'h80000100, prediction_pc;
    logic [GHR_WIDTH-1:0] before_history=0,local_history=0;
    fe_redirect_kind_t kind=REDIRECT_ARCH;
    logic [1:0] valid=0,credit;
    bpu_update_t updates[2];
    bpu_update_t recovery_info;
    ftq_entry_t prediction;
    int checks=0;
    bpu dut(.clk(clk),.rst(rst),.flush(flush),.redirect_pc(pc),.redirect_kind(kind),
        .redirect_info(recovery_info),
        .ftq_widx(FTQ_NUM_ENTRIES'(1)), .ftq_corr_hit(1'b0),
        .bpu_corr_valid(), .bpu_corr_idx(), .bpu_corr_wr_en(),
        .bpu_corr_wr_idx(), .bpu_corr_wr_data(), .bpu_corr_start_pc(),
        .redirect_ghr_before(before_history),.redirect_actual_taken(taken),
        .local_repair_valid(local_valid),.local_repair_ghr(local_history),
        .ftq_wready(ftq_ready),.ftq_wvalid(ftq_valid),.bpu_resp_pc(prediction_pc),.ftq_wdata(prediction),
        .bpu_update_valid(valid),.bpu_update(updates),.bpu_update_credit(credit));
    task automatic event_word(input logic [31:0] a, input bit direction);
        @(negedge clk);
        updates[0]='0; updates[0].update_pc=a; updates[0].actual_taken=direction;
        updates[0].actual_target=32'h80000200; updates[0].actual_cfi_type=CFI_COND_BRANCH;
        valid=1;
        @(negedge clk); valid=0;
        wait (dut.commit_queue.occupancy == 0);
        repeat(8) @(negedge clk);
    endtask
    initial begin
        updates[0]='0; updates[1]='0; recovery_info='0;
        repeat(3) @(negedge clk); rst=0;
        // Train two BTB records, then use different blocks with aliased PHT
        // indices to make both original branches predict not-taken.
        event_word(32'h80000100,1); event_word(32'h80001100,0);
        event_word(32'h80000104,1); event_word(32'h80001104,0);
        kind=REDIRECT_ARCH; flush=1;
        @(negedge clk); flush=0; ftq_ready=1;
        do @(negedge clk); while(!ftq_valid);
        if(prediction_pc!=pc || prediction.pred_meta[0].pred_type!=CFI_COND_BRANCH ||
           prediction.pred_meta[1].pred_type!=CFI_COND_BRANCH ||
           prediction.pred_meta[0].pred_taken || prediction.pred_meta[1].pred_taken)
            $fatal(1,"multi-CFI predictor fixture");
        if(prediction.pred_meta[0].ghr_before!=GHR_WIDTH'(10) ||
           prediction.pred_meta[1].ghr_before!=GHR_WIDTH'(20)) $fatal(1,"full per-CFI snapshots");
        checks+=2; ftq_ready=0;
        // Older commit events and unrelated branch recovery in the SAME cycle.
        valid=3; updates[0].actual_taken=1; updates[1]=updates[0]; updates[1].actual_taken=0;
        kind=REDIRECT_BRANCH; before_history=GHR_WIDTH'('h651); taken=1; flush=1;
        @(negedge clk);
        if(dut.ghr_spec!=GHR_WIDTH'('hca3)) $fatal(1,"branch recovery used commit training metadata");
        if(dut.commit_queue.occupancy==0) $fatal(1,"redirect dropped accepted training");
        checks+=2; valid=0; flush=0;
        repeat(3) @(negedge clk);
        // ARCH must include BOTH commits accepted on its own edge: 10 -> 42 -> 171.
        valid=3; updates[0].actual_taken=1; updates[1].actual_taken=1;
        kind=REDIRECT_ARCH; flush=1;
        @(negedge clk);
        if(dut.ghr_spec!=GHR_WIDTH'(171)) $fatal(1,"ARCH history omitted same-cycle commits");
        checks++; valid=0; flush=0;
`ifdef CONFIG_FE_LOOP_PRED
        if(dut.loop_predictor_u.committed[updates[0].update_pc[$clog2(LOOP_ENTRIES)+1:2]].iter != 2)
            $fatal(1,"Loop committed iteration delayed behind table training");
        checks++;
`endif
        local_valid=1; local_history=GHR_WIDTH'('h321); flush=1;
        @(negedge clk);
        if(dut.ghr_spec!=GHR_WIDTH'('h321)) $fatal(1,"local repair history");
        checks++; flush=0; local_valid=0;
`ifdef CONFIG_FE_RAS
        // Immediate committed RAS advances twice before FIFO training catches up.
        updates[0].actual_cfi_type=CFI_CALL; updates[1].actual_cfi_type=CFI_CALL;
        valid=3; kind=REDIRECT_ARCH; flush=1;
        @(negedge clk);
        if(dut.ras_u.sp_commit!=2 || dut.ras_u.sp_spec!=2) $fatal(1,"RAS delayed commit state");
        checks++; valid=0; flush=0;
`endif
`ifdef CONFIG_FE_TAGE
        // Precise history must use the redirecting branch, even while unrelated
        // older events are simultaneously accepted and queued for training.
        @(negedge clk);
        recovery_info='0; recovery_info.actual_cfi_type=CFI_COND_BRANCH;
        recovery_info.pred_meta.tage_meta.meta_valid=1;
        recovery_info.pred_meta.tage_meta.ckpt_ptr=TAGE_CKPT_PTR_WIDTH'(13);
        recovery_info.pred_meta.tage_meta.cond_prefix=TAGE_COND_PREFIX_WIDTH'(2);
        dut.tage_u.ckpt_mem[13]=TAGE_GHV_WIDTH'('h35);
        updates[0]='0; updates[0].actual_cfi_type=CFI_COND_BRANCH;
        updates[0].actual_taken=0; updates[1]=updates[0]; updates[1].actual_taken=1;
        valid=3; kind=REDIRECT_BRANCH; taken=1; flush=1;
        @(negedge clk);
        if(dut.tage_u.hist_r.ghr!=TAGE_GHV_WIDTH'('h1a9))
            $fatal(1,"TAGE recovery used delayed training instead of redirect checkpoint");
        checks++; valid=0; flush=0;
        @(negedge clk);
        begin
            logic [TAGE_GHV_WIDTH-1:0] expected;
            expected=(dut.tage_u.ghr_commit<<2)|TAGE_GHV_WIDTH'(2);
            valid=3; updates[0].actual_taken=1; updates[1].actual_taken=0;
            kind=REDIRECT_ARCH; flush=1;
            @(negedge clk);
            if(dut.tage_u.hist_r.ghr!=expected)
                $fatal(1,"TAGE ARCH omitted accepted commit lanes");
            checks++; valid=0; flush=0;
        end
`endif
        rst=1; @(negedge clk); rst=0;
        if(dut.ghr_spec!=0 || dut.commit_queue.occupancy!=0) $fatal(1,"history reset");
        $display("ALL TESTS PASSED: BPU history %0d checks, multi-CFI snapshots, independent BRANCH/ARCH/local recovery, dual commit",checks);
        $finish;
    end
    initial begin #20000; $fatal(1,"timeout"); end
endmodule

/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
