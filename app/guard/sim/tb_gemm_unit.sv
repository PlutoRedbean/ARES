`timescale 1ns/1ps
module tb_gemm_unit;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0, in_valid = 0;
    logic [63:0] feat = 0;
    wire ov; wire [1:0] cls; wire [31:0] s0, s1, s2, s3;

    l2_int4_gemm dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_feat(feat),
        .out_valid(ov), .out_class(cls), .out_s0(s0), .out_s1(s1), .out_s2(s2), .out_s3(s3));

    task automatic run(input logic [63:0] f, input string name);
        begin
            feat = f;
            in_valid = 1; @(negedge clk); in_valid = 0;
            repeat (60) @(negedge clk);
            $display("%s: class=%0d s=%0d,%0d,%0d,%0d", name, cls, $signed(s0), $signed(s1), $signed(s2), $signed(s3));
            $display("   feat=%016h", feat);
            $display("   A1 row0=%0d,%0d,%0d,%0d", $signed(dut.a_tile1[7:0]), $signed(dut.a_tile1[15:8]), $signed(dut.a_tile1[23:16]), $signed(dut.a_tile1[31:24]));
            $display("   A1 row1=%0d,%0d,%0d,%0d", $signed(dut.a_tile1[39:32]), $signed(dut.a_tile1[47:40]), $signed(dut.a_tile1[55:48]), $signed(dut.a_tile1[63:56]));
            $display("   B1 row0=%0d,%0d,%0d,%0d", $signed(dut.b_tile1[7:0]), $signed(dut.b_tile1[15:8]), $signed(dut.b_tile1[23:16]), $signed(dut.b_tile1[31:24]));
            $display("   C1 = %0d %0d %0d %0d", $signed(dut.c1_q[0*128 +: 32]), $signed(dut.c1_q[1*128 +: 32]), $signed(dut.c1_q[2*128 +: 32]), $signed(dut.c1_q[3*128 +: 32]));
            $display("   C2 = %0d %0d %0d %0d", $signed(dut.c2_q[0*128 +: 32]), $signed(dut.c2_q[1*128 +: 32]), $signed(dut.c2_q[2*128 +: 32]), $signed(dut.c2_q[3*128 +: 32]));
            $display("   A2 row1=%0d,%0d,%0d,%0d", $signed(dut.a_tile2[39:32]), $signed(dut.a_tile2[47:40]), $signed(dut.a_tile2[55:48]), $signed(dut.a_tile2[63:56]));
            $display("   B2 col0=%0d,%0d,%0d,%0d", $signed(dut.b_tile2[7:0]), $signed(dut.b_tile2[39:32]), $signed(dut.b_tile2[71:64]), $signed(dut.b_tile2[103:96]));
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        // 银行卡：k_bank=1 (byte1), len_b=1 (byte5), bias=1 (byte7) -> 期望 [2,-5,7,-5]
        run(64'h01_00_01_00_00_00_01_00, "bank");
        // 身份证：k_id=1 -> 期望 [2,7,-5,-5]
        run(64'h01_00_01_00_00_00_00_01, "id18");
        // 无关键词 -> [2,-5,-5,-5]... 注意 dist=3 (byte4=3) 时 y=6-6+1=1
        run(64'h01_00_01_03_00_00_00_00, "none");
        $finish;
    end
endmodule