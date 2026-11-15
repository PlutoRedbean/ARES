`ifndef __INST_PARA_VH__
`define __INST_PARA_VH__

`define INSTS_NUM 39

// inst types define
`define R  3'd0
`define I  3'd1
`define S  3'd2
`define B  3'd3
`define U  3'd4
`define J  3'd5

// opcode define
`define   ADD_opcode 7'b0110011
`define   SUB_opcode 7'b0110011
`define   AND_opcode 7'b0110011
`define    OR_opcode 7'b0110011
`define   XOR_opcode 7'b0110011

`define  ADDI_opcode 7'b0010011
`define  ANDI_opcode 7'b0010011
`define   ORI_opcode 7'b0010011
`define  XORI_opcode 7'b0010011

`define   BEQ_opcode 7'b1100011
`define   BNE_opcode 7'b1100011
`define   BLT_opcode 7'b1100011
`define   BGE_opcode 7'b1100011
`define  BLTU_opcode 7'b1100011
`define  BGEU_opcode 7'b1100011

`define   JAL_opcode 7'b1101111
`define  JALR_opcode 7'b1100111

`define    LB_opcode 7'b0000011
`define    LH_opcode 7'b0000011
`define    LW_opcode 7'b0000011
`define   LBU_opcode 7'b0000011
`define   LHU_opcode 7'b0000011
`define    SB_opcode 7'b0100011
`define    SH_opcode 7'b0100011
`define    SW_opcode 7'b0100011

`define   SLL_opcode 7'b0110011
`define  SLLI_opcode 7'b0010011
`define   SRL_opcode 7'b0110011
`define  SRLI_opcode 7'b0010011
`define   SRA_opcode 7'b0110011
`define  SRAI_opcode 7'b0010011

`define   SLT_opcode 7'b0110011
`define  SLTU_opcode 7'b0110011
`define  SLTI_opcode 7'b0010011
`define SLTIU_opcode 7'b0010011

`define CSRRW_opcode 7'b1110011
`define CSRRS_opcode 7'b1110011

`define AUIPC_opcode 7'b0010111
`define   LUI_opcode 7'b0110111

// func3 define
`define    NO_func3 3'b000

`define   ADD_func3 3'b000
`define   SUB_func3 3'b000
`define   AND_func3 3'b111
`define    OR_func3 3'b110
`define   XOR_func3 3'b100

`define  ADDI_func3 3'b000
`define  ANDI_func3 3'b111
`define   ORI_func3 3'b110
`define  XORI_func3 3'b100

`define   BEQ_func3 3'b000
`define   BNE_func3 3'b001
`define   BLT_func3 3'b100
`define   BGE_func3 3'b101
`define  BLTU_func3 3'b110
`define  BGEU_func3 3'b111

`define  JALR_func3 3'b000

`define    LB_func3 3'b000
`define    LH_func3 3'b001
`define    LW_func3 3'b010
`define   LBU_func3 3'b100
`define   LHU_func3 3'b101
`define    SB_func3 3'b000
`define    SH_func3 3'b001
`define    SW_func3 3'b010

`define   SLL_func3 3'b001
`define  SLLI_func3 3'b001
`define   SRL_func3 3'b101
`define  SRLI_func3 3'b101
`define   SRA_func3 3'b101
`define  SRAI_func3 3'b101

`define CSRRW_func3 3'b001
`define CSRRS_func3 3'b010

`define   SLT_func3 3'b010
`define  SLTU_func3 3'b011
`define  SLTI_func3 3'b010
`define SLTIU_func3 3'b011

// func7 define
`define    NO_func7 7'b0000000

`define   ADD_func7 7'b0000000
`define   SUB_func7 7'b0100000
`define   AND_func7 7'b0000000
`define    OR_func7 7'b0000000
`define   XOR_func7 7'b0000000

`define   SLL_func7 7'b0000000
`define   SRL_func7 7'b0000000
`define   SRA_func7 7'b0100000

`define   SLT_func7 7'b0000000
`define  SLTU_func7 7'b0000000

// shtype define
`define SLLI_shtype 6'b000000
`define SRLI_shtype 6'b000000
`define SRAI_shtype 6'b010000

// CSR_addr define
`define MEPC_ADDR       12'h341
`define MTVEC_ADDR      12'h305
`define MCAUSE_ADDR     12'h342
`define MSTATUS_ADDR    12'h300
`define MCYCLE_ADDR     12'hb00
`define MCYCLEH_ADDR    12'hb80
`define MVENDORID_ADDR  12'hf11
`define MARCHID_ADDR    12'hf12

// ebreak define
`define NOP     32'b00000000000000000000000000010011
`define ECALL   32'b00000000000000000000000001110011
`define EBREAK  32'b00000000000100000000000001110011
`define MRET    32'b00110000001000000000000001110011
`define FENCE_I 32'b00000000000000000001000000001111

`define ENVIR_WIDTH     3

`define ENVIR_NORMAL    `ENVIR_WIDTH'd0
`define ENVIR_ECALL     `ENVIR_WIDTH'd1
`define ENVIR_EBREAK    `ENVIR_WIDTH'd2
`define ENVIR_MRET      `ENVIR_WIDTH'd3
`define ENVIR_FENCE_I   `ENVIR_WIDTH'd4

`endif
