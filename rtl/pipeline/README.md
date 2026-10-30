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

- `core/vsrc/build/Mundus.sv` (firtool 1.77.0, 3326 lines)
- SHA-256 `54b79fdd0d2614e12518a8bdafb285fa979cee71e03da016313e147d63c70ca9`
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
| MMIO | `soc/mc/pipeline_mmio.sv` | Per-hart hart-id/count, 64-bit cycle counter, UART, LED |
| SoC | `soc/mc/pipeline_mc_soc_top.sv` | `CORES=2` or `CORES=4`; shared L2, per-hart IROM/MMIO |

The L1 D-cache is write-through, so coherence is write-invalidate: an L2
store pulses the exact word address to every other hart, and the L1 clears that
direct-mapped tag.  A refill carries the epoch sampled when the load left L1;
if any L2 write happened while the refill was in flight, the line is not
installed.  This avoids a per-line directory and keeps the invalidate sideband
to a single tag-RAM write.  The L2 request is latched before lookup; arbitration
is a small round-robin over hart valid bits, not a path through the data arrays.

`student_top` remains the single-hart profile.  `pipeline_mc_soc_top` is the
2/4-hart profile; `core_en` holds selected harts in reset for debug.  The
multi-hart MMIO is private per hart, so an MMIO load always sees the two-cycle
response the pipeline core expects; the shared resource is the L2/DRAM.

See [docs/pipeline_multicore.md](../../docs/pipeline_multicore.md) for the
protocol, memory map, timing notes and test evidence.

## Known gaps (next milestones)

- The full accelerated CoreMark image uses 7609 / 8192 IROM words (about
  30.4 KiB of 32 KiB); further code growth needs trimming or a larger IROM.
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

## Regeneration

Do not hand-edit `core/vsrc/build/Mundus.sv`.  Edit `core/scsrc` and run:

```bash
make pipeline-core-gen
```

The generation project is `rtl/pipeline/gen`; its mill cache is
`rtl/pipeline/gen/out/` (ignored).  Re-importing from npc is only needed when
the upstream source tree changes.
