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
| `tests/abstract-machine/` | AbstractMachine subset with the ARES (riscv32-ares) bare-metal runtime |
| `tests/cpu-tests/` | ISA regression ported from ysyx-workbench am-kernels/tests/cpu-tests |

## Simulation and regression

The simulation flow is a port of the ysyx-workbench/npc Verilator environment.
It currently uses the npc (Mundus) RTL as a temporary DUT so that the ported
tests can be validated before the ARES RTL is complete:

```bash
make -C sim                                   # build the simulator
make -C sim run PROGRAM=<image.bin>           # run one image
make -C sim wave PROGRAM=<image.bin>          # same, with an FST waveform
make -C sim lint                              # lint the RTL

cd tests/cpu-tests
make ARCH=riscv32-ares run                    # full ISA regression
make ARCH=riscv32-ares ALL=add run            # a single test
```

See `sim/README.md` for the memory map, DPI-C contract and how to point
the flow at ARES' own RTL later.

---