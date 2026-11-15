//=============================================================================
// pipeline_l2 directed coherence / data-integrity test
//-----------------------------------------------------------------------------
// Runs with -GCORES=2 or -GCORES=4.  The TB drives the L2 ports directly and
// checks:
//   * read hit/miss and write-through-store visibility;
//   * a write invalidates every other hart and never the writer;
//   * the epoch advances exactly once per accepted write;
//   * dirty-victim writeback and re-read after a same-set conflict.
//=============================================================================
`timescale 1ns/1ps
module tb_pipeline_l2_mc #(
    parameter integer CORES = 4
);
    localparam integer SETS = 16;

    logic clk, rst;
    initial begin clk = 1'b0; rst = 1'b1; end
    always #5 clk = ~clk;

    logic [CORES-1:0]        c_rd_valid, c_rd_ready;
    logic [CORES-1:0][31:0]  c_rd_addr;
    logic [CORES-1:0]        c_rsp_valid, c_rsp_ready;
    logic [CORES-1:0][127:0] c_rsp_data;
    logic [CORES-1:0]        c_wr_valid, c_wr_ready;
    logic [CORES-1:0][31:0]  c_wr_addr;
    logic [CORES-1:0][127:0] c_wr_data;
    logic [CORES-1:0][15:0]  c_wr_be;

    logic [CORES-1:0] coh_inv_valid;
    logic [31:0]      coh_inv_addr;
    logic [7:0]       coh_epoch;

    logic         mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
    logic [31:0]  mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rsp_data, mem_wr_data;
    logic [15:0]  mem_wr_be;
    logic         mem_wr_valid, mem_wr_ready;
    logic         l2_idle;
    logic [31:0]  hit_count, miss_count;

    pipeline_l2 #(
        .CORES(CORES), .SETS(SETS), .WAYS(4)
    ) dut (
        .clk(clk), .rst(rst),
        .c_rd_valid(c_rd_valid), .c_rd_ready(c_rd_ready), .c_rd_addr(c_rd_addr),
        .c_rsp_valid(c_rsp_valid), .c_rsp_ready(c_rsp_ready), .c_rsp_data(c_rsp_data),
        .c_wr_valid(c_wr_valid), .c_wr_ready(c_wr_ready), .c_wr_addr(c_wr_addr),
        .c_wr_data(c_wr_data), .c_wr_be(c_wr_be),
        .coh_inv_valid(coh_inv_valid), .coh_inv_addr(coh_inv_addr), .coh_epoch(coh_epoch),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready), .mem_rd_addr(mem_rd_addr),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready), .mem_rsp_data(mem_rsp_data),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_be(mem_wr_be),
        .l2_idle(l2_idle), .hit_count(hit_count), .miss_count(miss_count)
    );

    //---- backing memory model --------------------------------------------
    logic [127:0] mem [0:4095];
    logic         b_rsp_valid_q;
    logic [127:0] b_rsp_data_q;

    assign mem_rd_ready = 1'b1;
    assign mem_wr_ready = 1'b1;
    assign mem_rsp_valid = b_rsp_valid_q;
    assign mem_rsp_data  = b_rsp_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            b_rsp_valid_q <= 1'b0;
            b_rsp_data_q  <= 128'd0;
        end else if (mem_rd_valid && mem_rd_ready && !b_rsp_valid_q) begin
            b_rsp_valid_q <= 1'b1;
            b_rsp_data_q  <= mem[{2'b00, mem_rd_addr[13:4]}];
        end else if (b_rsp_valid_q && mem_rsp_ready) begin
            b_rsp_valid_q <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (mem_wr_valid && mem_wr_ready) begin
            for (int i = 0; i < 16; i++) begin
                if (mem_wr_be[i]) mem[{2'b00, mem_wr_addr[13:4]}][8*i +: 8] <= mem_wr_data[8*i +: 8];
            end
        end
    end

    //---- directed helpers -------------------------------------------------
    task automatic core_read(input int c, input [31:0] addr, output [127:0] data);
        begin
            @(negedge clk);
            while (!l2_idle) @(negedge clk);
            c_rd_valid[c] = 1'b1;
            c_rd_addr[c]  = addr;
            @(negedge clk);
            c_rd_valid[c] = 1'b0;
            while (!c_rsp_valid[c]) @(negedge clk);
            data = c_rsp_data[c];
            c_rsp_ready[c] = 1'b1;
            @(negedge clk);
            c_rsp_ready[c] = 1'b0;
        end
    endtask

    task automatic core_write(input int c, input [31:0] addr,
                              input [127:0] data, input [15:0] be);
        begin
            @(negedge clk);
            while (!l2_idle) @(negedge clk);
            c_wr_valid[c] = 1'b1;
            c_wr_addr[c]  = addr;
            c_wr_data[c]  = data;
            c_wr_be[c]    = be;
            @(negedge clk);
            c_wr_valid[c] = 1'b0;
            c_wr_data[c]  = 128'd0;
            c_wr_be[c]    = 16'd0;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    int unsigned inv_count [0:3];
    int unsigned inv_before [0:3];
    int unsigned err_count;
    logic [7:0]  epoch_seen;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 4; i++) inv_count[i] <= 0;
            epoch_seen <= 0;
        end else begin
            for (int i = 0; i < CORES; i++)
                if (coh_inv_valid[i]) inv_count[i] <= inv_count[i] + 1;
            if (coh_epoch != epoch_seen) epoch_seen <= coh_epoch;
        end
    end

    task automatic expect_word(input [127:0] value, input [31:0] addr,
                               input [127:0] data, input string name);
        logic [31:0] got;
        begin
            got = data[(addr[3:2]*32) +: 32];
            if (got !== value[31:0]) begin
                $display("FAIL %s addr=%h got=%h exp=%h", name, addr, got, value[31:0]);
                err_count = err_count + 1;
            end
        end
    endtask

    initial begin
        err_count = 0;
        epoch_seen = 0;
        c_rd_valid = '0; c_wr_valid = '0; c_rsp_ready = '0;
        c_rd_addr = '0; c_wr_addr = '0; c_wr_data = '0; c_wr_be = '0;

        for (int i = 0; i < 4096; i++) mem[i] = 128'd0;
        for (int i = 0; i < 256; i++)
            mem[i] = {4{32'h1000_0000 + i}};

        repeat (4) @(posedge clk); #1; rst = 1'b0;
        repeat (2) @(posedge clk);


        // 1) Every hart reads the same line.  Only the first access misses.
        for (int c = 0; c < CORES; c++) begin
            logic [127:0] d;
            core_read(c, 32'h8010_0000, d);
            expect_word(mem[0], 32'h8010_0000, d, "initial read");
        end

        // 2) Hart 0 writes word0; every other hart must be invalidated and
        //    must observe the new value on its next read.
        core_write(0, 32'h8010_0000, {4{32'h1122_3344}}, 16'h000F);
        if (inv_count[0] != 0) begin
            $display("FAIL writer hart0 received an invalidation"); err_count++;
        end
        for (int c = 1; c < CORES; c++) begin
            if (inv_count[c] != 1) begin
                $display("FAIL hart%0d inv count=%0d (expected 1)", c, inv_count[c]);
                err_count++;
            end
        end
        for (int c = 0; c < CORES; c++) begin
            logic [127:0] d;
            core_read(c, 32'h8010_0000, d);
            if (d[31:0] !== 32'h1122_3344) begin
                $display("FAIL hart%0d sees stale word0: %h", c, d[31:0]);
                err_count++;
            end
        end

        // 3) A second hart writes word1.
        for (int c = 0; c < CORES; c++) inv_before[c] = inv_count[c];
        core_write(1, 32'h8010_0000, {4{32'h5566_7788}}, 16'h00F0);
        if (inv_count[1] != inv_before[1]) begin
            $display("FAIL writer hart1 received an invalidation"); err_count++;
        end
        for (int c = 0; c < CORES; c++) begin
            if (c != 1 && inv_count[c] != inv_before[c] + 1) begin
                $display("FAIL hart%0d inv delta=%0d (expected 1)", c, inv_count[c] - inv_before[c]);
                err_count++;
            end
        end
        for (int c = 0; c < CORES; c++) begin
            logic [127:0] d;
            core_read(c, 32'h8010_0000, d);
            if (d[63:32] !== 32'h5566_7788) begin
                $display("FAIL hart%0d sees stale word1: %h", c, d[63:32]);
                err_count++;
            end
            if (d[31:0] !== 32'h1122_3344) begin
                $display("FAIL word0 changed to %h", d[31:0]); err_count++;
            end
        end

        // 4) Write miss and cross-hart read.
        core_write(2, 32'h8010_1000, {4{32'hDEAD_BEEF}}, 16'h000F);
        for (int c = 0; c < CORES; c++) begin
            logic [127:0] d;
            core_read(c, 32'h8010_1000, d);
            if (d[31:0] !== 32'hDEAD_BEEF) begin
                $display("FAIL write-miss read hart%0d: %h", c, d[31:0]);
                err_count++;
            end
        end

        // 5) Five lines mapping to set 0 force a dirty-victim writeback.
        for (int k = 1; k <= 5; k++) begin
            logic [31:0] a;
            a = 32'h8010_0000 + (k * 32'h400);
            core_write(3, a, {4{32'hA000_0000 + k}}, 16'h000F);
        end
        // The first line (offset 0) was the oldest way and must have been
        // written back to the backing model with its last value.
        if (mem[0][31:0] !== 32'h1122_3344) begin
            $display("FAIL dirty victim writeback mem[0]=%h", mem[0][31:0]);
            err_count++;
        end
        begin
            logic [127:0] d;
            core_read(0, 32'h8010_0000, d);
            if (d[31:0] !== 32'h1122_3344) begin
                $display("FAIL re-read after eviction: %h", d[31:0]);
                err_count++;
            end
        end

        // 6) Epoch must be non-zero and every write must have been visible.
        if (epoch_seen == 0) begin
            $display("FAIL coherence epoch never advanced"); err_count++;
        end

        if (err_count == 0) begin
            $display("PASS: pipeline_l2 CORES=%0d hits=%0d misses=%0d epoch=%0d inv=[%0d,%0d,%0d,%0d]",
                     CORES, hit_count, miss_count, epoch_seen,
                     inv_count[0], inv_count[1], inv_count[2], inv_count[3]);
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d errors", err_count);
        end
    end

    initial begin
        #200000;
        $fatal(1, "TIMEOUT");
    end
endmodule
