  .option norvc
  .section .text.init
  .globl _start
  .type _start, @function

  .macro mulbe rd, rs1, rs2
    .insn r 0x0b, 0, 1, \rd, \rs1, \rs2
  .endm

  .macro check_imm reg, value
    li x31, \value
    bne \reg, x31, fail
  .endm

_start:
  # Boundary and signed CoreMark MATDAT cases.
  li x1, 0
  li x2, 0
  mulbe x5, x1, x2
  check_imm x5, 0

  li x1, -1
  li x2, 1
  mulbe x5, x1, x2
  check_imm x5, 1905

  li x1, 0x1234
  li x2, -0x5433
  mulbe x5, x1, x2
  check_imm x5, 1125

  li x1, 0x3415
  li x2, 0x66
  mulbe x5, x1, x2
  check_imm x5, 14

  # The custom multiply must also execute in the high issue slot.
  li x1, -1
  li x2, 1
  .balign 8
  nop
  mulbe x5, x1, x2
  check_imm x5, 1905

  # A dependent ALU instruction must wait for the multiply WB result.
  li x1, 0x1234
  li x2, -0x5433
  mulbe x5, x1, x2
  addi x6, x5, 7
  check_imm x5, 1125
  check_imm x6, 1132

  # Back-to-back independent custom multiplies exercise both MAC lanes.
  li x3, -1
  li x4, 1
  .balign 8
  mulbe x5, x1, x2
  mulbe x6, x3, x4
  check_imm x5, 1125
  check_imm x6, 1905

  # x0 remains immutable when it is selected as rd.
  mulbe x0, x1, x2
  check_imm x0, 0

pass:
  addi x10, x0, 0
  ebreak

fail:
  addi x10, x0, 1
  ebreak

  .size _start, . - _start
