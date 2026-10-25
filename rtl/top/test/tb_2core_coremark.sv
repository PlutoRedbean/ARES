//=============================================================================
// ARES - two real frontends + shared L2, two AMP CoreMark instances
//-----------------------------------------------------------------------------
// Both harts execute the same code image; hart1's D-side is offset by
// C1_DATA_OFFSET so its data/stack live at 0x8020_0000.. while hart0 uses
// 0x8010_0000...  The backing image is duplicated at +1 MiB for hart1.
//
// +DMEM=<128-bit-wide coremark image>  (same format as tb_ares_coremark)
//=============================================================================
`timescale 1ns/1ps
module tb_2core_coremark;
    import ares_pkg::*;

    localparam int unsigned MEM_WORDS = 1 << 20;  // 16 MiB
    localparam int unsigned DATA_LINES = 16'h4000;  // 0x8010_0000..0x8013_ffff
    localparam logic [31:0] C1_OFFSET  = 32'h0010_0000;

    logic clk, rst;
    initial begin clk = 1'b0; rst = 1'b1; end
    always #5 clk = ~clk;

    logic         l2_mem_rd_valid, l2_mem_rd_ready, l2_mem_rsp_valid, l2_mem_rsp_ready;
    logic [31:0]  l2_mem_rd_addr, l2_mem_wr_addr;
    logic [127:0] l2_mem_rsp_data, l2_mem_wr_data;
    logic [15:0]  l2_mem_wr_be;
    logic         l2_mem_wr_valid, l2_mem_wr_ready;
    logic         l2_idle;
    logic [31:0]  l2_hits, l2_misses;

    logic [31:0] c0_fetch_pc, c1_fetch_pc;
    logic [1:0] c0_retire_valid, c0_retire_rd_wen, c0_retire_is_ebreak;
    logic [4:0] c0_retire_rd [2];
    logic [31:0] c0_retire_wdata [2], c0_retire_pc [2];
    logic [1:0] c1_retire_valid, c1_retire_rd_wen, c1_retire_is_ebreak;
    logic [4:0] c1_retire_rd [2];
    logic [31:0] c1_retire_wdata [2], c1_retire_pc [2];

    ares_2core_frontend_l2_top #(
        .RESET_MTVEC(32'h8000_0000),
        .RESET_VEC(32'h8000_0000),
        .L2_SETS(128),
        .C1_DATA_OFFSET(C1_OFFSET),
        .HART1_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rst(rst),
        .l2_mem_rd_valid(l2_mem_rd_valid), .l2_mem_rd_ready(l2_mem_rd_ready),
        .l2_mem_rd_addr(l2_mem_rd_addr),
        .l2_mem_rsp_valid(l2_mem_rsp_valid), .l2_mem_rsp_ready(l2_mem_rsp_ready),
        .l2_mem_rsp_data(l2_mem_rsp_data),
        .l2_mem_wr_valid(l2_mem_wr_valid), .l2_mem_wr_ready(l2_mem_wr_ready),
        .l2_mem_wr_addr(l2_mem_wr_addr), .l2_mem_wr_data(l2_mem_wr_data),
        .l2_mem_wr_be(l2_mem_wr_be),
        .c0_fetch_pc(c0_fetch_pc),
        .c0_retire_valid(c0_retire_valid), .c0_retire_rd_wen(c0_retire_rd_wen),
        .c0_retire_rd(c0_retire_rd), .c0_retire_wdata(c0_retire_wdata),
        .c0_retire_pc(c0_retire_pc), .c0_retire_is_ebreak(c0_retire_is_ebreak),
        .c1_fetch_pc(c1_fetch_pc),
        .c1_retire_valid(c1_retire_valid), .c1_retire_rd_wen(c1_retire_rd_wen),
        .c1_retire_rd(c1_retire_rd), .c1_retire_wdata(c1_retire_wdata),
        .c1_retire_pc(c1_retire_pc), .c1_retire_is_ebreak(c1_retire_is_ebreak),
        .l2_idle(l2_idle), .l2_hit_count(l2_hits), .l2_miss_count(l2_misses)
    );

    logic [127:0] mem [0:MEM_WORDS-1];
    logic         mem_rsp_valid_q;
    logic [127:0] mem_rsp_data_q;

    assign l2_mem_rd_ready = 1'b1;
    assign l2_mem_wr_ready = 1'b1;
    assign l2_mem_rsp_valid = mem_rsp_valid_q;
    assign l2_mem_rsp_data  = mem_rsp_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rsp_valid_q <= 1'b0;
            mem_rsp_data_q  <= 128'h0;
        end else begin
            if (l2_mem_rd_valid && l2_mem_rd_ready && !mem_rsp_valid_q) begin
                mem_rsp_valid_q <= 1'b1;
                mem_rsp_data_q  <= mem[l2_mem_rd_addr[23:4]];
            end else if (mem_rsp_valid_q && l2_mem_rsp_ready) begin
                mem_rsp_valid_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (l2_mem_wr_valid && l2_mem_wr_ready) begin
            for (int i = 0; i < 16; i++)
                if (l2_mem_wr_be[i]) mem[l2_mem_wr_addr[23:4]][8*i +: 8] <= l2_mem_wr_data[8*i +: 8];
        end
    end

    logic [31:0] a0_0, a0_1;
    logic        done0, done1, pass0, pass1;
    int unsigned ms_tick;
    int unsigned bad_h1_rd, bad_h1_wr, bad_h0_wr;
    logic [63:0] cycles, cycles0, cycles1;
    int unsigned ret0, ret1;
    int unsigned checks, errors;

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

    always_ff @(posedge clk) begin
        if (rst) begin
            a0_0 <= 0; a0_1 <= 0;
            done0 <= 0; done1 <= 0; pass0 <= 0; pass1 <= 0;
            cycles <= 0; cycles0 <= 0; cycles1 <= 0;
            ret0 <= 0; ret1 <= 0;
            ms_tick <= 0;
            bad_h1_rd <= 0; bad_h1_wr <= 0; bad_h0_wr <= 0;
        end else begin
            cycles <= cycles + 1'b1;
            ms_tick <= ms_tick + 1;
            if (dut.u_hart1.mem_rd_valid && (dut.u_hart1.mem_rd_addr < 32'h8020_0000)) begin
                bad_h1_rd <= bad_h1_rd + 1;
                if (bad_h1_rd < 5) $display("BAD H1 RD addr=%h", dut.u_hart1.mem_rd_addr);
            end
            if (dut.u_hart1.mem_wr_valid && (dut.u_hart1.mem_wr_addr < 32'h8020_0000)) begin
                bad_h1_wr <= bad_h1_wr + 1;
                if (bad_h1_wr < 5) $display("BAD H1 WR addr=%h", dut.u_hart1.mem_wr_addr);
            end
            if (dut.u_hart0.mem_wr_valid && (dut.u_hart0.mem_wr_addr >= 32'h8020_0000)) begin
                bad_h0_wr <= bad_h0_wr + 1;
                if (bad_h0_wr < 5) $display("BAD H0 WR addr=%h", dut.u_hart0.mem_wr_addr);
            end
            if (ms_tick % 100000 == 0)
                $display("T=%0tns ret0=%0d ret1=%0d pc0=%h pc1=%h a0_0=%h a0_1=%h l2=%0d/%0d",
                         $time, ret0, ret1, c0_fetch_pc, c1_fetch_pc, a0_0, a0_1, l2_hits, l2_misses);
            for (int lane = 0; lane < 2; lane++) begin
                if (c0_retire_valid[lane]) begin
                    ret0 <= ret0 + 1;
                    if (c0_retire_rd_wen[lane] && (c0_retire_rd[lane] == 5'd10))
                        a0_0 <= c0_retire_wdata[lane];
                    if (c0_retire_is_ebreak[lane] && !done0) begin
                        done0 <= 1'b1;
                        pass0 <= (a0_0 == 32'h0);
                        cycles0 <= cycles;
                    end
                end
                if (c1_retire_valid[lane]) begin
                    ret1 <= ret1 + 1;
                    if (c1_retire_rd_wen[lane] && (c1_retire_rd[lane] == 5'd10))
                        a0_1 <= c1_retire_wdata[lane];
                    if (c1_retire_is_ebreak[lane] && !done1) begin
                        done1 <= 1'b1;
                        pass1 <= (a0_1 == 32'h0);
                        cycles1 <= cycles;
                    end
                end
            end
        end
    end

    string dmem_file;
    initial begin
        checks = 0; errors = 0;
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 128'h0;
        if (!$value$plusargs("DMEM=%s", dmem_file)) begin
            $display("ERROR: +DMEM=<coremark dmem hex> is required");
            $finish;
        end
        $readmemh(dmem_file, mem);

        // hart1 data/stack = hart0 data region shifted by C1_OFFSET (1 MiB).
        // Source index 0x10000 (address 0x8010_0000); destination 0x20000.
        for (int i = 0; i < DATA_LINES; i++) mem[32'h0002_0000 + i] = mem[32'h0001_0000 + i];

        repeat (5) @(posedge clk);
        #1; rst = 1'b0;

        wait (done0 && done1);
        repeat (3) @(posedge clk); #1;

        check(done0 && pass0, "hart0 CoreMark a0=0");
        check(done1 && pass1, "hart1 CoreMark a0=0");
        check(ret0 > 0 && ret1 > 0, "both harts retired instructions");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - 2 harts + shared L2, two CoreMark instances", checks);
            $display("hart0: retires=%0d cycles=%0d IPC=%0.6f CM/MHz=%0.4f",
                     ret0, cycles0, real'(ret0) / real'(cycles0), 100.0e6 / real'(cycles0));
            $display("hart1: retires=%0d cycles=%0d IPC=%0.6f CM/MHz=%0.4f",
                     ret1, cycles1, real'(ret1) / real'(cycles1), 100.0e6 / real'(cycles1));
            $display("aggregate: retires=%0d max_cycles=%0d IPC=%0.6f CM/MHz=%0.4f",
                     ret0 + ret1, (cycles0 > cycles1) ? cycles0 : cycles1,
                     real'(ret0 + ret1) / real'((cycles0 > cycles1) ? cycles0 : cycles1),
                     200.0e6 / real'((cycles0 > cycles1) ? cycles0 : cycles1));
            $display("L2: hits=%0d misses=%0d", l2_hits, l2_misses);
        end else begin
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        end
        $finish;
    end

    initial begin
        #600000000;  // 600 ms: two shared-L2 CoreMark copies
        $display("*** TIMEOUT: done0=%0d done1=%0d a0_0=%h a0_1=%h cycles=%0d ret0=%0d ret1=%0d pc0=%h pc1=%h hits=%0d misses=%0d ***",
                 done0, done1, a0_0, a0_1, cycles, ret0, ret1,
                 c0_fetch_pc, c1_fetch_pc, l2_hits, l2_misses);
        $finish;
    end
endmodule
