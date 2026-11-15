// guard/sim/tb_l1_redact.sv
//
// RTL 合并 + mask 替换的一致性测试：回放 build/vectors，与金标
// `redact(policy="mask")` 逐字节比对，并比对审计记录（start/len/type）。
// 用法：+dir=build/vectors

`timescale 1ns/1ps

module tb_l1_redact;

    localparam int MAXB = 4096;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n    = 1'b0;
    logic       in_valid = 1'b0;
    logic       in_last  = 1'b0;
    logic [7:0] in_char  = 8'h00;

    wire        out_valid;
    wire [7:0]  out_char;
    wire        a_valid;
    wire [31:0] a_start;
    wire [7:0]  a_len;
    wire [3:0]  a_type;
    wire        done, ovf;
    wire [15:0] dropped;

    l1_redact_top dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .out_valid(out_valid), .out_char(out_char),
        .a_valid(a_valid), .a_start(a_start), .a_len(a_len), .a_type(a_type),
        .done(done), .ovf(ovf), .dropped(dropped)
    );

    logic [7:0] obuf [0:MAXB-1];
    int obytes;
    int as [0:1023];
    int al [0:1023];
    int at [0:1023];
    int an;

    always @(posedge clk) begin
        if (out_valid) begin
            if (obytes < MAXB) obuf[obytes] = out_char;
            obytes++;
        end
        if (a_valid) begin
            if (an < 1024) begin
                as[an] = int'(a_start);
                al[an] = int'(a_len);
                at[an] = int'(a_type);
            end
            an++;
        end
    end

    string vdir, in_path, out_path;
    int    mfd, cfd, ofd, c, idx;

    initial begin
        if (!$value$plusargs("dir=%s", vdir)) vdir = "build/vectors";
        mfd = $fopen($sformatf("%s/manifest.txt", vdir), "r");
        if (mfd == 0) begin
            $display("FAIL: no manifest in %s", vdir);
            $fatal(1);
        end

        while ($fscanf(mfd, "%d\n", idx) == 1) begin
            cases++;
            in_path  = $sformatf("%s/case_%04d.in",  vdir, idx);
            out_path = $sformatf("%s/case_%04d.mask", vdir, idx);
            ofd = $fopen(out_path, "rb");
            if (ofd == 0) begin
                $display("FAIL: no golden mask for case %0d", idx);
                $fatal(1);
            end

            rst_n = 1'b0; in_valid = 1'b0; in_last = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
            obytes = 0; an = 0;

            cfd = $fopen(in_path, "rb");
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
            $fclose(cfd);

            begin
                int waited = 0;
                while (!done && waited < 4096) begin
                    @(negedge clk);
                    waited++;
                end
                if (!done) begin
                    $display("FAIL case %0d: no done after %0d cycles", idx, waited);
                    errors++;
                end
                // 让监视器多采几拍，避免漏掉最后一拍的寄存器输出
                repeat (4) @(negedge clk);
            end

            // 比对审计记录
            begin
                int n = 0;
                int e_start, e_len, e_type;
                int bad = 0;
                int xs [0:1023];
                int xl [0:1023];
                int xt [0:1023];
                int afd = $fopen($sformatf("%s/case_%04d.audit", vdir, idx), "r");
                while ($fscanf(afd, "%d %d %d\n", e_start, e_len, e_type) == 3) begin
                    if (n < 1024) begin xs[n] = e_start; xl[n] = e_len; xt[n] = e_type; end
                    if (n >= an || as[n] != e_start || al[n] != e_len || at[n] != e_type) bad = 1;
                    n++;
                end
                $fclose(afd);
                if (n != an) bad = 1;
                if (bad) begin
                    errors++;
                    if (errors <= 3) begin
                        $display("FAIL case %0d: audit differs", idx);
                        for (int i = 0; i < n; i++) $display("  exp %0d+%0d t=%0d", xs[i], xl[i], xt[i]);
                        for (int i = 0; i < an; i++) $display("  got %0d+%0d t=%0d", as[i], al[i], at[i]);
                    end
                end
            end

            // 比对字节流
            begin
                int ebytes = 0;
                int mismatch = 0;
                while ((c = $fgetc(ofd)) != -1) begin
                    if (ebytes >= MAXB || obytes < ebytes + 1) begin
                        mismatch = 1;
                    end else if (obuf[ebytes] != c[7:0]) begin
                        mismatch = 1;
                    end
                    ebytes++;
                end
                $fclose(ofd);
                if (ebytes != obytes) mismatch = 1;
                if (mismatch) begin
                    $display("FAIL case %0d: mask bytes differ (exp %0d, got %0d)", idx, ebytes, obytes);
                    errors++;
                    if (errors > 5) $fatal(1, "too many failures");
                end
            end
        end

        $fclose(mfd);
        $display("redact cases=%0d errors=%0d", cases, errors);
        $finish;
    end

    int cases = 0;
    int errors = 0;

endmodule
