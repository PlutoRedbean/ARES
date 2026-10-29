# ARES simulation flow

Verilator simulation of `ares_cpu_top`: real Frontend + Backend/LSU +
AXI-Lite-to-registered-IROM bridge. The legacy Mundus/NPC DUT and its
Chisel generation tools have been removed. No external NPC project is needed.

## Mainline direction and current entry points

The project mainline is the shared-L2 ARES SoC. Start with repository-root
`make lint-l2 unit-l2 unit-l2-frontend` for the existing L2/real-frontend prototype.
Its complete MMIO/interrupt/boot/software harness and default simulation entry
still need integration. The commands below remain the independent CPU/IROM/DPI
regression, without shared L2; they do not validate the mainline SoC.
See [the plan](../docs/implementation_plan.md) for migration and system gates.

## Core regression quick start

Run from the ARES repository root:

```bash
make -C sim
make -C sim lint-all
make -C tests/cpu-tests ARCH=riscv32-ares run
make -C sim run PROGRAM="$PWD/tests/cpu-tests/build/add-riscv32-ares.bin"
make -C sim wave PROGRAM="$PWD/tests/cpu-tests/build/add-riscv32-ares.bin"
```

`RTL_ROOT` defaults to `<ARES>/rtl`, and `TOPNAME` to `tb_ares_cpu`.
Commands that still pass `ARES_RTL=1` work, but the switch is no longer needed.
Builds use separate ignored directories for each top under `sim/build/` and
`sim/build_wave/`. Generated configuration lives under `configs/build/`.

## Optimization and optional heavy checks

The main `sim/Makefile` build and the repository-root CoreMark simulation
targets use Verilator `-O3` and C++ `-O3`. Ordinary assertions remain enabled.
`SIM_HEAVY_CHECKS=1` is the default; use `SIM_HEAVY_CHECKS=0` to compile out the
following simulation-only invariant scans and their associated assertions:

| Module | Optional checks |
| --- | --- |
| `be_top` | Uncommitted source dependency scan and per-register youngest producer reconstruction |
| `lq` | Pairwise queue-order and tag uniqueness |
| `sq` | Flush suffix and occupied/committed prefix scans |
| `mshr` | Pairwise physical-line and set/way lock uniqueness |

The switch defines `ARES_DISABLE_HEAVY_CHECKS` at compile time. It removes the
checker computations as well as the assertions; it does not disable
`CONFIG_SIMULATION`, ordinary protocol assertions, CIQ occupancy checks, LQ
completion tracking, or the dual-core L2 shadow checker. Full-check builds
remain the correctness-validation configuration. No speedup has been measured
for this option yet.

```bash
# Build the simulators only; do not build a benchmark image or run CoreMark.
make build-coremark-sim build-2core-coremark-sim
make build-coremark-sim build-2core-coremark-sim SIM_HEAVY_CHECKS=0

# Run only the short synthetic RV32 harness checks, without CoreMark.
make test-coremark-harness
make test-coremark-harness SIM_HEAVY_CHECKS=0

# Subsequent full benchmark runs use the selected check configuration.
make unit-2core-coremark SIM_HEAVY_CHECKS=0
```

CoreMark simulators use `sim/build/unit/` for full checks and
`sim/build/unit_light/` for light checks. The normal CPU harness uses
`sim/build_light/` (or `sim/build_wave_light/`) for light checks. This keeps the
two configurations from reusing a binary built with different checks.
CoreMark testbenches print the selected check mode at startup.

## Layout

| Path | Contents |
| --- | --- |
| `sim/Makefile` | Verilator build/run rules, ARES RTL source list and configuration |
| `sim/rtl/tb_ares_cpu.sv` | Default real-FE CPU bench, registered IROM, retirement and metadata scoreboards |
| `sim/rtl/tb_ares_core.sv` | Retained independent Core bench with FE stub |
| `sim/rtl/tb_mem_beat_if.sv` | 128-bit memory beat adapter to the DPI memory model |
| `sim/rtl/tb_mmio_if.sv` | MMIO request/response adapter to the DPI device model |
| `sim/csrc/main.cpp` | Reset, clock, run loop and trap reporting |
| `sim/csrc/memory.cpp` | Guest memory/device model and image loading |
| `sim/csrc/dut.cpp` | DPI entry points and architectural retirement tracking |

## How a test runs

1. `tests/cpu-tests/Makefile` builds a bare-metal image using the ARES
   AbstractMachine runtime (`ARCH=riscv32-ares`).
2. `tests/abstract-machine/scripts/platform/ares.mk` invokes `sim/Makefile`.
3. The harness loads the image at `0x8000_0000`, applies reset, and clocks the
   model. The synchronous IROM model supplies the real ICache/IFU/BPU/IQ path.
4. `ares_core_top` executes them; the test bench forwards retirement events to
   the harness, which maintains architectural PC/GPR state.
5. Retired EBREAK terminates the test. Exit status is 0 for GOOD TRAP, 1 for
   BAD TRAP, 2 for a model error, or 3 for exceeding the cycle budget.

See `docs/core_verification_flow.md` for ordering, backpressure and observation
contracts. The DPI function names inherited from the old harness are retained
where used by ARES test benches; no legacy CPU RTL is compiled.

## Guest memory model

| Range | Backing model |
| --- | --- |
| `0x8000_0000 + 32 KiB` | IROM |
| `0x8010_0000 + 256 KiB` | cacheable DRAM window |
| `0x8030_0000 + 256 KiB` | retained model alias, bit 21 cleared |
| `0x8040_0000 .. 0x80FF_FFFF` | retained model extension |
| `0xA000_0000` | MMIO console at `+0x3F8`, RTC at `+0x48/+0x4C` |

The memory model retains compatibility windows; it does not establish ARES
architectural cacheability or FPGA RAM capacity. The core regression uses the
generic ARES MMIO profile. The migrated JYD `student_top` and its actual FPGA
address/backing behavior are described separately in `docs/jyd_soc_integration.md`
and exercised by `make unit-soc`.

## Configuration and options

Use `make menuconfig` or `make defconfig` from the repository root. The
configuration generator supplies MUL latency and cache line size definitions.

```text
--max-cycles=N     cycle budget (default 20000000)
--reset-cycles=N   reset duration (default 20)
--itrace           print retired instructions
--perip-trace      trace memory/device requests
-v, --verbose      extra diagnostics and register dump
-l/--elf/--diff/--csv  accepted for AM compatibility
```

The run target retains `+verilator+rand+reset+0` for reproducible execution.

## Verification boundary

The default is real-FE Core/ISA verification; `make isa-stub` selects the
retained C3 path. `make unit-soc` separately tests actual JYD RTL memory/peripheral
bridges with a program fetched autonomously from IROM. These do not validate
RT-Thread, miniTensor shared-memory DMA, physical FPGA clocks or post-route PPA. NEMU difftest and an interactive debugger are not provided.

## C5 regression and program images

```bash
make isa                       # real FE: 36/36
make isa-stub                  # retained FE stub: 36/36
make unit-frontend             # IQ/FIFO/history/protocol/IROM bridge, strict assertions
make unit-frontend-modes       # Tournament/RAS/Loop disabled; independent GHR remains
make unit-soc                  # real CPU, IROM, JYD DRAM/MMIO/UART/LED
make test-images               # physical image split guards
python3 scripts/split_image.py path/to/program.bin build/program
```

The flat binary may include a 1MiB address gap before DRAM. Split by address:
first 32KiB -> `irom.hex` (4096 x 64-bit), +0x100000 -> `dram.hex`
(65536 x 32-bit). Nonzero bytes in the hole or bytes beyond physical DRAM are
rejected. SoC simulation IP models accept `+IROM_HEX=... +DRAM_HEX=...` and keep
the hardware's one-cycle IROM / two-cycle RAM read timing. The test fixture
uses `tests/soc-tests/c5_smoke.S`, not direct IQ injection.

The C5 CPU configuration requires `CONFIG_IO_USE_AXI=y`, Fetch=4 and Decode=2.
Only 0x80000000–0x80007fff is executable. Final-ROM windows have a masked suffix;
out-of-window speculation waits for Redirect. There is no new fetch Trap or
DRAM execution support. A real unsupported target fails the simulation watchdog.
