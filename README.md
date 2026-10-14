# ARES

**ARES** (AI-accelerated RISC-V Embedded SoC) is an open-source **RISC-V AI-accelerated SoC** described in Verilog.

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/PlutoRedbean/ARES.git
cd ARES

# 2. Build the RTL simulator (Verilator)
make -C sim

# 3. Build and run the ISA regression (am-kernels cpu-tests)
make -C tests/cpu-tests ARCH=riscv32-ares run
```

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

The simulation flow builds the local `ares_core_top` (Backend + LSU) with a
contract-compliant frontend stub. The legacy Mundus/NPC DUT has been removed;
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
ARES Core with a frontend stub; the real frontend and RT-Thread integration
remain follow-up work. The miniTensor control path is now instanced by the
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
