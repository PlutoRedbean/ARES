> 历史部署资料：以下命令的工作目录是外部 Mundus 工程。ARES 当前入口见 [miniTensor README](../README.md)。
> 这里的通过结果属于旧平台，尚未在 ARES＋RT-Thread 上重验；日志目录是本地忽略内容。

# miniTensor × Mundus/NPC × RT-Thread Nano：完整部署说明

> 面向**另一台电脑**的从零说明。按顺序执行即可在 Verilator 上跑通完整 tiny-yolov3。
> 本目录位于 `$MUNDUS_HOME/miniTensor/`，是 miniTensor 加速器与其集成的**唯一真源**。

> **ARES 仓库说明**：以下部署步骤和验收记录属于旧 Mundus 平台。
> ARES 已移除根目录 `npc/`；RT-Thread 工程后续加入，当前还没有 ARES＋RT-Thread＋miniTensor 闭环。
> 本目录保留加速器 RTL、测试、驱动、BSP 补丁及模型，供后续移植使用。
> 在 ARES 中复现旧流程时，先设置 `MUNDUS_HOME=/absolute/path/to/Mundus`，
> 再运行本地 `miniTensor/integration/run_jyd_sim.sh`；脚本自动将本地目录作为 `MT_HOME`。
> miniTensor 独立回归使用 `make -C miniTensor regress`，无需根目录 `npc/` 或 RT-Thread。
> `models/yc_weights.bin`、`models/ym_weights.bin` 是忽略的生成文件，使用对应打包脚本重新生成。

---

## 0. 最终状态

完整 **tiny-yolov3**（13 卷积 + 6 池化 + FPN 上采样 + 通道拼接 + 2 个检测头）在真实
Mundus/NPC 核 + RT-Thread Nano 上驱动 miniTensor 执行，21 个 stage 逐字节与整数 golden 一致：

    miniTensor FULL tiny-yolov3 PASSED (21 stages, 3128301 commands, 384458980 cycles)
    HIT GOOD TRAP

模型是**预训练** tiny-yolov3（keras2onnx 1.6.0 导出，COCO 80 类）；部署只做 fold BN +
训练后 INT8 量化，没有训练。仿真分辨率 64x64（训练分辨率 416x416，仿真跑不动）。

---

## 1. 仓库结构

    $MUNDUS_HOME/
      npc/                         CPU 核（Chisel）+ 测试台；miniTensor 集成改动在这里
      rtthread-nano/               子模块：RT-Thread Nano BSP
      nvboard/                     子模块：可选，本流程不需要（只给 MODE=nvboard）
      miniTensor/                  本目录：加速器 RTL + 集成 + 工具 + 文档
        rtl/ tb/                   miniTensor RTL 与 standalone 验证
        integration/               外仓库直接引用这里
          bsp/                     RT-Thread 驱动 mt_*.c（BSP Makefile 编译这里）
          npc/                     MMIO->CV-X-IF shim、128-bit DMA bridge
          tools/                   夹具生成器（pack_full.py 等）
          patches/                 外仓库改动快照
          logs/                    验收日志
        models/                    预训练 ONNX + 生成的权重 blob
        handoff/archive/design/    历史设计记录（平时不用看）

---

## 2. 主机环境

已验证版本：Verilator 5.040、OpenJDK 21、riscv64-unknown-elf-gcc 13.2、Python 3.12。

### 2.1 系统包（Ubuntu/Debian）

    sudo apt update
    sudo apt install -y build-essential flex bison libncurses-dev \
        python3 python3-venv python3-pip git curl ca-certificates \
        verilator openjdk-21-jdk gcc-riscv64-unknown-elf \
        libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev

若发行版的 Verilator 低于 5.x，请从源码安装（https://verilator.org）。
若没有 `gcc-riscv64-unknown-elf` 包，可安装 xPack/官方 RISC-V 工具链并保证
`riscv64-unknown-elf-gcc` 在 PATH 中。

### 2.2 获取代码并定位根目录

    # 本流程在 0818_jyd_test 分支上：默认分支（Mundus）没有这些改动，必须 -b 指定。
    # 不要用 --recursive：仓库里还有若干本流程用不到、甚至可能无权限的子模块，
    # 按 2.3 只 init rtthread-nano 即可（nvboard 不需要）。
    git clone -b 0818_jyd_test <Mundus-仓库地址> Mundus
    export MUNDUS_HOME=/absolute/path/to/Mundus
    cd $MUNDUS_HOME

### 2.3 子模块（首次）

    git submodule update --init rtthread-nano

只需要 `rtthread-nano`（BSP）。**`nvboard` 不需要**：它只用于 `MODE=nvboard`
（板级仿真 / pin 绑定），JYD 的 Verilator 流程用不到；`npc/Makefile` 里它的
`include` 已经是可选的，目录不存在也能构建。
其余子模块（ysyxSoC / am-kernels / ...）本流程也不需要；构建时若出现
`find: .../ysyxSoC/...: No such file or directory` 的警告可以忽略。

### 2.4 npc 构建工具（首次）

    # mill 0.12.4：npc/Makefile 调用的就是 $NPC_HOME/mill 这个可执行文件
    curl -fL -o npc/mill \
      https://github.com/com-lihaoyi/mill/releases/download/0.12.4/0.12.4-assembly
    chmod +x npc/mill

    cd npc
    make -C tools/kconfig NAME=mconf NAME=conf     # 需要 flex/bison/ncurses-dev
    make -C tools/capstone                         # 需要网络
    cd $MUNDUS_HOME

### 2.5 生成 NPC 配置与 Verilog（首次，或改配置后）

    cd $MUNDUS_HOME/npc
    cat > /tmp/mundus_jyd_defconfig <<'EOF'
    # CONFIG_RVE is not set
    CONFIG_BP_TAGE=y
    CONFIG_BRANCH_RAS=y
    CONFIG_BRANCH_BTB_WIDTH=8           # 256 项 BTB（默认 4=16 项）
    CONFIG_BRANCH_LOOP_PREDICTOR=y      # 循环预测
    CONFIG_ICACHE_BYTE_64=y             # I-cache 64 B/块
    CONFIG_ICACHE_BLOCK_128=y           # 128 块
    CONFIG_ICACHE_WAY_1=y               # 1 路 → 8 KiB 直接映射
    CONFIG_FRONTEND_QUEUE_DEPTH=4       # 前端指令缓冲 4 项
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
    rm -rf include            # conf 顺带生成的目录，是构建副产物，不需要
    export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
    export PATH=$PWD:$PATH          # Makefile 用裸 'mill'
    make verilog                    # 生成 vsrc/build/Mundus.sv

> 必须用上面的 defconfig：`CONFIG_RVE` 默认 y（与 5 位 GPR 冲突），分支预测默认
> `BP_ALWAYS_NOT_TAKEN`（会让 Scala 编译失败）。

---

## 3. Python 环境（生成夹具用）

    cd $MUNDUS_HOME/miniTensor
    python3 -m venv .venv
    .venv/bin/pip install -r requirements.txt

---

## 4. 生成模型夹具

    cd $MUNDUS_HOME/miniTensor
    .venv/bin/python integration/tools/pack_full.py

产出：`models/ym_weights.bin`（8.70 MiB：输入 + INT8 权重/偏置/配置 + 每级整数 golden）和
`integration/bsp/mt_yolomodel_weights.h`（21 条层表）。
ARES 不跟踪生成的 blob；首次使用或修改模型/打包器后需执行此步。

---

## 5. 构建固件

    cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd
    make CROSS_COMPILE=riscv64-unknown-elf- \
      MUNDUS_HOME=$MUNDUS_HOME NPC_HOME=$MUNDUS_HOME/npc \
      MT_WITH_COREMARK=0 image

`MT_HOME` 默认是 `$(MUNDUS_HOME)/miniTensor`，无需手动传。
第 6 节的一键脚本会自动做这一步；这里是手动版，便于单独排查固件问题。

---

## 6. 运行仿真

**运行仿真统一只用这一条命令**（脚本会构建固件和 Verilator 模型；没改动时是秒级复用。
完整模型约 20-30 分钟 / 3.8 亿拍）：

    cd $MUNDUS_HOME/miniTensor
    JYD_CONSOLE_CMDS='mt_yolomodel;quit' ./integration/run_jyd_sim.sh

脚本内部就是 `make -C <BSP> image` + `make -C <BSP> run`（后者按需 `make -C npc wave`），
并把 `PATH`（找 `mill`）、`JAVA_HOME`（JDK 21）、`NVBOARD_HOME`、`VERILATOR_RESET=0`、
`MT_WITH_COREMARK=0` 都设好。**不要再手动跑 `make run` 或 `./build/MundusJyd`**，避免参数不一致。

### 6.1 CoreMark（可选）

本机是 GCC 13.2、没有 `-mtune=mundus`，所以 **CoreMark 和整套 miniTensor 测试放不进 32 KiB IROM**：
不带 CoreMark 时 `.text` 已经 27,928 字节，CoreMark 单独也要 24,224 字节。规则是
**CoreMark 必须独占**（`MT_TESTS=""`）；默认的 `-O3` 或带上测试都会 IROM 溢出。

**软件 CoreMark**（`CRC=0/MATRIX=0`）用 `-Os`：

    cd $MUNDUS_HOME/miniTensor
    MT_WITH_COREMARK=1 MT_TESTS="" COREMARK_HW_CRC=0 COREMARK_HW_MATRIX=0 \
      COREMARK_OPT_FLAGS=-Os JYD_CONSOLE_CMDS='coremark;quit' ./integration/run_jyd_sim.sh

**硬件 CoreMark**（`CRC16+MULBE`，menuconfig 里 Custom Instruction Hardware 两项都要开）在 GCC 13.2 下
`-Os` 会踩 `divu` retire 断言（见 §9 第 2/8 条），要改用 `-O2`（`.text` = 32,016/32,768，很紧）：

    MT_WITH_COREMARK=1 MT_TESTS="" COREMARK_HW_CRC=1 COREMARK_HW_MATRIX=1 \
      COREMARK_OPT_FLAGS=-O2 JYD_CONSOLE_CMDS='coremark;quit' ./integration/run_jyd_sim.sh

跑 miniTensor/YOLO 时不传这些变量即可（脚本默认 `MT_WITH_COREMARK=0`）。

---

## 7. 回归与解码

    # 快速回归（2-3 分钟）：mt_net / mt_yolocnn / mt_conv
    cd $MUNDUS_HOME/miniTensor
    JYD_CONSOLE_CMDS='mt_net;mt_yolocnn;mt_conv;quit' ./integration/run_jyd_sim.sh

    # 用两个 head 的 golden 做 YOLOv3 解码 + NMS
    cd $MUNDUS_HOME/miniTensor
    .venv/bin/python integration/tools/yolo_decode.py

---

## 8. 验收标准

- 第 6 步每个 stage 都是 `ok`，结尾 `miniTensor FULL tiny-yolov3 PASSED` 且 `HIT GOOD TRAP`；
- 第 7 步三个测试 `PASSED`；
- 参考：21 stages / 3,128,301 commands / 384,458,980 cycles，日志见 `integration/logs/`。

---

## 9. 已知问题

1. **`+verilator+rand+reset+0` 必须**：随机复位会让前端不退休；Makefile 已默认 0。
2. **固件不要在 pooling 路径用整除**：Verilator 测试台会在 `divu` 上 retire/PC 错乱；
   `net_pool_k`/`net_pool_k_same` 已改成移位/减法。
3. **加速器地址 bit21 必须为 0**；模型区从 `0x8040_0000` 起。
4. **必须显式传 `NPC_HOME`**：环境里可能有另一个预设值，而 Makefile 用 `?=`。
5. **本机工具链无 newlib**：`integration/bsp/compat/` 提供最小 libc 头。
6. npc 的 lint 很严（`-Werror-WIDTHTRUNC`）；miniTensor 的 sv 如报宽度截断用文件内 pragma。
7. **循环预测会有 `MULTIDRIVEN`**：开 `CONFIG_BRANCH_LOOP_PREDICTOR` 后生成的
   `vsrc/Mundus/TageDirection.v` 里 `shifted_pc` 有多个组合驱动，Verilator 默认当 error。
   `npc/Makefile` 已加 `-Wno-MULTIDRIVEN`；默认 defconfig 现在是 **TAGE + 256 项 BTB + 循环预测**。
8. **硬件 CoreMark（CRC16+MULBE）会在 `divu` 上踩 retire bug**（同第 2 条）；
   软件 CoreMark 能完整跑完。

---

## 10. 地址空间（速查）

| 窗口 | 用途 |
| --- | --- |
| `0x8000_0000` 32 KiB | IROM |
| `0x8010_0000-0x8012_FFFF` | cacheable DRAM（`.rodata/.data/.bss`/栈） |
| `0x8013_0000-0x8013_FFFF` | miniTensor scratch，只走别名 |
| `0x8020_1000` | miniTensor MMIO（INSTR/RS1/RS2/KICK/STATUS/RESULT） |
| `0x8030_0000-0x8033_FFFF` | uncached 别名（映射低 256 KiB） |
| `0x8040_0000-0x80FF_FFFF` | 权重 blob + 激活（12 MiB 非缓存窗口） |

控制通路：CPU 写 MMIO -> perip_bridge -> `mt_cvxif_shim` -> CV-X-IF -> mini_tensor_top。
数据通路：miniTensor 128-bit DMA -> `mt_dma_bridge` -> DPI -> 与 CPU 共享的 `dram[]`。
一致性：D-cache 写回且无 flush，所以 miniTensor 的 buffer 只走 uncached 别名/窗口。

---

## 11. 旧 Mundus 仓库提交说明（历史参考）

| 仓库 | 内容 |
| --- | --- |
| `Mundus` | `npc/`（普通目录）与 `miniTensor/`（本目录）直接跟踪 |
| `rtthread-nano` 子模块 | BSP 的 `Makefile`/`linker.ld`/`finsh_compat.c` 改动 |

`miniTensor/` 已作为普通目录跟踪（与 `npc/` 一致）：Mundus 根的 `.gitignore` 里有
`!/miniTensor/**`，`miniTensor/.gitignore` 只排除构建/环境产物（`.venv/`、`obj_dir/` 等）。

注意 `rtthread-nano` 是子模块：它的 BSP 改动要在子模块里 commit 并 push，Mundus 再更新指针；
否则别人 clone 下来的子模块没有这些改动，构建会失败。改动快照见 `integration/patches/rtthread-nano.patch`。

`integration/patches/` 下还有 `npc.patch`，是 `npc/` 改动的参照（`npc/` 本身已被 Mundus 跟踪，
补丁只用于复查/重放）。

### 发布前检查（要让别人能跑，缺一不可）

1. `Mundus` 里提交：`npc/`、`miniTensor/`、`.gitignore`、`README.md`；
2. `rtthread-nano` 子模块里 `git add -A && git commit && git push`（BSP 的 Makefile / linker.ld /
   finsh_compat.c），再在 `Mundus` 里提交更新后的子模块指针；
3. 确认 `git submodule status` 里 `rtthread-nano` 指向刚 push 的提交；
4. 在**另一个空目录** `git clone --recursive` 一遍，按本文档跑第 5、6 步验证。

> 体积提醒：`models/tiny-yolov3.onnx` 约 34 MB，是保留的模型输入；`models/*.bin`
> 是忽略的生成文件，由第 4 步重新生成。旧验收日志只保留在本地，不随 ARES 克隆分发。
