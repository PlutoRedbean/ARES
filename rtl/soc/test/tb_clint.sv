//=============================================================================
// ARES SoC - CLINT unit test
//-----------------------------------------------------------------------------
// Checks per-hart MSIP, 64-bit MTIMECMP/MTIME, timer IRQ comparison, byte
// strobes, single-outstanding response behavior and mtime carry.
//=============================================================================
`timescale 1ns/1ps
module tb_clint;
    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
    end
    always #5 clk = ~clk;

    localparam logic [31:0] MSIP0  = 32'h0000_0000;
    localparam logic [31:0] MSIP1  = 32'h0000_0004;
    localparam logic [31:0] CMP0   = 32'h0000_4000;
    localparam logic [31:0] CMP1   = 32'h0000_4008;
    localparam logic [31:0] MTIME  = 32'h0000_BFF8;
    localparam logic [31:0] MTIMEH = 32'h0000_BFFC;

    logic        req_valid;
    logic        req_ready;
    logic        req_write;
    logic [31:0] req_addr;
    logic [31:0] req_wdata;
    logic [3:0]  req_wstrb;
    logic        rsp_valid;
    logic        rsp_ready;
    logic [31:0] rsp_data;
    logic        mtime_inc;
    logic [1:0]  msip;
    logic [1:0]  timer_irq;

    int unsigned checks;
    int unsigned errors;

    soc_clint #(.NUM_HARTS(2)) dut (
        .clk(clk),
        .rst(rst),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_write(req_write),
        .req_addr(req_addr),
        .req_wdata(req_wdata),
        .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),
        .rsp_ready(rsp_ready),
        .rsp_data(rsp_data),
        .mtime_inc(mtime_inc),
        .msip(msip),
        .timer_irq(timer_irq)
    );

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

    task automatic wr(input logic [31:0] addr, input logic [31:0] data,
                      input logic [3:0] strb);
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b1;
            req_addr  = addr;
            req_wdata = data;
            req_wstrb = strb;
            #1;
            check(req_ready, "wr accepted");
            @(posedge clk);
            #1;
            req_valid = 1'b0;
            req_write = 1'b0;
            req_wstrb = 4'h0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic rd(input logic [31:0] addr, output logic [31:0] data);
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b0;
            req_addr  = addr;
            req_wdata = 32'h0;
            req_wstrb = 4'h0;
            #1;
            check(req_ready, "rd accepted");
            @(posedge clk);
            #1;
            check(rsp_valid, "rd response valid");
            data = rsp_data;
            req_valid = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic tick(input int unsigned n);
        begin
            repeat (n) @(posedge clk);
            #1;
        end
    endtask

    logic [31:0] rdv;

    initial begin
        req_valid  = 1'b0;
        req_write  = 1'b0;
        req_addr   = 32'h0;
        req_wdata  = 32'h0;
        req_wstrb  = 4'h0;
        rsp_ready  = 1'b1;
        mtime_inc  = 1'b0;
        checks     = 0;
        errors     = 0;

        repeat (3) @(posedge clk);
        #1;
        rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;

        check(!msip[0] && !msip[1], "reset MSIP = 0");
        check(!timer_irq[0] && !timer_irq[1], "reset timers = 0 (cmp reset max)");
        check(req_ready, "reset req_ready = 1");

        // MSIP per hart
        wr(MSIP0, 32'h1, 4'h1);
        check(msip[0] && !msip[1], "MSIP0 set");
        rd(MSIP0, rdv);
        check(rdv == 32'h1, "MSIP0 readback");
        wr(MSIP0, 32'h0, 4'h1);
        check(!msip[0], "MSIP0 clear");
        wr(MSIP1, 32'h1, 4'h1);
        check(!msip[0] && msip[1], "MSIP1 independent");
        wr(MSIP1, 32'h0, 4'h1);

        // MTIMECMP / MTIME low words, per-hart timer
        wr(CMP0, 32'd5, 4'hF);
        wr(CMP0 + 32'h4, 32'd0, 4'hF);
        wr(MTIME, 32'd0, 4'hF);
        wr(MTIMEH, 32'd0, 4'hF);
        mtime_inc = 1'b1;
        tick(4);
        check(!timer_irq[0], "timer0 below compare");
        tick(1);
        check(timer_irq[0], "timer0 at compare");
        check(!timer_irq[1], "timer1 still masked by max compare");
        mtime_inc = 1'b0;

        wr(CMP1, 32'd3, 4'hF);
        wr(CMP1 + 32'h4, 32'd0, 4'hF);
        #1;
        check(timer_irq[1], "timer1 fires immediately at mtime>=cmp");

        // Raise timer0 compare above current mtime: IRQ drops.
        wr(CMP0, 32'hFFFF_FFFF, 4'hF);
        wr(CMP0 + 32'h4, 32'hFFFF_FFFF, 4'hF);
        #1;
        check(!timer_irq[0], "timer0 clears when compare raised");

        // 64-bit mtime carry and high-word readback.
        wr(MTIME, 32'hFFFF_FFFE, 4'hF);
        wr(MTIMEH, 32'd0, 4'hF);
        mtime_inc = 1'b1;
        tick(2);
        mtime_inc = 1'b0;
        rd(MTIME, rdv);
        check(rdv == 32'h0000_0000, "mtime low wraps to 0");
        rd(MTIMEH, rdv);
        check(rdv == 32'h0000_0001, "mtime high increments on carry");

        // Byte strobes on MTIMECMP low word.
        wr(CMP0, 32'h0000_0000, 4'hF);
        wr(CMP0, 32'hAABB_CCDD, 4'h1);
        rd(CMP0, rdv);
        check(rdv == 32'h0000_00DD, "cmp byte strobe [0] only");
        wr(CMP0, 32'hAABB_CCDD, 4'h2);
        rd(CMP0, rdv);
        check(rdv == 32'h0000_CCDD, "cmp byte strobe [1] only");
        wr(CMP0, 32'hAABB_CCDD, 4'h4);
        rd(CMP0, rdv);
        check(rdv == 32'h00BB_CCDD, "cmp byte strobe [2] only");
        wr(CMP0, 32'hAABB_CCDD, 4'h8);
        rd(CMP0, rdv);
        check(rdv == 32'hAABB_CCDD, "cmp byte strobe [3] only");

        // Stalled response: rsp_valid holds, req_ready drops, data stable.
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr  = MSIP0;
        rsp_ready = 1'b0;
        @(posedge clk);
        #1;
        check(rsp_valid, "stalled response asserts rsp_valid");
        check(!req_ready, "req_ready low while response stalled");
        check(msip[0] == 1'b0, "stalled read setup");
        repeat (3) @(posedge clk);
        #1;
        check(rsp_valid, "rsp_valid held under stall");
        req_valid = 1'b0;
        rsp_ready = 1'b1;
        @(posedge clk);
        #1;
        check(!rsp_valid, "rsp_valid clears after ready");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - CLINT MSIP/MTIMECMP/MTIME, per-hart timers, 64-bit carry, byte strobes, response stall", checks);
        end else begin
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        end
        $finish;
    end

    initial begin
        #200000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
