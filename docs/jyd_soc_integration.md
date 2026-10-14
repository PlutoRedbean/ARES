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
miniTensor control/status remains external to `student_top` for that later work.

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
