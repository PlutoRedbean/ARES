`timescale 1ns/1ps
// L2b 实体层位级 TB：喂 .in 字节流，比对金标生成的 (start, len, type)。
module tb_l2_entity;
    localparam int MAXS = 32;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0, in_valid = 0, in_last = 0;
    logic [7:0] in_char = 0;

    wire ov;
    wire [31:0] os;
    wire [7:0]  ol;
    wire [3:0]  ot;

    l2_entity dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .out_valid(ov), .out_start(os), .out_len(ol), .out_type(ot)
    );

    int got_s[MAXS], got_l[MAXS], got_t[MAXS];
    int got_n = 0;

    always_ff @(posedge clk) begin
        if (ov && got_n < MAXS) begin
            got_s[got_n] = int'(os);
            got_l[got_n] = int'(ol);
            got_t[got_n] = int'(ot);
            got_n = got_n + 1;
        end
    end

    string dir;
    int fd, i, errors, ncase, n_exp;
    byte unsigned b;
    int exp_s[MAXS], exp_l[MAXS], exp_t[MAXS];

    initial begin
        if (!$value$plusargs("dir=%s", dir)) begin $display("need +dir"); $finish; end
        fd = $fopen({dir, "/manifest.txt"}, "r");
        if (fd == 0) begin $display("no manifest"); $finish; end
        errors = 0;
        begin : loop_outer
        forever begin
            if ($fscanf(fd, "%d\n", ncase) != 1) disable loop_outer;
            begin : one
                string pin, pexp;
                int fin;
                $sformat(pin,  "%s/case_%04d.in",  dir, ncase);
                $sformat(pexp, "%s/case_%04d.exp", dir, ncase);

                rst_n = 0; in_valid = 0; in_last = 0; got_n = 0;
                repeat (4) @(negedge clk);
                rst_n = 1;
                repeat (2) @(negedge clk);

                fin = $fopen(pin, "rb");
                while (!$feof(fin)) begin
                    b = 0;
                    if ($fread(b, fin) == 1) begin
                        in_valid = 1; in_char = b;
                        @(negedge clk);
                    end
                end
                $fclose(fin);
                in_valid = 0;
                @(negedge clk);
                in_last = 1;
                @(negedge clk);
                in_last = 0;
                repeat (4) @(negedge clk);

                n_exp = 0;
                fin = $fopen(pexp, "r");
                while (!$feof(fin)) begin
                    int s, l, t;
                    if ($fscanf(fin, "%d %d %d\n", s, l, t) == 3) begin
                        exp_s[n_exp] = s; exp_l[n_exp] = l; exp_t[n_exp] = t;
                        n_exp = n_exp + 1;
                    end
                end
                $fclose(fin);

                if (n_exp != got_n) begin
                    errors = errors + 1;
                    $display("FAIL case %0d: spans exp %0d got %0d", ncase, n_exp, got_n);
                end else begin
                    for (i = 0; i < n_exp; i = i + 1) begin
                        if (exp_s[i] != got_s[i] || exp_l[i] != got_l[i] || exp_t[i] != got_t[i]) begin
                            errors = errors + 1;
                            $display("FAIL case %0d span %0d: exp %0d+%0d t%0d, got %0d+%0d t%0d",
                                     ncase, i, exp_s[i], exp_l[i], exp_t[i],
                                     got_s[i], got_l[i], got_t[i]);
                        end
                    end
                end
            end
        end
        end
        $display("entity cases=%0d errors=%0d", ncase + 1, errors);
        if (errors == 0) $display("PASS: L2b entity layer matches golden");
        else $fatal(1, "entity mismatch");
        $finish;
    end
endmodule
