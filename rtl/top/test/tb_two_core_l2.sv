//=============================================================================
// ARES - two-hart shared-L2 bring-up test
//-----------------------------------------------------------------------------
// Two ares_core_top instances (HART_ID 0/1) share one l2_top.  The two FE
// models run tiny programs that load a preloaded word from the shared L2
// backing memory and check it; both cores must retire EBREAK with a0=0.
//
// This verifies the structural 2-core + shared-L2 data path.  It is not a
// CoreMark multithread run: the real 2-core SoC still needs the FE integration,
// CLINT/PLIC/Mailbox and the software SMP/AMP port.
//=============================================================================
`timescale 1ns/1ps
module tb_two_core_l2;
    import ares_pkg::*;
    import fe_pkg::*;

    localparam int unsigned IMEM_WORDS = 64;
    localparam int unsigned MEM_WORDS  = 1 << 16;
    localparam logic [31:0] TB_RESET_PC = ares_pkg::RESET_PC;

    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
    end
    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // FE contracts
    //-------------------------------------------------------------------------
    logic [1:0] c0_iq_valid, c0_iq_accept_count;
    iq_entry_t c0_iq_inst [2];
    /* verilator lint_off UNUSEDSIGNAL */  // FE observation only
    logic c0_redirect_valid, c0_redirect_taken;
    logic [31:0] c0_redirect_pc, c0_redirect_count;
    fe_redirect_kind_t c0_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] c0_redirect_ghr;
    logic c0_fence_i;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] c0_fetch_pc;
    logic [1:0] c0_bpu_credit, c0_bpu_valid;
    bpu_update_t c0_bpu_update [2];

    logic [1:0] c1_iq_valid, c1_iq_accept_count;
    iq_entry_t c1_iq_inst [2];
    /* verilator lint_off UNUSEDSIGNAL */  // FE observation only
    logic c1_redirect_valid, c1_redirect_taken;
    logic [31:0] c1_redirect_pc, c1_redirect_count;
    fe_redirect_kind_t c1_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] c1_redirect_ghr;
    logic c1_fence_i;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] c1_fetch_pc;
    logic [1:0] c1_bpu_credit, c1_bpu_valid;
    bpu_update_t c1_bpu_update [2];

    logic [31:0] imem_c0 [IMEM_WORDS];
    logic [31:0] imem_c1 [IMEM_WORDS];

    fe_model #(.RESET_PC(TB_RESET_PC), .IMEM_WORDS(IMEM_WORDS)) u_fe0 (
        .clk(clk), .rst(rst),
        .iq_valid(c0_iq_valid), .iq_inst(c0_iq_inst), .iq_accept_count(c0_iq_accept_count),
        .backend_redirect_valid(c0_redirect_valid), .backend_redirect_pc(c0_redirect_pc),
        .bpu_update_credit(c0_bpu_credit), .bpu_update_valid(c0_bpu_valid), .bpu_update(c0_bpu_update),
        .imem(imem_c0), .fetch_pc(c0_fetch_pc), .redirect_count(c0_redirect_count)
    );

    fe_model #(.RESET_PC(TB_RESET_PC), .IMEM_WORDS(IMEM_WORDS)) u_fe1 (
        .clk(clk), .rst(rst),
        .iq_valid(c1_iq_valid), .iq_inst(c1_iq_inst), .iq_accept_count(c1_iq_accept_count),
        .backend_redirect_valid(c1_redirect_valid), .backend_redirect_pc(c1_redirect_pc),
        .bpu_update_credit(c1_bpu_credit), .bpu_update_valid(c1_bpu_valid), .bpu_update(c1_bpu_update),
        .imem(imem_c1), .fetch_pc(c1_fetch_pc), .redirect_count(c1_redirect_count)
    );

    //-------------------------------------------------------------------------
    // Shared L2 memory port
    //-------------------------------------------------------------------------
    logic         l2_mem_rd_valid, l2_mem_rd_ready, l2_mem_rsp_valid, l2_mem_rsp_ready;
    /* verilator lint_off UNUSEDSIGNAL */  // memory model only uses [19:4]
    logic [31:0]  l2_mem_rd_addr, l2_mem_wr_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [127:0] l2_mem_rsp_data, l2_mem_wr_data;
    logic [15:0]  l2_mem_wr_be;
    logic         l2_mem_wr_valid, l2_mem_wr_ready;
    logic         l2_idle;
    logic [31:0]  l2_hits, l2_misses;

    logic [1:0] c0_retire_valid, c0_retire_rd_wen, c0_retire_is_ebreak;
    logic [31:0] c0_retire_wdata [2];
    logic [4:0] c0_retire_rd [2];
    logic [1:0] c1_retire_valid, c1_retire_rd_wen, c1_retire_is_ebreak;
    logic [31:0] c1_retire_wdata [2];
    logic [4:0] c1_retire_rd [2];

    ares_2core_l2_top #(
        .RESET_MTVEC(TB_RESET_PC),
        .L2_SETS(16)
    ) dut (
        .clk(clk), .rst(rst),
        .c0_iq_valid(c0_iq_valid), .c0_iq_inst(c0_iq_inst), .c0_iq_accept_count(c0_iq_accept_count),
        .c0_backend_redirect_valid(c0_redirect_valid), .c0_backend_redirect_pc(c0_redirect_pc),
        .c0_backend_redirect_kind(c0_redirect_kind), .c0_backend_redirect_ghr_before(c0_redirect_ghr),
        .c0_backend_redirect_actual_taken(c0_redirect_taken),
        .c0_bpu_update_credit(c0_bpu_credit), .c0_bpu_update_valid(c0_bpu_valid), .c0_bpu_update(c0_bpu_update),
        .c0_timer_irq(1'b0), .c0_software_irq(1'b0), .c0_external_irq(1'b0), .c0_fence_i_valid(c0_fence_i),
        .c1_iq_valid(c1_iq_valid), .c1_iq_inst(c1_iq_inst), .c1_iq_accept_count(c1_iq_accept_count),
        .c1_backend_redirect_valid(c1_redirect_valid), .c1_backend_redirect_pc(c1_redirect_pc),
        .c1_backend_redirect_kind(c1_redirect_kind), .c1_backend_redirect_ghr_before(c1_redirect_ghr),
        .c1_backend_redirect_actual_taken(c1_redirect_taken),
        .c1_bpu_update_credit(c1_bpu_credit), .c1_bpu_update_valid(c1_bpu_valid), .c1_bpu_update(c1_bpu_update),
        .c1_timer_irq(1'b0), .c1_software_irq(1'b0), .c1_external_irq(1'b0), .c1_fence_i_valid(c1_fence_i),
        .l2_mem_rd_valid(l2_mem_rd_valid), .l2_mem_rd_ready(l2_mem_rd_ready), .l2_mem_rd_addr(l2_mem_rd_addr),
        .l2_mem_rsp_valid(l2_mem_rsp_valid), .l2_mem_rsp_ready(l2_mem_rsp_ready), .l2_mem_rsp_data(l2_mem_rsp_data),
        .l2_mem_wr_valid(l2_mem_wr_valid), .l2_mem_wr_ready(l2_mem_wr_ready), .l2_mem_wr_addr(l2_mem_wr_addr),
        .l2_mem_wr_data(l2_mem_wr_data), .l2_mem_wr_be(l2_mem_wr_be),
        .l2_idle(l2_idle), .l2_hit_count(l2_hits), .l2_miss_count(l2_misses),
        .c0_retire_valid(c0_retire_valid), .c0_retire_rd_wen(c0_retire_rd_wen),
        .c0_retire_rd(c0_retire_rd), .c0_retire_wdata(c0_retire_wdata),
        .c0_retire_is_ebreak(c0_retire_is_ebreak),
        .c1_retire_valid(c1_retire_valid), .c1_retire_rd_wen(c1_retire_rd_wen),
        .c1_retire_rd(c1_retire_rd), .c1_retire_wdata(c1_retire_wdata),
        .c1_retire_is_ebreak(c1_retire_is_ebreak)
    );

    //-------------------------------------------------------------------------
    // Backing memory
    //-------------------------------------------------------------------------
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
                mem_rsp_data_q  <= mem[l2_mem_rd_addr[19:4]];
            end else if (mem_rsp_valid_q && l2_mem_rsp_ready) begin
                mem_rsp_valid_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (l2_mem_wr_valid && l2_mem_wr_ready) begin
            for (int i = 0; i < 16; i++)
                if (l2_mem_wr_be[i]) mem[l2_mem_wr_addr[19:4]][8*i +: 8] <= l2_mem_wr_data[8*i +: 8];
        end
    end

    //-------------------------------------------------------------------------
    // Retire / EBREAK tracking
    //-------------------------------------------------------------------------
    logic [31:0] a0_c0, a0_c1;
    logic        done_c0, done_c1, pass_c0, pass_c1;
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
            a0_c0 <= 32'h0;
            a0_c1 <= 32'h0;
            done_c0 <= 1'b0;
            done_c1 <= 1'b0;
            pass_c0 <= 1'b0;
            pass_c1 <= 1'b0;
        end else begin
            for (int lane = 0; lane < 2; lane++) begin
                if (c0_retire_valid[lane]) begin
                    if (c0_retire_rd_wen[lane] && (c0_retire_rd[lane] == 5'd10))
                        a0_c0 <= c0_retire_wdata[lane];
                    if (c0_retire_is_ebreak[lane] && !done_c0) begin
                        done_c0 <= 1'b1;
                        pass_c0 <= (a0_c0 == 32'h0);
                    end
                end
                if (c1_retire_valid[lane]) begin
                    if (c1_retire_rd_wen[lane] && (c1_retire_rd[lane] == 5'd10))
                        a0_c1 <= c1_retire_wdata[lane];
                    if (c1_retire_is_ebreak[lane] && !done_c1) begin
                        done_c1 <= 1'b1;
                        pass_c1 <= (a0_c1 == 32'h0);
                    end
                end
            end
        end
    end

    initial begin
        for (int i = 0; i < IMEM_WORDS; i++) begin
            imem_c0[i] = 32'h0000_0013;
            imem_c1[i] = 32'h0000_0013;
        end
        imem_c0[0] = 32'h000012b7;
        imem_c0[1] = 32'h0002a303;
        imem_c0[2] = 32'h123453b7;
        imem_c0[3] = 32'h67838393;
        imem_c0[4] = 32'h00731663;
        imem_c0[5] = 32'h00000513;
        imem_c0[6] = 32'h00100073;
        imem_c0[7] = 32'h00100513;
        imem_c0[8] = 32'h00100073;
        imem_c1[0] = 32'h000022b7;
        imem_c1[1] = 32'h0002a303;
        imem_c1[2] = 32'h9abce3b7;
        imem_c1[3] = 32'hef038393;
        imem_c1[4] = 32'h00731663;
        imem_c1[5] = 32'h00000513;
        imem_c1[6] = 32'h00100073;
        imem_c1[7] = 32'h00100513;
        imem_c1[8] = 32'h00100073;
        for (int i = 0; i < MEM_WORDS; i++) mem[i] = 128'h0;
        mem[32'h0000_1000 >> 4] = 128'h00000000000000000000000012345678;
        mem[32'h0000_2000 >> 4] = 128'h0000000000000000000000009ABCDEF0;

        checks = 0; errors = 0;
        repeat (4) @(posedge clk);
        #1;
        rst = 1'b0;

        wait (done_c0 && done_c1);
        repeat (5) @(posedge clk);
        #1;

        check(done_c0 && pass_c0, "core0 program passed");
        check(done_c1 && pass_c1, "core1 program passed");
        check(l2_hits != 0 && l2_misses != 0, "shared L2 serviced both cores");
        check(l2_idle, "L2 idle after both programs");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - two harts + shared L2 (hits=%0d misses=%0d)", checks, l2_hits, l2_misses);
        end else begin
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        end
        $finish;
    end

    initial begin
        #500000;
        $display("*** TIMEOUT: c0_done=%0d c1_done=%0d pc0=%h pc1=%h hits=%0d misses=%0d ***",
                 done_c0, done_c1, c0_fetch_pc, c1_fetch_pc, l2_hits, l2_misses);
        $finish;
    end


endmodule
