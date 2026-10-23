// Controlled 16KiB streaming working set, larger than the 8KiB DCache.
// The same binary is used for all line sizes. No MMIO or host timing input.
.option norvc
.section .text
.globl _start
_start:
    lui t0, 0x80100
    li t1, 0
    li t2, 4096
write_loop:
    sw t1, 0(t0)
    addi t0, t0, 4
    addi t1, t1, 1
    bne t1, t2, write_loop
    lui t0, 0x80100
    li t1, 0
    li t3, 0
read_loop:
    lw t4, 0(t0)
    add t3, t3, t4
    addi t0, t0, 4
    addi t1, t1, 1
    bne t1, t2, read_loop
    li t4, 0x7ff800
    sub a0, t3, t4
    ebreak
