module Comparator(
  input  [31:0] din1      ,
  input  [31:0] din2      ,
  output        less      ,
  output        equal     ,
  output        greater
);

  cmp32 cmp32_inst(din1, din2, 1'd0, 1'd1, 1'd0, less, equal, greater);

endmodule

module cmp32(
  input  [31:0] io_a       ,
  input  [31:0] io_b       ,
  input         less_in    ,
  input         equal_in   ,
  input         greater_in ,
  output        io_less    ,
  output        io_equal   ,
  output        io_greater
);

  wire [1:0] less   ;
  wire [1:0] equal  ;
  wire [1:0] greater;

  cmp16 cmp16_inst0(io_a[15: 0], io_b[15: 0], less_in, equal_in, greater_in, less[0], equal[0], greater[0]);
  cmp16 cmp16_inst1(io_a[31:16], io_b[31:16], less[0], equal[0], greater[0], less[1], equal[1], greater[1]);

  assign io_equal   = equal[1]  ;
  assign io_less    = less[1]   ;
  assign io_greater = greater[1];

endmodule

module cmp16(
  input  [15:0] io_a       ,
  input  [15:0] io_b       ,
  input         less_in    ,
  input         equal_in   ,
  input         greater_in ,
  output        io_less    ,
  output        io_equal   ,
  output        io_greater
);

  wire [3:0] less   ;
  wire [3:0] equal  ;
  wire [3:0] greater;

  cmp4 cmp4_inst0(io_a[ 3: 0], io_b[ 3: 0], 1'b0, 1'b1, 1'b0, less[0], equal[0], greater[0]);
  cmp4 cmp4_inst1(io_a[ 7: 4], io_b[ 7: 4], 1'b0, 1'b1, 1'b0, less[1], equal[1], greater[1]);
  cmp4 cmp4_inst2(io_a[11: 8], io_b[11: 8], 1'b0, 1'b1, 1'b0, less[2], equal[2], greater[2]);
  cmp4 cmp4_inst3(io_a[15:12], io_b[15:12], 1'b0, 1'b1, 1'b0, less[3], equal[3], greater[3]);

  assign io_equal   = equal_in & equal[0] & equal[1] & equal[2] & equal[3];
  assign io_less    = less[3] |
                      less[2] & equal[3] |
                      less[1] & equal[2] & equal[3] |
                      less[0] & equal[1] & equal[2] & equal[3] |
                      less_in & equal[0] & equal[1] & equal[2] & equal[3];
  assign io_greater = greater[3] |
                      greater[2] & equal[3] |
                      greater[1] & equal[2] & equal[3] |
                      greater[0] & equal[1] & equal[2] & equal[3] |
                      greater_in & equal[0] & equal[1] & equal[2] & equal[3];

endmodule

module cmp4(
  input  [3:0] io_a       ,
  input  [3:0] io_b       ,
  input        less_in    ,
  input        equal_in   ,
  input        greater_in ,
  output       io_less    ,
  output       io_equal   ,
  output       io_greater
);

  wire [3:0] less   ;
  wire [3:0] equal  ;
  wire [3:0] greater;

  cmp1 cmp1_inst0(io_a[0], io_b[0], less[0], equal[0], greater[0]);
  cmp1 cmp1_inst1(io_a[1], io_b[1], less[1], equal[1], greater[1]);
  cmp1 cmp1_inst2(io_a[2], io_b[2], less[2], equal[2], greater[2]);
  cmp1 cmp1_inst3(io_a[3], io_b[3], less[3], equal[3], greater[3]);

  assign io_equal   = equal_in & equal[0] & equal[1] & equal[2] & equal[3];
  assign io_less    = less[3] |
                      less[2] & equal[3] |
                      less[1] & equal[2] & equal[3] |
                      less[0] & equal[1] & equal[2] & equal[3] |
                      less_in & equal[0] & equal[1] & equal[2] & equal[3];
  assign io_greater = greater[3] |
                      greater[2] & equal[3] |
                      greater[1] & equal[2] & equal[3] |
                      greater[0] & equal[1] & equal[2] & equal[3] |
                      greater_in & equal[0] & equal[1] & equal[2] & equal[3];

endmodule

module cmp1(
  input  a        ,
  input  b        ,
  output less     ,
  output equal    ,
  output greater
);

  assign less    = ~a &  b;
  assign equal   =  a ~^ b;
  assign greater =  a & ~b;

endmodule
