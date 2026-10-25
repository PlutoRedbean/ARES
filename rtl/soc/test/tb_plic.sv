//=============================================================================
// ARES SoC - PLIC unit test (32 sources, 2 contexts)
//-----------------------------------------------------------------------------
// Covers per-context enable/threshold, priority claim ordering, pending
// gateway, claim/complete in-service behavior, context independence and
// byte-strobed configuration writes.
//=============================================================================
`timescale 1ns/1ps
module tb_plic;
    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
    end
    always #5 clk = ~clk;

    localparam logic [31:0] PRIO1  = 32'h0000_0004;
    localparam logic [31:0] PRIO2  = 32'h0000_0008;
    localparam logic [31:0] PRIO3  = 32'h0000_000C;
    localparam logic [31:0] PEND   = 32'h0000_1000;
    localparam logic [31:0] EN0    = 32'h0000_2000;
    localparam logic [31:0] EN1    = 32'h0000_2080;
    localparam logic [31:0] TH0    = 32'h0020_0000;
    localparam logic [31:0] TH1    = 32'h0020_1000;
    localparam logic [31:0] CLAIM0 = 32'h0020_0004;
    localparam logic [31:0] CLAIM1 = 32'h0020_1004;

    logic        req_valid, req_ready, req_write;
    logic [31:0] req_addr, req_wdata;
    logic [3:0]  req_wstrb;
    logic        rsp_valid, rsp_ready;
    logic [31:0] rsp_data;
    logic [31:0] src;
    logic [1:0]  irq_out;

    int unsigned checks, errors;

    soc_plic #(.NUM_CONTEXTS(2)) dut (
        .clk(clk),
        .rst(rst),
        .src(src),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_write(req_write),
        .req_addr(req_addr),
        .req_wdata(req_wdata),
        .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),
        .rsp_ready(rsp_ready),
        .rsp_data(rsp_data),
        .irq_out(irq_out)
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
            check(req_ready, "plic wr accepted");
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
            check(req_ready, "plic rd accepted");
            @(posedge clk);
            #1;
            check(rsp_valid, "plic rd response valid");
            data = rsp_data;
            req_valid = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    logic [31:0] v;

    initial begin
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr  = 32'h0;
        req_wdata = 32'h0;
        req_wstrb = 4'h0;
        rsp_ready = 1'b1;
        src       = 32'h0;
        checks    = 0;
        errors    = 0;

        repeat (3) @(posedge clk);
        #1;
        rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;

        rd(PEND, v);
        check(v == 32'h0, "reset pending = 0");
        check(!irq_out[0] && !irq_out[1], "reset irq_out = 0");

        // Source 1, context 0 only.
        wr(PRIO1, 32'd1, 4'hF);
        wr(EN0, 32'h0000_0002, 4'hF);
        wr(TH0, 32'd0, 4'hF);
        src[1] = 1'b1;
        @(posedge clk);
        #1;
        rd(PEND, v);
        check(v == 32'h0000_0002, "source1 pending");
        check(irq_out[0], "ctx0 irq for source1");
        check(!irq_out[1], "ctx1 disabled for source1");

        // Claim, hold in service while source remains high.
        rd(CLAIM0, v);
        check(v == 32'd1, "claim ctx0 returns source1");
        rd(PEND, v);
        check(v == 32'h0000_0000, "claim clears pending");
        check(!irq_out[0], "in-service source does not re-irq");

        // Complete while source is still high: the level gateway re-pends.
        wr(CLAIM0, 32'd1, 4'hF);
        @(posedge clk);
        #1;
        check(irq_out[0], "complete re-pends held source");
        src[1] = 1'b0;
        rd(CLAIM0, v);
        check(v == 32'd1, "claim held pending after source drop");
        wr(CLAIM0, 32'd1, 4'hF);

        // Priority ordering and tie-break.
        wr(PRIO2, 32'd3, 4'hF);
        wr(PRIO3, 32'd2, 4'hF);
        wr(EN0, 32'h0000_000E, 4'hF);
        src[2] = 1'b1;
        src[3] = 1'b1;
        @(posedge clk);
        #1;
        rd(CLAIM0, v);
        check(v == 32'd2, "higher priority source2 claimed first");
        src[2] = 1'b0;                 // clear the device before complete
        wr(CLAIM0, 32'd2, 4'hF);
        @(posedge clk);
        #1;
        rd(CLAIM0, v);
        check(v == 32'd3, "source3 claimed next");
        src[3] = 1'b0;
        wr(CLAIM0, 32'd3, 4'hF);

        // Equal priority: lowest source ID wins.
        wr(PRIO2, 32'd2, 4'hF);
        wr(PRIO3, 32'd2, 4'hF);
        src[2] = 1'b1;
        src[3] = 1'b1;
        @(posedge clk);
        #1;
        rd(CLAIM0, v);
        check(v == 32'd2, "equal priority tie -> lowest source");
        src[2] = 1'b0;
        wr(CLAIM0, 32'd2, 4'hF);
        @(posedge clk);
        #1;
        rd(CLAIM0, v);
        check(v == 32'd3, "equal priority: source3 next");
        src[3] = 1'b0;
        wr(CLAIM0, 32'd3, 4'hF);

        // Threshold blocks an equal/lower priority but not a higher one.
        wr(TH0, 32'd2, 4'hF);
        wr(PRIO2, 32'd2, 4'hF);
        wr(PRIO3, 32'd3, 4'hF);
        src[2] = 1'b1;
        src[3] = 1'b1;
        @(posedge clk);
        #1;
        check(irq_out[0], "threshold: source3 (prio3) passes");
        rd(CLAIM0, v);
        check(v == 32'd3, "threshold: only source3 claimable");
        src[3] = 1'b0;
        wr(CLAIM0, 32'd3, 4'hF);
        @(posedge clk);
        #1;
        check(!irq_out[0], "threshold: source2 (prio2) blocked");
        rd(CLAIM0, v);
        check(v == 32'd0, "threshold: no claim when blocked");
        // Lower the threshold to drain the still-pending source2.
        wr(TH0, 32'd0, 4'hF);
        rd(CLAIM0, v);
        check(v == 32'd2, "threshold: lowered threshold exposes source2");
        src[2] = 1'b0;
        wr(CLAIM0, 32'd2, 4'hF);
        @(posedge clk);
        #1;

        // Context independence: ctx1 enables source2, ctx0 does not.
        wr(EN0, 32'h0, 4'hF);
        wr(EN1, 32'h0000_0004, 4'hF);
        wr(TH1, 32'd0, 4'hF);
        src[2] = 1'b1;
        @(posedge clk);
        #1;
        check(!irq_out[0], "ctx0 disabled");
        check(irq_out[1], "ctx1 independent enable");
        rd(PRIO1, v);
        check(v == 32'd1, "priority readback");
        rd(CLAIM1, v);
        check(v == 32'd2, "ctx1 claim");
        src[2] = 1'b0;
        wr(CLAIM1, 32'd2, 4'hF);
        @(posedge clk);
        #1;

        // Byte-strobed enable word: only bits 8-15 change.
        wr(EN0, 32'h0000_0000, 4'hF);
        wr(EN0, 32'h0000_0200, 4'h2);
        rd(EN0, v);
        check(v == 32'h0000_0200, "enable byte strobe");
        wr(EN0, 32'h0, 4'hF);

        // No pending claim returns 0.
        rd(CLAIM0, v);
        check(v == 32'd0, "claim with no pending returns 0");

        // Complete unknown/invalid source does not disturb state.
        wr(CLAIM0, 32'd31, 4'hF);
        rd(PEND, v);
        check(v == 32'h0, "invalid complete leaves pending clean");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - PLIC priority/enable/threshold, claim/complete, gateway re-pend, tie-break, byte strobes, context independence", checks);
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
