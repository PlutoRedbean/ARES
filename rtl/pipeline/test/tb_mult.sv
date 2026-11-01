`timescale 1ns / 1ps
//=============================================================================
// tb_mult - unit test for rtl/pipeline/soc/ip/mult.v
//-----------------------------------------------------------------------------
// Covers:
//   * the 17/16-bit split boundaries (0xFFFF/0x10000/0x1FFFF/0x20000 on both
//     operands), because a wrong split shows up exactly there,
//   * signs: +/+, +/-, -/+, -/-, INT32_MIN, -1, all-ones,
//   * 20k random pairs, mixing full-range values (high partial products) with
//     small ones (carry chains),
//   * every product is checked on the cycle it is due against a 33x33
//     reference; only the low 64 bits are compared, which is what WBU reads,
//   * CE deasserted: the result must hold,
//   * a PIPELINE_STAGES=5 instance, which walks the optional tail-register
//     path (CONFIG_MUL_LATENCY is 4, so that branch is normally unused).
//
// Latency contract: operands presented in cycle n appear on P after the 4th
// following clock edge, matching the old flat implementation so the
// EX1 -> WBU distance in Mundus does not change.
//
// Run:
//   make pipeline-mult-test
// or:
//   iverilog -g2012 -I rtl/pipeline/include -I rtl/pipeline/core/vsrc/include \
//       -o /tmp/tb_mult rtl/pipeline/soc/ip/mult.v rtl/pipeline/test/tb_mult.sv \
//       && vvp /tmp/tb_mult
//=============================================================================
module tb_mult;

    localparam integer N_LAT    = 4;      // latency the core consumes
    localparam integer M_LAT    = 5;      // extra-stage branch
    localparam integer N_RANDOM = 20000;
    localparam integer M_RANDOM = 500;
    localparam integer DV_N     = 26;     // directed value count

    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    //---- 33x33 reference ----------------------------------------------------
    function [63:0] ref_prod;
        input [32:0] x;
        input [32:0] y;
        reg signed [32:0] xs;
        reg signed [32:0] ys;
        reg signed [65:0] p;
        begin
            xs = x;
            ys = y;
            p  = xs * ys;
            ref_prod = p[63:0];
        end
    endfunction

    //---- DUT: latency 4 -----------------------------------------------------
    reg  [32:0] a4;
    reg  [32:0] b4;
    reg         ce4 = 1'b1;
    wire [63:0] p4;

    mult #(.PIPELINE_STAGES(N_LAT)) dut4 (
        .CLK (clk),
        .CE  (ce4),
        .A   (a4),
        .B   (b4),
        .P   (p4)
    );

    // 4-deep shadow of what the DUT owes us: exp4[3] is the product that must
    // be on p4 right now; a4_h/b4_h keep the matching operands for messages.
    reg [63:0] exp4 [0:3];
    reg [32:0] a4_h [0:3];
    reg [32:0] b4_h [0:3];

    integer i;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            exp4[i] = 64'b0;
            a4_h[i] = 33'b0;
            b4_h[i] = 33'b0;
        end
    end

    always @(posedge clk) begin
        if (ce4) begin
            checks = checks + 1;
            if (p4 !== exp4[3]) begin
                errors = errors + 1;
                $display("ERROR [lat4] %09x * %09x : expected %016x got %016x (t=%0t)",
                         a4_h[3], b4_h[3], exp4[3], p4, $time);
            end
            exp4[3] <= exp4[2];
            exp4[2] <= exp4[1];
            exp4[1] <= exp4[0];
            exp4[0] <= ref_prod(a4, b4);
            a4_h[3] <= a4_h[2];
            a4_h[2] <= a4_h[1];
            a4_h[1] <= a4_h[0];
            a4_h[0] <= a4;
            b4_h[3] <= b4_h[2];
            b4_h[2] <= b4_h[1];
            b4_h[1] <= b4_h[0];
            b4_h[0] <= b4;
        end
    end

    //---- DUT: latency 5 (tail-register branch) ------------------------------
    reg  [32:0] a5;
    reg  [32:0] b5;
    wire [63:0] p5;
    reg         pm_check = 1'b0;

    mult #(.PIPELINE_STAGES(M_LAT)) dut5 (
        .CLK (clk),
        .CE  (1'b1),
        .A   (a5),
        .B   (b5),
        .P   (p5)
    );

    reg [63:0] exp5 [0:4];
    integer j;
    initial begin
        for (j = 0; j < 5; j = j + 1) exp5[j] = 64'b0;
    end

    always @(posedge clk) begin
        if (pm_check) begin
            checks = checks + 1;
            if (p5 !== exp5[4]) begin
                errors = errors + 1;
                $display("ERROR [lat5] expected %016x got %016x (t=%0t)",
                         exp5[4], p5, $time);
            end
        end
        exp5[4] <= exp5[3];
        exp5[3] <= exp5[2];
        exp5[2] <= exp5[1];
        exp5[1] <= exp5[0];
        exp5[0] <= ref_prod(a5, b5);
    end

    //---- directed values ----------------------------------------------------
    // Both sides of every split boundary (bit 16 / bit 17 of each operand).
    reg [32:0] dv [0:DV_N-1];
    initial begin
        dv[ 0] = 33'h0_0000_0000;   //  0
        dv[ 1] = 33'h0_0000_0001;   //  1
        dv[ 2] = 33'h1_FFFF_FFFF;   // -1
        dv[ 3] = 33'h0_0000_FFFF;
        dv[ 4] = 33'h0_0001_0000;   //  2^16
        dv[ 5] = 33'h0_0001_FFFF;   //  split - 1
        dv[ 6] = 33'h0_0002_0000;   //  2^17 (split boundary)
        dv[ 7] = 33'h0_0003_FFFF;
        dv[ 8] = 33'h0_7FFF_FFFF;
        dv[ 9] = 33'h0_8000_0000;   //  INT32_MIN as a positive 33-bit value
        dv[10] = 33'h0_FFFF_FFFF;   //  UINT32_MAX
        dv[11] = 33'h1_0000_0000;   // -2^32
        dv[12] = 33'h1_0000_0001;   // -2^32+1
        dv[13] = 33'h1_8000_0000;   // -2^31
        dv[14] = 33'h1_FFFF_0000;
        dv[15] = 33'h1_FFFE_FFFF;
        dv[16] = 33'h0_0000_0002;
        dv[17] = 33'h0_1234_5678;
        dv[18] = 33'h1_EDCB_A988;
        dv[19] = 33'h0_0002_0001;
        dv[20] = 33'h0_0001_0001;
        dv[21] = 33'h1_FFFF_FFFE;
        dv[22] = 33'h0_5555_5555;
        dv[23] = 33'h1_AAAA_AAAA;
        dv[24] = 33'h0_0000_8000;
        dv[25] = 33'h0_0000_7FFF;
    end

    //---- stimulus -----------------------------------------------------------
    integer k;
    integer m;
    reg [31:0] r1;
    reg [31:0] r2;
    reg [63:0] hold;

    initial begin
        a4 = 33'b0;
        b4 = 33'b0;
        a5 = 33'b0;
        b5 = 33'b0;

        // let the pipeline fill with the zero operands
        repeat (6) @(negedge clk);

        // 1) directed x directed, back to back
        for (k = 0; k < DV_N; k = k + 1) begin
            for (m = 0; m < DV_N; m = m + 1) begin
                @(negedge clk);
                a4 = dv[k];
                b4 = dv[m];
            end
        end

        // 2) random mix: full positive, mixed sign, small, full signed
        for (k = 0; k < N_RANDOM; k = k + 1) begin
            @(negedge clk);
            r1 = $urandom;
            r2 = $urandom;
            case (k % 4)
                0: begin
                    a4 = {1'b0, r1};
                    b4 = {1'b0, r2};
                end
                1: begin
                    a4 = {1'b1, r1};
                    b4 = {1'b0, r2};
                end
                2: begin
                    a4 = {1'b0, {15'b0, r1[16:0]}};
                    b4 = {1'b0, {15'b0, r2[16:0]}};
                end
                default: begin
                    a4 = {r1[0], r1};
                    b4 = {r2[0], r2};
                end
            endcase
        end

        // 3) CE low: the result must hold, and the shadow must not shift
        @(negedge clk);
        a4 = 33'h0_0000_1234;
        b4 = 33'h0_0000_5678;
        repeat (10) @(negedge clk);
        hold = p4;
        ce4 = 1'b0;
        repeat (5) @(negedge clk);
        checks = checks + 1;
        if (p4 !== hold) begin
            errors = errors + 1;
            $display("ERROR [ce] result moved while CE was low: %016x -> %016x",
                     hold, p4);
        end
        ce4 = 1'b1;
        repeat (5) @(negedge clk);

        // 4) latency-5 instance: same operands, one extra stage
        pm_check = 1'b1;
        for (k = 0; k < DV_N; k = k + 1) begin
            @(negedge clk);
            a5 = dv[k];
            b5 = dv[DV_N-1-k];
        end
        for (k = 0; k < M_RANDOM; k = k + 1) begin
            @(negedge clk);
            r1 = $urandom;
            r2 = $urandom;
            a5 = {r1[0], r1};
            b5 = {r2[0], r2};
        end
        repeat (8) @(negedge clk);
        pm_check = 1'b0;
        repeat (4) @(negedge clk);

        if (errors == 0) begin
            $display("ALL TESTS PASSED: mult PIPELINE_STAGES=%0d and %0d, %0d checked cycles",
                     N_LAT, M_LAT, checks);
        end else begin
            $display("FAILED: %0d errors over %0d checked cycles", errors, checks);
        end
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
