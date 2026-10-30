    .section .text
    .globl _start
_start:
    lui  t0, 0xA0001
    lw   t1, 0x70C(t0)       # matrix status
    lui  t2, 0xA0002
    lw   t3, 0x718(t2)       # state status
    li   a0, 0
    ebreak
1:  j 1b
