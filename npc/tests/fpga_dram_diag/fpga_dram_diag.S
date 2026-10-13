  .option norvc
  .option norelax
  .section .text.init
  .globl _start
  .type _start, @function

  .macro display base, upper, lower
    lui x12, \upper
    addi x12, x12, \lower
    sw x12, 0(\base)
    # The SEG snapshot crosses through a mailbox whose busy signal does not
    # backpressure MMIO writes. Keep consecutive markers far enough apart for
    # the transfer and both multiplexed display phases to complete.
    .rept 64
    nop
    .endr
  .endm

_start:
  # x30 is the lane-0 reference MMIO base used by stage and error reporting.
  .balign 8
  lui x30, 0x80200
  addi x20, x0, 20
  .balign 8
  addi x30, x30, 0x20
  addi x20, x20, 1

  display x30, 0x10101, 0x010

  # The final x15 producer is deliberately the high instruction of an
  # aligned fetch group. The first store may still see a nearby bypass.
  .balign 8
  lui x15, 0x80200
  addi x21, x0, 21
  .balign 8
  addi x21, x21, 1
  addi x15, x15, 0x20

  display x15, 0x11111, 0x111

  # Push the x15 producer beyond every ordinary forwarding window while both
  # issue lanes continue writing unrelated registers.
  .rept 32
  addi x22, x22, 1
  xori x23, x23, 1
  .endr

  bne x15, x30, fail_lane1_persistence
  display x15, 0x12121, 0x212

  # The DRAM probe is at the first 32-bit word of the companion DRAM COE.
  .balign 8
  lui x29, 0x80100
  addi x24, x0, 24
  lui x14, 0x5a3cc
  addi x14, x14, 0x3a5

  display x30, 0x20202, 0x020

  # A stable 0x20202020 means this request did not complete architecturally.
  # The returned word is sent directly to SEG before any comparison.
  .balign 8
  lw x13, 0(x29)
  addi x25, x25, 1
  sw x13, 0(x30)
  bne x13, x14, fail_dram_data

  # This x15 use occurs after the slow-load hold but before any redirect.
  display x15, 0x30303, 0x030

  # Force a taken redirect. The final store must recover the old lane-1 x15
  # value from persistent architectural/holding state, not a producer bypass.
  .balign 8
  beq x13, x14, redirect_target
  addi x26, x26, 1
  jal x0, fail_redirect
  addi x27, x27, 1

redirect_target:
  bne x15, x30, fail_redirect_operand
  display x15, 0x50505, 0x050
  jal x0, pass

fail_lane1_persistence:
  display x30, 0xe1010, 0x001
  jal x0, fail

fail_dram_data:
  display x30, 0xe2010, 0x001
  jal x0, fail

fail_redirect:
  display x30, 0xe3010, 0x001
  jal x0, fail

fail_redirect_operand:
  display x30, 0xe3020, 0x001
  jal x0, fail

pass:
  # Let the final MMIO store drain before terminating simulation.
  .rept 16
  nop
  .endr
#ifdef SIMULATION
  addi x10, x0, 0
  ebreak
#else
1:
  jal x0, 1b
#endif

fail:
  .rept 16
  nop
  .endr
#ifdef SIMULATION
  addi x10, x0, 1
  ebreak
#else
2:
  jal x0, 2b
#endif

  .size _start, . - _start

  .section .data
  .balign 8
dram_probe_words:
  .word 0x5a3cc3a5
  .word 0xc001d00d
