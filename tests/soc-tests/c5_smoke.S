.option norvc
.section .text
.globl _start
_start:
    lui t0, 0x80300
    li t1, 0x123
    sw t1, 0(t0)
    lb t2, 0(t0)
    li t3, 0x23
    bne t2, t3, fail
    lui t0, 0x80100
    lw t2, 0(t0)
    bne t2, t1, fail
    lw t2, 0(t0)
    bne t2, t1, fail
    lui s0, 0x80200
    sw t2, 0x40(s0)
    li t1, 0x4b
    sw t1, 0x60(s0)
    jal ra, function
    li t1, 77
    bne a1, t1, fail
    // A target equal to pc+4 must run without forced BRU recovery.
    auipc t0, 0
    addi t0, t0, 12
    jalr zero, 0(t0)
    li a0, 0
    ebreak
function:
    li a1, 77
    ret
fail:
    li a0, 1
    ebreak
