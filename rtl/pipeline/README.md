# ARES pipeline single-issue SoC (M1.5 + CoreMark + M4 acceleration)

Status: M1 core semantics, 36/36 ISA tests, and the baseline 100-iteration
CoreMark all pass in the standalone simulation.  The RTL-level Pango platform
layer is in place: Xilinx XPM CDC removed, inferred/initialized IROM+DRAM,
100/50 MHz PLL, per-domain reset, UART board top, and a PDS flow.  The PDS
synthesis/implementation/board run itself still has to be executed on the
Pango tool host.  The core and SoC sources are imported from
ysyx-workbench/npc; the jyd SoC uses a 32-bit IROM with no 64-bit
compatibility path.

M4 accelerated images are also implemented on this pipeline: the core decodes
the ARES custom-0 CRC8 instruction (split into two 4-bit EX1/EX2 stages), and
the SoC instantiates the existing 9-PE matrix engine and state-machine token
scanner behind a small 0xA000_1000 / 0xA000_2000 MMIO wrapper.  The 100-iteration
simulation passes all known CoreMark CRCs; full acceleration reaches
7.916002 CoreMark/MHz.  See [docs/pipeline_accel_images.md](../../docs/pipeline_accel_images.md).

## Source provenance

| Part | Source | Commit |
| --- | --- | --- |
| Core | npc `5-stage-pipeline` | `1d839c86c8eee76c7540298a467700e065432e93` |
| SoC | npc `jyd` | `31f47241393120a9092527b65892b010e6e38234` |
| Base | ARES `pipeline` | `0eea64d62877ccd9f59a139b6fa49b931519030f` |

The M1 `FENCE/EBREAK/retire` changes are local to `core/scsrc` in this ARES
tree; the npc checkout remains untouched.

Generated core RTL:

- `core/vsrc/build/Mundus.sv` (firtool 1.77.0, 3335 lines)
- SHA-256 `1aa0e9390eb9bc769deac1db0b69492715d7e0320623874612a8ff492862a12b`
- Generated **inside this ARES checkout** by `rtl/pipeline/gen` with
  `make pipeline-core-gen`; the output target is
  `rtl/pipeline/core/vsrc/build/Mundus.sv`.
- The core is generated with `CONFIG_SIMULATION=false` in
  `gen/configs/scsrc/autoconf.scala`, so the npc difftest/DPIC hooks are not
  emitted.

A per-file hash manifest is in `MANIFEST.sha256`; `gen/out/` is a local
mill cache and is git-ignored.

Imported trees:

```text
rtl/pipeline/core/scsrc/                 # 5-stage-pipeline Chisel source
rtl/pipeline/core/vsrc/Mundus/           # handwritten core wrappers
rtl/pipeline/core/vsrc/modules/          # generic modules
rtl/pipeline/core/vsrc/include/          # inst_para.vh / common_para.vh ...
rtl/pipeline/core/vsrc/DPIC/             # empty unless DPIC is defined
rtl/pipeline/core/vsrc/build/Mundus.sv   # generated core (ARES target)
rtl/pipeline/soc/jyd/                    # jyd SoC / peripheral RTL
rtl/pipeline/soc/ip/                     # jyd/5-stage memory and MDU models
rtl/pipeline/soc/pango/                  # Pango CDC + inferred DRAM
rtl/pipeline/board/                      # PLL, clock/reset, board top
rtl/pipeline/test/                       # smoke TB + DPI memory model
rtl/pipeline/gen/                        # ARES-local mill build for the core
```

## Direct modifications

- `soc/jyd/student_top.sv` uses a 32-bit instruction word:
  - `instruction[31:0]` instead of `[63:0]`;
  - `inst_addr = pc[CONFIG_IROM_ADDR_WIDTH+2:2]` (32-bit word index);
  - `IROM_BMEM32` instead of `IROM_BMEM`;
  - the jyd `myCPU` `timer_irq` connection is removed; the 5-stage core has no
    interrupt port and interrupts are out of scope;
  - commit observation ports are exported.
- `soc/jyd/irom_bmem32.sv`: 8192 x 32-bit entries, one-cycle read, DPI
  `vaddr_read` for simulation, inferred BRAM initialized from
  `build/pipeline/irom.hex` for synthesis.
- `include/pipeline_autoconf.vh`: merged core/SoC parameters.
  `CONFIG_IROM_ADDR_WIDTH` remains 12 (old 64-bit-pair width); the 32-bit
  wrapper uses one extra address bit.
- `include/autoconf.vh`: shim for the unmodified jyd includes.
- Core M1 changes:
  - `FENCE`/`FENCE.I` decode as an `ENVIR_FENCE` barrier; the fence is held
    in Decode until `EXU.lsu_idle` and the jyd peripheral bridge `perip_idle`
    are both true;
  - `EBREAK` is commit-visible via `retire_is_ebreak`; a sticky halt bit
    freezes the pipeline after it retires;
  - `retire_valid/pc/pc_next/rd_wen/rd/wdata/is_ebreak` are exported from
    `Mundus`, `myCPU` and `student_top`;
  - `PERIP.idle` and `LSU.idle` were added for the fence handshake.
- `soc/jyd/perip_bridge.sv` exports `perip_idle` (store queue empty, no staged
  BRAM write, no response in flight).
- `soc/jyd/perip_bridge.sv` also implements the CoreMark `0xA000_xxxx` window:
  - `0xA000_03F8` write aliases the native UART TX;
  - `0xA000_03FC` read returns bit0 = UART busy (`~console_tx_ready`);
  - `0xA000_0050/54` read a free-running 64-bit CPU cycle counter.
  The native jyd `0x8020_xxxx` map remains unchanged.

## Pango platform layer (M3 RTL preparation)

The imported jyd SoC depended on Xilinx XPM and DPI-only memories.  Those are
replaced by portable, synthesizable RTL:

| Area | Implementation |
| --- | --- |
| CDC | `soc/pango/pipeline_cdc.v`: 2-FF single/array synchronizers, gray-code counter CDC, four-phase bundled-data mailbox. No XPM. |
| Reset | Async assert / sync release per clock domain (`pipeline_cdc_reset_sync`), including a `cnt_rst` inside `perip_bridge` and `counter`. |
| DRAM | `soc/pango/pipeline_bram.v` (`BRAM`, 65536 x 32, byte enables, 2-cycle read) replaces the DPI model in the PDS file list; initialized from `build/pipeline/dram.hex`. |
| IROM | `irom_bmem32.sv` synthesizes to inferred BRAM initialized from `build/pipeline/irom.hex`. |
| MDU | Divide-by-zero now returns the architectural `{-1, dividend}` instead of the non-synthesizable `$random` probe. |
| Clocks | `board/pipeline_pll.v`: 27 MHz -> 100 MHz CPU / 50 MHz peripheral (`GTP_GPLL`), simulation model in `pipeline_pll_sim.v`. |
| Board | `board/pipeline_board_top.v` + `fpga/pango/pipeline/`: pins, generated clocks, PDS `compile/synthesize/dev_map/pnr` flow. |

File lists:

- `pipeline.f`: Verilator simulation (DPI memories, behavioural PLL).
- `pipeline_mc.f`: `pipeline.f` plus the multi-hart coherent SoC files.
- `pipeline_pango.f`: PDS synthesis (no DPI, inferred memories, `GTP_GPLL`).

The SoC wrappers (`student_top`, `perip_bridge`, `pipeline_accel`) are
written in Verilog-2001-compatible style; the reused accelerator engines
(`rtl/accel/*.sv`) are SystemVerilog.  The generated `Mundus.sv` is
Verilog-2001 style.  The PDS flow compiles with
`-verilog_standard {SystemVerilog}`, which covers the accelerator engines.

Image split (the ARES ELF is dense from 0x8000_0000):

```bash
make coremark-image     # if build/coremark does not exist yet
make pipeline-image     # -> build/pipeline/{irom,dram}.hex + image.json
```

## Verification

```bash
make pipeline-core-gen   # Chisel -> rtl/pipeline/core/vsrc/build/Mundus.sv
make pipeline-lint
make pipeline-smoke
make pipeline-isa         # 36/36 cpu-tests
make pipeline-coremark    # baseline 100-iteration CoreMark
make pipeline-image       # Pango IROM/DRAM readmemh split
make pipeline-pango-lint  # board top + PLL model + Pango CDC
make pipeline-console     # Pango-only CDC/UART/mailbox directed test
make pipeline-coremark-images          # CRC / matrix / state / full
make pipeline-coremark-{crc,matrix,state,full}
make pipeline-image PIPELINE_IMAGE_ELF=<elf> PIPELINE_IMAGE_OUT=<dir>
make pipeline-mc-test                  # 2-hart + 4-hart coherent SoC
make pipeline-mc-lint                  # both CORES options
make pipeline-coremark-mc              # 2-hart full-accelerated CoreMark (AMP)
```

- `pipeline-core-gen`: writes the generated core into ARES, not into npc.
- `pipeline-lint`: Verilator 5.046, 0 errors; warnings are the imported
  timescale/decl-filename/unused-signal classes.
- `pipeline-smoke`: 8-instruction program:
  `lui/addi/sw/fence/addi/sw/ebreak/jal`.
  It observes:
  - store `0x55` to `0x80100000` before the fence;
  - store `0x66` to `0x80100004` after the fence (proves the fence released);
  - `RETIRE ebreak pc=0x80000018` and `ebreak_seen=1`;
  - the pipeline halts after EBREAK.
- `pipeline-isa`: 36/36 ISA tests pass.  The harness loads each
  `tests/cpu-tests/build/*-riscv32-ares.bin` image and checks EBREAK plus a0.
- `pipeline-coremark`: baseline `build/coremark/coremark.bin`, 100 iterations:
  - timed cycles `43,597,126`;
  - `2,293,729` CoreMark/MHz;
  - CRCs `e714 / 1fd7 / 8e3a / 988c` and `CoreMark PASS`.
- `pipeline-console`: compiles the SoC without `__VERILATOR__`, so it runs the
  same CDC/UART/BRAM path as the Pango board (100 MHz CPU / 50 MHz peripheral,
  generic CDC, real UART toggle handshake, LED/SEG mailbox, inferred IROM/DRAM
  initialized from `build/pipeline/{irom,dram}.hex`).  It checks the IROM/DRAM
  image words, SW CDC, LED mailbox, `O K \n` on the UART pin, and the cycle
  counter; `CONSOLE PASS` with `errors=0`.  The IROM/DRAM word checks assume
  the frozen CoreMark image in `build/pipeline/image.json`.

## M4 accelerated images

The pipeline SoC reuses the OoO accelerator RTL and software variants:

| Variant | Hardware | 100-iter CoreMark/MHz |
| --- | --- | ---: |
| Baseline | - | 2.293729 |
| CRC | custom-0 CRC8, EX1/EX2 4-bit stages | 2.676882 |
| CRC + matrix | `mtx9_engine` at 0xA000_1000 | 4.080407 |
| CRC + state | `state9_engine` at 0xA000_2000 | 4.289536 |
| Full | CRC + array list + matrix + state | 7.916002 |

All four variants print `e714 / 1fd7 / 8e3a / 988c` and `CoreMark PASS`.
The full image occupies 7609 / 8192 IROM words, so code-size headroom is small.
See `docs/pipeline_accel_images.md` for the MMIO map, response timing and
critical-path notes.

## M4 multi-hart coherent SoC

The pipeline SoC now has a configurable 2/4-hart coherent build:

| Block | File | Role |
| --- | --- | --- |
| Hart | `soc/mc/pipeline_hart.sv` | Mundus core + private IROM + L2/MMIO adapter |
| L2 | `soc/mc/pipeline_l2.sv` | 64 B line, 16 B beat, 4-way write-back shared L2; word-granular write-invalidate and an 8-bit coherence epoch |
| Core port | `soc/mc/pipeline_core_port.sv` | 32-bit perip ↔ 128-bit L2 beat + private MMIO; one outstanding request |
| MMIO | `soc/mc/pipeline_mmio.sv` | Per-hart hart-id/count, 64-bit cycle counter, UART, LED, per-hart matrix/state MMIO |
| SoC | `soc/mc/pipeline_mc_soc_top.sv` | `CORES=2` or `CORES=4`; shared L2, per-hart IROM/MMIO; `DATA_STRIDE` |
| AMP SoC v2 | `soc/amp/pipeline_amp_top.sv` | `CORES=2/4`; shared IROM + per-hart I$ or replicated banks + private DRAM window + shared mailbox |
| I$ | `soc/amp/pipeline_icache.sv` | per-hart 16 KiB direct-mapped instruction cache, 64 B lines, `irom.ready` miss stall |
| IROM arbiter | `soc/amp/pipeline_irom_arbiter.sv` | round-robin refill bursts over one shared 32 KiB IROM bank |
| AMP CoreMark | `soc/mc/pipeline_coremark_amp_top.sv` | legacy-name wrapper over `pipeline_amp_top` |
| MT mailbox | `soc/mc/pipeline_coremark_mbox.sv` | shared uncached CoreMark mailbox, 4 slots × 16 words at `0xA000_F000` |
| AMP link | `tests/abstract-machine/scripts/ares-linker-mc.ld` | 32 KiB per-hart private window, `_stack_top=0x8010_8000` |
| AMP TB | `test/tb_pipeline_coremark_amp.sv` | 2/4-hart CoreMark TB (four completion ports) |

The L1 D-cache is write-through, so coherence is write-invalidate: an L2
store pulses the exact word address to every other hart, and the L1 clears that
direct-mapped tag.  A refill carries the epoch sampled when the load left L1;
if any L2 write happened while the refill was in flight, the line is not
installed.  This avoids a per-line directory and keeps the invalidate sideband
to a single tag-RAM write.  The L2 request is latched before lookup; arbitration
is a small round-robin over hart valid bits, not a path through the data arrays.

`student_top` remains the single-hart profile.  `pipeline_amp_top` is the
2/4-hart non-coherent AMP profile.  By default (`USE_ICACHE=1`) the harts share
one 32 KiB IROM bank and each hart has a private 16 KiB direct-mapped I$
(64 B lines, `irom.ready` miss stall) whose refills are burst-arbitrated; the
`USE_ICACHE=0` profile is the Phase 2 variant with one replicated 32 KiB bank
per hart.  Every hart also has a private 32 KiB DRAM window (`DATA_OFFSET`),
private MMIO/accelerators and a shared uncached mailbox.
`pipeline_coremark_amp_top` is kept as a legacy-name wrapper.
`pipeline_mc_soc_top` is the 2/4-hart coherent profile;
`core_en` holds selected harts in reset for debug.
The multi-hart MMIO is private per hart, so an MMIO load always sees the
two-cycle response the pipeline core expects; the shared resource is L2/DRAM.

`pipeline_coremark_amp_top` is the first full-accelerated CoreMark profile:
each hart instantiates its own `student_top` (private IROM, perip_bridge DRAM,
UART/timer and matrix/state engines).  `DATA_OFFSET` gives each hart a private
32 KiB data window; the image uses
`tests/abstract-machine/scripts/ares-linker-mc.ld` with
`_stack_top=0x8010_8000`.  `make pipeline-coremark-mc` runs two harts and both
report 7.916002 CoreMark/MHz (aggregate 15.832004); the shared-L2 CoreMark
profile still needs the L2 response-ordering fix described in the multi-core
doc.

The standard CoreMark `MULTITHREAD` profile reuses that top with a rendezvous
path: `pipeline_coremark_mbox` (slot h = `0xA000_F000 + h*0x40`) plus a per-hart
id at `0xA000_0FF0` in `perip_bridge`.  `scripts/coremark_mt_pipe/` is a
parameterized overlay (`ARES_MT_CORES`, `ARES_MT_ITERATIONS` passed as staged
Makefile defines), so the 2- and 4-hart images are separate builds.  Since a
full 10,000-iteration run is hours of Verilator time, `make pipeline-coremark-mt
CORES=2|4` uses `PIPELINE_MT_SIM_TOTAL=200` (2×100 / 4×50) and prints a single
aggregate report: 2 harts 4.580135 CoreMark/MHz, 4 harts 9.167960 CoreMark/MHz
(200 iterations each, near-linear scaling).  Every context CRC matches the
single-hart reference (0x988c for 100 iterations, 0x0158 for 50) and every hart
exits with `a0=0`.  The full-accelerated single-report run is
`make pipeline-coremark-full-mt CORES=2` (512-line I$, 200 total iterations):
15.816722 CoreMark/MHz, CRCs 0x988c ×2, `CoreMark PASS`.  Its IROM image is
32,432 B of the 32 KiB bank, so the **4-hart full-accelerated aggregate image
does not fit** (linker overflow by 300 B); use `make pipeline-coremark-mc
CORES=4` for the 4-hart full-accelerated AMP profile (one MULTITHREAD=1 report
per hart) or grow the IROM in a later milestone.
See [docs/pipeline_coremark_mt_plan.md](../../docs/pipeline_coremark_mt_plan.md) for
the architecture and [docs/pipeline_coremark_full_mt_flow.md](../../docs/pipeline_coremark_full_mt_flow.md)
for the step-by-step IROM image build and full-accelerated MT run.

Phase 3 adds the per-hart instruction cache and collapses the IROM to one
shared bank: the IFU now waits on `irom.ready`, each hart has a 16 KiB
direct-mapped I$, and a round-robin arbiter grants whole 64 B refill bursts.
With the 200-iteration profile the scores are 4.579943 (2 harts) and 9.166984
(4 harts) CoreMark/MHz - within 0.03% of the no-cache/replicated-bank profile -
while the whole run fetches only 5,072 / 8,784 words from the shared IROM
instead of reading a bank on every fetch cycle.  The ~30 KiB full-accelerated
images use the 512-line (32 KiB) I$ in `pipeline-coremark-mc` to avoid capacity
misses.

See [docs/pipeline_multicore.md](../../docs/pipeline_multicore.md) for the
protocol, memory map, timing notes and test evidence.

## Known gaps (next milestones)

- The 2-hart full-accelerated aggregate image uses 8,108 / 8,192 IROM words
  (32,432 B of 32 KiB, 336 B spare).  The 4-hart aggregate version needs about
  33,068 B and does not link; 4-hart full acceleration currently runs as the
  AMP profile (30,436 B MULTITHREAD=1 image).  Growing the IROM to 64 KiB or
  trimming code is a Phase 4 item.
- Pango PDS is not installed on this Linux host.  The RTL/platform layer is
  ready, but PG2L200H synthesis, implementation, timing/resources and the
  on-board run still have to be executed on the Pango host; see
  `fpga/pango/pipeline/README.md`.
- The board top ties UART RX idle because the existing Pango board profile has
  no RX pin.  CoreMark scoring only needs TX.
- The ISA/CoreMark harnesses are standalone DPI TBs, not the ARES
  `tb_ares_cpu`/`tb_ares_coremark` scoreboards.
- The CoreMark `0xA000` window is currently a direct bridge modification; a
  native `0x8020` software/platform variant is still possible later.
- The PLL parameters and inferred-RAM `$readmemh` flow must be confirmed by
  the first PDS build (see the flow README for expected reports).
- The 2/4-hart coherent top is verified in Verilator.  A Pango board wrapper
  and 128-bit shared-DRAM `$readmemh` image are still needed for PDS/board
  signoff; the L2 itself is BRAM-friendly and has no vendor primitives.
- The private-memory AMP CoreMark profile passes for two harts.  The shared-L2
  CoreMark path still has a response-ordering bug on overlapping loads (first
  `.rodata` table read is captured zero/one-behind in the L1 refill path);
  fix that before accepting a shared-L2 multi-hart CoreMark score.
- The approved non-coherent 2/4-hart CoreMark MULTITHREAD plan (shared IROM,
  private DRAM, per-hart accelerators, no L2/coherence) is in
  [docs/pipeline_coremark_mt_plan.md](../../docs/pipeline_coremark_mt_plan.md).

## Regeneration

Do not hand-edit `core/vsrc/build/Mundus.sv`.  Edit `core/scsrc` and run:

```bash
make pipeline-core-gen
```

The generation project is `rtl/pipeline/gen`; its mill cache is
`rtl/pipeline/gen/out/` (ignored).  Re-importing from npc is only needed when
the upstream source tree changes.
