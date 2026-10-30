# Pipeline SoC: 2/4-hart coherent multi-core (M4)

> Status: RTL + Verilator implementation complete for 2 and 4 harts.
> Pango board wrapper and PDS/board signoff remain open.
> Baseline: pipeline-single-issue, after the M4 acceleration images.

## 1. Configuration

The number of harts is a build-time parameter, not a software switch:

| Build | Command | Top parameter |
| --- | --- | --- |
| Dual-core | `make pipeline-mc-run PIPELINE_MC_CORES=2` | `CORES=2` |
| Quad-core | `make pipeline-mc-run PIPELINE_MC_CORES=4` | `CORES=4` |
| Both | `make pipeline-mc-test` | runs both above |
| Lint both | `make pipeline-mc-lint` | `-GCORES=2/4` |

`CORES` is a parameter of `pipeline_mc_soc_top`; the same RTL elaborates in
both configurations.  The single-hart `student_top` profile is unchanged and
remains the CoreMark/ISA path.

## 2. Block diagram

```text
                 private per hart                     shared / coherent
  hart0: pipeline_hart ── 32-bit perip ── pipeline_core_port ─┐
         (Mundus core + private IROM)                          │
  hart1: pipeline_hart ── 32-bit perip ── pipeline_core_port ─┤
         ...                                                  ├─ pipeline_l2 ── 128-bit beat ── DRAM model/BRAM
  hartN: pipeline_hart ── 32-bit perip ── pipeline_core_port ─┘
                                                              │
                                              coh_inv_valid/addr, epoch
```

| File | Responsibility |
| --- | --- |
| `rtl/pipeline/soc/mc/pipeline_hart.sv` | one Mundus core + one private 32 KiB IROM + one core port |
| `rtl/pipeline/soc/mc/pipeline_core_port.sv` | converts 32-bit perip to 16 B L2 beats, classifies DRAM vs MMIO, one outstanding request |
| `rtl/pipeline/soc/mc/pipeline_l2.sv` | 64 B line, 16 B beat, 4-way write-back/write-allocate shared L2 |
| `rtl/pipeline/soc/mc/pipeline_mmio.sv` | per-hart hart id/count, cycle counter, UART, LED |
| `rtl/pipeline/soc/mc/pipeline_mc_soc_top.sv` | `CORES` parameter, shared L2, per-hart IROM/MMIO, retire observation |

## 3. Coherence protocol

The pipeline L1 D-cache is **write-through** and direct-mapped (8 KiB, 4 B
entries, tag + valid in BRAM).  A store always reaches the shared L2; a store
hit also updates the local L1 copy.  Therefore the shared layer only needs
**write-invalidate**:

1. The L2 accepts a store from hart *k* and updates/allocates the 64 B line.
2. It registers a one-cycle invalidate pulse to every hart except *k*.  The
   pulse carries the **exact stored word address**, because the L1 caches 4 B
   words, not 64 B lines.
3. Each L1 clears the direct-mapped tag at `addr[12:2]`.  No tag compare is
   needed; clearing the whole index cannot leave a stale alias.
4. The L2 increments an 8-bit `coh_epoch` on every accepted store.
5. A cacheable load captures the epoch when it leaves L1.  The epoch travels
   with the load through LS2/LS3.  On refill, the line is installed only if the
   captured epoch still equals the current L2 epoch.  This closes the race
   "read old line -> remote store -> install old line" without a directory.
6. MMIO loads are not part of the coherence protocol.

The protocol is deliberately **one L2 transaction at a time**.  The L2
round-robins over hart load/store valid bits; the request is latched in
`S_IDLE`, tag lookup happens in `S_LOOKUP`, and miss handling is split into
`S_WB -> S_RF_REQ -> S_RF_RSP -> S_RESP`.  The invalidate sideband is a
registered pulse, so the coherence path is flop-to-flop and is not in the data
array or arbitration path.

## 4. Memory map (multi-hart profile)

| Address | Size | Attribute | Use |
| --- | --- | --- | --- |
| `0x8000_0000` | 32 KiB | IROM (per hart, replicated image) | code |
| `0x8010_0000..0x8013_FFFF` | 256 KiB | cacheable, coherent via L2 | shared data, per-hart stacks |
| `0xA000_0FF0` | 4 B | private MMIO | hart id |
| `0xA000_0FF4` | 4 B | private MMIO | configured hart count |
| `0xA000_0050/54` | 8 B | private MMIO | 64-bit cycle counter |
| `0xA000_03F8` | 4 B | private MMIO | UART TX |
| `0xA000_03FC` | 4 B | private MMIO | UART status (bit0 = busy) |
| `0x8020_0060/64` | 8 B | private MMIO | jyd-compatible UART alias |
| `0x8020_0040` | 4 B | private MMIO | LED register |

MMIO is **per hart** (one `pipeline_mmio` instance per hart) so a dependent
MMIO load always sees the two-cycle response the pipeline core expects.  The
shared resource is the L2/DRAM, not the control registers.  The board top only
brings hart 0's UART to the physical pin; the other UARTs are available for
simulation/debug.

## 5. Critical-path / pipelining decisions

- L2 request latched before tag lookup; no combinational path from hart ports
  through the data arrays to the response.
- Round-robin arbitration is a small OR/priority over `CORES` valid bits
  (2 or 4), not a crossbar through the cache.
- Invalidate is a registered one-cycle pulse; L1 invalidation is a single
  tag-RAM write.
- Epoch comparison is an 8-bit equality on the refill path only.
- L1 stores remain write-through, so there is no dirty-line writeback/snoop
  protocol in the L1.
- MMIO response is a fixed registered two-cycle path (S_IDLE -> S_RSP1 -> S_RSP).
- Core port has one outstanding request; the response source/word is registered,
  so the core-facing rdata mux does not depend on the live perip address.
- Core-side fixes made while integrating multi-hart:
  - LSU `ls2_valid` is now flushed on a frontend redirect (previously the
    always-false `ex1_ex2_bubble` was used);
  - the speculative load-replay path is restricted to the cacheable L1 window,
    so a delayed MMIO load is not treated as a cache miss;
  - the core port holds a request until the core deasserts `perip_valid`, so a
    stalled request cannot be committed twice.

## 6. Test and evidence

The default multi-hart test is `tests/pipeline-mc/mc_linear.S`: a branch-free
program that every hart executes.  Each hart publishes one word into the shared
cacheable window, waits a fixed number of cycles, then reads every published
word and publishes its own result.  This exercises real L1 invalidations and L2
data, and avoids depending on the pipeline core's branch/flush corner cases.

Commands and observed results (Verilator 5.046):

```bash
make pipeline-mc-test
pipeline-mc: cores=2 active=3 cycles=4167 done=3/3 a0=[00000000,...] PASS
pipeline-mc: cores=4 active=f cycles=4221 done=f/f a0=[00000000,...] PASS
```

Additional gates kept green after the core changes:

```bash
make pipeline-smoke     # FENCE before/after stores, EBREAK halt
make pipeline-isa       # 36/36 cpu-tests
make pipeline-mc-lint   # 2 and 4 hart elaboration
make unit-l2            # existing L2 reference model (single/dual port)
```

The standalone L2 coherence checker is `rtl/pipeline/test/tb_pipeline_l2_mc.sv`
(`CORES=2/4`): it checks read/write visibility, invalidate-to-other-harts,
writer-not-invalidated, epoch advancement and dirty-victim writeback.

## 7. Limits / next steps

- L2 is a bring-up single-transaction cache: no per-port MSHR, banking, QoS,
  writeback queue or sectoring.  Those remain the PPA/performance step.
- The 2/4-hart top is simulated; a Pango board wrapper and 128-bit shared-DRAM
  `$readmemh` image are still needed for PDS synthesis, timing and board run.
- The shared L2 is coherent for the L1 D-cache; instruction fetch is per-hart
  IROM replication, so code is coherent by construction.  Dynamic code loading
  and FENCE.I/ICache maintenance remain a separate task.
- Software still owns inter-hart ordering: the program must use FENCE around
  shared flags/data.  The hardware provides write-invalidate visibility, not
  an atomic memory model (no A extension).
