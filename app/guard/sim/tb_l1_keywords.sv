// guard/sim/tb_l1_keywords.sv
//
// 关键词匹配器一致性：回放 build/kw 的用例，逐条比对 (start,len,kid)。
// 用法：+dir=build/kw

`timescale 1ns/1ps

module tb_l1_keywords;

    localparam int MAX = 4096;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n    = 1'b0;
    logic       in_valid = 1'b0;
    logic       in_last  = 1'b0;
    logic [7:0] in_char  = 8'h00;

    wire        out_valid;
    wire [31:0] out_start;
    wire [7:0]  out_len;
    wire [2:0]  out_kid;

    l1_keyword_match dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .out_valid(out_valid), .out_start(out_start), .out_len(out_len), .out_kid(out_kid)
    );

    int a_start [0:MAX-1];
    int a_len   [0:MAX-1];
    int a_kid   [0:MAX-1];
    int a_n;

    int x_start [0:MAX-1];
    int x_len   [0:MAX-1];
    int x_kid   [0:MAX-1];

    int errors = 0;
    int cases  = 0;
    int running = 0;

    always @(posedge clk) begin
        if (running && out_valid) begin
            if (a_n < MAX) begin
                a_start[a_n] = int'(out_start);
                a_len[a_n]   = int'(out_len);
                a_kid[a_n]   = int'(out_kid);
            end
            a_n++;
        end
    end

    task automatic do_reset();
        rst_n = 1'b0; in_valid = 1'b0; in_last = 1'b0; running = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        a_n = 0;
        running = 1;
    endtask

    string vdir, in_path, exp_path;
    int    mfd, cfd, efd, c, idx;

    initial begin
        if (!$value$plusargs("dir=%s", vdir)) vdir = "build/kw";
        mfd = $fopen($sformatf("%s/manifest.txt", vdir), "r");
        if (mfd == 0) begin
            $display("FAIL: no manifest in %s", vdir);
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
            @(negedge clk);
            while ((c = $fgetc(cfd)) != -1) begin
                in_valid = 1'b1;
                in_char  = c[7:0];
                @(negedge clk);
            end
            in_valid = 1'b0;
            @(negedge clk);
            in_last = 1'b1;
            @(negedge clk);
            in_last = 1'b0;
            repeat (2) @(negedge clk);
            $fclose(cfd);

            begin
                automatic int n = 0;
                int e_start, e_len, e_kid;
                efd = $fopen(exp_path, "r");
                while ($fscanf(efd, "%d %d %d\n", e_start, e_len, e_kid) == 3) begin
                    x_start[n] = e_start;
                    x_len[n]   = e_len;
                    x_kid[n]   = e_kid;
                    n++;
                end
                $fclose(efd);

                begin
                    automatic int bad = (n != a_n);
                    for (int i = 0; i < n && i < a_n; i++) begin
                        if (x_start[i] != a_start[i] || x_len[i] != a_len[i] || x_kid[i] != a_kid[i])
                            bad = 1;
                    end
                    if (bad) begin
                        errors++;
                        if (errors <= 5) begin
                            $display("FAIL case %0d exp n=%0d got n=%0d", idx, n, a_n);
                            for (int i = 0; i < n; i++) $display("  exp %0d+%0d kid=%0d", x_start[i], x_len[i], x_kid[i]);
                            for (int i = 0; i < a_n; i++) $display("  got %0d+%0d kid=%0d", a_start[i], a_len[i], a_kid[i]);
                        end
                    end
                end
            end
        end

        $fclose(mfd);
        $display("kw cases=%0d errors=%0d", cases, errors);
        if (errors != 0) $fatal(1, "L1 keyword mismatch");
        $display("PASS: L1 keyword matcher matches golden");
        $finish;
    end

endmodule
