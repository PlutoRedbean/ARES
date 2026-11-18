`timescale 1ns/1ps
module tb_ner_probe;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0, in_valid = 0, in_last = 0;
    logic [7:0] in_char = 0;
    wire ov, busy; wire [31:0] os; wire [7:0] ol; wire [3:0] ot;

    l2_ner dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_char(in_char),
                .in_last(in_last), .out_valid(ov), .out_start(os), .out_len(ol),
                .out_type(ot), .busy(busy));

    string s;
    int i;
    logic seen = 0;
    always @(posedge clk) begin
        if (!seen && dut.st == 4'(dut.S_EMB)) begin
            $display("S_EMB start: ntok=%0d nbyte=%0d tid0=%0d", dut.ntok, dut.nbyte, dut.tok_id[0]);
            #1 $display("  emb_addr=%0d emb_data=%0d rom0=%0d rom7136=%0d",
                        dut.emb_addr, dut.emb_data, dut.u_rom.emb[0], dut.u_rom.emb[7136]);
            seen = 1;
        end
    end
    initial begin
        if (!$value$plusargs("str=%s", s)) s = "王经理";
        repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        for (i = 0; i < s.len(); i++) begin
            while (busy) @(negedge clk);
            in_valid = 1; in_char = s[i]; @(negedge clk);
        end
        in_valid = 0; @(negedge clk); in_last = 1; @(negedge clk); in_last = 0;
        wait (!busy); repeat (4) @(negedge clk);
        $display("ntok=%0d nbyte=%0d", dut.ntok, dut.nbyte);
        for (i = 0; i < 6; i++) $display("tok %0d id=%0d off=%0d len=%0d", i, dut.tok_id[i], dut.tok_off[i], dut.tok_len[i]);
        for (i = 0; i < 6; i++) $display("lab %0d = %0d", i, dut.lab[i]);
        for (i = 0; i < 8; i++) $display("x0_%0d=%0d h1_0_%0d=%0d h2_0_%0d=%0d", i, $signed(dut.x[i]), i, $signed(dut.h1[i]), i, $signed(dut.h2[i]));
        for (i = 0; i < 3; i++) $display("logit0_%0d=%0d", i, $signed(dut.best));
        repeat (2) @(negedge clk);
        $finish;
    end
endmodule