`timescale 1ns/1ps
// ROM 回读自检：几个固定地址的值必须和 weights_int8.npz 一致。
module tb_l2_ner_rom;
    logic [15:0] emb_addr = 0;
    logic [11:0] c1_addr = 0, c2_addr = 0;
    logic [4:0]  c1b_addr = 0, c2b_addr = 0;
    logic [7:0]  h_addr = 0;
    logic [1:0]  hb_addr = 0;
    wire [7:0] emb_d, c1_d, c2_d, h_d;
    wire signed [31:0] c1b_d, c2b_d, hb_d;

    l2_ner_rom dut (
        .emb_addr(emb_addr), .emb_data(emb_d),
        .conv1_addr(c1_addr), .conv1_data(c1_d),
        .conv1_b_addr(c1b_addr), .conv1_b_data(c1b_d),
        .conv2_addr(c2_addr), .conv2_data(c2_d),
        .conv2_b_addr(c2b_addr), .conv2_b_data(c2b_d),
        .head_addr(h_addr), .head_data(h_d),
        .head_b_addr(hb_addr), .head_b_data(hb_d)
    );

    initial begin
        #1;
        for (int a = 0; a < 4; a++) begin
            emb_addr = a; #1; $display("EMB %0d %0d", a, $signed(emb_d));
        end
        for (int a = 0; a < 4; a++) begin
            c1_addr = a; #1; $display("C1 %0d %0d", a, $signed(c1_d));
            c2_addr = a; #1; $display("C2 %0d %0d", a, $signed(c2_d));
        end
        c1b_addr = 0; c2b_addr = 0; hb_addr = 0; h_addr = 0; #1;
        $display("C1B0 %0d", c1b_d);
        $display("C2B0 %0d", c2b_d);
        $display("HB0 %0d", hb_d);
        $display("H0 %0d", $signed(h_d));
        $finish;
    end
endmodule
