# Dual-core CoreMark on the shared L2 — resolved

Status: **two-hart AMP CoreMark passes.** Both harts run an independent CoreMark
copy (100 iterations) through their own real frontend and private L1D, sharing
one `l2_top`. Branch: `l2-cache`.

This document supersedes the earlier "shared L2 data corruption" note. The
original diagnosis was wrong: the dual-core run was never corrupting data. It
aborted on a simulation assertion that fired on a *speculative* instruction.

## 1. Symptom that was reported

`tb_2core_coremark` ran two software-CRC CoreMark images on two real frontends
sharing one L2. At about 44.7 ms simulated time hart0 (then hart1) tripped the
LSU natural-alignment assertion:

```text
[44695475000] %Error: lsu_agu.sv:188: a_natural_align
```

Both harts were at ~1.84M "retires", PC ~`0x8000_0634`, L2 hit/miss ~3261/203.
That was read as data/pointer corruption. It is not.

## 2. What the investigation actually showed

1. **The L2 is functionally correct.** A golden "shadow" model of the backing
   memory was added to the testbench (`tb_2core_coremark`): the initial image
   plus every store accepted at the L2 core ports, applied with byte enables.
   Every read response of *all four* L2 ports (i0, i1, c0, c1) and every dirty
   writeback beat is compared against it.

   ```text
   L2 shadow check: rsp=21981 err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0
   ```

   Not one mismatch. So no response to either hart was ever wrong, and no dirty
   line was ever written back with wrong data.

2. **Hart0's architectural execution is identical with and without hart1.**
   The full retire stream (PC, `rd_wen`, `rd`, `wdata` per retired
   instruction, 2.77M entries to the abort point) was dumped for
   (a) both harts in lockstep and (b) hart0 alone (`+H1EN=0`). The two streams
   are **byte-identical for all 2,768,013 instructions**, and the two harts are
   identical to each other as well. The reference stream continues normally past
   that index, so the instruction that tripped the assertion is not in the
   architectural stream: it is junk fetched behind a mispredicted branch.

3. **The misaligned accesses are speculative.** All 52 firings (26 per hart,
   over a 71 µs window) are the same operation — `addr=0x000000a3`, `size=1`
   (LH), `load`, `kill_now=0` — issued while the backend's architectural next PC
   was `0x8000_03d8`, i.e. on the wrong side of an incorrectly predicted control
   transfer. They are squashed.

`lsu_agu`'s `out_valid` is the *speculative issue stage*. A junk `LH` behind a
mispredicted branch legitimately carries any register value as its base, so it
can be "misaligned". Asserting alignment there is not a property of the design.

## 3. Fix

The natural-alignment contract (`SPEC-A1 / D-C0-01`) is now checked only where
an access becomes architectural, so squashed operations can never trip it:

| Check | Module | When |
|---|---|---|
| `a_load_natural_align` | `rtl/memory/lsu_top.sv` | a live LQ entry is handed to the cache (`lq_lookup_valid`) |
| `a_drain_mask_legal` | `rtl/memory/lsu_top.sv` | a COMMITTED store drains (pre-existing; already sound) |

The speculative assertion in `rtl/memory/lsu_agu.sv` was removed; the LQ exposes
`lookup_size` so the check can be expressed at the LSU boundary. Measured on the
dual-core run: the AGU check fired 52 times, the new load check fired **0**
times — the squashed junk never reaches a cache lookup.

A store can never corrupt memory this way: a store only reaches the L1D after
its SQ entry is COMMITTED (`sq_drain_valid` drives the dcache store path), so a
wrong-path store is dropped with its entry.

## 4. Testbench issues found on the way

* **Two-wide retire undercount.** Both CoreMark benches incremented the retire
  counter once per cycle inside the `lane` loop, so a cycle retiring two
  instructions counted once. Reported retires/IPC were ~1.5x low
  (single-hart was reported as 21,229,636 retires, IPC 0.425; the real numbers
  are 31,348,582 / 0.628). Fixed in `tb_ares_coremark` and `tb_2core_coremark`.
* **Same-cycle `a0` sampling.** `pass <= (a0 == 0)` read `a0` before a lane-0
  `mv a0, ...` committed in the same cycle. Both benches now use an effective
  value.
* **Aggregate CoreMark/MHz** assumed two harts unconditionally; it now follows
  `+H1EN`.

## 5. Reproduce

Build the software-CRC CoreMark image (100 iterations) and its 128-bit-wide
memory image:

~~~bash
export MUNDUS_HOME=/home/ccy/Documents/qs/Mundus
rm -rf /tmp/coremark_sw
cp -a $MUNDUS_HOME/am-kernels/benchmarks/coremark /tmp/coremark_sw
rm -rf /tmp/coremark_sw/build
sed -i 's/^#define ITERATIONS .*/#define ITERATIONS 100/' \
    /tmp/coremark_sw/include/core_portme.h

python3 - <<'PY'
from pathlib import Path
p = Path('/tmp/coremark_sw/src/core_main.c')
s = p.read_text()
s = s.replace('\ttotal_time=get_time();\n',
              '\ttotal_time=get_time();\n\t(void)total_time;\n', 1)
p.write_text(s)
PY

cd /tmp/coremark_sw
AM_HOME=$MUNDUS_HOME/abstract-machine \
NPC_HOME=$MUNDUS_HOME/npc NEMU_HOME=$MUNDUS_HOME/nemu \
MUNDUS_HOME=$MUNDUS_HOME \
make ARCH=riscv32-jyd CROSS_COMPILE=riscv64-unknown-elf- image

python3 - <<'PY'
from pathlib import Path
b = Path('/tmp/coremark_sw/build/coremark-riscv32-jyd.bin').read_bytes()
if len(b) % 16:
    b += b'\0' * (16 - len(b) % 16)
with open('/tmp/coremark_sw_dmem.hex', 'w') as f:
    for i in range(0, len(b), 16):
        f.write(f'{int.from_bytes(b[i:i+16], "little"):032x}\n')
PY
~~~

Single-hart reference (also the same L2/frontend path):

~~~bash
cd /home/ccy/Documents/qs/ARES
make unit-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

Two-hart AMP run:

~~~bash
make unit-2core-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

Both take ~10-20 min of Verilator wall time (the dual run is ~500k cycles of
simulated time).

## 6. Probes that are worth keeping

* `+H1EN=0` on `tb_2core_coremark` holds hart1 in reset and ends the run when
  hart0 finishes — a single-hart reference produced by the *same* binary, with
  the same L2 configuration.
* The L2 shadow checker is part of `tb_2core_coremark` now, so any future
  shared-L2 data-path regression is caught directly instead of being inferred
  from a downstream crash.

## 7. Importance

The frontend adapter, AXI bridge and AMP data offset were never at fault.
Do not chase the shared L2 for a dual-core failure without first checking
whether the failing access is architectural: dump the retire stream and compare
it against a single-hart run of the same image.
