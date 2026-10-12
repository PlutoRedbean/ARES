#define REG_L   lw
#define REG_S   sw

#define SZREG   4

.macro DEFINE_MEMCPY sym, sect
/* memcpy impl */
.section \sect, "ax"
.globl \sym
.type \sym, @function

\sym:
  move t2, a0  /* Preserve return value */

  /* Defer to byte-oriented copy for small sizes */
  sltiu a3, a2, 128
  bnez a3, 4f
  /* Use word-oriented copy only if low-order bits match */
  andi a3, t2, SZREG-1
  andi a4, a1, SZREG-1
  bne a3, a4, 4f

  beqz a3, 2f  /* Skip if already aligned */
  /*
   * Round to nearest double word-aligned address
   * greater than or equal to start address
   */

1:
  lb a5, 0(a1)
  addi a1, a1, 1
  sb a5, 0(t2)
  addi t2, t2, 1
  bltu a1, a3, 1b
  sub a2, a2, a4  /* Update count */

2:
  andi a4, a2, ~((16*SZREG)-1)
  beqz a4, 4f
  add a3, a1, a4

3:
  REG_L a4, (0*SZREG)(a1)
  REG_L a5, (1*SZREG)(a1)
  REG_L t0, (2*SZREG)(a1)
  REG_L t1, (3*SZREG)(a1)
  REG_S a4, (0*SZREG)(t2)
  REG_S a5, (1*SZREG)(t2)
  REG_S t0, (2*SZREG)(t2)
  REG_S t1, (3*SZREG)(t2)

  REG_L a4, (4*SZREG)(a1)
  REG_L a5, (5*SZREG)(a1)
  REG_L t0, (6*SZREG)(a1)
  REG_L t1, (7*SZREG)(a1)
  REG_S a4, (4*SZREG)(t2)
  REG_S a5, (5*SZREG)(t2)
  REG_S t0, (6*SZREG)(t2)
  REG_S t1, (7*SZREG)(t2)

  REG_L a4, ( 8*SZREG)(a1)
  REG_L a5, ( 9*SZREG)(a1)
  REG_L t0, (10*SZREG)(a1)
  REG_L t1, (11*SZREG)(a1)
  REG_S a4, ( 8*SZREG)(t2)
  REG_S a5, ( 9*SZREG)(t2)
  REG_S t0, (10*SZREG)(t2)
  REG_S t1, (11*SZREG)(t2)

  REG_L a4, (12*SZREG)(a1)
  REG_L a5, (13*SZREG)(a1)
  REG_L t0, (14*SZREG)(a1)
  REG_L t1, (15*SZREG)(a1)
  addi a1, a1, 16*SZREG
  REG_S a4, (12*SZREG)(t2)
  REG_S a5, (13*SZREG)(t2)
  REG_S t0, (14*SZREG)(t2)
  REG_S t1, (15*SZREG)(t2)
  addi t2, t2, 16*SZREG

  bltu a1, a3, 3b
  andi a2, a2, (16*SZREG)-1  /* Update count */

4:
  /* Handle trailing misalignment */
  beqz a2, 6f
  add a3, a1, a2

  /* Use word-oriented copy if co-aligned to word boundary */
  or a5, a1, t2
  or a5, a5, a3
  andi a5, a5, 3
  bnez a5, 5f

7:
  lw a4, 0(a1)
  addi a1, a1, 4
  sw a4, 0(t2)
  addi t2, t2, 4
  bltu a1, a3, 7b

  ret

5:
  lb a4, 0(a1)
  addi a1, a1, 1
  sb a4, 0(t2)
  addi t2, t2, 1
  bltu a1, a3, 5b

6:
  ret

.size \sym, . - \sym
.endm

/* func define */
DEFINE_MEMCPY _memcpy, .boot
