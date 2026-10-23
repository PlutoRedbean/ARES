// Preserve grants and every valid request while separating recovery control
// from payload selection. Payloads on invalid ports are outside the contract.
`timescale 1ns/1ps
module tb_issue_equiv;
    import ares_pkg::*;
    queue_entry_t cand[ISSUE_WIDTH_MAX];
    logic [31:0] src1[ISSUE_WIDTH_MAX], src2[ISSUE_WIDTH_MAX];
    logic src_ready[ISSUE_WIDTH_MAX];
    tag_t issue_ptr, commit_ptr;
    logic lsu_mmio_order_idle,recovery_valid,flush_active;
    logic [7:0] fu_can_accept,fu_issue_valid,ref_valid;
    logic [2:0] load_credit;
    logic [3:0] store_credit;
    logic [ISSUE_WIDTH_MAX-1:0] issue_grant,ref_grant;
    tag_t issue_tag[ISSUE_WIDTH_MAX],ref_tag[ISSUE_WIDTH_MAX];
    fu_req_t fu_req[8],ref_req[8];
    int unsigned seed,valid_checks;
    be_issue_sched dut(.*);
    be_issue_sched_reference reference_model (.cand(cand),.src1(src1),.src2(src2),.src_ready(src_ready),
        .issue_ptr(issue_ptr),.commit_ptr(commit_ptr),.lsu_mmio_order_idle(lsu_mmio_order_idle),
        .recovery_valid(recovery_valid),.flush_active(flush_active),.fu_can_accept(fu_can_accept),
        .load_credit(load_credit),.store_credit(store_credit),.issue_grant(ref_grant),
        .issue_tag(ref_tag),.fu_issue_valid(ref_valid),.fu_req(ref_req));
    function automatic int unsigned rnd(input int unsigned limit);
        seed=seed*32'd1664525+32'd1013904223;
        return (seed>>8)%limit;
    endfunction
    initial begin
        seed=32'h27182818; valid_checks=0;
        for(int n=0;n<100000;n++) begin
            issue_ptr.slot_index=4'(rnd(16)); commit_ptr.slot_index=4'(rnd(16));
            lsu_mmio_order_idle=1'(rnd(2)); recovery_valid=(rnd(8)==0); flush_active=(rnd(8)==0);
            fu_can_accept=8'(rnd(256)); load_credit=3'(rnd(5)); store_credit=4'(rnd(9));
            for(int i=0;i<ISSUE_WIDTH_MAX;i++) begin
                cand[i]='0; cand[i].valid=(rnd(8)!=0); cand[i].state=entry_state_t'(rnd(4));
                cand[i].fu_type=fu_type_t'(rnd(8)); cand[i].op=(rnd(2)==0)?OP_MUL:OP_ADD;
                cand[i].is_serializing=(rnd(8)==0);
                cand[i].is_load=1'(rnd(2)); cand[i].is_store=!cand[i].is_load;
                cand[i].pc=32'h80000000+32'(4*n+i*4); cand[i].imm=32'(rnd(4096));
                cand[i].pred_npc=cand[i].pc+4; cand[i].csr_addr=12'(rnd(4096));
                cand[i].csr_write_en=1'(rnd(2));
                src_ready[i]=(rnd(4)!=0);
                src1[i]=(rnd(2)==0) ? 32'(rnd(65536)) : 32'(rnd(32'hffffffff));
                src2[i]=(rnd(2)==0) ? 32'(rnd(65536)) : 32'(rnd(32'hffffffff));
            end
            #1;
            if(issue_grant!==ref_grant || fu_issue_valid!==ref_valid)
                $fatal(1,"issue grant equivalence failed cycle %0d",n);
            for(int i=0;i<ISSUE_WIDTH_MAX;i++)
                if(issue_tag[i]!==ref_tag[i]) $fatal(1,"issue tag equivalence");
            for(int p=0;p<8;p++) if(fu_issue_valid[p]) begin
                valid_checks++;
                if(fu_req[p]!==ref_req[p]) $fatal(1,"valid request equivalence port %0d",p);
            end
        end
        if(valid_checks<1000) $fatal(1,"issue test lacks valid requests");
        $display("ALL TESTS PASSED: issue equivalence 100000 vectors / %0d valid requests, recovery/flush/prefix/credits/SMUL",valid_checks);
        $finish;
    end
endmodule
