.section .text.startup, "ax", @progbits
.globl _start
.type _start, @function
.align 2

_start:
    /* Linker relaxation must not turn this into a gp-relative load. */
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    la sp, __stack_top

    /* Synchronous traps and machine timer IRQs use one direct-mode handler. */
    la t0, trap_entry
    csrw mtvec, t0

    la t0, __bss_start
    la t1, __bss_end

.Lclear_bss:
    bgeu t0, t1, .Lstart_c
    sw zero, 0(t0)
    addi t0, t0, 4
    j .Lclear_bss

.Lstart_c:
    /* GNU entry() is provided by RT-Thread's components.c. */
    call entry

    /* rtthread_startup() must never return. */
    li a0, 0x7f
    ebreak

.Lhang:
    j .Lhang

    .size _start, . - _start
