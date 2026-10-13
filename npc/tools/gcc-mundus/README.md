# Mundus GCC 16.1 scheduling model

`gcc-16.1-mundus.patch` adds `-mtune=mundus` to the RISC-V GCC backend.  It
models the current NPC integer pipeline, without changing the ISA selected by
`-march=rv32im_zicsr`.

The modeled rules are:

- at most two instructions issue per cycle;
- integer ALU, multiply, or memory may use slot 0;
- integer ALU, multiply, memory, or control flow may use slot 1;
- conservatively schedule at most one load/store per cycle;
- divide, trap, atomic, CSR/FP-transfer-like classes issue alone;
- ALU/store/control latency is 1, load latency is 3, multiply latency is 4,
  and RV32 divide latency is 35 cycles.

GCC represents an inline `asm` statement as type `multi`.  This model treats
that class as a one-cycle pairable integer operation so the CoreMark CRC16 and
MULBE `.insn` statements can be scheduled with independent work.

The D-cache is physically split into two banks selected by `addr[2]`, but the
current RTL deliberately accepts at most one architectural load/store per
issue group.  The generic GCC model therefore schedules at most one memory
operation per cycle.  Experimental dual-load scheduling was removed because
it disturbed more valuable load/ALU/MUL schedules and did not improve CoreMark.

Apply the patch at the root of an unmodified GCC 16.1.0 source tree:

```sh
patch -p1 < /path/to/ysyx-redbean/npc/tools/gcc-mundus/gcc-16.1-mundus.patch
```

Configure and build the cross compiler in a separate build directory using the
same target options as the existing GCC 16.1 toolchain.  Then build the BSP
with both the patched compiler prefix and the tune flag:

```sh
make CROSS_COMPILE=/path/to/mundus-gcc/bin/riscv32-unknown-elf- \
  MUNDUS_TUNE_FLAGS=-mtune=mundus
```

`MUNDUS_TUNE_FLAGS` is also passed at the LTO link step; omitting it there
would silently schedule the final LTO-generated code for the generic core.
