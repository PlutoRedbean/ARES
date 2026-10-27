//=============================================================================
// ARES - shared L2 reference-model test
//-----------------------------------------------------------------------------
// Directed sequences run against l2_top with an independent checker
// (l2_ref_model) that owns the backing memory and the golden image:
//
//   * cross-port visibility and role swap (c0 <-> c1)
//   * clean refill, write-allocate with byte-enable merge
//   * six tags in one set: dirty writebacks and wrap-around replacement
//   * partial / sparse byte enables and 64 B lines assembled beat by beat
//   * response-receive stalls (payload must stay stable)
//   * memory-side read/write stalls and extra read latency (inside the model)
//   * cold reset in the middle of a refill: no residual response afterwards
//   * final drain (four fresh tags per set) plus a sweep of every touched
//     line, which proves that dirty data really reached the backing memory
//
// The checker accepts any victim way: it verifies victim data and set, not the
// replacement order (decision D-A3).
//=============================================================================
`timescale 1ns/1ps
module tb_l2_ref;
    import l2_pkg::*;

    localparam int unsigned SETS  = 16;
    localparam int unsigned WAYS  = 4;
    localparam logic [31:0] BASE  = 32'h8000_0000;
    localparam int unsigned BYTES = 1 << 20;

    logic clk, rst;
    initial begin clk = 1'b0; rst = 1'b1; end
    always #5 clk = ~clk;

    // Upper ports: 0=c0, 1=c1, 2=i0, 3=i1.
    logic [3:0]  rd_valid, rd_ready, rsp_valid, rsp_ready;
    logic [31:0] rd_addr [4];
    wire  [127:0] rsp_data [4];

    logic [1:0]   wr_valid, wr_ready;
    logic [31:0]  wr_addr [2];
    logic [127:0] wr_data [2];
    logic [15:0]  wr_be   [2];

    logic        mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
    logic [31:0] mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rsp_data, mem_wr_data;
    logic [15:0] mem_wr_be;
    logic        mem_wr_valid, mem_wr_ready;
    logic        l2_idle;
    logic [31:0] hit_count, miss_count;

    int unsigned err_data, err_owner, err_wb, rsp_count, wb_count, accepted, outstanding;

    l2_top #(.SETS(SETS), .WAYS(WAYS)) dut (
        .clk(clk), .rst(rst),
        .c0_rd_valid(rd_valid[0]), .c0_rd_ready(rd_ready[0]), .c0_rd_addr(rd_addr[0]),
        .c0_rsp_valid(rsp_valid[0]), .c0_rsp_ready(rsp_ready[0]), .c0_rsp_data(rsp_data[0]),
        .c0_wr_valid(wr_valid[0]), .c0_wr_ready(wr_ready[0]), .c0_wr_addr(wr_addr[0]),
        .c0_wr_data(wr_data[0]), .c0_wr_be(wr_be[0]),
        .c1_rd_valid(rd_valid[1]), .c1_rd_ready(rd_ready[1]), .c1_rd_addr(rd_addr[1]),
        .c1_rsp_valid(rsp_valid[1]), .c1_rsp_ready(rsp_ready[1]), .c1_rsp_data(rsp_data[1]),
        .c1_wr_valid(wr_valid[1]), .c1_wr_ready(wr_ready[1]), .c1_wr_addr(wr_addr[1]),
        .c1_wr_data(wr_data[1]), .c1_wr_be(wr_be[1]),
        .i_rd_valid(rd_valid[2]), .i_rd_ready(rd_ready[2]), .i_rd_addr(rd_addr[2]),
        .i_rsp_valid(rsp_valid[2]), .i_rsp_ready(rsp_ready[2]), .i_rsp_data(rsp_data[2]),
        .i1_rd_valid(rd_valid[3]), .i1_rd_ready(rd_ready[3]), .i1_rd_addr(rd_addr[3]),
        .i1_rsp_valid(rsp_valid[3]), .i1_rsp_ready(rsp_ready[3]), .i1_rsp_data(rsp_data[3]),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready), .mem_rd_addr(mem_rd_addr),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready), .mem_rsp_data(mem_rsp_data),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_be(mem_wr_be),
        .l2_idle(l2_idle), .hit_count(hit_count), .miss_count(miss_count)
    );

    l2_ref_model #(
        .SETS(SETS), .BASE(BASE), .BYTES(BYTES),
        .MEM_LAT(2), .RD_STALL(2), .WR_STALL(1)
    ) u_ref (
        .clk(clk), .rst(rst),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_addr(rd_addr),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_data(rsp_data),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_addr(wr_addr),
        .wr_data(wr_data), .wr_be(wr_be),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready), .mem_rd_addr(mem_rd_addr),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready), .mem_rsp_data(mem_rsp_data),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_be(mem_wr_be),
        .err_data(err_data), .err_owner(err_owner), .err_wb(err_wb),
        .rsp_count(rsp_count), .wb_count(wb_count), .accepted(accepted),
        .outstanding(outstanding)
    );

    int unsigned checks, errors, accepted_base;
    localparam int unsigned MAX_TOUCH = 512;
    logic [31:0] touched [0:MAX_TOUCH-1];
    int unsigned n_touch;

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

    // Same deterministic pattern the checker initialises its images with.
    /* verilator lint_off UNUSEDSIGNAL */  // only bits [11:0] shape the pattern
    function automatic logic [7:0] pat_byte(input logic [31:0] addr);
        pat_byte = (addr[7:0] + 8'h5A) ^ {addr[11:8], 4'h0};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off UNUSEDSIGNAL */  // the beat offset is masked below
    function automatic logic [127:0] pat(input logic [31:0] addr);
        for (int b = 0; b < 16; b++)
            pat[8*b +: 8] = pat_byte({addr[31:4], 4'h0} + 32'(b));
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off UNUSEDSIGNAL */  // only the line address is recorded
    task automatic note_touch(input logic [31:0] addr);
        logic [31:0] line;
        bit found;
        begin
            line  = {addr[31:6], 6'b0};
            found = 1'b0;
            for (int i = 0; i < n_touch; i++)
                if (touched[i] == line) found = 1'b1;
            if (!found && n_touch < MAX_TOUCH) begin
                touched[n_touch] = line;
                n_touch++;
            end
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    task automatic l2_read(input logic [1:0] port, input logic [31:0] addr,
                           input int rsp_delay, output logic [127:0] data);
        begin
            note_touch(addr);
            @(negedge clk);
            rd_valid[port]  = 1'b1;
            rd_addr[port]   = addr;
            rsp_ready[port] = (rsp_delay == 0);
            #1;
            while (!rd_ready[port]) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            rd_valid[port] = 1'b0;
            if (rsp_delay != 0) begin
                repeat (rsp_delay) @(posedge clk);
                rsp_ready[port] = 1'b1;
                #1;
            end
            while (!rsp_valid[port]) begin @(posedge clk); #1; end
            data = rsp_data[port];
            @(posedge clk); #1;
            rsp_ready[port] = 1'b0;
        end
    endtask

    task automatic l2_write(input logic port, input logic [31:0] addr,
                            input logic [127:0] data, input logic [15:0] be);
        begin
            note_touch(addr);
            @(negedge clk);
            wr_valid[port] = 1'b1;
            wr_addr[port]  = addr;
            wr_data[port]  = data;
            wr_be[port]    = be;
            #1;
            while (!wr_ready[port]) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            wr_valid[port] = 1'b0;
            while (!l2_idle) begin @(posedge clk); #1; end
        end
    endtask

    function automatic logic [31:0] A(input int unsigned off);
        A = BASE + 32'(off);
    endfunction

    logic [127:0] d0, d1, d2;
    logic [127:0] v [0:5];

    initial begin
        for (int i = 0; i < 4; i++) begin
            rd_valid[i] = 1'b0; rsp_ready[i] = 1'b0; rd_addr[i] = 32'h0;
        end
        for (int i = 0; i < 2; i++) begin
            wr_valid[i] = 1'b0; wr_addr[i] = 32'h0; wr_data[i] = 128'h0; wr_be[i] = 16'h0;
        end
        checks = 0; errors = 0; n_touch = 0;

        repeat (3) @(posedge clk);
        #1; rst = 1'b0;
        repeat (2) @(posedge clk); #1;
        check(l2_idle, "reset: L2 idle");

        //--- cold reset in the middle of a refill -----------------------------
        @(negedge clk);
        rd_valid[0] = 1'b1; rd_addr[0] = A(32'h9000);
        #1;
        while (!rd_ready[0]) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        rd_valid[0] = 1'b0;
        repeat (4) @(posedge clk); #1;
        rst = 1'b1;
        repeat (2) @(posedge clk); #1;
        rst = 1'b0;
        repeat (2) @(posedge clk); #1;
        check(!rsp_valid[0] && !rsp_valid[1] && !rsp_valid[2] && !rsp_valid[3],
              "cold reset: no residual response");
        check(l2_idle, "cold reset: L2 idle again");
        accepted_base = accepted;

        //--- clean refill after the reset -------------------------------------
        l2_read(0, A(32'h2000), 0, d0);
        check(d0 == pat(A(32'h2000)), "clean refill returns backing data");
        l2_read(1, A(32'h2000), 0, d1);
        check(d1 == d0, "second port hits the same line");

        //--- write / read through both ports ----------------------------------
        l2_write(0, A(32'h1000), 128'h1111_2222_3333_4444_5555_6666_7777_8888, 16'hFFFF);
        l2_read(0, A(32'h1000), 0, d0);
        check(d0 == 128'h1111_2222_3333_4444_5555_6666_7777_8888, "c0 write/read hit");
        l2_read(1, A(32'h1000), 0, d1);
        check(d1 == d0, "c1 reads c0 line");
        l2_write(1, A(32'h1000), 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0000_1111, 16'hFFFF);
        l2_read(0, A(32'h1000), 0, d0);
        check(d0 == 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0000_1111, "c1 write, c0 read");

        //--- write-allocate miss with a partial byte enable -------------------
        l2_read(0, A(32'h3000), 0, d0);
        l2_write(0, A(32'h3000), 128'h0, 16'h000F);
        l2_read(0, A(32'h3000), 0, d1);
        check(d1[31:0] == 32'h0, "partial write updates enabled bytes");
        check(d1[127:32] == d0[127:32], "partial write keeps disabled bytes");

        //--- six tags in one set: writebacks and wrap-around ------------------
        for (int i = 0; i < 6; i++)
            v[i] = {4{32'h2000_0000 + 32'(i) * 32'h0101_0101}};
        for (int i = 0; i < 6; i++)
            l2_write(0, A(i * 32'h400), v[i], 16'hFFFF);
        for (int i = 0; i < 6; i++) begin
            l2_read(0, A(i * 32'h400), 0, d0);
            check(d0 == v[i], $sformatf("same-set line %0d survives eviction", i));
        end
        l2_read(1, A(32'h400), 0, d0);
        check(d0 == v[1], "c1 reads an evicted-then-refilled line");

        //--- sparse byte enables ----------------------------------------------
        l2_read(0, A(32'h4000), 0, d0);
        l2_write(0, A(32'h4000), 128'h0000_0000_0000_0000_0000_0000_DEAD_BEEF, 16'h000F);
        l2_read(0, A(32'h4000), 0, d1);
        check(d1[31:0] == 32'hDEAD_BEEF && d1[127:32] == d0[127:32],
              "byte enable 0x000F merges only the low word");
        l2_write(0, A(32'h4000), 128'h0, 16'h8001);
        l2_read(0, A(32'h4000), 0, d2);
        check(d2[7:0] == 8'h0 && d2[127:120] == 8'h0, "sparse byte enable 0x8001 writes both ends");
        check(d2[119:8] == d1[119:8], "sparse byte enable keeps the middle");

        //--- a 64 B line assembled from four beats ----------------------------
        for (int b = 0; b < 4; b++)
            l2_write(0, A(32'h5000 + 32'(b) * 32'h10), {4{32'hB000_0000 + 32'(b)}},
                     16'hFFFF);
        for (int b = 0; b < 4; b++) begin
            l2_read(0, A(32'h5000 + 32'(b) * 32'h10), 0, d0);
            check(d0 == {4{32'hB000_0000 + 32'(b)}},
                  $sformatf("64 B line beat %0d", b));
        end

        //--- response-receive stall: payload must stay stable ------------------
        @(negedge clk);
        rd_valid[0] = 1'b1; rd_addr[0] = A(32'h6000);
        #1;
        while (!rd_ready[0]) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        rd_valid[0] = 1'b0;
        // Hold ready low until the response has been offered, then keep it
        // pending for a few cycles and require a stable payload.
        while (!rsp_valid[0]) begin @(posedge clk); #1; end
        d0 = rsp_data[0];
        repeat (4) @(posedge clk); #1;
        check(rsp_valid[0] && rsp_data[0] == d0, "stall: payload stable while ready is low");
        rsp_ready[0] = 1'b1;
        #1;
        @(posedge clk); #1;
        rsp_ready[0] = 1'b0;

        //--- instruction port read -------------------------------------------
        l2_read(2, A(32'h2000), 0, d0);
        check(d0 == pat(A(32'h2000)), "i0 port reads the shared line");

        //--- drain: four fresh tags per set evict every resident line --------
        for (int s = 0; s < 16; s++)
            for (int k = 0; k < 4; k++)
                l2_write(0, A(32'h8000 + 32'(s) * 32'h40 + 32'(k) * 32'h400),
                         {4{32'hD000_0000 + 32'(s) * 32'h100 + 32'(k)}}, 16'hFFFF);

        //--- sweep every touched line through the L2 --------------------------
        for (int i = 0; i < n_touch; i++)
            for (int b = 0; b < 4; b++)
                l2_read(1, touched[i] + 32'(b) * 32'h10, 0, d0);

        check(outstanding == 0, "checker: no outstanding read");
        check(hit_count + miss_count == accepted - accepted_base,
              "hit+miss counters match accepted transactions");
        check(hit_count != 0 && miss_count != 0, "hit and miss counters advanced");
        check(err_data == 0, "checker: response data matches golden image");
        check(err_owner == 0, "checker: one response per accepted read, right port");
        check(err_wb == 0, "checker: writebacks match golden and stay in set");
        check(errors == 0, "directed checks passed");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - L2 reference model (hits=%0d misses=%0d wb=%0d rsp=%0d lines=%0d)",
                     checks, hit_count, miss_count, wb_count, rsp_count, n_touch);
        end else begin
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
            $fatal(1, "tb_l2_ref failed");
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("*** TIMEOUT ***");
        $fatal(1, "tb_l2_ref timeout");
    end
endmodule
