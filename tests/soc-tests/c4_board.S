.option norvc
.option norelax
.section .reset,"ax"
.globl _start
_start:
    j main

.section .trap,"ax"
trap:
    csrr t0, mcause
    li t1, 11
    bne t0, t1, fail
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    addi s1, s1, 1
    mret

.section .text,"ax"
main:
    lui s0, 0x80200
    li s1, 0
    ecall
    li t0, 1
    bne s1, t0, fail
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
    lw t2, 16(t0)
    li t3, 0x5a5aa5a5
    bne t2, t3, fail
    la s2, message
print:
    lbu a0, 0(s2)
    beqz a0, ready
    jal ra, putc
    addi s2, s2, 1
    j print
ready:
    li t0, 0x123
    sw t0, 0x40(s0)
echo:
    lw t0, 0x64(s0)
    andi t0, t0, 1
    beqz t0, echo
    lw a0, 0x68(s0)
    jal ra, putc
    j echo
putc:
    lw t0, 0x64(s0)
    andi t0, t0, 2
    beqz t0, putc
    sw a0, 0x60(s0)
    ret
fail:
    lui t0, 0x80200
    li t1, 0xdead
    sw t1, 0x40(t0)
1:  j 1b
.section .data,"aw"
    .word 0x5a5aa5a5
message: .asciz "ARES C4 OK\r\n"
