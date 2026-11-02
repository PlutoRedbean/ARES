#include "cpuport.h"

.section .text.trap, "ax", @progbits
.globl trap_entry
.type trap_entry, @function
.align 2

/*
 * Stack layout matches RT-Thread's 32-register RISC-V context frame:
 *   sp[0] = mepc, sp[1] = ra, sp[2] = mstatus,
 *   sp[4..31] = x4..x31. x2 is recovered by releasing the frame and
 *   x3/gp is fixed for the whole image.
 */
trap_entry:
    addi sp, sp, -(32 * REGBYTES)

    STORE x1,   1 * REGBYTES(sp)
    STORE x4,   4 * REGBYTES(sp)
    STORE x5,   5 * REGBYTES(sp)
    STORE x6,   6 * REGBYTES(sp)
    STORE x7,   7 * REGBYTES(sp)
    STORE x8,   8 * REGBYTES(sp)
    STORE x9,   9 * REGBYTES(sp)
    STORE x10, 10 * REGBYTES(sp)
    STORE x11, 11 * REGBYTES(sp)
    STORE x12, 12 * REGBYTES(sp)
    STORE x13, 13 * REGBYTES(sp)
    STORE x14, 14 * REGBYTES(sp)
    STORE x15, 15 * REGBYTES(sp)
    STORE x16, 16 * REGBYTES(sp)
    STORE x17, 17 * REGBYTES(sp)
    STORE x18, 18 * REGBYTES(sp)
    STORE x19, 19 * REGBYTES(sp)
    STORE x20, 20 * REGBYTES(sp)
    STORE x21, 21 * REGBYTES(sp)
    STORE x22, 22 * REGBYTES(sp)
    STORE x23, 23 * REGBYTES(sp)
    STORE x24, 24 * REGBYTES(sp)
    STORE x25, 25 * REGBYTES(sp)
    STORE x26, 26 * REGBYTES(sp)
    STORE x27, 27 * REGBYTES(sp)
    STORE x28, 28 * REGBYTES(sp)
    STORE x29, 29 * REGBYTES(sp)
    STORE x30, 30 * REGBYTES(sp)
    STORE x31, 31 * REGBYTES(sp)

    csrr t0, mepc
    STORE t0, 0 * REGBYTES(sp)
    csrr t0, mstatus
    STORE t0, 2 * REGBYTES(sp)

    csrr a0, mcause
    LOAD a1, 0 * REGBYTES(sp)
    call rt_hw_trap_handler

    /* The C handler returns the address at which execution should resume. */
    STORE a0, 0 * REGBYTES(sp)

    /* Apply a scheduler decision requested by rt_tick_increase() in IRQ mode. */
    la t0, rt_thread_switch_interrupt_flag
    LOAD t1, 0(t0)
    beqz t1, .Ltrap_restore
    STORE zero, 0(t0)

    la t0, rt_interrupt_from_thread
    LOAD t1, 0(t0)
    STORE sp, 0(t1)

    la t0, rt_interrupt_to_thread
    LOAD t1, 0(t0)
    LOAD sp, 0(t1)

.Ltrap_restore:
    LOAD t0, 2 * REGBYTES(sp)
    csrw mstatus, t0
    LOAD t0, 0 * REGBYTES(sp)
    csrw mepc, t0

    LOAD x1,   1 * REGBYTES(sp)
    LOAD x4,   4 * REGBYTES(sp)
    LOAD x5,   5 * REGBYTES(sp)
    LOAD x6,   6 * REGBYTES(sp)
    LOAD x7,   7 * REGBYTES(sp)
    LOAD x8,   8 * REGBYTES(sp)
    LOAD x9,   9 * REGBYTES(sp)
    LOAD x10, 10 * REGBYTES(sp)
    LOAD x11, 11 * REGBYTES(sp)
    LOAD x12, 12 * REGBYTES(sp)
    LOAD x13, 13 * REGBYTES(sp)
    LOAD x14, 14 * REGBYTES(sp)
    LOAD x15, 15 * REGBYTES(sp)
    LOAD x16, 16 * REGBYTES(sp)
    LOAD x17, 17 * REGBYTES(sp)
    LOAD x18, 18 * REGBYTES(sp)
    LOAD x19, 19 * REGBYTES(sp)
    LOAD x20, 20 * REGBYTES(sp)
    LOAD x21, 21 * REGBYTES(sp)
    LOAD x22, 22 * REGBYTES(sp)
    LOAD x23, 23 * REGBYTES(sp)
    LOAD x24, 24 * REGBYTES(sp)
    LOAD x25, 25 * REGBYTES(sp)
    LOAD x26, 26 * REGBYTES(sp)
    LOAD x27, 27 * REGBYTES(sp)
    LOAD x28, 28 * REGBYTES(sp)
    LOAD x29, 29 * REGBYTES(sp)
    LOAD x30, 30 * REGBYTES(sp)
    LOAD x31, 31 * REGBYTES(sp)

    addi sp, sp, (32 * REGBYTES)
    mret

    .size trap_entry, . - trap_entry

/*
 * Exercise both caller-saved and callee-saved registers across one ecall.
 * Returns zero on success, otherwise the index of the damaged register.
 */
.section .text, "ax", @progbits
.globl rt_hw_trap_self_test
.type rt_hw_trap_self_test, @function
.align 2
rt_hw_trap_self_test:
    addi sp, sp, -16
    STORE ra, 12(sp)
    STORE s1, 8(sp)

    li a0, 0x13579bdf
    li a1, 0x2468ace0
    li t0, 0x11223344
    li s1, 0x55667788
    ecall

    li t1, 0x13579bdf
    bne a0, t1, .Ltest_a0_fail
    li t1, 0x2468ace0
    bne a1, t1, .Ltest_a1_fail
    li t1, 0x11223344
    bne t0, t1, .Ltest_t0_fail
    li t1, 0x55667788
    bne s1, t1, .Ltest_s1_fail
    li a0, 0
    j .Ltest_done

.Ltest_a0_fail:
    li a0, 1
    j .Ltest_done
.Ltest_a1_fail:
    li a0, 2
    j .Ltest_done
.Ltest_t0_fail:
    li a0, 3
    j .Ltest_done
.Ltest_s1_fail:
    li a0, 4

.Ltest_done:
    LOAD s1, 8(sp)
    LOAD ra, 12(sp)
    addi sp, sp, 16
    ret

    .size rt_hw_trap_self_test, . - rt_hw_trap_self_test
