// guard/sim/tb_l1_digit_engine.sv
//
// 回放 build/vectors 下的用例：把 .in 的字节逐个喂给 l1_digit_engine，
// 与 .exp（每行 "start len type"）逐条比对。
//
// 用法：+dir=build/vectors

`timescale 1ns/1ps

module tb_l1_digit_engine;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n    = 1'b0;
    logic       in_valid = 1'b0;
    logic       in_last  = 1'b0;
    logic [7:0] in_char  = 8'h00;

    wire        out_valid;
    wire [31:0] out_start;
    wire [7:0]  out_len;
    wire [2:0]  out_type;

    l1_digit_engine dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .out_valid(out_valid),
        .out_start(out_start),
        .out_len  (out_len),
        .out_type (out_type)
    );

    int starts [0:1023];
    int lens   [0:1023];
    int types  [0:1023];
    int nhits;

    int errors = 0;
    int cases  = 0;

    task automatic record_hit();
        if (out_valid) begin
            if (nhits < 1024) begin
                starts[nhits] = int'(out_start);
                lens[nhits]   = int'(out_len);
                types[nhits]  = int'(out_type);
            end
            nhits++;
        end
    endtask

    task automatic do_reset();
        rst_n    = 1'b0;
        in_valid = 1'b0;
        in_last  = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        nhits = 0;
    endtask

    // 一个字符占两个 negedge，中间的 posedge 让 DUT 采样。
    task automatic feed(input logic [7:0] ch);
        @(negedge clk);
        in_valid = 1'b1;
        in_char  = ch;
        @(negedge clk);
        in_valid = 1'b0;
        record_hit();
    endtask

    task automatic flush();
        @(negedge clk);
        in_last  = 1'b1;
        in_valid = 1'b0;
        @(negedge clk);
        in_last = 1'b0;
        record_hit();
    endtask

    string vdir;
    string in_path;
    string exp_path;
    int    mfd;
    int    cfd;
    int    efd;
    int    c;
    int    idx;

    initial begin
        if (!$value$plusargs("dir=%s", vdir)) vdir = "build/vectors";

        mfd = $fopen($sformatf("%s/manifest.txt", vdir), "r");
        if (mfd == 0) begin
            $display("FAIL: cannot open manifest in %s", vdir);
            $fatal(1);
        end

        while ($fscanf(mfd, "%d\n", idx) == 1) begin
            cases++;
            do_reset();

            in_path  = $sformatf("%s/case_%04d.in",  vdir, idx);
            exp_path = $sformatf("%s/case_%04d.exp", vdir, idx);

            cfd = $fopen(in_path, "rb");
            if (cfd == 0) begin
                $display("FAIL: cannot open %s", in_path);
                errors++;
                continue;
            end
            while ((c = $fgetc(cfd)) != -1) feed(c[7:0]);
            $fclose(cfd);
            flush();

            efd = $fopen(exp_path, "r");
            if (efd == 0) begin
                $display("FAIL: cannot open %s", exp_path);
                errors++;
                continue;
            end

            begin
                int exp_n = 0;
                int ok    = 1;
                int e_start;
                int e_len;
                int e_type;
                while ($fscanf(efd, "%d %d %d\n", e_start, e_len, e_type) == 3) begin
                    if (exp_n >= nhits ||
                        starts[exp_n] != e_start ||
                        lens[exp_n]   != e_len   ||
                        types[exp_n]  != e_type) begin
                        ok = 1'b0;
                        if (errors < 5) begin
                            $display("  mismatch case=%0d idx=%0d exp=(%0d,%0d,%0d) got=(%0d,%0d,%0d)",
                                     idx, exp_n, e_start, e_len, e_type,
                                     (exp_n < nhits) ? starts[exp_n] : -1,
                                     (exp_n < nhits) ? lens[exp_n]   : -1,
                                     (exp_n < nhits) ? types[exp_n]  : -1);
                        end
                    end
                    exp_n++;
                end
                $fclose(efd);
                if (exp_n != nhits) ok = 0;
                if (!ok) begin
                    errors++;
                    $display("FAIL: case %0d (exp %0d hits, got %0d)", idx, exp_n, nhits);
                end
            end
        end

        $fclose(mfd);
        $display("cases=%0d errors=%0d", cases, errors);
        if (errors != 0) $fatal(1, "L1 digit engine mismatch");
        $display("PASS: L1 digit engine matches golden vectors");
        $finish;
    end

endmodule
