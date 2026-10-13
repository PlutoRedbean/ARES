  .option norvc
  .section .text.init
  .globl _start
  .type _start, @function

  .macro crc16 rd, rs1, rs2
    .insn r 0x0b, 0, 0, \rd, \rs1, \rs2
  .endm

  .macro check_imm reg, value
    li x31, \value
    bne \reg, x31, fail
  .endm

_start:
  # Boundary and representative CoreMark values.
  li x1, 0
  li x2, 0
  crc16 x5, x1, x2
  check_imm x5, 0

  li x1, 0x3415
  li x2, 0x0066
  crc16 x5, x1, x2
  check_imm x5, 0xe724

  li x1, 0xe051
  li x2, 0
  crc16 x5, x1, x2
  check_imm x5, 0x183c

  li x1, 0xffff
  crc16 x5, x1, x0
  check_imm x5, 0xb001

  li x2, 0xffff
  crc16 x5, x0, x2
  check_imm x5, 0xb001

  # The custom instruction must also execute in the high issue slot.
  li x1, 0x8001
  li x2, 1
  .balign 8
  nop
  crc16 x5, x1, x2
  check_imm x5, 0xa001

  # Same-group CRC -> ALU flat bypass.
  li x1, 0x1234
  li x2, 0xabcd
  .balign 8
  crc16 x5, x1, x2
  addi x6, x5, 1
  check_imm x5, 0xe283
  check_imm x6, 0xe284

  # Same-group CRC -> CRC dependency through rs2.
  li x3, 0x5678
  .balign 8
  crc16 x5, x1, x2
  crc16 x6, x3, x5
  check_imm x5, 0xe283
  check_imm x6, 0x4743

  # x0 remains immutable even when selected as rd.
  crc16 x0, x1, x2
  check_imm x0, 0

pass:
  addi x10, x0, 0
  ebreak

fail:
  addi x10, x0, 1
  ebreak

  .size _start, . - _start
