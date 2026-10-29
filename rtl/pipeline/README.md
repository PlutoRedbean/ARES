# ARES pipeline single-issue SoC (M1.5 + CoreMark simulation)

Status: M1 core semantics, 36/36 ISA tests, and the baseline 100-iteration
CoreMark all pass in the standalone simulation.  The core and SoC sources are
imported from ysyx-workbench/npc; the jyd SoC uses a 32-bit IROM with no
64-bit compatibility path.

## Source provenance

| Part | Source | Commit |
| --- | --- | --- |
| Core | npc `5-stage-pipeline` | `1d839c86c8eee76c7540298a467700e065432e93` |
| SoC | npc `jyd` | `31f47241393120a9092527b65892b010e6e38234` |
| Base | ARES `pipeline` | `0eea64d62877ccd9f59a139b6fa49b931519030f` |

The M1 `FENCE/EBREAK/retire` changes are local to `core/scsrc` in this ARES
tree; the npc checkout remains untouched.

Generated core RTL:

- `core/vsrc/build/Mundus.sv` (firtool 1.77.0, 3192 lines)
- SHA-256 `4b50ab9388b322afdd2dc15fec6fc9724c78d637fd1365e551da63f05d71c05c`
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
  `vaddr_read` for simulation, inferred BRAM placeholder for synthesis.
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

## Verification

```bash
make pipeline-core-gen   # Chisel -> rtl/pipeline/core/vsrc/build/Mundus.sv
make pipeline-lint
make pipeline-smoke
make pipeline-isa         # 36/36 cpu-tests
make pipeline-coremark    # baseline 100-iteration CoreMark
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

## Known gaps (next milestones)

- Pango PDS is not installed on this Linux host; PG2L200H
  SystemVerilog/PDS/resource/timing checks remain pending.
- The ISA/CoreMark harnesses are standalone DPI TBs, not the ARES
  `tb_ares_cpu`/`tb_ares_coremark` scoreboards.
- The CoreMark `0xA000` window is currently a direct bridge modification; a
  native `0x8020` software/platform variant is still possible later.
- `IROM_BMEM32`/BRAM non-Verilator paths are placeholders; Pango BRAM wrappers
  and image initialization are M3 work.

## Regeneration

Do not hand-edit `core/vsrc/build/Mundus.sv`.  Edit `core/scsrc` and run:

```bash
make pipeline-core-gen
```

The generation project is `rtl/pipeline/gen`; its mill cache is
`rtl/pipeline/gen/out/` (ignored).  Re-importing from npc is only needed when
the upstream source tree changes.
