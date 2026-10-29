module Segment(
    input             DP        ,   // 选择是否启用小数点，低电平不启用，高电平启用
    input             seg_en    ,   // 选择是否启用该数码管，低电平不启用，高电s平启用
    input             mode      ,   // 选择是否需要编码数码管，低电平为不需要，高电平为需要
    input       [6:0] in        ,
    output      [7:0] seg
);

wire [1:0] key;

wire [6:0] seg_num;

MuxKeyWithDefault #(4, 2, 2) key_gen (key, {seg_en, mode}, 2'b00, {
    2'b00, 2'b00,
    2'b01, 2'b00,
    2'b10, 2'b01,
    2'b11, 2'b10
});

MuxKeyWithDefault #(16, 4, 7) encode (seg_num, in[3:0], 7'h7f, {
    4'h0, 7'b0000001,
    4'h1, 7'b1001111,
    4'h2, 7'b0010010,
    4'h3, 7'b0000110,
    4'h4, 7'b1001100,
    4'h5, 7'b0100100,
    4'h6, 7'b0100000,
    4'h7, 7'b0001111,
    4'h8, 7'b0000000,
    4'h9, 7'b0000100,
    4'ha, 7'b0001000,
    4'hb, 7'b1100000,
    4'hc, 7'b0110001,
    4'hd, 7'b1000010,
    4'he, 7'b0110000,
    4'hf, 7'b0111000
});

MuxKeyWithDefault #(3, 2, 7) seg_gen (seg[7:1], key, 7'b1111111, {
    2'b00, 7'b1111111,
    2'b01, in[6:0],
    2'b10, seg_num
});

assign seg[0] = seg_en ? ~DP : 1'b1;

endmodule
