// guard/sim/tb_l1_engine.sv
//
// 一致性测试：按 1 字节/拍回放 build/vectors 的用例，逐类型比对命中。
// 每个引擎单独记录命中的 (start,len)，与 .exp 中同类型的行按顺序比较。
//
// 用法：+dir=build/vectors

`timescale 1ns/1ps

module tb_l1_engine;

    localparam int MAXHITS = 4096;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n    = 1'b0;
    logic       in_valid = 1'b0;
    logic       in_last  = 1'b0;
    logic [7:0] in_char  = 8'h00;

    wire        digit_valid;
    wire [31:0] digit_start;
    wire [7:0]  digit_len;
    wire [2:0]  digit_type;
    wire        email_valid, ipv4_valid, uscc_valid, plate_valid;
    wire        kw_valid;
    wire [31:0] kw_start;
    wire [7:0]  kw_len;
    wire [2:0]  kw_kid;
    wire [31:0] email_start, ipv4_start, uscc_start, plate_start;
    wire [7:0]  email_len, ipv4_len, uscc_len, plate_len;

    l1_engine dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .digit_valid(digit_valid), .digit_start(digit_start), .digit_len(digit_len), .digit_type(digit_type),
        .email_valid(email_valid), .email_start(email_start), .email_len(email_len),
        .ipv4_valid(ipv4_valid),   .ipv4_start(ipv4_start),   .ipv4_len(ipv4_len),
        .uscc_valid(uscc_valid),   .uscc_start(uscc_start),   .uscc_len(uscc_len),
        .plate_valid(plate_valid), .plate_start(plate_start), .plate_len(plate_len),
        .kw_valid(kw_valid), .kw_start(kw_start), .kw_len(kw_len), .kw_kid(kw_kid)
    );

    // 每类型一份命中记录
    int a_start [0:8][0:MAXHITS-1];
    int a_len   [0:8][0:MAXHITS-1];
    int a_n     [0:8];

    int x_start [0:8][0:MAXHITS-1];
    int x_len   [0:8][0:MAXHITS-1];
    int x_n     [0:8];

    int errors = 0;
    int cases  = 0;
    int running = 0;

    task automatic rec(input int t, input [31:0] st, input [7:0] ln);
        if (a_n[t] < MAXHITS) begin
            a_start[t][a_n[t]] = int'(st);
            a_len[t][a_n[t]]   = int'(ln);
        end
        a_n[t]++;
    endtask

    always @(posedge clk) begin
        if (running) begin
            if (digit_valid) rec(int'(digit_type), digit_start, digit_len);
            if (email_valid) rec(5, email_start, email_len);
            if (ipv4_valid)  rec(6, ipv4_start,  ipv4_len);
            if (uscc_valid)  rec(7, uscc_start,  uscc_len);
            if (plate_valid) rec(8, plate_start, plate_len);
        end
    end

    task automatic do_reset();
        rst_n    = 1'b0;
        in_valid = 1'b0;
        in_last  = 1'b0;
        running  = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        for (int t = 1; t <= 8; t++) a_n[t] = 0;
        running = 1;
    endtask

    string vdir, in_path, exp_path;
    int    mfd, cfd, efd, c, idx;

    initial begin
        if (!$value$plusargs("dir=%s", vdir)) vdir = "build/vectors";
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
            repeat (4) @(negedge clk);
            $fclose(cfd);

            for (int t = 1; t <= 8; t++) x_n[t] = 0;
            efd = $fopen(exp_path, "r");
            if (efd == 0) begin
                $display("FAIL: cannot open %s", exp_path);
                errors++;
                continue;
            end
            begin
                int e_start, e_len, e_type;
                while ($fscanf(efd, "%d %d %d\n", e_start, e_len, e_type) == 3) begin
                    if (e_type >= 1 && e_type <= 8 && x_n[e_type] < MAXHITS) begin
                        x_start[e_type][x_n[e_type]] = e_start;
                        x_len[e_type][x_n[e_type]]   = e_len;
                    end
                    x_n[e_type]++;
                end
            end
            $fclose(efd);

            begin
                int bad = 0;
                for (int t = 1; t <= 8; t++) begin
                    if (x_n[t] != a_n[t]) bad = 1;
                    for (int i = 0; i < x_n[t] && i < a_n[t]; i++) begin
                        if (x_start[t][i] != a_start[t][i] || x_len[t][i] != a_len[t][i]) bad = 1;
                    end
                end
                if (bad) begin
                    errors++;
                    if (errors <= 5) begin
                        $display("FAIL case %0d", idx);
                        for (int t = 1; t <= 8; t++) begin
                            if (x_n[t] != a_n[t] || x_n[t] > 0) begin
                                $write("  type %0d exp n=%0d [", t, x_n[t]);
                                for (int i = 0; i < x_n[t]; i++) $write("%0d+%0d ", x_start[t][i], x_len[t][i]);
                                $write("] got n=%0d [", a_n[t]);
                                for (int i = 0; i < a_n[t]; i++) $write("%0d+%0d ", a_start[t][i], a_len[t][i]);
                                $display("]");
                            end
                        end
                    end
                end
            end
        end

        $fclose(mfd);
        $display("cases=%0d errors=%0d", cases, errors);
        if (errors != 0) $fatal(1, "L1 engine mismatch");
        $display("PASS: L1 engine matches golden vectors");
        $finish;
    end

endmodule
