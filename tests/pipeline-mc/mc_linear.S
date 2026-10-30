//=============================================================================
// ARES pipeline multi-hart coherence test - branch-free linear version
//-----------------------------------------------------------------------------
// 2 or 4 harts execute the same straight-line program.  Every hart publishes
// one word into the shared cacheable window, waits a fixed number of cycles,
// then reads every published word.  The fixed delay replaces a software barrier
// so the test has no conditional branches in the coherence region.  This keeps
// the test focused on the L1 write-through + L2 write-invalidate path and
// avoids dependence on the pipeline core's branch/flush corner cases.
//
// Build with -DNCPU=2 or -DNCPU=4.
//=============================================================================
    .set NCPU, 2

    .section .text
    .globl _start
_start:
    // hart id -> t0
    lui   t0, 0xA0001
    addi  t0, t0, -16
    lw    t0, 0(t0)

    // s0 = common shared base; t1 = private slot
    lui   s0, 0x80100
    slli  t2, t0, 2
    add   t1, s0, t2

    // publish 0x100+id
    addi  t3, t0, 0x100
    sw    t3, 0(t1)
    fence
    .rept 2048
    nop
    .endr

    // Verify every slot.  Expected slot k = 0x100+k.
    li    a0, 0
.if NCPU >= 1
    li    t4, 0x100
    lw    t5, 0(s0)
    sub   t5, t5, t4
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif
.if NCPU >= 2
    li    t4, 0x101
    lw    t5, 4(s0)
    sub   t5, t5, t4
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif
.if NCPU >= 3
    li    t4, 0x102
    lw    t5, 8(s0)
    sub   t5, t5, t4
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif
.if NCPU >= 4
    li    t4, 0x103
    lw    t5, 12(s0)
    sub   t5, t5, t4
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif

    // Publish the local result and let all result words settle.
    lui   t6, 0x80101
    addi  t6, t6, -1024
    add   s1, t6, t2
    sw    a0, 0(s1)
    fence
    .rept 2048
    nop
    .endr

    // Verify every result word is zero.
.if NCPU >= 1
    lw    t5, 0(t6)
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif
.if NCPU >= 2
    lw    t5, 4(t6)
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif
.if NCPU >= 3
    lw    t5, 8(t6)
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif
.if NCPU >= 4
    lw    t5, 12(t6)
    sltu  t5, x0, t5
    add   a0, a0, t5
.endif

    ebreak
1:  j 1b
