/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
`timescale 1ns/1ps
// Real frontend + protocol BE model. Instruction order and history checked by
// a sequential reference, with delayed/stalled memory and IQ backpressure.
module tb_fe_be_contract;
    import fe_pkg::*;
    logic clk=0,rst=1;
    always #5 clk=~clk;
    axi_if bus();
    logic [1:0] valid,accept,credit,updates_valid;
    iq_entry_t inst [2];
    bpu_update_t updates [2];
    logic redirect=0,actual_taken=0;
    logic [31:0] redirect_pc=0;
    logic [GHR_WIDTH-1:0] redirect_history=0;
    logic [31:0] expected_pc=32'h80000000;
    logic [GHR_WIDTH-1:0] expected_history=0;
    logic [31:0] fetch_pc;
    int cycles=0, consumed=0, corrections=0, responses=0;
    int phase=0, finish_at=0;
    logic memory_busy=0;
    int delay_left=0;
    logic [31:0] memory_addr;
    logic [31:0] words [8192];
    frontend dut(.clk(clk),.rst(rst),.iq_rvalid(valid),.iq_rbits(inst),.iq_raccept_cnt(accept),
        .backend_redirect_valid(redirect),.backend_redirect_pc(redirect_pc),.backend_redirect_kind(REDIRECT_BRANCH),
        .backend_redirect_ghr_before(redirect_history),.backend_redirect_actual_taken(actual_taken),
        .bpu_update_credit(credit),.bpu_update_valid(updates_valid),.bpu_update(updates),.ifu_axi_bus(bus),
        .fetch_pc_out(fetch_pc),.iq_occupancy(),.iq_enq_count(),.iq_deq_count(),.ftq_occupancy(),
        .ftq_alloc(),.ftq_pop(),.icache_refill(),.icache_req_fire());
    assign bus.arready=!rst && !memory_busy && (cycles%3!=0);
    assign bus.awready=0; assign bus.wready=0; assign bus.bvalid=0; assign bus.bresp=0; assign bus.rresp=0;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(rst) begin bus.rvalid<=0; bus.rdata<=0; memory_busy<=0; end
        else begin
            if(bus.arvalid && bus.arready) begin
                if(bus.araddr<32'h80000000 || bus.araddr>=32'h80008000) $fatal(1,"fetch escaped IROM");
                memory_addr<=bus.araddr; memory_busy<=1; delay_left<=cycles%8+1;
            end
            if(memory_busy && !bus.rvalid) begin
                if(delay_left!=0) delay_left<=delay_left-1;
                else begin bus.rvalid<=1; bus.rdata<=words[(memory_addr-32'h80000000)>>2]; end
            end
            if(bus.rvalid && bus.rready) begin bus.rvalid<=0; memory_busy<=0; responses++; end
        end
    end
    function automatic logic [31:0] actual_next(input iq_entry_t e);
        if(e.inst[6:0]==7'h6f)
            return e.pc+{{11{e.inst[31]}},e.inst[31],e.inst[19:12],e.inst[20],e.inst[30:21],1'b0};
        if(e.inst[6:0]==7'h67) return 32'h80000040;
        return e.pc+4;
    endfunction
    always_comb begin
        accept=0; updates_valid=0; updates[0]='0; updates[1]='0;
        if(!rst && !redirect && phase!=2 && cycles%23>=12) begin
            if(valid[0]) accept=1;
            if(valid==3 && !inst[0].is_cfi && cycles%3!=0) accept=2;
            for(int l=0;l<2;l++) begin
                if(l<int'(accept) && inst[l].is_cfi) begin
                    if(credit==0) accept=2'(l);
                    else begin
                        updates_valid[l]=1;
                        updates[l].update_pc=inst[l].pc;
                        updates[l].actual_taken=inst[l].cfi_type!=CFI_COND_BRANCH;
                        updates[l].actual_target=actual_next(inst[l]);
                        updates[l].actual_cfi_type=inst[l].cfi_type;
                        updates[l].pred_meta=inst[l].pred_meta;
                    end
                end
            end
        end
    end
    always @(posedge clk) if(!rst) begin
        redirect<=0;
        if(dut.fe_redirect_valid) corrections++;
        if(redirect && accept!=0) $fatal(1,"dispatch during redirect");
        for(int l=0;l<2;l++) if(l<int'(accept)) begin
            if(inst[l].pc!==expected_pc || inst[l].inst!==words[(expected_pc-32'h80000000)>>2])
                $fatal(1,"instruction lost/repeated/wrong path: got %x expected %x",inst[l].pc,expected_pc);
            if(inst[l].is_cfi) begin
                if(inst[l].pred_meta.ghr_before!==expected_history) $fatal(1,"per-CFI history got %x expected %x",inst[l].pred_meta.ghr_before,expected_history);
                expected_history=(expected_history<<1)|GHR_WIDTH'(inst[l].cfi_type!=CFI_COND_BRANCH);
                if(actual_next(inst[l])!=inst[l].pred_npc) begin
                    redirect<=1; redirect_pc<=actual_next(inst[l]);
                    redirect_history<=inst[l].pred_meta.ghr_before; actual_taken<=inst[l].cfi_type!=CFI_COND_BRANCH;
                end
            end
            expected_pc=actual_next(inst[l]); consumed++;
            if(phase==1) begin
                if(inst[l].pc!=32'h80007ffc || valid!=1) $fatal(1,"IROM final window mask");
                phase=2; finish_at=cycles+80;
            end
        end
        if(consumed>=600 && phase==0) begin
            if(corrections<5 || responses<8) $fatal(1,"insufficient correction/refill coverage");
            phase=1; redirect<=1; redirect_pc<=32'h80007ffc;
            redirect_history<=expected_history; actual_taken<=0;
            expected_history=expected_history<<1; expected_pc=32'h80007ffc;
        end
        if(phase==2 && cycles>=finish_at) begin
            if(valid!=0) $fatal(1,"out-of-ROM or stale-path instruction visible");
            $display("ALL TESTS PASSED: real FE contract %0d instructions, %0d local corrections, %0d delayed responses, final-ROM window/stale response isolation",consumed,corrections,responses);
            $finish;
        end
    end
    initial begin
        foreach(words[i]) words[i]=32'h00000013;
        words[1]=32'h00101463; // never-taken BNE, PC+8 target
        words[2]=32'h00101463;
        words[3]=32'h0140006f; // JAL PC+20 -> 0x20
        words[9]=32'h00008067; // unpredicted JALR -> 0x40 in BE reference
        words[17]=32'hfbdff06f; // JAL -68 -> 0
        repeat(4) @(negedge clk); rst=0;
    end
    initial begin #300000; $fatal(1,"timeout consumed=%0d pc=%x",consumed,expected_pc); end
endmodule

/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
