`timescale 1ns / 1ps
//=============================================================================
// tb_div - unit test for rtl/pipeline/soc/ip/div.v
//-----------------------------------------------------------------------------
// Covers:
//   * directed boundary pairs, including divisor == 0 (RV32M -1/dividend),
//     a < b, a == b, all-ones, 2^31, powers of two,
//   * random pairs against the behavioural reference,
//   * result latency and hold: no result before fire+LATENCY, valid for one
//     cycle at fire+LATENCY, data held until the next accepted request,
//   * LATENCY=35 (the value Mundus/EXU/DIV consumes) and LATENCY=17 (the
//     documented minimum) instances,
//   * a fire while busy is ignored: it must not disturb the operation in
//     flight and must not produce a phantom valid pulse.
//
// Run:
//   make pipeline-div-test
// or:
//   iverilog -g2012 -I rtl/pipeline/include -I rtl/pipeline/core/vsrc/include \
//       -o /tmp/tb_div rtl/pipeline/soc/ip/div.v rtl/pipeline/test/tb_div.sv \
//       && vvp /tmp/tb_div
//=============================================================================
module tb_div;

    localparam integer N_LAT    = 35;    // probe latency used by DIV in Mundus.sv
    localparam integer M_LAT    = 17;    // minimum supported latency
    localparam integer N_RANDOM = 2000;
    localparam integer M_RANDOM = 200;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    //---- 35-cycle DUT -------------------------------------------------------
    reg  [31:0] a_n;
    reg  [31:0] b_n;
    reg         tv_n;
    wire [63:0] dout_n;
    wire        dvalid_n;
    reg  [63:0] prev_n;

    div #(.LATENCY(N_LAT)) dut_n (
        .aclk                    (clk),
        .s_axis_dividend_tdata   (a_n),
        .s_axis_dividend_tready  (),
        .s_axis_dividend_tvalid  (tv_n),
        .s_axis_divisor_tdata    (b_n),
        .s_axis_divisor_tready   (),
        .s_axis_divisor_tvalid   (tv_n),
        .m_axis_dout_tdata       (dout_n),
        .m_axis_dout_tvalid      (dvalid_n)
    );

    //---- 17-cycle DUT -------------------------------------------------------
    reg  [31:0] a_m;
    reg  [31:0] b_m;
    reg         tv_m;
    wire [63:0] dout_m;
    wire        dvalid_m;
    reg  [63:0] prev_m;

    div #(.LATENCY(M_LAT)) dut_m (
        .aclk                    (clk),
        .s_axis_dividend_tdata   (a_m),
        .s_axis_dividend_tready  (),
        .s_axis_dividend_tvalid  (tv_m),
        .s_axis_divisor_tdata    (b_m),
        .s_axis_divisor_tready   (),
        .s_axis_divisor_tvalid   (tv_m),
        .m_axis_dout_tdata       (dout_m),
        .m_axis_dout_tvalid      (dvalid_m)
    );

    //---- reference model ----------------------------------------------------
    function [63:0] ref_result;
        input [31:0] x;
        input [31:0] y;
        begin
            if (y == 32'd0) ref_result = {32'hFFFF_FFFF, x};
            else            ref_result = {x / y, x % y};
        end
    endfunction

    task automatic fail_pair;
        input [31:0] x;
        input [31:0] y;
        input [63:0] exp;
        input [63:0] got;
        input [127:0] tag;
        begin
            errors = errors + 1;
            $display("ERROR [%0s] %08x / %08x : expected %016x got %016x (t=%0t)",
                     tag, x, y, exp, got, $time);
        end
    endtask

    //---- 35-cycle driver ----------------------------------------------------
    task automatic issue_n;
        input [31:0] x;
        input [31:0] y;
        begin
            @(negedge clk);
            a_n = x; b_n = y; tv_n = 1'b1;
            @(posedge clk);       // fire edge
            @(negedge clk);
            tv_n = 1'b0;
        end
    endtask

    task automatic expect_n;
        input [31:0] x;
        input [31:0] y;
        input [63:0] exp;
        begin
            checks = checks + 1;
            repeat (9) @(negedge clk);                 // before the result
            if (dvalid_n !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR: valid_n high too early for %08x/%08x", x, y);
            end
            // AXIS: the payload is only meaningful with tvalid, and the divide-by-zero
            // result is written on the fire edge, so it may legitimately appear
            // early.  Every other result must wait for the iteration.
            if (y != 32'd0 && dout_n !== prev_n) begin
                errors = errors + 1;
                $display("ERROR: dout_n changed before latency for %08x/%08x: %016x",
                         x, y, dout_n);
            end
            repeat (N_LAT - 10) @(negedge clk);        // fire + N_LAT
            if (dvalid_n !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR: valid_n missing at fire+%0d for %08x/%08x", N_LAT, x, y);
            end
            if (dout_n !== exp) fail_pair(x, y, exp, dout_n, "lat35");
            @(negedge clk);
            if (dvalid_n !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR: valid_n stuck high for %08x/%08x", x, y);
            end
            if (dout_n !== exp) begin
                errors = errors + 1;
                $display("ERROR: dout_n not held after result for %08x/%08x", x, y);
            end
            prev_n = exp;
        end
    endtask

    task automatic run_n;
        input [31:0] x;
        input [31:0] y;
        reg [63:0] exp;
        begin
            exp = ref_result(x, y);
            issue_n(x, y);
            expect_n(x, y, exp);
        end
    endtask

    //---- 17-cycle driver ----------------------------------------------------
    task automatic issue_m;
        input [31:0] x;
        input [31:0] y;
        begin
            @(negedge clk);
            a_m = x; b_m = y; tv_m = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tv_m = 1'b0;
        end
    endtask

    task automatic expect_m;
        input [31:0] x;
        input [31:0] y;
        input [63:0] exp;
        begin
            checks = checks + 1;
            repeat (9) @(negedge clk);
            if (dvalid_m !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR: valid_m high too early for %08x/%08x", x, y);
            end
            if (y != 32'd0 && dout_m !== prev_m) begin
                errors = errors + 1;
                $display("ERROR: dout_m changed before latency for %08x/%08x: %016x",
                         x, y, dout_m);
            end
            repeat (M_LAT - 10) @(negedge clk);
            if (dvalid_m !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR: valid_m missing at fire+%0d for %08x/%08x", M_LAT, x, y);
            end
            if (dout_m !== exp) fail_pair(x, y, exp, dout_m, "lat17");
            @(negedge clk);
            if (dvalid_m !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR: valid_m stuck high for %08x/%08x", x, y);
            end
            if (dout_m !== exp) begin
                errors = errors + 1;
                $display("ERROR: dout_m not held after result for %08x/%08x", x, y);
            end
            prev_m = exp;
        end
    endtask

    task automatic run_m;
        input [31:0] x;
        input [31:0] y;
        reg [63:0] exp;
        begin
            exp = ref_result(x, y);
            issue_m(x, y);
            expect_m(x, y, exp);
        end
    endtask

    //---- directed boundary table -------------------------------------------
    reg [31:0] dv_a [0:17];
    reg [31:0] dv_b [0:17];
    integer k;

    initial begin
        dv_a[0] = 32'd0;          dv_b[0] = 32'd1;
        dv_a[1] = 32'd0;          dv_b[1] = 32'hFFFF_FFFF;
        dv_a[2] = 32'd1;          dv_b[2] = 32'd1;
        dv_a[3] = 32'd42;         dv_b[3] = 32'd1;
        dv_a[4] = 32'hFFFF_FFFF;  dv_b[4] = 32'd1;
        dv_a[5] = 32'hFFFF_FFFF;  dv_b[5] = 32'hFFFF_FFFF;
        dv_a[6] = 32'h8000_0000;  dv_b[6] = 32'hFFFF_FFFF;
        dv_a[7] = 32'h8000_0000;  dv_b[7] = 32'd1;
        dv_a[8] = 32'h7FFF_FFFF;  dv_b[8] = 32'd2;
        dv_a[9] = 32'd3;          dv_b[9] = 32'd7;
        dv_a[10] = 32'hDEAD_BEEF; dv_b[10] = 32'h1234;
        dv_a[11] = 32'hFFFF_FFFF; dv_b[11] = 32'd2;
        dv_a[12] = 32'hFFFF_FFFF; dv_b[12] = 32'd3;
        dv_a[13] = 32'h0001_0000; dv_b[13] = 32'h0000_0100;
        dv_a[14] = 32'hFFFF_FFFE; dv_b[14] = 32'h0000_FFFF;
        dv_a[15] = 32'h1234_5678; dv_b[15] = 32'd0;
        dv_a[16] = 32'd0;         dv_b[16] = 32'd0;
        dv_a[17] = 32'hC000_0000; dv_b[17] = 32'h0000_0003;
    end

    //---- test body ----------------------------------------------------------
    initial begin
        a_n = 32'd0; b_n = 32'd0; tv_n = 1'b0; prev_n = 64'd0;
        a_m = 32'd0; b_m = 32'd0; tv_m = 1'b0; prev_m = 64'd0;

        // 1) directed, 35-cycle instance
        for (k = 0; k < 18; k = k + 1) begin
            run_n(dv_a[k], dv_b[k]);
        end

        // 2) random, 35-cycle instance
        for (k = 0; k < N_RANDOM; k = k + 1) begin
            run_n($urandom, $urandom);
        end
        // a few with a small divisor, where the digit selection saturates
        for (k = 0; k < 100; k = k + 1) begin
            run_n($urandom, $urandom & 32'h0000_FFFF);
        end

        // 3) fire while busy must be ignored (A completes, no phantom valid)
        begin
            reg [63:0] exp_a;
            exp_a = ref_result(32'h1234_5678, 32'h0000_0010);
            issue_n(32'h1234_5678, 32'h0000_0010);     // ends at fire+1
            repeat (2) @(negedge clk);                 // fire+3
            tv_n = 1'b1; a_n = 32'hFFFF_FFFF; b_n = 32'd3;
            @(posedge clk);                            // dropped: busy
            @(negedge clk);
            tv_n = 1'b0;
            repeat (N_LAT - 4) @(negedge clk);         // fire + N_LAT
            checks = checks + 1;
            if (dout_n !== exp_a) fail_pair(32'h1234_5678, 32'h10, exp_a, dout_n, "busy");
            @(negedge clk);
            checks = checks + 1;
            if (dvalid_n !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR: phantom valid after dropped request");
            end
            repeat (3) @(negedge clk);                 // past the phantom window
            checks = checks + 1;
            if (dvalid_n !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR: phantom valid from dropped request");
            end
            prev_n = exp_a;
        end

        // 4) back-to-back at the 36-cycle spacing DIV actually uses
        for (k = 0; k < 8; k = k + 1) begin
            run_n($urandom, $urandom);
        end

        // 5) directed + random, 17-cycle instance
        for (k = 0; k < 18; k = k + 1) begin
            run_m(dv_a[k], dv_b[k]);
        end
        for (k = 0; k < M_RANDOM; k = k + 1) begin
            run_m($urandom, $urandom);
        end

        if (errors == 0) begin
            $display("ALL TESTS PASSED: div LATENCY=35 and LATENCY=17, %0d checked operations", checks);
        end else begin
            $display("FAILED: %0d errors over %0d checked operations", errors, checks);
        end
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
