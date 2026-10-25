//=============================================================================
// ARES - shared L2 unit test
//-----------------------------------------------------------------------------
// Two synthetic 128-bit-beat masters exercise the shared L2:
//   * write/read hit through core0, read hit through core1
//   * read miss (clean refill)
//   * write miss (write-allocate + merge)
//   * dirty eviction/writeback with wrap-around tags
//   * byte enables
//   * concurrent requests from both ports
//=============================================================================
`timescale 1ns/1ps
module tb_l2;
    import l2_pkg::*;

    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
    end
    always #5 clk = ~clk;

    localparam int unsigned SETS = 16;
    localparam int unsigned MEM_WORDS = 1 << 16;

    logic c0_rd_valid, c0_rd_ready, c0_rsp_valid, c0_rsp_ready;
    logic [31:0] c0_rd_addr;
    logic [127:0] c0_rsp_data;
    logic c0_wr_valid, c0_wr_ready;
    logic [31:0] c0_wr_addr;
    logic [127:0] c0_wr_data;
    logic [15:0] c0_wr_be;

    logic c1_rd_valid, c1_rd_ready, c1_rsp_valid, c1_rsp_ready;
    logic [31:0] c1_rd_addr;
    logic [127:0] c1_rsp_data;
    logic c1_wr_valid, c1_wr_ready;
    logic [31:0] c1_wr_addr;
    logic [127:0] c1_wr_data;
    logic [15:0] c1_wr_be;

    logic mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
    /* verilator lint_off UNUSEDSIGNAL */  // memory model only indexes [19:4]
    logic [31:0] mem_rd_addr;
    logic [31:0] mem_wr_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic mem_wr_valid, mem_wr_ready;
    logic [127:0] mem_wr_data, mem_rsp_data_128;
    logic [15:0] mem_wr_be;

    logic l2_idle;
    logic [31:0] hit_count, miss_count;

    int unsigned checks, errors;

    l2_top #(.SETS(SETS), .WAYS(4)) dut (
        .clk(clk), .rst(rst),
        .c0_rd_valid(c0_rd_valid), .c0_rd_ready(c0_rd_ready), .c0_rd_addr(c0_rd_addr),
        .c0_rsp_valid(c0_rsp_valid), .c0_rsp_ready(c0_rsp_ready), .c0_rsp_data(c0_rsp_data),
        .c0_wr_valid(c0_wr_valid), .c0_wr_ready(c0_wr_ready), .c0_wr_addr(c0_wr_addr),
        .c0_wr_data(c0_wr_data), .c0_wr_be(c0_wr_be),
        .c1_rd_valid(c1_rd_valid), .c1_rd_ready(c1_rd_ready), .c1_rd_addr(c1_rd_addr),
        .c1_rsp_valid(c1_rsp_valid), .c1_rsp_ready(c1_rsp_ready), .c1_rsp_data(c1_rsp_data),
        .c1_wr_valid(c1_wr_valid), .c1_wr_ready(c1_wr_ready), .c1_wr_addr(c1_wr_addr),
        .c1_wr_data(c1_wr_data), .c1_wr_be(c1_wr_be),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready), .mem_rd_addr(mem_rd_addr),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready), .mem_rsp_data(mem_rsp_data_128),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_be(mem_wr_be),
        .l2_idle(l2_idle), .hit_count(hit_count), .miss_count(miss_count)
    );

    //-------------------------------------------------------------------------
    // Backing memory model: 16 B words, one-cycle read response.
    //-------------------------------------------------------------------------
    logic [127:0] mem [0:MEM_WORDS-1];
    logic         mem_rsp_valid_q;
    logic [127:0] mem_rsp_data_q;

    assign mem_rd_ready = 1'b1;
    assign mem_wr_ready = 1'b1;
    assign mem_rsp_valid = mem_rsp_valid_q;
    assign mem_rsp_data_128 = mem_rsp_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rsp_valid_q <= 1'b0;
            mem_rsp_data_q  <= 128'h0;
        end else begin
            if (mem_rd_valid && mem_rd_ready && !mem_rsp_valid_q) begin
                mem_rsp_valid_q <= 1'b1;
                mem_rsp_data_q  <= mem[mem_rd_addr[19:4]];
            end else if (mem_rsp_valid_q && mem_rsp_ready) begin
                mem_rsp_valid_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (mem_wr_valid && mem_wr_ready) begin
            for (int i = 0; i < 16; i++)
                if (mem_wr_be[i]) mem[mem_wr_addr[19:4]][8*i +: 8] <= mem_wr_data[8*i +: 8];
        end
    end

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

    //-------------------------------------------------------------------------
    // Port drivers
    //-------------------------------------------------------------------------
    task automatic l2_read(input logic port, input logic [31:0] addr,
                           output logic [127:0] data);
        begin
            @(negedge clk);
            if (port) begin
                c1_rd_valid = 1'b1;
                c1_rd_addr  = addr;
            end else begin
                c0_rd_valid = 1'b1;
                c0_rd_addr  = addr;
            end
            #1;
            while (port ? !c1_rd_ready : !c0_rd_ready) begin
                @(posedge clk); #1;
            end
            @(posedge clk); #1;
            if (port) c1_rd_valid = 1'b0; else c0_rd_valid = 1'b0;

            while (port ? !c1_rsp_valid : !c0_rsp_valid) begin
                @(posedge clk); #1;
            end
            data = port ? c1_rsp_data : c0_rsp_data;
            if (port) c1_rsp_ready = 1'b1; else c0_rsp_ready = 1'b1;
            @(posedge clk); #1;
            if (port) c1_rsp_ready = 1'b0; else c0_rsp_ready = 1'b0;
        end
    endtask

    task automatic l2_write(input logic port, input logic [31:0] addr,
                            input logic [127:0] data, input logic [15:0] be);
        begin
            @(negedge clk);
            if (port) begin
                c1_wr_valid = 1'b1;
                c1_wr_addr  = addr;
                c1_wr_data  = data;
                c1_wr_be    = be;
            end else begin
                c0_wr_valid = 1'b1;
                c0_wr_addr  = addr;
                c0_wr_data  = data;
                c0_wr_be    = be;
            end
            #1;
            while (port ? !c1_wr_ready : !c0_wr_ready) begin
                @(posedge clk); #1;
            end
            @(posedge clk); #1;
            if (port) c1_wr_valid = 1'b0; else c0_wr_valid = 1'b0;
            while (!l2_idle) begin
                @(posedge clk); #1;
            end
        end
    endtask

    logic [127:0] rd0, rd1;
    logic [127:0] pat [0:7];
    localparam logic [127:0] MEM4000 = 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_1111_2222;

    initial begin
        c0_rd_valid = 0; c0_rd_addr = 0; c0_rsp_ready = 0;
        c0_wr_valid = 0; c0_wr_addr = 0; c0_wr_data = 0; c0_wr_be = 0;
        c1_rd_valid = 0; c1_rd_addr = 0; c1_rsp_ready = 0;
        c1_wr_valid = 0; c1_wr_addr = 0; c1_wr_data = 0; c1_wr_be = 0;
        checks = 0; errors = 0;

        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 128'h0;
        for (int i = 0; i < 8; i++) pat[i] = {4{32'h1000_0000 + 32'(i)}};

        repeat (3) @(posedge clk);
        #1;
        rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        check(l2_idle, "reset: L2 idle");

        // Write then read through the other port: shared data.
        l2_write(1'b0, 32'h0000_1000, pat[0], 16'hFFFF);
        l2_read (1'b0, 32'h0000_1000, rd0);
        check(rd0 == pat[0], "core0 write/read hit");
        l2_read (1'b1, 32'h0000_1000, rd1);
        check(rd1 == pat[0], "core1 reads core0 line");

        // Write from core1, read from core0.
        l2_write(1'b1, 32'h0000_2000, pat[1], 16'hFFFF);
        l2_read (1'b0, 32'h0000_2000, rd0);
        check(rd0 == pat[1], "core0 reads core1 line");

        // Clean miss: preload backing memory, then read.
        mem[32'h0000_3000 >> 4] = pat[2];
        l2_read(1'b0, 32'h0000_3000, rd0);
        check(rd0 == pat[2], "clean refill from memory");
        l2_read(1'b1, 32'h0000_3000, rd1);
        check(rd1 == pat[2], "clean refill then second-port hit");

        // Dirty eviction/writeback: five lines map to the same set
        // (index = addr[9:6], SETS=16) and four ways are available.
        l2_write(1'b0, 32'h0000_0000, pat[0], 16'hFFFF);
        l2_write(1'b0, 32'h0000_0400, pat[1], 16'hFFFF);
        l2_write(1'b0, 32'h0000_0800, pat[2], 16'hFFFF);
        l2_write(1'b0, 32'h0000_0C00, pat[3], 16'hFFFF);
        l2_write(1'b0, 32'h0000_1000, pat[4], 16'hFFFF);
        l2_read (1'b0, 32'h0000_0000, rd0);
        check(rd0 == pat[0], "dirty victim writeback + refill");
        l2_read (1'b1, 32'h0000_0400, rd1);
        check(rd1 == pat[1], "second line after eviction");
        l2_read (1'b0, 32'h0000_1000, rd0);
        check(rd0 == pat[4], "newest line retained");

        // Byte enables: merge into a clean line fetched from memory.
        mem[32'h0000_4000 >> 4] = MEM4000;
        l2_write(1'b0, 32'h0000_4000, 128'h0123_4567_89AB_CDEF_0000_0000_0000_0000, 16'h000F);
        l2_read (1'b0, 32'h0000_4000, rd0);
        check(rd0[31:0] == 32'h0, "byte enable writes low 4 bytes");
        check(rd0[63:32] == MEM4000[63:32] && rd0[127:64] == MEM4000[127:64],
              "byte enable preserves other bytes");

        // Concurrent requests from both ports.
        mem[32'h0000_5000 >> 4] = pat[5];
        mem[32'h0000_5040 >> 4] = pat[6];
        fork
            l2_read(1'b0, 32'h0000_5000, rd0);
            l2_read(1'b1, 32'h0000_5040, rd1);
        join
        check(rd0 == pat[5] && rd1 == pat[6], "concurrent dual-port reads");

        check(hit_count != 0 && miss_count != 0, "hit/miss counters advanced");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - shared L2 hit/miss, clean refill, dirty writeback, byte enables, dual-port concurrency (hits=%0d misses=%0d)", checks, hit_count, miss_count);
        end else begin
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        end
        $finish;
    end

    initial begin
        #500000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
