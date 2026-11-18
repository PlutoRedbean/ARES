`timescale 1ns/1ps
module tb_ner_doc;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0, in_valid = 0, in_last = 0;
    logic [7:0] in_char = 0;
    wire out_valid; wire [7:0] out_char;
    wire a_valid; wire [31:0] a_start; wire [7:0] a_len; wire [3:0] a_type;
    wire done, ovf, busy_l2b, kw_valid; wire [2:0] kw_kid; wire [15:0] dropped;

    l1_redact_top #(.USE_NER(1'b1)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .out_valid(out_valid), .out_char(out_char),
        .a_valid(a_valid), .a_start(a_start), .a_len(a_len), .a_type(a_type),
        .done(done), .ovf(ovf), .dropped(dropped),
        .kw_valid(kw_valid), .kw_kid(kw_kid), .busy_l2b(busy_l2b)
    );

    string path;
    int fd, cyc, b;
    initial begin
        if (!$value$plusargs("file=%s", path)) path = "sim/doc_case.txt";
        repeat (4) @(negedge clk); rst_n = 1; repeat (3) @(negedge clk);
        fd = $fopen(path, "rb");
        while (!$feof(fd)) begin
            b = $fgetc(fd);
            if (b >= 0) begin
                while (busy_l2b) @(negedge clk);
                in_valid = 1; in_char = b[7:0]; @(negedge clk);
            end
        end
        $fclose(fd);
        in_valid = 0; @(negedge clk); in_last = 1; @(negedge clk); in_last = 0;
        for (cyc = 0; cyc < 12000000; cyc = cyc + 1) begin
            @(negedge clk);
            if (out_valid) $write("%02x", out_char);
            if (done) cyc = 12000000;
        end
        $display("");
        $finish;
    end
endmodule