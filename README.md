# ARES

**ARES** (AI-accelerated RISC-V Embedded SoC) is an open-source **RISC-V AI-accelerated SoC**
described in Verilog.

This repository is the **complete, runnable ARES project**: the Mundus/NPC RISC-V core, the
RT-Thread Nano `MundusJyd` BSP, and the **miniTensor** INT8 AI accelerator (CV-X-IF slave +
128-bit DMA). The full **tiny-yolov3** network runs bit-exactly on the accelerator over 21
stages on the Verilator model of the real core:

    miniTensor FULL tiny-yolov3 PASSED (21 stages, 3128301 commands, 384458980 cycles)
    HIT GOOD TRAP

---

## Repository layout

| Path | Contents |
| --- | --- |
| `npc/` | Mundus/NPC RISC-V core (Chisel) + Verilator testbench; miniTensor integration shims |
| `rtthread-nano/` | RT-Thread Nano kernel + `MundusJyd` BSP (vendored regular directory, not a submodule) |
| `miniTensor/` | miniTensor RTL, shim/DMA bridge, drivers, model fixtures, tools, docs |
| `common.mk` | shared path variables (`MUNDUS_HOME`, `NPC_HOME`, ...) used by the Makefiles |
| `docs/` | microarchitecture documentation |

> The layout is identical to the original Mundus monorepo, so every script and
> `MUNDUS_HOME`-relative path works unchanged. The only difference is that `rtthread-nano/`
> is vendored here, so **no `git submodule` step is required**, and `nvboard` / `ysyxSoC` /
> `am-kernels` are **not** needed for the Verilator flow.

---

## Quick start (Verilator)

The full step-by-step deployment notes (Chinese) live in [miniTensor/README.md](miniTensor/README.md).
The short version:

### 1. Host environment

Ubuntu/Debian with Verilator 5.x, OpenJDK 21, `riscv64-unknown-elf-gcc` and Python 3.12:

```bash
sudo apt install -y build-essential flex bison libncurses-dev \
    python3 python3-venv python3-pip git curl ca-certificates \
    verilator openjdk-21-jdk gcc-riscv64-unknown-elf \
    libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev
```

### 2. Clone and set the project root

```bash
git clone git@github.com:PlutoRedbean/ARES.git
export MUNDUS_HOME=$PWD/ARES
cd $MUNDUS_HOME
```

### 3. npc build tools (first time)

```bash
curl -fL -o npc/mill \
  https://github.com/com-lihaoyi/mill/releases/download/0.12.4/0.12.4-assembly
chmod +x npc/mill
make -C npc/tools/kconfig NAME=mconf NAME=conf   # needs flex/bison/ncurses-dev
make -C npc/tools/capstone                       # needs network
```

### 4. Generate the NPC config and Chisel Verilog (first time, or after changing config)

```bash
cd $MUNDUS_HOME/npc
cat > /tmp/mundus_jyd_defconfig <<'EOF'
# CONFIG_RVE is not set
CONFIG_BP_TAGE=y
CONFIG_BRANCH_RAS=y
CONFIG_BRANCH_BTB_WIDTH=8
CONFIG_BRANCH_LOOP_PREDICTOR=y
CONFIG_ICACHE_BYTE_64=y
CONFIG_ICACHE_BLOCK_128=y
CONFIG_ICACHE_WAY_1=y
CONFIG_FRONTEND_QUEUE_DEPTH=4
CONFIG_IROM_SIZE_32KB=y
CONFIG_DCACHE_SIZE_8KB=y
CONFIG_STORE_BUFFER_DEPTH_4=y
CONFIG_CUSTOM_CRC16=y
CONFIG_CUSTOM_MULBE=y
EOF

export KCONFIG_CONFIG=$PWD/configs/build/.config
tools/kconfig/build/conf --defconfig=/tmp/mundus_jyd_defconfig configs/Kconfig
python3 tools/pysrc/autogen_cfg.py -i configs/build/.config \
    --out-c configs/build/csrc/include/ --out-v configs/build/vsrc/include/ \
    --out-s configs/build/scsrc/
rm -rf include
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
export PATH=$PWD:$PATH
make verilog
```

> This defconfig is required: `CONFIG_RVE` defaults to `y` (conflicts with the 5-bit GPR
> encoding) and the default branch predictor is `BP_ALWAYS_NOT_TAKEN` (fails the Scala build).

### 5. Run the full tiny-yolov3

```bash
cd $MUNDUS_HOME/miniTensor
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt   # for the Python tools
JYD_CONSOLE_CMDS='mt_yolomodel;quit' ./integration/run_jyd_sim.sh
```

The generated model blob `miniTensor/models/ym_weights.bin` and layer table
`miniTensor/integration/bsp/mt_yolomodel_weights.h` are committed, so the fixture
generation step (section 4 of the full guide) can be skipped for a normal run.

### 6. Quick regression

```bash
JYD_CONSOLE_CMDS='mt_net;mt_yolocnn;mt_conv;quit' ./integration/run_jyd_sim.sh
```

---

## Notes

- Verilator reset mode must be 0 (`+verilator+rand+reset+0`): the random-reset default wedges
  the frontend on the `jyd` platform. The run script and `npc/Makefile` default it correctly.
- `nvboard` is optional and only used by `MODE=nvboard`.
- The `rtthread-nano` BSP is vendored directly (it used to be a submodule of the Mundus repo).

## Documentation

- [docs/microarch/frontend.md](docs/microarch/frontend.md)
- [docs/microarch/backend.md](docs/microarch/backend.md)
- [docs/microarch/miniTensor.md](docs/microarch/miniTensor.md)
- [miniTensor/README.md](miniTensor/README.md) — full deployment guide
