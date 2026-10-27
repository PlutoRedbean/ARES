//=============================================================================
// ARES - two real frontends + shared L2, two AMP CoreMark instances
//-----------------------------------------------------------------------------
// Both harts execute the same code image; hart1's D-side is offset by
// C1_DATA_OFFSET so its data/stack live at 0x8020_0000.. while hart0 uses
// 0x8010_0000...  The backing image is duplicated at +1 MiB for hart1.
//
// Checked:
//   * both harts reach EBREAK with a0 = 0 (two independent CoreMark copies);
//   * per-hart retires/cycles/IPC and the aggregate CoreMark/MHz;
//   * hart1 stays inside its data window and hart0 never writes hart1's;
//   * an independent "L2 shadow" golden model: every I/D read response of both
//     harts and every dirty writeback beat must equal the shadow memory.
//
// +DMEM=<128-bit-wide coremark image>  (same format as tb_ares_coremark)
// +H1EN=0   hold hart1 in reset; hart0 then runs alone and the run stops when
//           hart0 finishes (same binary, used for single-hart reference runs)
//=============================================================================
`timescale 1ns/1ps
module tb_2core_coremark;
    import ares_pkg::*;

    localparam int unsigned MEM_WORDS = 1 << 20;  // 16 MiB
    localparam int unsigned DATA_LINES = 16'h4000;  // 0x8010_0000..0x8013_ffff
    localparam logic [31:0] C1_OFFSET  = 32'h0010_0000;

    logic clk, rst;
    logic hart1_en;
    initial begin clk = 1'b0; rst = 1'b1; hart1_en = 1'b1; end
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
        .clk(clk), .rst(rst), .hart1_en(hart1_en),
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

    //-------------------------------------------------------------------------
    // L2 response shadow checker
    //-----------------------------------------------------------------------------
    // An independent golden model of the shared memory as seen at the L2 ports.
    // Every read response (I and D of both harts) must equal the shadow, and
    // every writeback beat must equal the shadow as well (a mismatch there means
    // a dirty L2 line held the wrong data, which silently corrupts memory).
    // Stores accepted at the L2 core ports update the shadow with their byte
    // enables, exactly as the L2 write path does.
    //-------------------------------------------------------------------------
    localparam int unsigned MEM_BYTES = MEM_WORDS * 16;
    logic [7:0]   shadow [0:MEM_BYTES-1];
    // +SHADOW_FAULT=1 corrupts exactly one expected byte.  The error counters
    // are cumulative, so a single wrong response must stay fatal even though
    // every later response matches (A1 item 6, "errors do not disappear").
    logic         shadow_fault_en;
    logic         shadow_fault_used;
    logic [31:0]  pend_i0, pend_i1, pend_c0, pend_c1;
    logic         pend_i0_v, pend_i1_v, pend_c0_v, pend_c1_v;
    int unsigned  err_i0, err_i1, err_c0, err_c1, err_wb;
    int unsigned  chk_rsp_total;

    task automatic shadow_wr(input logic [31:0] addr, input logic [127:0] data,
                             input logic [15:0] be);
        for (int i = 0; i < 16; i++)
            if (be[i]) shadow[{addr[23:4], 4'b0000} + i] = data[8*i +: 8];
    endtask

    task automatic chk_data(input string who, input logic [31:0] base,
                            input logic [127:0] data, inout int unsigned errs);
        logic [7:0] exp;
        for (int i = 0; i < 16; i++) begin
            exp = shadow[{base[23:4], 4'b0000} + i];
            if (shadow_fault_en && !shadow_fault_used) begin
                exp = ~exp;               // one deliberate corruption
                shadow_fault_used = 1'b1;
            end
            if (data[8*i +: 8] !== exp) begin
                errs = errs + 1;
                if (errs < 4)
                    $display("[%0t] %s MISMATCH addr=%h byte%0d got=%h exp=%h",
                             $time, who, {base[23:4], 4'b0000}, i, data[8*i +: 8], exp);
                return;
            end
        end
    endtask

    always @(posedge clk) begin
        /* verilator lint_off BLKSEQ */
        if (rst) begin
            pend_i0_v <= 1'b0; pend_i1_v <= 1'b0;
            pend_c0_v <= 1'b0; pend_c1_v <= 1'b0;
            pend_i0 <= '0; pend_i1 <= '0; pend_c0 <= '0; pend_c1 <= '0;
        end else begin
            //--- stores accepted at the L2 core ports (write path) -----------
            if (dut.c0_wr_valid && dut.c0_wr_ready)
                shadow_wr(dut.c0_wr_addr, dut.c0_wr_data, dut.c0_wr_be);
            if (dut.c1_wr_valid && dut.c1_wr_ready)
                shadow_wr(dut.c1_wr_addr, dut.c1_wr_data, dut.c1_wr_be);

            //--- writeback beats must reproduce the shadow -------------------
            if (l2_mem_wr_valid && l2_mem_wr_ready) begin
                for (int i = 0; i < 16; i++)
                    if (l2_mem_wr_data[8*i +: 8] !== shadow[{l2_mem_wr_addr[23:4], 4'b0000} + i]) begin
                        err_wb = err_wb + 1;
                        if (err_wb < 6)
                            $display("[%0t] WB MISMATCH addr=%h byte%0d got=%h exp=%h",
                                     $time, {l2_mem_wr_addr[23:4], 4'b0000}, i,
                                     l2_mem_wr_data[8*i +: 8],
                                     shadow[{l2_mem_wr_addr[23:4], 4'b0000} + i]);
                        break;
                    end
            end

            //--- outstanding request beats ----------------------------------
            if (dut.c0_i_rd_valid && dut.c0_i_rd_ready) begin
                pend_i0 <= {dut.c0_i_rd_addr[23:4], 4'b0000}; pend_i0_v <= 1'b1;
            end
            if (dut.c1_i_rd_valid && dut.c1_i_rd_ready) begin
                pend_i1 <= {dut.c1_i_rd_addr[23:4], 4'b0000}; pend_i1_v <= 1'b1;
            end
            if (dut.c0_rd_valid && dut.c0_rd_ready) begin
                pend_c0 <= {dut.c0_rd_addr[23:4], 4'b0000}; pend_c0_v <= 1'b1;
            end
            if (dut.c1_rd_valid && dut.c1_rd_ready) begin
                pend_c1 <= {dut.c1_rd_addr[23:4], 4'b0000}; pend_c1_v <= 1'b1;
            end

            //--- read responses --------------------------------------------
            if (dut.c0_i_rsp_valid && dut.c0_i_rsp_ready) begin
                chk_rsp_total = chk_rsp_total + 1;
                if (!pend_i0_v) begin
                    err_i0 = err_i0 + 1;
                    if (err_i0 < 4) $display("[%0t] I0 RSP without request", $time);
                end else chk_data("I0", pend_i0, dut.c0_i_rsp_data, err_i0);
                pend_i0_v <= 1'b0;
            end
            if (dut.c1_i_rsp_valid && dut.c1_i_rsp_ready) begin
                chk_rsp_total = chk_rsp_total + 1;
                if (!pend_i1_v) begin
                    err_i1 = err_i1 + 1;
                    if (err_i1 < 4) $display("[%0t] I1 RSP without request", $time);
                end else chk_data("I1", pend_i1, dut.c1_i_rsp_data, err_i1);
                pend_i1_v <= 1'b0;
            end
            if (dut.c0_rsp_valid && dut.c0_rsp_ready) begin
                chk_rsp_total = chk_rsp_total + 1;
                if (!pend_c0_v) begin
                    err_c0 = err_c0 + 1;
                    if (err_c0 < 4) $display("[%0t] C0 RSP without request", $time);
                end else chk_data("C0", pend_c0, dut.c0_rsp_data, err_c0);
                pend_c0_v <= 1'b0;
            end
            if (dut.c1_rsp_valid && dut.c1_rsp_ready) begin
                chk_rsp_total = chk_rsp_total + 1;
                if (!pend_c1_v) begin
                    err_c1 = err_c1 + 1;
                    if (err_c1 < 4) $display("[%0t] C1 RSP without request", $time);
                end else chk_data("C1", pend_c1, dut.c1_rsp_data, err_c1);
                pend_c1_v <= 1'b0;
            end
        end
        /* verilator lint_on BLKSEQ */
    end

    logic [31:0] a0_0, a0_1;
    logic [31:0] a0_0_eff, a0_1_eff;
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
            if (!done0) begin
                ret0 <= ret0 + unsigned'(c0_retire_valid[0])
                      + unsigned'(c0_retire_valid[1] && !(c0_retire_valid[0] && c0_retire_is_ebreak[0]));
                /* verilator lint_off BLKSEQ */
                a0_0_eff = a0_0;
                for (int lane = 0; lane < 2; lane++) begin
                    if (c0_retire_valid[lane]) begin
                        if (c0_retire_rd_wen[lane] && (c0_retire_rd[lane] == 5'd10)) begin
                            a0_0_eff = c0_retire_wdata[lane];
                            a0_0 <= c0_retire_wdata[lane];
                        end
                        if (c0_retire_is_ebreak[lane]) begin
                            done0 <= 1'b1;
                            pass0 <= (a0_0_eff == 32'h0);
                            cycles0 <= cycles + 1'b1;
                            break;
                        end
                    end
                end
                /* verilator lint_on BLKSEQ */
            end
            if (!done1) begin
                ret1 <= ret1 + unsigned'(c1_retire_valid[0])
                      + unsigned'(c1_retire_valid[1] && !(c1_retire_valid[0] && c1_retire_is_ebreak[0]));
                /* verilator lint_off BLKSEQ */
                a0_1_eff = a0_1;
                for (int lane = 0; lane < 2; lane++) begin
                    if (c1_retire_valid[lane]) begin
                        if (c1_retire_rd_wen[lane] && (c1_retire_rd[lane] == 5'd10)) begin
                            a0_1_eff = c1_retire_wdata[lane];
                            a0_1 <= c1_retire_wdata[lane];
                        end
                        if (c1_retire_is_ebreak[lane]) begin
                            done1 <= 1'b1;
                            pass1 <= (a0_1_eff == 32'h0);
                            cycles1 <= cycles + 1'b1;
                            break;
                        end
                    end
                end
                /* verilator lint_on BLKSEQ */
            end
        end
    end

    string dmem_file;
    initial begin
        checks = 0; errors = 0;
        shadow_fault_en = $test$plusargs("SHADOW_FAULT");
        shadow_fault_used = 1'b0;
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 128'h0;
        if (!$value$plusargs("DMEM=%s", dmem_file))
            $fatal(1, "+DMEM=<coremark dmem hex> is required");
        begin
            int image_fd;
            image_fd = $fopen(dmem_file, "r");
            if (image_fd == 0) $fatal(1, "Cannot open DMEM image: %s", dmem_file);
            $fclose(image_fd);
        end
        $readmemh(dmem_file, mem);

        // hart1 data/stack = hart0 data region shifted by C1_OFFSET (1 MiB).
        // Source index 0x10000 (address 0x8010_0000); destination 0x20000.
        for (int i = 0; i < DATA_LINES; i++) mem[32'h0002_0000 + i] = mem[32'h0001_0000 + i];

        // Golden shadow = the initial memory image.
        for (int i = 0; i < MEM_WORDS; i++)
            for (int b = 0; b < 16; b++)
                shadow[(i*16) + b] = mem[i][8*b +: 8];
        err_i0 = 0; err_i1 = 0; err_c0 = 0; err_c1 = 0; err_wb = 0; chk_rsp_total = 0;

        begin
            int h1;
            if (!$value$plusargs("H1EN=%d", h1)) h1 = 1;
            hart1_en = (h1 != 0);
        end

        repeat (5) @(posedge clk);
        #1; rst = 1'b0;

        // With hart1 held in reset the run ends when hart0 finishes (used to
        // produce a hart0-only reference stream with the same binary).
        wait (done0 && (done1 || !hart1_en));
        repeat (3) @(posedge clk); #1;

        $display("L2 shadow check: rsp=%0d err_i0=%0d err_i1=%0d err_c0=%0d err_c1=%0d err_wb=%0d",
                 chk_rsp_total, err_i0, err_i1, err_c0, err_c1, err_wb);
        check(done0 && pass0, "hart0 CoreMark a0=0");
        if (hart1_en) begin
            check(done1 && pass1, "hart1 CoreMark a0=0");
            check(ret0 > 0 && ret1 > 0, "both harts retired instructions");
        end
        check(bad_h1_rd == 0 && bad_h1_wr == 0 && bad_h0_wr == 0, "AMP private data windows");
        check(err_i0 == 0, "I0 read responses match memory");
        check(err_i1 == 0, "I1 read responses match memory");
        check(err_c0 == 0, "C0 read responses match memory");
        check(err_c1 == 0, "C1 read responses match memory");
        check(err_wb == 0, "L2 dirty writebacks match memory");

        // Optional completion-cycle bound (A1 item 6); default runs unchanged.
        begin
            longint unsigned max_cycles;
            if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
                if (max_cycles == 0) $fatal(1, "MAX_CYCLES must be positive");
                check(done0 && (cycles0 <= max_cycles) &&
                      (!hart1_en || (done1 && (cycles1 <= max_cycles))),
                      $sformatf("completion within MAX_CYCLES=%0d (hart0=%0d hart1=%0d)",
                                max_cycles, cycles0, cycles1));
            end
        end

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - 2 harts + shared L2, two CoreMark instances", checks);
            $display("hart0: retires=%0d cycles=%0d IPC=%0.6f CM/MHz=%0.4f",
                     ret0, cycles0, real'(ret0) / real'(cycles0), 100.0e6 / real'(cycles0));
            $display("hart1: retires=%0d cycles=%0d IPC=%0.6f CM/MHz=%0.4f",
                     ret1, cycles1, real'(ret1) / real'(cycles1), 100.0e6 / real'(cycles1));
            $display("aggregate: retires=%0d max_cycles=%0d IPC=%0.6f CM/MHz=%0.4f",
                     ret0 + ret1, (cycles0 > cycles1) ? cycles0 : cycles1,
                     real'(ret0 + ret1) / real'((cycles0 > cycles1) ? cycles0 : cycles1),
                     (hart1_en ? 200.0e6 : 100.0e6) / real'((cycles0 > cycles1) ? cycles0 : cycles1));
            $display("L2: hits=%0d misses=%0d", l2_hits, l2_misses);
        end else begin
            $fatal(1, "CoreMark failed: %0d errors / %0d checks", errors, checks);
        end
        $finish;
    end

    initial begin
        int timeout_ns;
        if (!$value$plusargs("TIMEOUT_NS=%d", timeout_ns)) timeout_ns = 600000000;
        if (timeout_ns <= 0) $fatal(1, "TIMEOUT_NS must be positive");
        // Runtime input is checked above; a zero-delay scheduling mode is unnecessary.
        /* verilator lint_off ZERODLY */
        #(timeout_ns);
        /* verilator lint_on ZERODLY */  // 600 ms: two shared-L2 CoreMark copies
        $display("*** TIMEOUT: done0=%0d done1=%0d a0_0=%h a0_1=%h cycles=%0d ret0=%0d ret1=%0d pc0=%h pc1=%h hits=%0d misses=%0d ***",
                 done0, done1, a0_0, a0_1, cycles, ret0, ret1,
                 c0_fetch_pc, c1_fetch_pc, l2_hits, l2_misses);
        $fatal(1, "CoreMark timeout");
    end
endmodule
