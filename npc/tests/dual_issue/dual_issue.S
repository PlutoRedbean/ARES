  .option norvc
  .section .text.init
  .globl _start
  .type _start, @function

  .macro check_imm reg, value
    li x31, \value
    bne \reg, x31, fail
  .endm

_start:
  li x1, 5
  li x2, 3
  li x3, -1

  # Every restricted-lane RV32I operation is placed in the high fetch slot.
  .balign 8
  nop
  lui x5, 0x12345
  check_imm x5, 0x12345000

  .balign 8
  nop
  auipc x5, 0
  auipc x6, 0
  addi x6, x6, -4
  bne x5, x6, fail

  .balign 8
  nop
  addi x5, x1, 7
  check_imm x5, 12
  .balign 8
  nop
  slti x5, x1, 6
  check_imm x5, 1
  .balign 8
  nop
  sltiu x5, x1, 6
  check_imm x5, 1
  .balign 8
  nop
  xori x5, x1, 3
  check_imm x5, 6
  .balign 8
  nop
  ori x5, x1, 2
  check_imm x5, 7
  .balign 8
  nop
  andi x5, x1, 3
  check_imm x5, 1
  .balign 8
  nop
  slli x5, x1, 2
  check_imm x5, 20
  .balign 8
  nop
  srli x5, x3, 4
  check_imm x5, 0x0fffffff
  .balign 8
  nop
  srai x5, x3, 4
  check_imm x5, -1

  .balign 8
  nop
  add x5, x1, x2
  check_imm x5, 8
  .balign 8
  nop
  sub x5, x1, x2
  check_imm x5, 2
  .balign 8
  nop
  sll x5, x1, x2
  check_imm x5, 40
  .balign 8
  nop
  slt x5, x2, x1
  check_imm x5, 1
  .balign 8
  nop
  sltu x5, x2, x1
  check_imm x5, 1
  .balign 8
  nop
  xor x5, x1, x2
  check_imm x5, 6
  .balign 8
  nop
  srl x5, x1, x2
  check_imm x5, 0
  .balign 8
  nop
  sra x5, x3, x2
  check_imm x5, -1
  .balign 8
  nop
  or x5, x1, x2
  check_imm x5, 7
  .balign 8
  nop
  and x5, x1, x2
  check_imm x5, 1

  # Slot-0 ALU result is consumed by one and then both slot-1 sources.
  .balign 8
  addi x7, x0, 10
  addi x8, x7, 5
  check_imm x8, 15
  .balign 8
  addi x7, x0, 11
  add x8, x7, x7
  check_imm x8, 22

  # A non-ALU producer cannot use the flat same-group bypass.
  li x1, 6
  li x2, 7
  .balign 8
  mul x9, x1, x2
  addi x10, x9, 1
  check_imm x9, 42
  check_imm x10, 43

  # WAW-only and WAW with the supported ALU0 flat RAW path pair.  The
  # younger physical write wins while differential retirement still observes
  # both instructions in program order.
  fence.i
  addi x11, x0, 1
  addi x11, x0, 2
  check_imm x11, 2

  fence.i
  addi x11, x0, 3
  addi x11, x11, 4
  check_imm x11, 7

  # WAW plus an unavailable same-group result remains split.
  fence.i
  mul x9, x1, x2
  addi x9, x9, 1
  check_imm x9, 43

  # WAR pairs, and x0 never creates a dependency.
  li x12, 9
  .balign 8
  addi x13, x12, 1
  addi x12, x0, 12
  check_imm x13, 10
  check_imm x12, 12

  .balign 8
  addi x0, x0, 1
  addi x14, x0, 14
  check_imm x14, 14

  # Two producer lanes feed both lanes of the following group.
  .balign 8
  addi x15, x0, 5
  addi x16, x0, 6
  .balign 8
  add x17, x15, x16
  sub x18, x16, x15
  check_imm x17, 11
  check_imm x18, 1

  # Carry one ALU producer through Ex2/Ex3/Ex4/WB while consumers in both
  # lanes take the registered ISS selection and final Ex1 value.
  fence.i
  .balign 8
  addi x6, x0, 18
  addi x20, x0, 20
  .balign 8
  add x7, x6, x1
  addi x21, x0, 21
  .balign 8
  addi x22, x0, 22
  add x8, x6, x2
  .balign 8
  addi x9, x6, 3
  addi x23, x0, 23
  .balign 8
  addi x24, x0, 24
  addi x10, x6, 4
  .balign 8
  add x4, x6, x1
  addi x25, x0, 25
  check_imm x7, 24
  check_imm x8, 25
  check_imm x9, 21
  check_imm x10, 22
  check_imm x4, 24

  # Two live writes to one rd must select the younger stage, and both
  # following consumer lanes must observe that same youngest producer.
  fence.i
  .balign 8
  addi x11, x0, 10
  addi x20, x0, 20
  .balign 8
  addi x11, x0, 30
  addi x21, x0, 21
  .balign 8
  add x12, x11, x1
  add x13, x11, x2
  check_imm x12, 36
  check_imm x13, 37

  # Branch and multiply consumers also take their final ordinary operands
  # in Ex1 rather than requiring them to be ready in ISS.
  fence.i
  .balign 8
  addi x14, x0, 1
  addi x15, x0, 2
  .balign 8
  bne x14, x15, 2f
  j fail
2:
  # An ALU0-dependent branch initially occupying slot 1 must serialize.  This
  # deliberately places the producer at the low address of an aligned pair.
  fence.i
  .balign 8
  addi x14, x0, 1
  bne x14, x0, alu_branch_serialized
  j fail
alu_branch_serialized:
  fence.i
  .balign 8
  addi x17, x0, 6
  addi x18, x0, 7
  .balign 8
  mul x19, x17, x18
  addi x20, x0, 20
  check_imm x19, 42

  # Full slot 0 pairs independent slot-1 ALU work across M and memory paths.
  .balign 8
  mul x19, x1, x2
  addi x20, x0, 20
  check_imm x19, 42
  check_imm x20, 20

  .balign 8
  div x19, x1, x2
  addi x20, x0, 21
  check_imm x19, 0
  check_imm x20, 21

  lui x30, %hi(scratch)
  addi x30, x30, %lo(scratch)
  li x22, 0x55
  .balign 8
  sw x22, 0(x30)
  addi x23, x0, 23
  check_imm x23, 23
  .balign 8
  lw x24, 0(x30)
  addi x25, x0, 25
  bne x24, x22, fail
  check_imm x25, 25

  fence.i
  lw x24, 0(x30)
  addi x24, x24, 1
  check_imm x24, 0x56

  # The configured 8 KiB cache invalidates 2048 tag entries after reset.
  # Keep this directed test alive long enough for refill writes to become
  # available before distinguishing a cold replay from following hits.
  li x28, 4200
1:
  addi x28, x28, -1
  bnez x28, 1b

  # A slot-0 load and its same-group ALU consumer serialize, independent of
  # whether the cache access misses or hits and whether one or both sources
  # consume the load result.
  lui x29, %hi(cold_load_data)
  addi x29, x29, %lo(cold_load_data)
  li x26, 0x12345678
  .balign 8
  lw x24, 0(x29)
  addi x25, x24, 1
  bne x24, x26, fail
  check_imm x25, 0x12345679

  .balign 8
  lw x24, 0(x29)
  add x25, x24, x24
  check_imm x25, 0x2468acf0

  fence.i
  .balign 8
  lw x24, 0(x29)
  addi x25, x24, 2
  check_imm x25, 0x1234567a

  # A lane-1 consumer in the following group exercises the ordinary Ex1
  # late-bypass path for a load produced by lane 1.
  .balign 8
  nop
  lw x24, 0(x29)
  .balign 8
  addi x27, x0, 27
  addi x25, x24, 1
  check_imm x25, 0x12345679
  check_imm x27, 27

  # A following-group multiply may speculate on a lane-1 load hit.  A miss
  # would replay the multiply using the existing Ex1 load replay mechanism.
  fence.i
  .balign 8
  nop
  lw x17, 0(x30)
  .balign 8
  mul x18, x17, x2
  addi x20, x0, 20
  check_imm x18, 0x253

  # Conditional branches dependent on a same-group load also serialize.
  fence.i
  .balign 8
  lw x24, 0(x29)
  bne x24, x26, fail

  fence.i
  .balign 8
  lw x24, 0(x29)
  beq x24, x26, load_pair_branch_taken
  j fail
load_pair_branch_taken:
  addi x27, x0, 27
  check_imm x27, 27

  # Two oldest memory candidates serialize on the current single-request
  # LSU, while both instructions still complete correctly.
  lw x24, 0(x30)
  lw x25, 0(x30)
  bne x24, x22, fail
  bne x25, x22, fail

  # Slot 1 owns an independent fixed-latency integer MAC.  A serial fence
  # leaves the following nop/MUL pair at the head of the compacting IQ.
  fence.i
  nop
  mul x4, x1, x2
  check_imm x4, 42

  fence.i
  nop
  mulh x4, x3, x2
  check_imm x4, -1

  fence.i
  nop
  mulhsu x4, x3, x2
  check_imm x4, -1

  fence.i
  nop
  mulhu x4, x3, x2
  check_imm x4, 6

  # Both MACs accept independent multiplies in the same group.
  fence.i
  mul x4, x1, x2
  mulhu x5, x3, x2
  check_imm x4, 42
  check_imm x5, 6

  # ALU0 can feed either or both slot-1 MAC inputs through the Ex1 flat path.
  fence.i
  addi x6, x0, 9
  mul x7, x6, x2
  addi x8, x7, 1
  check_imm x8, 64

  fence.i
  addi x6, x0, 5
  mul x7, x6, x6
  check_imm x7, 25

  # Keep a slow older producer live while evaluating slot-1 readiness.  The
  # decode estimate advances the registered producer snapshot across decode
  # and synchronous GPR read, so this pair no longer needs a conservative
  # slot1-late rejection when the value will be ready at the consumer Ex1.
  .balign 8
  mul x19, x1, x2
  fence.i
  .balign 8
  addi x20, x0, 1
  addi x21, x19, 1
  check_imm x21, 43

  # A dependent second DIV simultaneously observes the long-resource and
  # operand interlocks; an older WB-DIV may still remain the primary cause.
  fence.i
  div x19, x1, x2
  div x20, x19, x2
  check_imm x20, 0

  # A serial low-slot fence leaves the high slot to pair across the block.
  .balign 8
  fence.i
  addi x22, x0, 22
  addi x23, x0, 23
  check_imm x22, 22
  check_imm x23, 23

  # CSR and a high-slot load exercise both serial rejection classes.  CSR
  # writes consume load/M results in Ex4, and adjacent CSR operations must see
  # the preceding architectural update.
  lw x24, 0(x30)
  csrrw x0, mscratch, x24
  csrrs x25, mscratch, x0
  check_imm x25, 0x55

  mul x24, x1, x2
  csrrw x26, mscratch, x24
  check_imm x26, 0x55
  csrrs x25, mscratch, x0
  check_imm x25, 42

  addi x24, x25, 1
  csrrw x26, mscratch, x24
  check_imm x26, 42
  csrrwi x27, mscratch, 7
  check_imm x27, 43
  csrrci x28, mscratch, 1
  check_imm x28, 7
  csrrsi x28, mscratch, 8
  check_imm x28, 6
  csrrs x24, mscratch, x0
  check_imm x24, 14

  .balign 8
  addi x25, x0, 25
  lw x26, 0(x30)
  csrrw x0, mscratch, x0

  # Taken control transfers occupy each 64-bit slot.  The first target is the
  # high slot of its block, so redirected fetch must discard the older low slot.
  .balign 8
  beq x0, x0, high_target
  addi x27, x0, -1
  addi x27, x0, -2
high_target:
  addi x27, x0, 27
  check_imm x27, 27

  .balign 8
  addi x28, x0, 28
  beq x0, x0, high_branch_target
  addi x28, x0, -1
high_branch_target:
  check_imm x28, 28

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
  .word 0
  .balign 64
cold_load_data:
  .word 0x12345678
