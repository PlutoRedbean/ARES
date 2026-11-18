`timescale 1ns/1ps
module tb_ner_probe;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0, in_valid = 0, in_last = 0;
    logic [7:0] in_char = 0;
    wire ov, busy; wire [31:0] os; wire [7:0] ol; wire [3:0] ot;
    l2_ner dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_char(in_char),
                .in_last(in_last), .out_valid(ov), .out_start(os), .out_len(ol),
                .out_type(ot), .busy(busy));

    string path;
    int fd, i;
    byte unsigned b;
    initial begin
        if (!$value$plusargs("file=%s", path)) path = "build/ner_vectors/case_0004.in";
        repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        fd = $fopen(path, "rb");
        while (!$feof(fd)) begin
            b = 0;
            if ($fread(b, fd) == 1) begin
                while (busy) @(negedge clk);
                in_valid = 1; in_char = b; @(negedge clk);
            end
        end
        $fclose(fd);
        in_valid = 0; @(negedge clk); in_last = 1; @(negedge clk); in_last = 0;
        wait (!busy); repeat (4) @(negedge clk);
        $display("ntok=%0d", dut.ntok);
        for (i = 0; i < 16; i = i + 1) $display("lab %0d = %0d  off=%0d len=%0d", i, dut.lab[i], dut.tok_off[i], dut.tok_len[i]);
        $finish;
    end
endmodule
