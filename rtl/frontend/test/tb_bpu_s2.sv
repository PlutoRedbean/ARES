// Exercise the real BPU/FTQ S2 path: the two-slot uBTB evicts an earlier CFI
// while the four-way mBTB still retains it, requiring an in-place correction.
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
`timescale 1ns/1ps
module tb_bpu_s2;
`ifdef CONFIG_FE_MBTB
`ifdef CONFIG_FE_RAS
`define TEST_BPU_S2_ON
`endif
`endif
`ifdef TEST_BPU_S2_ON
    import fe_pkg::*;
    logic clk, rst, flush, wvalid, wready, rvalid, rready;
    logic [31:0] redirect_pc, response_pc;
    logic [1:0] updates_valid, credit;
    bpu_update_t updates[2];
    ftq_entry_t wdata, rdata, correction_data;
    logic [FTQ_NUM_ENTRIES-1:0] widx, correction_idx, rewrite_idx;
    logic correction_valid, correction_hit, rewrite;
    logic [31:0] correction_pc;
    int corrections, checked;
    cfi_type_t first_kind;
    logic [PRED_CKPT_W-1:0] saved_ras_ptr;
    logic [$clog2(RAS_ENTRIES+1)-1:0] saved_ras_sp;
`ifdef CONFIG_FE_TAGE
    logic [TAGE_CKPT_PTR_WIDTH-1:0] saved_tage_ptr;
    logic [TAGE_GHV_WIDTH-1:0] saved_history;
`endif
    localparam logic[31:0] A=32'h80000100;
    initial begin clk=0; forever #5 clk=~clk; end
    bpu dut(.clk(clk),.rst(rst),.flush(flush),.redirect_pc(redirect_pc),
        .redirect_kind(REDIRECT_ARCH),.redirect_ghr_before('0),.redirect_actual_taken(1'b0),
        .local_repair_valid(1'b0),.local_repair_ghr('0),.redirect_info('0),
        .bpu_update_valid(updates_valid),.bpu_update(updates),.bpu_update_credit(credit),
        .ftq_wready(wready),.ftq_wvalid(wvalid),.bpu_resp_pc(response_pc),.ftq_wdata(wdata),
        .ftq_widx(widx),.ftq_corr_hit(correction_hit),.bpu_corr_valid(correction_valid),
        .bpu_corr_idx(correction_idx),.bpu_corr_wr_en(rewrite),.bpu_corr_wr_idx(rewrite_idx),
        .bpu_corr_wr_data(correction_data),.bpu_corr_start_pc(correction_pc));
    ftq queue(.clk(clk),.rst(rst),.flush(flush),.wvalid(wvalid),.wready(wready),.wdata(wdata),
        .rvalid(rvalid),.rready(rready),.rdata(rdata),.occupancy(),.alloc(),.pop(),
        .wr_idx_oh(widx),.corr_idx(correction_idx),.corr_valid(correction_valid),
        .corr_hit(correction_hit),.corr_wr_en(rewrite),.corr_wr_idx(rewrite_idx),
        .corr_wr_data(correction_data),.corr_start_pc(correction_pc));
    task automatic train(input logic[31:0] pc, target, input cfi_type_t kind);
        @(negedge clk);
        while(credit==0) @(negedge clk);
        updates[0]='0; updates[0].update_pc=pc; updates[0].actual_target=target;
        updates[0].actual_cfi_type=kind; updates[0].actual_taken=1;
`ifdef CONFIG_FE_TAGE
        updates[0].pred_meta.tage_meta.base_ctr=3;
        updates[0].pred_meta.tage_meta.base_idx=pc[TAGE_BASE_INDEX_WIDTH+1:2];
        updates[0].pred_meta.tage_meta.slot_id=TAGE_SLOT_ID_WIDTH'((pc>>2)%FETCH_WIDTH);
`endif
        updates_valid=1;
        @(negedge clk); updates_valid=0;
        wait(dut.commit_queue.occupancy==0);
        repeat(10) @(negedge clk);
    endtask
    always @(posedge clk) if(!rst && !flush && dut.corr_fire && correction_pc==A) begin
        if(!correction_data.pred_cfi_valid[0] ||
            correction_data.pred_meta[0].pred_type!=first_kind ||
            !correction_data.pred_meta[0].pred_taken ||
            correction_data.pred_meta[0].pred_target!=A+32'h100)
            $fatal(1,"S2 omitted the mBTB-only first CFI");
        if(!rvalid || rdata.start_pc!=A || rdata.pred_meta[0]!=correction_data.pred_meta[0])
            $fatal(1,"FTQ head did not bypass S2 correction metadata");
        saved_ras_ptr=correction_data.pred_meta[0].ras_ckpt_ptr;
        saved_ras_sp=dut.ras_u.snap_mem[saved_ras_ptr][$clog2(RAS_ENTRIES+1)-1:0];
`ifdef CONFIG_FE_TAGE
        saved_tage_ptr=correction_data.pred_meta[0].tage_meta.ckpt_ptr;
        saved_history=dut.tage_u.ckpt_mem[saved_tage_ptr];
`endif
        corrections++;
    end
    initial begin
        corrections=0; checked=0;
        first_kind=CFI_COND_BRANCH;
        for(int phase=0;phase<2;phase++) begin
            first_kind=CFI_CALL;
`ifdef CONFIG_FE_TAGE
            first_kind=(phase==0)?CFI_COND_BRANCH:CFI_CALL;
`endif
            rst=1; flush=0; redirect_pc=A; rready=0;
            updates_valid=0; updates[0]='0; updates[1]='0;
            repeat(4) @(negedge clk); rst=0;
            train(A,A+32'h100,first_kind);
            train(A+4,A+32'h200,CFI_CALL); train(A+8,A+32'h300,CFI_CALL);
            flush=1; @(negedge clk); flush=0;
            repeat(40) @(negedge clk);
            if(corrections!=phase+1) $fatal(1,"S2 correction was not exercised exactly once");
            if(!rvalid || rdata.start_pc!=A || rdata.pred_meta[0].pred_target!=A+32'h100)
                $fatal(1,"corrected FTQ entry was lost under backpressure");
`ifdef CONFIG_FE_TAGE
            if(!rdata.pred_meta[0].tage_meta.meta_valid) $fatal(1,"TAGE metadata not backfilled");
            if(dut.tage_u.ckpt_mem[saved_tage_ptr]!=saved_history)
                $fatal(1,"S2 restart overwrote a live TAGE checkpoint");
`endif
            if(dut.ras_u.snap_mem[saved_ras_ptr][$clog2(RAS_ENTRIES+1)-1:0]!=saved_ras_sp)
                $fatal(1,"S2 restart overwrote a live RAS checkpoint");
            checked++;
            rready=1; @(negedge clk); rready=0;
            if(!rvalid || rdata.start_pc!=A+32'h100) $fatal(1,"wrong-path FTQ tail survived S2 restart");
            checked++;
        end
        $display("ALL TESTS PASSED: BPU S2 %0d corrections, %0d checks, mBTB-only CFI/FTQ bypass/tail kill/stall/live checkpoints/TAGE backfill",corrections,checked);
        $finish;
    end
    initial begin #20000; $fatal(1,"BPU S2 timeout"); end
`else
    initial begin
        $display("SKIP: BPU S2 contract test requires mBTB and RAS");
        $finish;
    end
`endif
`ifdef TEST_BPU_S2_ON
`undef TEST_BPU_S2_ON
`endif
endmodule
/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
