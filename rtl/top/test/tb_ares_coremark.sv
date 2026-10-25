//=============================================================================
// ARES - real frontend + shared L2 CoreMark bring-up
//-----------------------------------------------------------------------------
// Loads a flat CoreMark image into the L2 backing memory (16 MiB), then runs
// the real rtl/frontend through the legacy adapter into ares_core_top.  The
// ICache AXI master uses the L2 I read port; the D side uses L2 core port 0.
//
// The image is supplied as a 128-bit-wide $readmemh file:
//   +DMEM=<path>
// where line i is the 16-byte word at byte address 0x8000_0000 + 16*i.
//=============================================================================
`timescale 1ns/1ps
module tb_ares_coremark;
    import ares_pkg::*;

    localparam int unsigned MEM_WORDS = 1 << 20;  // 16 MiB

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
    logic [31:0]  fe_fetch_pc;
    logic [1:0]   retire_valid, retire_rd_wen, retire_is_ebreak;
    logic [4:0]   retire_rd [2];
    logic [31:0]  retire_wdata [2];
    logic [31:0]  retire_pc [2];

    ares_frontend_l2_top #(
        .RESET_MTVEC(32'h8000_0000),
        .RESET_VEC(32'h8000_0000),
        .L2_SETS(128)
    ) dut (
        .clk(clk), .rst(rst),
        .l2_mem_rd_valid(l2_mem_rd_valid), .l2_mem_rd_ready(l2_mem_rd_ready),
        .l2_mem_rd_addr(l2_mem_rd_addr),
        .l2_mem_rsp_valid(l2_mem_rsp_valid), .l2_mem_rsp_ready(l2_mem_rsp_ready),
        .l2_mem_rsp_data(l2_mem_rsp_data),
        .l2_mem_wr_valid(l2_mem_wr_valid), .l2_mem_wr_ready(l2_mem_wr_ready),
        .l2_mem_wr_addr(l2_mem_wr_addr), .l2_mem_wr_data(l2_mem_wr_data),
        .l2_mem_wr_be(l2_mem_wr_be),
        .l2_idle(l2_idle), .l2_hit_count(l2_hits), .l2_miss_count(l2_misses),
        .fe_fetch_pc(fe_fetch_pc),
        .retire_valid(retire_valid), .retire_rd_wen(retire_rd_wen),
        .retire_rd(retire_rd), .retire_wdata(retire_wdata),
        .retire_pc(retire_pc),
        .retire_is_ebreak(retire_is_ebreak)
    );

    // Backing memory: one 128-bit beat, one-cycle response.
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

    // CoreMark exits via EBREAK in _trm_init; a0 is the return code.
    logic [31:0] a0;
    logic [31:0] a0_eff;
    logic        done, pass;
    int unsigned checks, errors;
    int unsigned ret_count;
    logic [63:0] cycle_count;

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
            a0 <= 32'h0;
            done <= 1'b0;
            pass <= 1'b0;
            ret_count <= 0;
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1'b1;
            // Two instructions may retire per cycle: counting one per cycle
            // undercounts the retire total (~1.5x here) and reports a wrong IPC.
            ret_count <= ret_count + unsigned'(retire_valid[0]) + unsigned'(retire_valid[1]);
            // a0 including a same-cycle lane-0 write, so an EBREAK in lane 1
            // compares against the architectural a0
            /* verilator lint_off BLKSEQ */
            a0_eff = a0;
            for (int lane = 0; lane < 2; lane++)
                if (retire_valid[lane] && retire_rd_wen[lane] && (retire_rd[lane] == 5'd10))
                    a0_eff = retire_wdata[lane];
            /* verilator lint_on BLKSEQ */
            for (int lane = 0; lane < 2; lane++) begin
                if (retire_valid[lane]) begin
                    if (retire_rd_wen[lane] && (retire_rd[lane] == 5'd10))
                        a0 <= retire_wdata[lane];
                    if (retire_is_ebreak[lane] && !done) begin
                        done <= 1'b1;
                        pass <= (a0_eff == 32'h0);
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

        repeat (5) @(posedge clk);
        #1; rst = 1'b0;

        wait (done);
        repeat (3) @(posedge clk); #1;

        check(done, "CoreMark reached EBREAK");
        check(pass, "CoreMark returned a0=0");
        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - ARES real FE + shared L2 CoreMark", checks);
            $display("CoreMark metrics: retires=%0d cycles=%0d IPC=%0.6f CoreMark/MHz=%0.4f time_ns=%0d hits=%0d misses=%0d pc=%h",
                     ret_count, cycle_count, real'(ret_count) / real'(cycle_count),
                     100.0e6 / real'(cycle_count), $time, l2_hits, l2_misses, fe_fetch_pc);
        end else
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        $finish;
    end

    initial begin
        #600000000;  // 600 ms: measured completion was ~499 ms
        $display("*** TIMEOUT: pc=%h done=%0d a0=%h hits=%0d misses=%0d retires=%0d ***",
                 fe_fetch_pc, done, a0, l2_hits, l2_misses, ret_count);
        $display("cycles=%0d", cycle_count);
        $display("FE: iq_occ=%0d ftq_occ=%0d icache_refill=%b icache_req_fire=%b",
                 dut.u_fe.iq_occupancy, dut.u_fe.ftq_occupancy,
                 dut.u_fe.icache_refill, dut.u_fe.icache_req_fire);
        $display("L2 I: rd_valid=%b rd_ready=%b rsp_valid=%b rsp_ready=%b bridge_state=%0d",
                 dut.l2_i_rd_valid, dut.l2_i_rd_ready,
                 dut.l2_i_rsp_valid, dut.l2_i_rsp_ready, dut.u_ibridge.state_q);
        $display("AXI: arvalid=%b arready=%b rvalid=%b rready=%b",
                 dut.ifu_axi.arvalid, dut.ifu_axi.arready,
                 dut.ifu_axi.rvalid, dut.ifu_axi.rready);
        $display("BE: occ=%0d free=%0d decerr=%b next=%h ser=%b drain=%b redir=%b",
                 dut.u_core.u_backend.dbg_occupancy,
                 dut.u_core.u_backend.free_count_w,
                 dut.u_core.u_backend.decode_err,
                 dut.u_core.u_backend.dbg_arch_next_pc,
                 dut.u_core.u_backend.serializing_present_w,
                 dut.u_core.u_backend.irq_drain_w,
                 dut.u_core.u_backend.redirect_any_w);
        $finish;
    end
endmodule
