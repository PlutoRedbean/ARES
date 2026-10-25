# Reproducible ARES Vivado projects

The project mainline is the **shared-L2 ARES SoC**. The current generator and
`fpga/board.json` still select JYD `student_top`/the existing board wrapper,
without shared L2. The commands below are reference platform generation and
regression entry points. A complete L2 SoC board top/manifest/profile and its
clock/resource targets must be integrated before mainline FPGA sign-off; see
[the Implementation Plan](../../docs/implementation_plan.md).

Run from the repository with Python 3 and **Vivado 2025.2** on PATH. No original
Vivado checkout, `npc/`, `miniTensor/`, XCI, generated RTL, DCP or GUI setup is
required. All generated files belong in a new output directory.

```bash
# Generate the migrated student_top subsystem project and its IROM/BRAM IP.
# 250 is an example requested CPU frequency, not measured Fmax.
python3 scripts/vivado/create_project.py --cpu-mhz 250

# Also generate the new board PLL, ready for a future physical board wrapper.
python3 scripts/vivado/create_project.py --cpu-mhz 250 --with-pll \
    --output build/vivado/with-pll

# Run actual subsystem synthesis, including IP synthesis.
python3 scripts/vivado/create_project.py --cpu-mhz 250 --stage synth \
    --jobs 4 --output build/vivado/synth

# Backend/LSU only, with DCache data IP but without SoC memories.
python3 scripts/vivado/create_project.py --profile core --cpu-mhz 250 \
    --output build/vivado/core

# The Makefile provides the same entry points.
make vivado-project FPGA_CPU_MHZ=250 FPGA_OUT=build/vivado/team
make test-vivado lint-soc unit-soc
```

The default `soc` profile uses **`student_top` with `ares_cpu_top Core_cpu` (real FE + BE/LSU + IROM bridge)**.
The FE contract and IROM seam are now internal to the platform. CPU instruction
fetch uses the dedicated synchronous IROM.
Both `soc` and `core` run synthesis **out of context**. Their platform/CPU external ports
have no final board I/O timing budget. They are useful for compilation
and resource checks; **they cannot sign off MC4 or create a working board
bitstream**. See [SoC integration decisions](../../docs/jyd_soc_integration.md).

## What is preserved

`baseline.xml` is a source/IP-free settings snapshot from the user-designated
JYD2025 `digital_twin.xpr`. It preserves:

- FPGA `xc7k325tffg900-2`, project/library/simulator options;
- `synth_1` / `Flow_PerfOptimized_high`, including explicit synthesis options;
- `impl_1` / `Performance_ExplorePostRoutePhysOpt`, post-route phys-opt and
  `-tns_cleanup`, plus `impl_1_copy_1` and `impl_1_copy_2` settings;
- report strategies and dashboard configuration;
- board pin and clock-group constraints, copied verbatim to
  `constraints/board.xdc`. Only the **board** profile applies these constraints.

Old design sources, IP-specific filesets/runs, old testbench tops, memory
images, waveforms, checkpoint paths, compiled state and project identity are
not reused. A fresh project ID and ARES tops are assigned. The source management
mode becomes `All` to let Vivado order ARES packages. XPM libraries are enabled
for the migrated CDC helpers. In OOC profiles, `-mode out_of_context` and explicit
clock constraints are added; the requested clock is recorded as a target.
Automatic incremental synthesis remains configured, but **no old checkpoint**
is loaded. IP runs are created afresh. Launcher concurrency defaults to four
jobs and can be selected with `--jobs`; effective run properties are recorded.

The template uses the original 2023-named run flows under Vivado 2025.2, matching
the designated project's settings. Other tool versions require the explicit
`--allow-version-mismatch` switch and separate validation. Historical reports
and old source/IP contents are not evidence about ARES timing or correctness.

## Sources, configuration and IP

The source set is selected deterministically from `rtl/common`, `rtl/backend`,
`rtl/memory`, and the applicable `rtl/top` / `rtl/soc/jyd` modules. Testbenches,
DPI models and legacy CPU sources are excluded. The `soc` profile now includes
all real FE sources, interfaces, CPU wrapper and IROM bridge; `core` remains
the BE/LSU-only OOC top. `fe_pkg.sv` precedes `ares_pkg.sv` and `lsu_pkg.sv`.
The resolved configuration header and frontend Kconfig are snapshotted too.

The default configuration is the versioned `configs/defconfig` plus Kconfig
defaults: `MUL_LATENCY=3`, `LINE_BYTES=32`. Local `menuconfig` state is never
silently consumed. Select it explicitly if required:

```bash
python3 scripts/vivado/create_project.py --cpu-mhz 250 \
    --config configs/build/.config --output build/vivado/local-config
```

IP recipes are versioned Tcl, not inherited XCI or DCP:

| Recipe | Generated IP | Contract |
|---|---|---|
| `ip/memories.tcl` | `IROM_BMEM`, Block Memory Generator 8.4 | 4096 × 64-bit ROM, one-cycle synchronous read, 32KiB |
| `ip/memories.tcl` | `BRAM`, Block Memory Generator 8.4 | 65536 × 32-bit simple dual-port RAM, four byte write enables, two-cycle registered read, 256KiB |
| `ip/cache_data.tcl` | `ares_icache_data_bram`, Block Memory Generator 8.4 | configured line width × set count (default 256 × 64), SDP common clock, one-cycle read, synchronous output reset; two copies per ICache way |
| `ip/cache_data.tcl` | `ares_dcache_data_bram`, Block Memory Generator 8.4 | 512 × 64-bit SDP per DCache way, eight byte write enables, one-cycle read, no data reset |
| `ip/pll.tcl` | `pll`, Clocking Wizard 6.0 | differential 200MHz input, 50MHz output 1, requested CPU frequency on output 2, `locked`, no reset port |

Cache **data** storage uses these IPs in FPGA builds. Tag/valid/dirty/replacement
arrays, GPR and queues remain RTL. ICache has two SDP copies per way so both
read ports and a refill retain their old behavior: port A reads old data on a
same-address refill, port B holds during refill. The common-clock write port
uses READ_FIRST; optional output registers are disabled. BMG safety logic is
explicitly disabled because the platform already supplies synchronous reset
release and its post-reset EN extension would break output hold. No data RAM
contents are cleared on reset. The default data-only probe uses 32 RAMB36 for
ICache plus 2 for DCache (34 of 445 tiles); the shallow, wide ICache and duplicated
read copies consume more physical capacity than its logical 8KiB size.
The cross-port old-data behavior follows the synchronous READ_FIRST contract
in AMD's [Block Memory Generator guide, PG058](https://docs.amd.com/v/u/en-US/pg058-blk-mem-gen).

`CONFIG_SIMULATION` selects portable behavioral storage for Verilator.
`CONFIG_SIMULATION` plus `ARES_CACHE_IP_SIM` selects the generated IP for vendor
model verification. The same configuration drives RTL and IP geometry; a
mismatched ICache wrapper fails elaboration. XPM comes from the installed
Vivado library. The optional PLL is not instantiated by OOC tops.

To reproduce cache IP synthesis and XSim contract checks (ICache read/refill/
reset, DCache byte writes and 16/32/64B geometries, DCache controller):

```bash
python3 scripts/vivado/verify_cache_ip.py --output build/vivado/cache-ip
vivado -mode batch -source build/vivado/cache-ip/verify.tcl
```

The tool snapshots verification sources and retains per-test logs under
`verification_results/`. It checks five cases against BMG behavioral models,
then the same five in fresh XSim libraries containing the generated RAMB36E1
functional netlists. Test traffic starts after the 100ns UNISIM configuration
GSR; ordinary runtime reset and read-cycle checks are still exercised.
Cache IP recipes are included automatically in every
profile; neither XCI nor generated IP files need to be checked into Git.

Without program/data images, the platform memories are zero-filled; the
resulting project is a build scaffold, not a bootable software image. Supply
COE files explicitly; their radix, widths and maximum depths are checked:

```bash
python3 scripts/vivado/create_project.py --cpu-mhz 250 \
    --irom-coe firmware/irom64.coe --dram-coe firmware/dram32.coe \
    --output build/vivado/firmware
```

Every output directory contains an `inputs/` source/config/IP recipe snapshot,
`inputs.json` with SHA-256 hashes and effective configuration, `generate.tcl`,
`ares.xpr`, `compile_order.rpt`, `ip_status.rpt`, `settings.txt` and tool logs.
Synthesis adds `reports/`. A subsequent checkout edit cannot silently change
the sources used by that build. Re-run the Python command into a fresh directory
to update inputs; existing directories are refused rather than overwritten.
Vivado rejects `$`, `[` and `]` in imported HDL paths even when Tcl-quoted;
the launcher rejects those paths before creating the output directory.

`--prepare-only` writes the inputs and project scaffold without launching
Vivado. It does **not** generate IP or validate vendor properties. Normally
Vivado is launched automatically. Paths in the replay Tcl are relative to its
own directory; after relocating a prepared build, run:

```bash
cd <prepared-output>
vivado -mode batch -source generate.tcl
```

For an already-generated project, use a fresh generated build rather than
replaying `create_ip` into populated IP directories.

## Full board integration and routing

The physical `rtl/board/top.sv` and versioned `fpga/board.json` now connect
the real CPU/IROM/DRAM platform, PLL/reset conditioners and an 8N1 115200-baud
UART console. The 200MHz differential clock and original pin assignments are
retained. Virtual switches/keys are zero; miniTensor is reserved for C6 Core
XIF and is not instantiated in this first board baseline. There is no defined
external reset pin; power-up/PLL lock loss triggers a cold reset. Decisions:
[`c4_execution_decisions.md`](../../docs/c4_execution_decisions.md).

Build the nonzero boot image before synthesis or routing:

```bash
make board-firmware lint-board unit-board
make vivado-route FPGA_PROFILE=board FPGA_CPU_MHZ=250 \
  FPGA_OUT=build/vivado/board-route \
  FPGA_ARGS='--manifest fpga/board.json --jobs 1 --irom-coe build/firmware/c4-board/irom.coe --dram-coe build/firmware/c4-board/dram.coe'
```

Firmware prints `ARES C4 OK`, sets LED=0x123 and echoes received UART bytes.
It checks the DRAM initializer, cache miss/hit and ECALL/MRET using the reset
trap vector at 0x80000100. This does not sign off the legacy pulse timer or
RTOS interrupts. `unit-board` uses explicit test-only PLL/BRAM models, tests
serial framing and two autonomous boots separated by PLL loss; it does not
prove operation on physical hardware. Board synth/route rejects missing
IROM/DRAM images. General Vivado worker concurrency is capped at two threads;
run concurrency is separately selected by `--jobs`.

Paths in the additive manifest are relative to the repository; source order
is maintained before Vivado updates compile order. For example:

```json
{
  "top": "top",
  "sources": ["rtl/board/top.sv"],
  "include_dirs": [],
  "constraints": ["fpga/vivado/constraints/board_io_timing.xdc"],
  "ip_recipes": []
}
```

This is a schema example; use the actual `fpga/board.json`. The SoC source set already includes the real FE, CPU
wrapper and IROM bridge; list the physical board wrapper, extra dependencies
and additional board constraints in the manifest.
User IP recipes receive `ares_ip_dir`, `ares_cpu_mhz`, `ares_irom_coe` and
`ares_dram_coe`; use explicit catalog versions and avoid host-local paths.

```bash
python3 scripts/vivado/create_project.py --profile board --manifest fpga/board.json \
    --cpu-mhz 250 --stage route --output build/vivado/board-route
```

Board mode retains physical `top`, applies the original board XDC, generates
PLL and memories, and runs through post-route physical optimization when
requested. Missing sources/tops fail explicitly. Core/SoC profiles reject
`--stage route`, so an OOC result cannot accidentally be presented as board
sign-off. No automatic clock-frequency sweep, timing exceptions or bitstream
programming is performed.

Routing success means the implementation completed, **not that timing passed**.
Review `timing_routed.rpt`, `check_timing_routed.rpt`, `utilization_routed.rpt`,
`cdc_routed.rpt`, `clocks_routed.rpt`, `methodology_routed.rpt` and
`route_status.rpt`. MC4 still requires actual CPU clock >200MHz, setup/hold
passing in all applicable domains, and no unresolved unconstrained paths or
constraint problems. The legacy blanket asynchronous clock groups have been
removed. The timing XDC constrains reset-conditioner preset pins, synchronizer
first stages and stable UART bundled-data paths; it gives display/UART outputs
a 2ns external budget. The clock wizard supplies primary/generated clocks.
Review these assumptions and actual exception matches in every final build;
unmatched constraints or incomplete CDC analysis prevent sign-off.
