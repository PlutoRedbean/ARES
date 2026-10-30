    .section .text
    .globl _start
_start:
    lui  x1, 0x80100
    addi x2, x0, 0x55
    sw   x2, 0(x1)
    fence
    addi x2, x0, 0x66
    sw   x2, 4(x1)
    ebreak
1:  j 1b
