  .option norvc
  .section .text.init
  .globl _start
  .type _start, @function

  .macro check_imm reg, value
    li x31, \value
    bne \reg, x31, fail
  .endm

_start:
  la x30, scratch

  # The 8 KiB D-cache invalidates one word per cycle after reset. Wait until
  # initialization completes so the hit/refill checks below exercise the cache
  # rather than only the uncached startup window.
  li x28, 2100
cache_init_wait:
  addi x28, x28, -1
  bne x28, x0, cache_init_wait

  # Full-word forwarding from a ready Ex1 store.
  li x5, 0x11223344
  sw x5, 0(x30)
  lw x6, 0(x30)
  check_imm x6, 0x11223344

  # Partial SB/SH data is merged with the older word before load extension.
  li x5, 0xaa
  sb x5, 1(x30)
  lw x6, 0(x30)
  check_imm x6, 0x1122aa44

  li x5, 0xbbcc
  sh x5, 2(x30)
  lw x6, 0(x30)
  check_imm x6, 0xbbccaa44

  # Signed and unsigned byte/half loads consume the same merged raw word.
  li x5, 0x80
  sb x5, 4(x30)
  lb x6, 4(x30)
  check_imm x6, -128
  lbu x7, 4(x30)
  check_imm x7, 128

  li x5, 0x8001
  sh x5, 6(x30)
  lh x6, 6(x30)
  check_imm x6, -32767
  lhu x7, 6(x30)
  check_imm x7, 32769

  # Four distinct in-flight stores provide one byte each. Ex4 is oldest and
  # Ex1 youngest when the load reaches issue.
  li x5, 0x11
  li x6, 0x22
  li x7, 0x33
  li x8, 0x44
  sb x5, 16(x30)
  sb x6, 17(x30)
  sb x7, 18(x30)
  sb x8, 19(x30)
  lw x9, 16(x30)
  check_imm x9, 0x44332211

  # A younger store to the same byte must override the older producer.
  li x5, 0xaa
  li x6, 0x55
  sb x5, 20(x30)
  sb x6, 20(x30)
  lbu x7, 20(x30)
  check_imm x7, 0x55

  # Younger byte data overrides one byte supplied by an older half store.
  li x5, 0x1122
  li x6, 0x77
  sh x5, 24(x30)
  sb x6, 25(x30)
  lhu x7, 24(x30)
  check_imm x7, 0x7722

  # Store data dependent on a fresh load is intentionally late. The younger
  # load must wait until the store's final data is available.
  la x29, source_words
  lw x5, 0(x29)
  sw x5, 32(x30)
  lw x6, 32(x30)
  check_imm x6, 0x6badc0de

  # A ready younger full-word store hides an older late producer completely.
  li x20, 7
  li x21, 9
  li x7, 0x13579bdf
  mul x5, x20, x21
  sw x5, 36(x30)
  sw x7, 36(x30)
  lw x6, 36(x30)
  check_imm x6, 0x13579bdf

  # MUL-to-store creates another late-data path and exercises the stall
  # without changing store visibility before Ex4.
  mul x5, x20, x21
  sw x5, 40(x30)
  lw x6, 40(x30)
  check_imm x6, 63

  # A cache hit and a fresh miss both consume transient store bytes.
  lw x6, 48(x30)
  li x5, 0x2468ace0
  sw x5, 48(x30)
  lw x6, 48(x30)
  check_imm x6, 0x2468ace0
  nop
  nop
  nop
  nop
  lw x7, 48(x30)
  check_imm x7, 0x2468ace0

  li x5, 0xdeadbeef
  sw x5, 52(x30)
  lw x6, 52(x30)
  check_imm x6, 0xdeadbeef

  # A transiently-forwarded miss must not refill the D-cache with the stale
  # memory word. Let the producer drain, then read the word again so this load
  # observes the committed refill rather than CoreStoreBuffer forwarding.
  nop
  nop
  nop
  nop
  nop
  nop
  lw x7, 52(x30)
  check_imm x7, 0xdeadbeef

  # Reproduce a read-modify-write status word: first cache the old value, then
  # consume a transient readback of the updated store and revisit the word
  # after the producer has left both store queues.
  li x5, 1
  sw x5, 80(x30)
  lw x6, 80(x30)
  check_imm x6, 1
  nop
  nop
  nop
  nop
  lw x6, 80(x30)
  check_imm x6, 1
  li x7, 0x20000
  or x6, x6, x7
  sw x6, 80(x30)
  lw x8, 80(x30)
  check_imm x8, 0x20001
  nop
  nop
  nop
  nop
  nop
  nop
  lw x8, 80(x30)
  check_imm x8, 0x20001

  # A taken branch flushes the wrong-path store/load pair. Neither result may
  # become architecturally visible.
  sw x0, 56(x30)
  lw x6, 56(x30)
  bne x6, x0, fail
  beq x0, x0, flush_target
  sw x5, 56(x30)
  lw x6, 56(x30)
flush_target:
  lw x6, 56(x30)
  bne x6, x0, fail

  # Keep stores and loads adjacent under sustained pressure.
  addi x22, x30, 64
  li x23, 0
  li x24, 32
pressure_loop:
  addi x23, x23, 1
  sw x23, 0(x22)
  lw x25, 0(x22)
  bne x25, x23, fail
  addi x24, x24, -1
  bne x24, x0, pressure_loop

pass:
  addi x10, x0, 0
  ebreak

fail:
  addi x10, x0, 1
  ebreak

  .size _start, . - _start

  .section .data
  .balign 8
scratch:
  .space 128
source_words:
  .word 0x6badc0de
  .word 0x89abcdef
