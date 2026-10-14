# ARES simulation flow

Verilator simulation of the local ARES Core (`ares_core_top`: Backend + LSU)
with a contract-compliant frontend stub. The legacy Mundus/NPC DUT and its
Chisel generation tools have been removed. No external NPC project is needed.

## Quick start

Run from the ARES repository root:

```bash
make -C sim
make -C sim lint-all
make -C tests/cpu-tests ARCH=riscv32-ares run
make -C sim run PROGRAM="$PWD/tests/cpu-tests/build/add-riscv32-ares.bin"
make -C sim wave PROGRAM="$PWD/tests/cpu-tests/build/add-riscv32-ares.bin"
```

`RTL_ROOT` defaults to `<ARES>/rtl`, and `TOPNAME` to `tb_ares_core`.
Commands that still pass `ARES_RTL=1` work, but the switch is no longer needed.
Builds use separate ignored directories for each top under `sim/build/` and
`sim/build_wave/`. Generated configuration lives under `configs/build/`.

## Layout

| Path | Contents |
| --- | --- |
| `sim/Makefile` | Verilator build/run rules, ARES RTL source list and configuration |
| `sim/rtl/tb_ares_core.sv` | ARES Core test bench with FE stub and retirement observations |
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
   model. `fe_stub` fetches instructions and feeds the approved FE/Core contract.
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

This is Core/ISA verification with an FE stub. It does not validate the real
frontend, RT-Thread, miniTensor integration, physical FPGA clocks or post-route
PPA. NEMU difftest and an interactive debugger are not provided.
