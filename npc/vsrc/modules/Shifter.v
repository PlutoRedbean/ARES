`include "ALU_flag_para.vh"
module Shifter #(DATA_WIDTH = 32, SHAMT_WIDTH = 5) (
  input  [DATA_WIDTH  - 1:0] din      ,
  input  [SHAMT_WIDTH - 1:0] shamt    ,
  input  [              3:0] ALU_ctrl ,
  output [DATA_WIDTH  - 1:0] dout
);
  
  wire [DATA_WIDTH  - 1:0] mid0   ;
  wire [DATA_WIDTH  - 1:0] mid1   ;
  wire [DATA_WIDTH  - 1:0] mid2   ;
  wire [DATA_WIDTH  - 1:0] mid3   ;

  wire [DATA_WIDTH  - 1:0] shift0 ;
  wire [DATA_WIDTH  - 1:0] shift1 ;
  wire [DATA_WIDTH  - 1:0] shift2 ;
  wire [DATA_WIDTH  - 1:0] shift3 ;
  wire [DATA_WIDTH  - 1:0] shift4 ;

  wire [DATA_WIDTH  - 1:0] left0  ;
  wire [DATA_WIDTH  - 1:0] left1  ;
  wire [DATA_WIDTH  - 1:0] left2  ;
  wire [DATA_WIDTH  - 1:0] left3  ;
  wire [DATA_WIDTH  - 1:0] left4  ;

  wire [DATA_WIDTH  - 1:0] right0 ;
  wire [DATA_WIDTH  - 1:0] right1 ;
  wire [DATA_WIDTH  - 1:0] right2 ;
  wire [DATA_WIDTH  - 1:0] right3 ;
  wire [DATA_WIDTH  - 1:0] right4 ;

  assign mid0 = ~shamt[0] ? din  : shift0;
  assign mid1 = ~shamt[1] ? mid0 : shift1;
  assign mid2 = ~shamt[2] ? mid1 : shift2;
  assign mid3 = ~shamt[3] ? mid2 : shift3;
  assign dout = ~shamt[4] ? mid3 : shift4;

  assign left0  = din  << 1 ;
  assign left1  = mid0 << 2 ;
  assign left2  = mid1 << 4 ;
  assign left3  = mid2 << 8 ;
  assign left4  = mid3 << 16;

  assign right0 = din  >> 1 ;
  assign right1 = mid0 >> 2 ;
  assign right2 = mid1 >> 4 ;
  assign right3 = mid2 >> 8 ;
  assign right4 = mid3 >> 16;

  assign shift0 = ALU_ctrl == `L_LSHIFT ?                  left0          :
                  ALU_ctrl == `R_LSHIFT ?                  right0         :
                  ALU_ctrl == `R_ASHIFT ? { { 1{din[31]}}, right0[30:0] } : din ;

  assign shift1 = ALU_ctrl == `L_LSHIFT ?                  left1          :
                  ALU_ctrl == `R_LSHIFT ?                  right1         :
                  ALU_ctrl == `R_ASHIFT ? { { 2{din[31]}}, right1[29:0] } : mid0;

  assign shift2 = ALU_ctrl == `L_LSHIFT ?                  left2          :
                  ALU_ctrl == `R_LSHIFT ?                  right2         :
                  ALU_ctrl == `R_ASHIFT ? { { 4{din[31]}}, right2[27:0] } : mid1;

  assign shift3 = ALU_ctrl == `L_LSHIFT ?                  left3          :
                  ALU_ctrl == `R_LSHIFT ?                  right3         :
                  ALU_ctrl == `R_ASHIFT ? { { 8{din[31]}}, right3[23:0] } : mid2;

  assign shift4 = ALU_ctrl == `L_LSHIFT ?                  left4          :
                  ALU_ctrl == `R_LSHIFT ?                  right4         :
                  ALU_ctrl == `R_ASHIFT ? { {16{din[31]}}, right4[15:0] } : mid3;
  
endmodule
