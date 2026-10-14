# JYD SoC migration decisions and boundary

## Approved scope (2026-10-14)

The user selected the JYD2025 FPGA/project configuration and copied the platform
into `npc/` for migration. Historical reports and old Core/IP contents are not
trusted implementation evidence. The user explicitly approved:

1. Migrate SoC and build scripts now; keep the ARES Core's FE contract exposed.
   Real FE integration remains C5 work.
2. Retain the copied SoC's device addresses and uncached aliases, recording
   their differences from the generic ARES memory specification.

`rtl/top/student_top.sv` now instantiates **`ares_core_top Core_cpu`**, not the old
`myCPU`. It keeps the fixed JYD board widths (64 switches, eight keys, 32 LEDs,
40 SEG signals), CPU/peripheral clocks and active-high reset. Additional ports
carry IQ/Redirect/BPU Update unchanged from `ares_core_top`, a synchronous IROM
address/data seam for the future FE, and miniTensor control/status signals.
This is a subsystem integration top, not a complete physical board top.

The transplanted helpers reside in `rtl/soc/jyd/`. They do not include legacy
Core RTL, legacy `autoconf.vh`, old vendor IP or DMA DPI implementations.
`perip_bridge` now accepts **four byte strobes and already aligned word data**,
replacing its old size mask/repeated byte data convention. The width converter
is its sole caller, and uses the same byte-lane convention as ARES LSU/MMIO.
`perip_order_idle` is a new read-only output indicating drained/staged stores;
uncached-memory write acknowledgements wait for actual RAM writes to finish.
SEG scan reset is synchronous and active high, consistent with ARES RTL reset
rules. CDC helpers use actual Vivado XPM in hardware; test-only models are
excluded from the generated project.

## Address profile and architectural differences

| Window | Migrated behavior |
|---|---|
| `0x8000_0000`, low 32KiB | 64-bit IROM pairs, synchronous one-cycle read; `ifetch_addr[14:3]` indexes ROM |
| `0x8010_0000–0x8013_FFFF` | cacheable DRAM, physically 256KiB |
| `0x8020_0000/0004/0010` | switch low/high words and keys |
| `0x8020_0020/0040/0050` | SEG, LED and millisecond counter |
| `0x8020_0060/0064/0068` | UART console TX, status and RX |
| `0x8020_1000–0x8020_101F` | miniTensor register control seam; status `+0x10`, result `+0x14` |
| `0x8030_0000–0x8033_FFFF` | uncached alias of the low DRAM; address bit 21 is cleared |
| `0x8040_0000–0x83FF_FFFF` | copied extended-window decoder; on this FPGA BRAM backing uses only low 18 address bits |

The last row reflects the **actual copied decode**, wider than its old comment
claim of `0x8040_0000–0x80FF_FFFF`. This migration does not pretend that the FPGA
has 12/64MiB of backing RAM: those addresses mirror the physical 256KiB. The
copied decoder and aliases are kept under the user's explicit choice; software
must use the actual physical capacity. Holes outside these decoded windows are
not a supported memory contract.

The generic ARES default remains `0xA000_xxxx` MMIO with no uncached aliases.
For the JYD profile only, `student_top` sets `MMIO_BASE=0x8020_0000`,
`MMIO_MASK=0xFFF0_0000`, and enables `JYD_UNCACHED_WINDOWS`. The new default-off
parameter passes through `ares_core_top` → `lsu_top` → `lsu_agu`; it classifies
the two uncached windows into the existing device req/rsp channel, bypassing
DCache. AGU stage count, Issue/Completion/Commit interfaces and generic defaults
are unchanged. This is an explicitly approved exception to memory.md's
non-aliasing physical-window rule, not a global spec replacement.

**No coherence is added between cached and uncached aliases.** Software must
avoid overlapping dirty cached data and uncached/DMA access. The original
miniTensor DMA bridge imports DPI unconditionally and is not synthesizable.
Its FPGA integration requires real shared-memory arbitration and visibility
decisions; it is not imported or silently tied to a dummy memory here.
miniTensor control/status remains external to `student_top`; the first ARES
control-path adaptation now connects it in a separate integration top,
`ares_soc_top`. See [miniTensor_soc_integration.md](miniTensor_soc_integration.md).

The copied counter emits a one-CPU-cycle IRQ pulse at millisecond changes after
being enabled; it is **not** an `mtime/mtimecmp` level interrupt controller.
SPEC-M12 is still open. This preserves the chosen platform behavior and does
not claim completion of the generic machine-timer/RTOS contract.

## Width converter contract

`ares_jyd_bus_bridge` owns four complete accepted 16-byte write beats (the
Fabric write queue required by memory.md §6.7). Each beat drains in ascending
32-bit word order with exact byte enables; zero-enable words are skipped.
Resource availability uses registered occupancy without borrowing a same-cycle
release. Payload remains stable under peripheral stalls.

There is one outstanding read, assembled from four peripheral word responses.
The full 128-bit result is held until `mem_rsp_ready`. MMIO is single-outstanding
and holds its result until `mmio_rsp_ready`. Reads and MMIO cannot pass older
accepted writes; they wait for both converter and peripheral write staging to
drain. A pending read or MMIO prevents new writes from extending that drain
indefinitely. MMIO write ACK is generated only after the device has accepted the
operation and the peripheral RAM store pipeline is idle. Reset cancels queues
and outstanding responses; it does not clear BRAM contents.

The legacy hardware port is only 32 bits; splitting 16-byte misses/writebacks
is a board-specific memory service cost. It does not change core issue width,
FU latency, cache-hit path, LSU completion bandwidth or the accepted 128-bit
bus protocol. Real frontend and multi-master DMA throughput remain unverified.

## Verification and integration fixes

- `make test-vivado`: generator tests (clean input set, config/image validation,
  output overwrite guards, clock/profile guards, relocation/Tcl literal paths).
- `make lint-soc`: whole `student_top`, real Core, platform helpers and IP timing
  models; intentional unconnected debug/mailbox pins are explicitly waived.
- `make lint-mt`: elaborates `student_top` + `ares_soc_top` + `mini_tensor_top`
  + `ares_mt_host_adapter` through the CV-X-IF host path; 0 warnings.
- `make unit-soc`: `tb_jyd_bus` exercises the real peripheral bridge under
  random downstream stalls, arbitrary byte masks, queue full/wrap/concurrent
  enqueue/dequeue, response backpressure, reset, aliases, MMIO and LED CDC;
  `tb_student_top` retires 12 instructions through real ARES Core, testing
  uncached stores/loads, MMIO and a cache miss/hit after a visible alias store.
- `tb_lsu_agu` retains default coverage and adds explicitly enabled uncached
  windows with boundaries and computed-address classification.
- Existing Backend/LSU unit suites and FE-stub ISA regression remain the generic
  core regression; they are separate from SoC and real-FE verification.

Executed validation (2026-10-14): generator **7/7**, Backend **4/4 TB**, LSU
**11/11 TB**, SoC **2/2 TB**, generic FE-stub ISA **36/36**; final lint targets
passed. The SoC bus bench produced **2864 checks**; the student_top bench
retired **12 instructions / 14 checks**. Actual Vivado IP generation and SoC
OOC synthesis completed on `xc7k325tffg900-2` with the preserved strategies.
The final synthesis contains **zero latches**, LUT **42428**, FF **16664**,
BRAM Tile **74.5**, DSP **5**. CPU target was 250MHz (4ns), not achieved Fmax:
synthesis WNS **-9.888ns**, TNS **-180019.219ns**, WHS **0.059ns**, THS **0**;
worst path is BRU `op_src1_reg[0]` → SMUL `op_result_reg[16]`. Internal
no_clock/unconstrained endpoints are zero; exposed OOC ports still lack
493 input and 491 output delay constraints. Board routing and PPA remain
unverified. Reports are in `build/vivado/soc-synth-final/reports/`.

Vivado initially rejected unqualified package types/constants in ANSI module
ports before their module-body import; they are now explicitly qualified.
Its first synthesis also inferred latches in `be_operand_read` around a loop
`continue`; an equivalent complete `if/else` supplies every output on every
path. The dispatch decode-consistency assertions now sample at clock edges,
avoiding transient combinational false failures in the integrated testbench.
These compatibility fixes preserve interface widths and active datapath behavior.

See [Vivado workflow](../fpga/vivado/README.md) for project creation and future
board routing. Subsystem synthesis is diagnostic; no post-route MC4 acceptance
is claimed by this migration. Tool reports and build inputs live under the
ignored `build/vivado/` tree.

## Files outside Backend/Memory and handoff

| Files | Necessity / compatibility / follow-up |
|---|---|
| `rtl/top/ares_core_top.sv` | Pass the default-off JYD classification parameter to LSU; generic port/latency behavior unchanged |
| `rtl/top/student_top.sv` | Replace old Core with ARES and expose its FE contract; FE/board owner must connect real FE and physical top later |
| `rtl/top/ares_soc_top.sv` | Integration top: student_top + CV-X-IF host adapter + real mini_tensor_top; DMA exported for the future Fabric |
| `rtl/soc/ares_mt_host_adapter.sv` | ARES-owned MMIO -> CV-X-IF host adapter (S09 control path) |
| `rtl/soc/jyd/ares_jyd_bus_bridge.sv` | New 16B→32-bit board adapter; preserves accepted write ownership, read ordering and MMIO ACK |
| `rtl/soc/jyd/perip_bridge.sv` | Migrate board map/CDC; byte-strobe caller updated with adapter; new idle observation; aliases deliberately retain copied backing semantics |
| `rtl/soc/jyd/bram_driver.sv` | Retain hardware BRAM port wiring; independent of old simulation config/DPI memory |
| `rtl/soc/jyd/counter.sv` | Migrate counter/IRQ without legacy config header; M-mode timer semantics remain a later architecture decision |
| `rtl/soc/jyd/cdc_xpm_nofifo_lib.sv` | Retain platform XPM CDC helpers; final board CDC still requires independent sign-off |
| `rtl/soc/jyd/display_seg.sv`, `seg7.sv` | Platform SEG output dependencies; synchronous reset migration; board default widths retained |
| `rtl/soc/jyd/test/tb_jyd_bus.sv`, `tb_student_top.sv` | Self-checking platform/Core integration tests; no synthesized test logic |
| `rtl/soc/jyd/test/memory_ip_models.sv`, `xpm_cdc_models.sv` | Unit-test timing/CDC models only; not substitutes for hardware IP/CDC sign-off |
| `scripts/vivado/create_project.py`, `generate.tcl`, `test_create_project.py` | Portable generator, vendor execution and input/guard tests; full board needs a complete source manifest |
| `fpga/vivado/baseline.xml`, `constraints/board.xdc` | Versioned non-source/IP project configuration and original board constraints; final I/O timing and clock exceptions still need validation |
| `fpga/vivado/ip/memories.tcl`, `ip/pll.tcl` | Reproducible fresh catalog IP, with explicit widths/latencies/frequencies |
| `fpga/vivado/README.md` | Team generation/configuration/build/sign-off instructions |
| `Makefile`, `.gitignore` | Team entry points and generated-output exclusion; ARES targets retained, legacy `lint-npc` retired during repository cleanup |
| `docs/implementation_plan.md`, this document | Track authorized scope, mapping exceptions, validation and remaining MC4/C5 work |

Original `npc/` was removed after migration during repository cleanup.
The miniTensor RTL, tests and RT-Thread integration sources are retained and are not
implicitly imported by the generator. Cleanup updates the index only for the
removed legacy files and untracked generated blobs; no commit was created.
