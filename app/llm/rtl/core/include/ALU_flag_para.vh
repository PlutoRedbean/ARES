`ifndef __ALU_FLAG_PARA_VH__
`define __ALU_FLAG_PARA_VH__

// is signed define
`define UNSIGNED 1'd0
`define   SIGNED 1'd1

// define ALU_flag
`define ADD         4'h0
`define SUB         4'h1
`define L_LSHIFT    4'h2
`define R_LSHIFT    4'h3
`define R_ASHIFT    4'h4
`define LESS        4'h5
`define BLESS       4'h6
`define BNLESS      4'h7
`define BEQUAL      4'h8
`define BNEQUAL     4'h9
`define XOR         4'ha
`define OR          4'hb
`define AND         4'hc

// define ALU_dst
`define DST_PC   3'd0
`define DST_REG  3'd1
`define DST_RMEM 3'd2
`define DST_WMEM 3'd3
`define DST_BRAN 3'd4
`define DST_CSR  3'd5

// define ALU_operand
`define OPR_NONE    3'd0
`define OPR_IMM     3'd1
`define OPR_RS1     3'd2
`define OPR_RS2     3'd3
`define OPR_PC      3'd4
`define OPR_SHAMT   3'd5
`define OPR_RS_SH   3'd6
`define OPR_CSR     3'd7

`endif
