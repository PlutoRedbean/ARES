`timescale 1ns/1ps
// L2 语义层位级 TB：把 .in 的字节流打进 l2_semantic_top，逐个游程比对
// 期望文件（.exp）的 class 与 span —— 期望由 host/golden/l2_int4.py 生成。
module tb_l2_int4;
    localparam int MAXRUNS = 64;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    logic in_valid = 0, in_last = 0;
    logic [7:0] in_char = 0;

    wire out_valid;
    wire [1:0] out_class;
    wire [31:0] out_start;
    wire [7:0] out_len;
    wire [31:0] s0, s1, s2, s3;

    l2_semantic_top dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .out_valid(out_valid), .out_class(out_class),
        .out_start(out_start), .out_len(out_len),
        .out_s0(s0), .out_s1(s1), .out_s2(s2), .out_s3(s3)
    );

    // ---- 收到的结果 ----
    int got_start[MAXRUNS];
    int got_len[MAXRUNS];
    int got_class[MAXRUNS];
    int got_n = 0;

    always_ff @(posedge clk) begin
        if (out_valid && got_n < MAXRUNS) begin
            got_start[got_n] = int'(out_start);
            got_len[got_n]   = int'(out_len);
            got_class[got_n] = int'(out_class);
            got_n            = got_n + 1;
        end
    end

    string dir;
    int fd, i, r, errors, ncase;
    byte unsigned b;
    int exp_c[MAXRUNS], exp_l[MAXRUNS], exp_k[MAXRUNS];

    initial begin
        if (!$value$plusargs("dir=%s", dir)) begin
            $display("need +dir=...");
            $finish;
        end
        fd = $fopen({dir, "/manifest.txt"}, "r");
        if (fd == 0) begin $display("no manifest"); $finish; end
        errors = 0;
        begin : loop_outer
        forever begin
            if ($fscanf(fd, "%d\n", ncase) != 1) disable loop_outer;
            begin : one_case
                int n_exp;
                string path_in, path_exp;
                $sformat(path_in,  "%s/case_%04d.in",  dir, ncase);
                $sformat(path_exp, "%s/case_%04d.exp", dir, ncase);

                // 复位
                rst_n = 0; in_valid = 0; in_last = 0; got_n = 0;
                repeat (4) @(negedge clk);
                rst_n = 1;
                repeat (2) @(negedge clk);

                // 喂字节
                begin : feed
                    int fdin;
                    fdin = $fopen(path_in, "rb");
                    while (!$feof(fdin)) begin
                        b = 0;
                        if ($fread(b, fdin) == 1) begin
                            in_valid = 1; in_char = b;
                            @(negedge clk);
                        end
                    end
                    $fclose(fdin);
                end
                in_valid = 0;
                @(negedge clk);
                in_last = 1;
                @(negedge clk);
                in_last = 0;
                // 等 GEMM 流水排空
                repeat (80) @(negedge clk);

                // 读期望
                begin : rd
                    int fe, s, l, k, a, bb, c, d;
                    fe = $fopen(path_exp, "r");
                    n_exp = 0;
                    while (!$feof(fe)) begin
                        if ($fscanf(fe, "%d %d %d %d %d %d %d\n", s, l, k, a, bb, c, d) == 7) begin
                            exp_l[n_exp] = l; exp_k[n_exp] = k; n_exp = n_exp + 1;
                        end
                    end
                    $fclose(fe);
                end

                if (n_exp != got_n) begin
                    errors = errors + 1;
                    $display("FAIL case %0d: runs exp %0d got %0d", ncase, n_exp, got_n);
                end else begin
                    for (i = 0; i < n_exp; i = i + 1) begin
                        if (exp_k[i] != got_class[i] || exp_l[i] != got_len[i]) begin
                            errors = errors + 1;
                            $display("FAIL case %0d run %0d: exp class=%0d len=%0d, got class=%0d len=%0d",
                                     ncase, i, exp_k[i], exp_l[i], got_class[i], got_len[i]);
                        end
                    end
                end
            end
        end
        end
        $display("l2 cases=%0d errors=%0d", ncase + 1, errors);
        if (errors == 0) $display("PASS: L2 semantic layer matches golden");
        else $fatal(1, "L2 mismatch");
        $finish;
    end
endmodule
