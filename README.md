# ARES

**ARES** (AI-accelerated RISC-V Embedded SoC) is an open-source **RISC-V AI-accelerated SoC** described in Verilog.

---

## Shared-L2 SoC mainline

The development mainline is **ARES SoC with shared L2**, currently based on the
two-hart AMP prototype. JYD `student_top` is retained for platform resources and
reference regressions. The L2 wrappers still have stub MMIO/interrupt paths;
the complete SoC, software boot and board integration remain to be implemented.
See the [Implementation Plan](docs/implementation_plan.md) for current gates.

```bash
make lint-l2 unit-l2 unit-l2-frontend
```

`unit-l2-frontend` runs single/dual real-frontend smoke tests; it does not replace
full CoreMark or system validation. `make sim/run/isa` still uses the existing
CPU/IROM/DPI bench without L2, and the current Vivado `soc`/board profiles still
select the JYD platform. Migrating those defaults to the complete L2 SoC is a
mainline task; selecting this direction has not changed the build defaults.

## Core regression quick start

```bash
# 1. Clone the repository
git clone https://github.com/PlutoRedbean/ARES.git
cd ARES

# 2. Build the RTL simulator (Verilator)
make -C sim

# 3. Build and run the ISA regression (am-kernels cpu-tests)
make -C tests/cpu-tests ARCH=riscv32-ares run
```

For the optional CRC-accelerated CoreMark variant (custom-0 CRC8 instruction,
compiler/link interposition, no `core_util.c` edits), see
[docs/coremark_crc_acceleration.md](docs/coremark_crc_acceleration.md) and
`scripts/build_coremark_crc.py`. The default `coremark-image` flow is
unchanged.

---

## Repository layout

| Path | Contents |
| --- | --- |
| `rtl/` | ARES synthesizable RTL (frontend, backend, memory subsystem, miniTensor) |
| `docs/` | microarchitecture and interface documentation |
| `sim/` | Verilator simulation flow (test bench, DPI-C memory/device model, harness) |
| `miniTensor/` | accelerator RTL, standalone tests, model tools and retained RT-Thread integration sources |
| `rtthread-nano/` | imported RT-Thread Nano source snapshot and legacy MundusJyd BSP; ARES adaptation pending |
| `fpga/vivado/` | reproducible project settings, board constraints and IP recipes |
| `tests/abstract-machine/` | AbstractMachine subset with the ARES (riscv32-ares) bare-metal runtime |
| `tests/cpu-tests/` | ISA regression ported from ysyx-workbench am-kernels/tests/cpu-tests |

## Simulation and regression

The default simulation builds `ares_cpu_top`: real Frontend + `ares_core_top`
(Backend + LSU) + the registered IROM bridge. The legacy Mundus/NPC DUT has been removed;
no external NPC project is needed for these commands:

```bash
make -C sim                                   # build the simulator
make -C sim run PROGRAM=<image.bin>           # run one image
make -C sim wave PROGRAM=<image.bin>          # same, with an FST waveform
make -C sim lint                              # lint the RTL

cd tests/cpu-tests
make ARCH=riscv32-ares run                    # full ISA regression
make ARCH=riscv32-ares ALL=add run            # a single test
```

See `sim/README.md` for the memory map and DPI-C contract. This verifies the
real ARES Frontend/Core with IROM-only instruction fetch. `make isa-stub`
retains the independent Backend/LSU regression. `make unit-frontend unit-frontend-modes unit-soc` exercises protocol, predictor-feature switches
and autonomous JYD SoC execution. RT-Thread adaptation remains follow-up work. The miniTensor control path is now instanced by the
`ares_soc_top` integration top (real `mini_tensor_top` + ARES CV-X-IF host
adapter over the `0x8020_1000` MMIO seam); the in-core XIF path and the
shared-memory Fabric are still open. RT-Thread driver/BSP integration sources
are retained under `miniTensor/integration/`; the RT-Thread source project is
now imported under `rtthread-nano/`, with ARES BSP/build adaptation pending.
Its legacy Mundus simulation script requires an explicit external
`MUNDUS_HOME`.

Generated outputs belong in the ignored build directories. FPGA generation
and validation commands are documented in `fpga/vivado/README.md`.

### miniTensor SoC control path (S09 / SPEC-M6 adaptation)

`rtl/top/ares_soc_top.sv` wraps `student_top` and instantiates the real
`mini_tensor_top`, driven by the ARES CV-X-IF host adapter
(`rtl/soc/ares_mt_host_adapter.sv`). The accelerator 128-bit uncached DMA
master is exported for the future Fabric. Elaborate the integrated subtree
with:

```bash
make lint-mt
```

See [miniTensor SoC integration](docs/miniTensor_soc_integration.md) for the
register map, sequencer rules and the remaining SPEC-M6/M7/M19 work.

---
