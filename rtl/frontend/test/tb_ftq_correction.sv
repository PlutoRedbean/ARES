/* verilator lint_off UNUSEDSIGNAL */
`timescale 1ns/1ps
module tb_ftq_correction;
    import fe_pkg::*;
    logic clk,rst,flush,wvalid,wready,rvalid,rready,corr_valid,corr_hit,corr_wr_en;
    ftq_entry_t wdata,rdata,corr_wr_data;
    logic [FTQ_NUM_ENTRIES-1:0] wr_idx_oh,corr_idx,corr_wr_idx;
    logic [31:0] corr_start_pc;
    logic [$clog2(FTQ_NUM_ENTRIES+1)-1:0] occupancy;
    logic alloc,pop;
    int checks=0;
    localparam logic[31:0] A=32'h80000100;
    initial begin clk=0; forever #5 clk=~clk; end
    ftq dut(.*);
    task automatic check(input bit ok,input string why);
        checks++;
        if(!ok) $fatal(1,"FTQ: %s",why);
    endtask
    initial begin
        rst=1;flush=0;wvalid=0;rready=0;corr_valid=0;corr_wr_en=0;
        wdata='0;corr_idx='0;corr_wr_idx='0;corr_wr_data='0;corr_start_pc=0;
        repeat(3) @(negedge clk);rst=0;
        for(int i=0;i<FTQ_NUM_ENTRIES;i++) begin
            wvalid=1;wdata.start_pc=A+32'(16*i);
            @(negedge clk);
        end
        wvalid=0;
        check(!wready && int'(occupancy)==FTQ_NUM_ENTRIES,"full queue");
        // Correct the final entry: no tail is discarded, but a simultaneous
        // head pop still frees one entry once the correction poison expires.
        corr_idx=FTQ_NUM_ENTRIES'(1)<<(FTQ_NUM_ENTRIES-1);
        corr_start_pc=A+32'(16*(FTQ_NUM_ENTRIES-1));corr_valid=1;rready=1;
        #1;check(corr_hit,"last allocated entry matches");
        @(negedge clk);corr_valid=0;rready=0;
        check(int'(occupancy)==FTQ_NUM_ENTRIES-1,"same-cycle read reduced occupancy");
        repeat(3) @(negedge clk);
        check(wready,"full flag released after correction plus pop");
        // A stale index whose PC was recycled cannot rewrite a new generation.
        corr_idx=FTQ_NUM_ENTRIES'(2);corr_wr_idx=corr_idx;
        corr_start_pc=A+32'h10000;corr_valid=1;corr_wr_en=1;
        corr_wr_data='0;corr_wr_data.start_pc=32'hdeadbeef;
        #1;check(!corr_hit,"stale correction identity rejected");
        @(negedge clk);corr_valid=0;corr_wr_en=0;
        check(rdata.start_pc==A+16,"stale rewrite did not corrupt head");
        $display("ALL TESTS PASSED: FTQ correction %0d checks, full/pop/poison/identity",checks);
        $finish;
    end
    initial begin #20000;$fatal(1,"FTQ timeout");end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
