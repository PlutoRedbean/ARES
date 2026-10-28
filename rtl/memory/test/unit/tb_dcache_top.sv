// Standalone DCache pipeline test: real arrays, controlled MSHR/WB peers.
// No LSU/AGU/LQ/SQ are instantiated. Checks external outcomes and retry safety.
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
`timescale 1ns/1ps
module tb_dcache_top;
    import ares_pkg::*;
    logic                                     clk;
    logic                                     rst;
    logic                                     lq_lookup_valid;
    logic                                     lq_lookup_ready;
    logic [1:0]                               lq_lookup_idx;
    ares_pkg::tag_t                           lq_lookup_tag;
    logic [31:0]                              lq_lookup_addr;
    logic [7:0]                               lq_wait_epoch [ares_pkg::LQ_ENTRIES];
    logic                                     hit_fill_valid;
    logic [1:0]                               hit_fill_idx;
    logic [31:0]                              hit_fill_word;
    logic                                     sq_drain_valid;
    logic [2:0]                               sq_drain_idx;
    ares_pkg::tag_t                           sq_drain_tag;
    logic [31:0]                              sq_drain_addr;
    logic [31:0]                              sq_drain_data;
    logic [3:0]                               sq_drain_mask;
    logic                                     sq_high_water;
    logic                                     store_start;
    logic                                     store_takeover;
    logic [ares_pkg::CIQ_ENTRIES-1:0]         kill_mask;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_lock_valid;
    logic [ares_pkg::MSHR_ENTRIES-1:0][31:0]  mshr_lock_line_addr;
    logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_lock_way;
    logic [31:0]                              mshr_match_line_addr;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_match_hit;
    logic                                     mshr_resv_valid;
    logic                                     mshr_resv_ready;
    logic [31:0]                              mshr_resv_line_addr;
    logic [1:0]                               mshr_resv_way;
    logic                                     mshr_resv_victim_dirty;
    logic [1:0]                               mshr_resv_wb_idx;
    logic                                     mshr_resv_is_store;
    logic [1:0]                               mshr_resv_lq_idx;
    ares_pkg::tag_t                           mshr_resv_lq_tag;
    logic [7:0]                               mshr_resv_lq_epoch;
    logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_resv_word_idx;
    logic [3:0]                               mshr_resv_store_mask;
    logic [31:0]                              mshr_resv_store_data;
    logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_resv_store_widx;
    logic                                     mshr_merge_valid;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_merge_sel;
    logic                                     mshr_merge_ready;
    logic                                     mshr_merge_is_store;
    logic [1:0]                               mshr_merge_lq_idx;
    ares_pkg::tag_t                           mshr_merge_lq_tag;
    logic [7:0]                               mshr_merge_lq_epoch;
    logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_merge_word_idx;
    logic [3:0]                               mshr_merge_store_mask;
    logic [31:0]                              mshr_merge_store_data;
    logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_merge_store_widx;
    logic                                     mshr_ovl_valid;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_ovl_sel;
    logic                                     mshr_ovl_ready;
    logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_ovl_widx;
    logic [3:0]                               mshr_ovl_mask;
    logic [31:0]                              mshr_ovl_data;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_cap_req_valid;
    logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_cap_req_way;
    logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] mshr_cap_req_row;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_cap_gnt;
    logic                                     cap_rsp_valid;
    logic [ares_pkg::DCACHE_INDEX_BITS-1:0]   cap_rsp_set;
    logic [$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_rsp_row;
    logic [1:0]                               cap_rsp_way;
    logic [63:0]                              cap_rsp_data;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_inst_valid;
    logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_inst_way;
    logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] mshr_inst_set;
    logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] mshr_inst_row;
    logic [ares_pkg::MSHR_ENTRIES-1:0][63:0]  mshr_inst_data;
    logic [ares_pkg::MSHR_ENTRIES-1:0][7:0]   mshr_inst_be;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_inst_last;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_inst_gnt;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_pub_valid;
    logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_pub_way;
    logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_TAG_BITS-1:0] mshr_pub_tag;
    logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_pub_dirty;
    logic [ares_pkg::WB_ENTRIES-1:0]          wb_free_mask;
    logic                                     wb_alloc_valid;
    logic [1:0]                               wb_alloc_idx;
    logic [31:0]                              wb_alloc_line_addr;
    logic [31:0]                              wb_vis_query;
    logic                                     wb_vis_block;
    // Speculative probe is not exercised by this unit bench.
    logic        probe_valid = 1'b0;
    logic        probe_ready;
    logic [1:0]  probe_idx = 2'd0;
    ares_pkg::tag_t probe_tag = '0;
    logic [31:0] probe_addr = 32'd0;
    logic        probe_sq_empty = 1'b0;
    logic        probe_wb_empty = 1'b0;
    logic        probe_hit_valid;
    logic [1:0]  probe_hit_idx;
    logic [31:0] probe_hit_word;
    ares_pkg::tag_t probe_hit_tag;
    int checks=0;
    initial begin clk=0; forever #5 clk=~clk; end
    dcache_top dut(.*);
    task automatic check(input bit ok, input string why);
        checks++;
        if(!ok) $fatal(1,"DCache: %s",why);
    endtask
    task automatic step;
        @(posedge clk); @(negedge clk);
    endtask
    task automatic install(input logic [31:0] address, input logic [1:0] way, input logic [31:0] seed);
        mshr_lock_valid[0]=1;
        mshr_lock_line_addr[0]=address;
        mshr_lock_way[0]=way;
        for(int r=0;r<ROWS_PER_LINE;r++) begin
            mshr_inst_valid[0]=1;
            mshr_inst_way[0]=way;
            mshr_inst_set[0]=address[DCACHE_OFFSET_BITS +: DCACHE_INDEX_BITS];
            mshr_inst_row[0]=$clog2(ROWS_PER_LINE)'(r);
            mshr_inst_data[0]={seed+32'(2*r+1),seed+32'(2*r)};
            mshr_inst_be[0]=8'hff;
            mshr_inst_last[0]=(r==ROWS_PER_LINE-1);
            mshr_pub_valid[0]=(r==ROWS_PER_LINE-1);
            mshr_pub_way[0]=way;
            mshr_pub_tag[0]=address[31 -: DCACHE_TAG_BITS];
            #1; check(mshr_inst_gnt[0],"install grant");
            step();
        end
        mshr_inst_valid='0; mshr_pub_valid='0; mshr_inst_last='0; mshr_lock_valid='0;
        step();
    endtask
    task automatic lookup(input logic [31:0] address);
        lq_lookup_addr=address; lq_lookup_idx=1; lq_lookup_tag.slot_index=3;
        lq_lookup_valid=1;
        do @(posedge clk); while(!lq_lookup_ready);
        @(negedge clk); lq_lookup_valid=0;
    endtask
    task automatic fill(input logic [31:0] expected);
        bit seen=0;
        for(int n=0;n<50;n++) begin
            @(posedge clk);
            if(hit_fill_valid) begin
                check(hit_fill_idx==1 && hit_fill_word===expected,"hit word/index");
                seen=1; break;
            end
        end
        check(seen,"load made bounded progress");
        @(negedge clk); step();
    endtask
    task automatic store(input logic [31:0] address, input logic [31:0] value, input logic [3:0] mask);
        bit seen=0;
        sq_drain_addr=address; sq_drain_data=value; sq_drain_mask=mask;
        sq_drain_tag.slot_index=4; sq_drain_valid=1;
        do @(posedge clk); while(!store_start);
        @(negedge clk); sq_drain_valid=0;
        for(int n=0;n<50;n++) begin
            @(posedge clk);
            if(store_takeover) begin seen=1; break; end
        end
        check(seen,"store takeover made bounded progress");
        @(negedge clk); step();
    endtask
    localparam logic [31:0] A=32'h80100000;
    initial begin
        rst=1;
        lq_lookup_valid='0;
        lq_lookup_idx='0;
        lq_lookup_tag='0;
        lq_lookup_addr='0;
        foreach(lq_wait_epoch[i]) lq_wait_epoch[i]='0;
        sq_drain_valid='0;
        sq_drain_idx='0;
        sq_drain_tag='0;
        sq_drain_addr='0;
        sq_drain_data='0;
        sq_drain_mask='0;
        sq_high_water='0;
        kill_mask='0;
        mshr_lock_valid='0;
        mshr_lock_line_addr='0;
        mshr_lock_way='0;
        mshr_match_hit='0;
        mshr_resv_ready='0;
        mshr_merge_ready='0;
        mshr_ovl_ready='0;
        mshr_cap_req_valid='0;
        mshr_cap_req_way='0;
        mshr_cap_req_row='0;
        mshr_inst_valid='0;
        mshr_inst_way='0;
        mshr_inst_set='0;
        mshr_inst_row='0;
        mshr_inst_data='0;
        mshr_inst_be='0;
        mshr_inst_last='0;
        mshr_pub_valid='0;
        mshr_pub_way='0;
        mshr_pub_tag='0;
        mshr_pub_dirty='0;
        wb_free_mask='0;
        wb_vis_block='0;
        mshr_resv_ready=1; mshr_merge_ready=1; mshr_ovl_ready=1; wb_free_mask='1;
        // Wait beyond UNISIM's 100ns configuration GSR before using BRAM.
        #120;
        repeat(4) step(); rst=0; step();
        install(A,2'b01,32'h12340000);
        for(int w=0;w<LINE_BYTES/4;w++) begin lookup(A+32'(4*w)); fill(32'h12340000+32'(w)); end
        store(A+4,32'haabbccdd,4'b0101);
        lookup(A+4); fill(32'h12bb00dd);
        // A resident but not yet visible WB line must retry, without a second allocation.
        wb_vis_block=1; lookup(A);
        repeat(6) begin
            @(posedge clk); check(!hit_fill_valid && !mshr_resv_valid,"WB visibility blocks stale reads");
        end
        @(negedge clk); wb_vis_block=0; fill(32'h12340000);
        // Lock the resident victim: no duplicate-line allocation into another way.
        mshr_lock_valid[0]=1; mshr_lock_line_addr[0]=A; mshr_lock_way[0]=2'b01;
        lookup(A);
        repeat(6) begin
            @(posedge clk); check(!hit_fill_valid && !mshr_resv_valid,"locked victim retries");
        end
        @(negedge clk); mshr_lock_valid='0; fill(32'h12340000);
        // Kill the owner while it is waiting; a late unlock cannot publish it.
        wb_vis_block=1; lookup(A); kill_mask[3]=1; step(); kill_mask='0; wb_vis_block=0;
        repeat(6) begin @(posedge clk); check(!hit_fill_valid,"killed lookup never fills"); end
        @(negedge clk);
        // Same-line MSHR merge retains waiter identity under backpressure.
        mshr_match_hit=1; mshr_merge_ready=0; lq_wait_epoch[1]=8'h67; lookup(A);
        repeat(4) step();
        check(mshr_merge_valid && mshr_merge_lq_idx==1 && mshr_merge_lq_tag.slot_index==3 && mshr_merge_lq_epoch==8'h67,"merge token held");
        mshr_merge_ready=1; step(); mshr_match_hit=0; step();
        // True miss reserves one way and preserves the aligned line address.
        lookup(A+32'(2*LINE_BYTES));
        begin
            bit seen;
            seen=0;
            for(int n=0;n<50;n++) begin
                @(posedge clk);
                if(mshr_resv_valid) begin
                    check(mshr_resv_line_addr==A+32'(2*LINE_BYTES) && $onehot(mshr_resv_way),"miss reserve address/onehot victim");
                    seen=1; break;
                end
            end
            check(seen,"miss reserve made bounded progress");
        end
        $display("ALL TESTS PASSED: tb_dcache_top %0d checks LINE_BYTES=%0d: install/hit/byte-store/retry/kill/merge/miss",checks,LINE_BYTES);
        $finish;
    end
    initial begin #100000; $fatal(1,"DCache test timeout"); end
endmodule
/* verilator lint_on BLKSEQ */
/* verilator lint_on UNUSEDSIGNAL */
