  .option norvc
  .section .text.init
  .globl _start
  .type _start, @function

_start:
  # A long reflected-CRC recurrence trains one branch PC into ACTIVE.
  li s0, 0xace1f00d
  li s1, 0xedb88320
  li s2, 256
  li s3, 128

crc_loop:
  .balign 8
  andi t0, s0, 1
  beq t0, x0, crc_zero
  srli s0, s0, 1
  xor s0, s0, s1
  j crc_next
crc_zero:
  srli s0, s0, 1
crc_next:
  addi s2, s2, -1
  bne s2, s3, no_boundary
  xori s0, s0, 0x55
no_boundary:
  bnez s2, crc_loop

  # The token survives unrelated instructions between ANDI and branch.
  andi t1, s0, 1
  nop
  addi t2, t2, 1
  beq t1, x0, non_adjacent_done
  nop
non_adjacent_done:

  # Both x0 operand orders are normalized to the nonzero register.
  andi t1, s0, 1
  beq x0, t1, x0_left_done
  nop
x0_left_done:
  andi t1, s0, 1
  bne x0, t1, x0_left_bne_done
  nop
x0_left_bne_done:

  # A younger ordinary write invalidates the one-shot predicate token.
  andi t3, s0, 1
  addi t3, t3, 1
  beq t3, x0, fail

  # Exact XPERM4 shape: lane0 load, lane1 ANDI, next-group branch.  Repeating
  # the sequence warms the cache and exercises delayed load-pair completion.
  la a0, scratch
  sh s0, 0(a0)
  li s4, 16
load_pair_loop:
  .balign 8
  lhu t4, 0(a0)
  andi t4, t4, 1
  beq t4, x0, load_pair_zero
  nop
load_pair_zero:
  addi s4, s4, -1
  bnez s4, load_pair_loop

  li a0, 0
  ebreak

fail:
  li a0, 1
  ebreak

  .section .bss
  .balign 8
scratch:
  .space 8
