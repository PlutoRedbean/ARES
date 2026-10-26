// Merge gate: native C5 frontend(s), private L1D and shared L2.
// Exercises fetch/refill, per-hart CSR, private AMP data and branch recovery.
`timescale 1ns/1ps
module tb_frontend_l2 #(
    parameter bit DUAL = 1'b1
);
    logic clk, rst;
    initial begin clk = 0; rst = 1; end
    always #5 clk = ~clk;
    logic rd_valid, rd_ready, rsp_valid, rsp_ready, wr_valid, wr_ready;
    /* verilator lint_off UNUSEDSIGNAL */ // memory model uses the 4 MiB test window
    logic [31:0] rd_addr, wr_addr;
    logic [31:0] pc [2], retire_pc [2][2];
    logic idle;
    logic [31:0] hits, misses;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [127:0] rsp_data, wr_data;
    logic [15:0] wr_be;
    logic [1:0] retire_valid [2], rd_wen [2], is_ebreak [2];
    logic [4:0] rd [2][2];
    logic [31:0] wdata [2][2];

    generate if (DUAL) begin : g_dual
        ares_2core_frontend_l2_top #(.L2_SETS(4)) dut (
            .clk(clk), .rst(rst), .hart1_en(1'b1),
            .l2_mem_rd_valid(rd_valid), .l2_mem_rd_ready(rd_ready), .l2_mem_rd_addr(rd_addr),
            .l2_mem_rsp_valid(rsp_valid), .l2_mem_rsp_ready(rsp_ready), .l2_mem_rsp_data(rsp_data),
            .l2_mem_wr_valid(wr_valid), .l2_mem_wr_ready(wr_ready), .l2_mem_wr_addr(wr_addr),
            .l2_mem_wr_data(wr_data), .l2_mem_wr_be(wr_be),
            .c0_fetch_pc(pc[0]), .c0_retire_valid(retire_valid[0]), .c0_retire_rd_wen(rd_wen[0]),
            .c0_retire_rd(rd[0]), .c0_retire_wdata(wdata[0]), .c0_retire_pc(retire_pc[0]),
            .c0_retire_is_ebreak(is_ebreak[0]),
            .c1_fetch_pc(pc[1]), .c1_retire_valid(retire_valid[1]), .c1_retire_rd_wen(rd_wen[1]),
            .c1_retire_rd(rd[1]), .c1_retire_wdata(wdata[1]), .c1_retire_pc(retire_pc[1]),
            .c1_retire_is_ebreak(is_ebreak[1]),
            .l2_idle(idle), .l2_hit_count(hits), .l2_miss_count(misses)
        );
    end else begin : g_single
        ares_frontend_l2_top #(.L2_SETS(4)) dut (
            .clk(clk), .rst(rst),
            .l2_mem_rd_valid(rd_valid), .l2_mem_rd_ready(rd_ready), .l2_mem_rd_addr(rd_addr),
            .l2_mem_rsp_valid(rsp_valid), .l2_mem_rsp_ready(rsp_ready), .l2_mem_rsp_data(rsp_data),
            .l2_mem_wr_valid(wr_valid), .l2_mem_wr_ready(wr_ready), .l2_mem_wr_addr(wr_addr),
            .l2_mem_wr_data(wr_data), .l2_mem_wr_be(wr_be),
            .fe_fetch_pc(pc[0]), .retire_valid(retire_valid[0]), .retire_rd_wen(rd_wen[0]),
            .retire_rd(rd[0]), .retire_wdata(wdata[0]), .retire_pc(retire_pc[0]),
            .retire_is_ebreak(is_ebreak[0]),
            .l2_idle(idle), .l2_hit_count(hits), .l2_miss_count(misses)
        );
        assign pc[1] = 0;
        assign retire_valid[1] = 0;
        assign rd_wen[1] = 0;
        assign rd[1] = '{default:'0};
        assign wdata[1] = '{default:'0};
        assign retire_pc[1] = '{default:'0};
        assign is_ebreak[1] = 0;
    end endgenerate

    logic [127:0] memory [1<<18];
    logic response_q;
    logic [127:0] data_q;
    assign rd_ready = !response_q;
    assign wr_ready = 1'b1;
    assign rsp_valid = response_q;
    assign rsp_data = data_q;
    always_ff @(posedge clk) begin
        if (rst) begin response_q <= 0; data_q <= 0; end
        else begin
            if (rd_valid && rd_ready) begin
                response_q <= 1;
                data_q <= memory[rd_addr[21:4]];
            end else if (response_q && rsp_ready) response_q <= 0;
            if (wr_valid && wr_ready)
                for (int b=0; b<16; b++)
                    if (wr_be[b]) memory[wr_addr[21:4]][8*b +: 8] <= wr_data[8*b +: 8];
        end
    end

    // Two private values derived from mhartid; a branch loop trains/replays BPU state.
    logic [31:0] program_words [16];
    initial begin
        foreach (memory[i]) memory[i] = 0;
        program_words = '{32'h801000b7, 32'hf14022f3, 32'h12328113, 32'h0020a023,
                          32'h0000a183, 32'h00311e63, 32'h00800213, 32'hfff20213,
                          32'hfe021ee3, 32'h00000513, 32'h00100073, 32'h0000006f,
                          32'h00100513, 32'h00100073, 32'h0000006f, 32'h00000013};
        for (int i=0; i<4; i++)
            memory[i] = {program_words[4*i+3], program_words[4*i+2],
                         program_words[4*i+1], program_words[4*i]};
        repeat (6) @(posedge clk);
        #1; rst = 0;
    end

    bit done [2], saw_load [2], saw_hartid [2];
    logic [31:0] a0 [2];
    int retired [2];
    always @(posedge clk) if (!rst) begin
        for (int h=0; h<(DUAL ? 2 : 1); h++) begin
            for (int lane=0; lane<2; lane++) if (retire_valid[h][lane] && !done[h]) begin
                retired[h]++;
                if (rd_wen[h][lane]) begin
                    case (rd[h][lane])
                        5: begin
                            if (wdata[h][lane] != 32'(h)) $fatal(1,"mhartid mismatch hart%0d",h);
                            saw_hartid[h] = 1;
                        end
                        3: begin
                            if (wdata[h][lane] != 32'h123+32'(h)) $fatal(1,"AMP data mismatch hart%0d",h);
                            saw_load[h] = 1;
                        end
                        10: a0[h] = wdata[h][lane];
                        default: ;
                    endcase
                end
                if (is_ebreak[h][lane]) begin
                    if (a0[h] != 0 || !saw_load[h] || !saw_hartid[h])
                        $fatal(1,"hart%0d failed before completion",h);
                    done[h] = 1;
                end
            end
        end
        if (done[0] && (!DUAL || done[1])) begin
            $display("ALL TESTS PASSED: native C5/L2 DUAL=%0b, retires=%0d/%0d",DUAL,retired[0],retired[1]);
            $finish;
        end
    end
    initial begin #1000000; $fatal(1,"native C5/L2 boot timeout pc=%h/%h",pc[0],pc[1]); end
endmodule
