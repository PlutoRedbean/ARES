# miniTensor × Mundus/NPC × RT-Thread Nano — 集成

> ARES 中保留本目录作为后续 RT-Thread/miniTensor 移植资料。
> 以下地址、时序和通过记录属于旧 Mundus 仿真，不代表 ARES 验收结果。
> 旧流程现在必须显式设置 `MUNDUS_HOME`，指向包含 `npc/` 和 RT-Thread BSP 的外部工程；
> `MT_HOME` 默认指向当前本地 miniTensor。ARES 的 RT-Thread 工程待后续加入。

本目录是 miniTensor 接入 Mundus/NPC 与 RT-Thread Nano 的**唯一真源**。
对 `Mundus/npc` 与 `Mundus/rtthread-nano` 的所有改动都从这里派生，便于复查与重放。

**日常部署只看一份文档：[`legacy_mundus_deployment.md`](../docs/legacy_mundus_deployment.md)**（构建/运行/验收/坑/并入 git）。
历史设计记录已归档到 [`../handoff/archive/design/`](../handoff/archive/design/)，索引见 [`../handoff/README.md`](../handoff/README.md)。

**部署清单 / 是否训练 / 是否改动 CPU 核 / 三工作区文件地图**：见 [`MANIFEST.md`](MANIFEST.md)。
外仓库改动的补丁在 [`patches/`](patches/)，验收日志在 `logs/`（本地日志）。

> `logs/` 中的原始日志现仅本地保留并由 Git 忽略；下方历史路径不保证在新克隆中存在。

---

## 1. 状态

| 项 | 状态 |
| --- | --- |
| `mt_cvxif_shim` 对真实 `mini_tensor_top` 的 standalone 测试 | ✅ 全绿 |
| `mt_dma_bridge` + DPI 契约 | ✅ 同上覆盖 |
| NPC 集成（perip 译码 + student_top 例化） | ✅ Verilator 编译通过 |
| **RT-Thread 下 `mt_gemm` 端到端自校验** | ✅ **PASSED** |
| **存储扩容：12 MiB uncached 窗口** | ✅ **PASSED**（`mt_memtest`；见 [y1_memory_expansion.md](../handoff/archive/design/y1_memory_expansion.md)） |
| **一层真实 3×3 卷积**（`mt_conv`） | ✅ **PASSED**（144/144 字节与 CPU 参考一致，7495 cycles） |
| **YOLO 形状检测网络**（`mt_net`） | ✅ **PASSED**（4 层逐层比对，16823 命令 / 1.76M cycles；见 [y3b_detection_network.md](../handoff/archive/design/y3b_detection_network.md)） |
| **命令队列（Y4 性能）** | ✅ `mt_net` 2.51M → **1.76M** cycles，`mt_conv` 1.61×；见 [y4_command_queue.md](../handoff/archive/design/y4_command_queue.md) |
| **离线权重打包 + INT8 量化（Y6）** | ✅ `mt_detect`：训练→量化→打包→部署，硬件与 Python 整数 Golden **逐比特一致（8/8 图）**；见 [y6_weight_pipeline.md](../handoff/archive/design/y6_weight_pipeline.md) |
| **权重分块（Y7）：解除整层权重必须装进 UB 的限制** | ✅ `mt_wide` **3072/3072**（9× UB 的层，1296 个权重行）；见 [y7_weight_tiling.md](../handoff/archive/design/y7_weight_tiling.md) |
| **残差连接（Y8）：VPU 首次用于真实网络** | ✅ `mt_res` **1024/1024**（CSP bottleneck 核心，ADD8+RELU8）；见 [y8_residual.md](../handoff/archive/design/y8_residual.md) |
| **真实 YOLO 模型（Y9）** | ✅ `mt_yolo` **16384/16384**（tiny-yolov3 stem 的真实训练权重 + **真实 LeakyReLU**，逐比特）；见 [y9_real_model.md](../handoff/archive/design/y9_real_model.md) |
| **LeakyReLU 无需改 RTL（Y10）** | ✅ `max(x, a·x)` = 两次 epilogue + 有符号 MAX8，真实权重上验证；修正了 Y9 的错误结论；见 [y10_leaky_relu.md](../handoff/archive/design/y10_leaky_relu.md) |
| **多层真实 YOLO 链（Y12）** | ✅ `mt_yolocnn`：三层真实 tiny-yolov3 权重 + 真实 LeakyReLU + 池化，**逐层逐比特一致**。根因是打包器漏了 `to_mem()`；见 [y12_chain_fixed.md](../handoff/archive/design/y12_chain_fixed.md) |
| **宽度补齐（Y13）：W 不必是 4 的倍数** | ✅ `wpad`/`src_w` 让 6 宽的层按 8 计算并逐比特验证；13 个真实卷积里 **9 个需要它**；见 [y13_width_padding.md](../handoff/archive/design/y13_width_padding.md) |
| **权重 blob（Y14）：解除镜像容量限制** | ✅ 权重改从 `0x8040_0000` 的非缓存 blob 加载，容量上限 **30 KB → 8 MB**，`.rodata` 159→134.6 KB；见 [y14_weight_blob.md](../handoff/archive/design/y14_weight_blob.md) |
| **调度器（Y17）：真实 YOLO 多级链路** | ✅ `mt_yolomodel` 把 tiny-yolov3 的前 4 个卷积 + 3 次池化串成一条链，逐级逐比特通过（467504 命令 / 62.2M cycles）。串起来后暴露三个单层测不出的限制（UB 行空间、tap 表、权重块）以及 **DMA 不译码 bit 21 导致的 2 MiB 别名**；见 [y17_scheduler.md](../handoff/archive/design/y17_scheduler.md) |
| **缓冲区基址（Y16）：激活搬出 64 KiB scratch** | ✅ 层描述符新增 `base`（默认 scratch，既有测试零改动）；`mt_yolocnn` 整条链跑在 `0x80C00000` 扩展窗口并逐比特通过。Y15 的失败根因是**基址被加了两次**；见 [y16_base_addressing.md](../handoff/archive/design/y16_base_addressing.md) |
| **完整 tiny-yolov3（Y19）：13 卷积 + 6 池化 + 上采样 + 拼接 + 两个检测头** | ✅ `mt_yolomodel` **21 个 stage 逐字节通过**（3,128,301 命令 / 384,458,980 cycles）；8.70 MiB 权重 blob 走 12 MiB 非缓存窗口，`__model_start` 由链接脚本给出；见 [y19_full_yolo.md](../handoff/archive/design/y19_full_yolo.md) |
| FPGA 上板 | ⏳ 未做（仿真里 DMA 是 DPI 客户端，上板需要真正的第二存储端口） |

实测一次完整会话：

```text
msh >mt_gemm
miniTensor self-check starting.
miniTensor GEMM PASSED (K=12, 4x4 INT8, requant+ReLU).
  command chain cycles: 724
miniTensor VPU PASSED (ADD8 / MAX8 / RELU8).
miniTensor self-check OK.
```

**724 cycles / 9 条命令 ≈ 80 cycles per command**（standalone 台架上只要 24.5），
差值就是 NPC 的 MMIO 往返开销。这个数字是后续性能优化的基准。

---

## 2. 结构

| 文件 | 目标位置 | 说明 |
| --- | --- | --- |
| `npc/mt_cvxif_shim.sv` | `npc` Verilator 文件表 | MMIO → CV-X-IF 主端适配器 |
| `npc/mt_dma_bridge.sv` | 同上 | 128-bit DMA → DPI 内存 |
| `npc/tb_mt_shim.sv` | standalone | shim 独立验证（含周期计数） |
| `npc/mt_dpi_mem.cpp` | standalone | 独立验证用的 DPI 内存 |
| `tools/pack_full.py` | 夹具生成器 | **完整 tiny-yolov3**：float 标定 + INT8 打包 + 逐级整数 golden |
| `tools/yolo_decode.py` | 解码器 | 读 blob 里两个 head 的 golden，标准 YOLOv3 解码 + NMS |
| `bsp/mt.h` / `bsp/mt.c` | `bsp/MundusJyd` 的 include 路径 | RT-Thread 驱动 |
| `bsp/mt_app.c` | 同上 | `mt_gemm` MSH 自校验命令 |
| `bsp/compat/*.h` | include 路径 | 极简 libc 头（本机工具链无 newlib） |
| `run_jyd_sim.sh` | — | **一键构建固件 + 跑仿真** |

---

## 3. 地址映射

| 窗口 | 大小 | 属性 | 用途 |
| --- | ---: | --- | --- |
| `0x8010_0000 – 0x8013_FFFF` | 256 KiB | **cacheable** | RT-Thread 的 `.rodata/.data/.bss`/栈 |
| `0x8013_0000 – 0x8013_FFFF` | 64 KiB | 物理切片 | miniTensor scratch，**只准从别名访问** |
| `0x8020_1000 – 0x8020_101F` | 32 B | MMIO | miniTensor 控制寄存器 |
| `0x8030_0000 – 0x8033_FFFF` | 4 MiB 窗口 | uncached **别名**（清 bit21） | 映射到 `0x8010_0000` |
| `0x8040_0000 – 0x80FF_FFFF` | **12 MiB** | uncached | **权重 / 激活缓冲区**：`.weights`（25 KiB 回归 blob）+ `.model`（8.7 MiB 完整模型）共用；`__model_start` 由链接脚本给出 |

`0x8014_0000 – 0x803F_FFFF` 是**故意留空**的：这段若划进 DRAM 就会把
`0x8020_0000` 的外设页一并吞掉。

`linker.ld` 的 `DRAM LENGTH` 已从 256K 改成 **192K**，把最高 64 KiB 让给加速器。

### 为什么 `BRAM.v` / `mem.cpp` 的 CPU 路径一行都不用改

`BRAM.v` 用**窗口内偏移**重建地址（扩容后是 22 位字地址）：

```systemverilog
assign raddr = { 8'b1000_0000, addrb, 2'b00 };   // 0x8000_0000 | (word << 2)
```

`bram_driver` 只把**归一化后的 24 位字节地址**交给它，所以访问别名
`0x8033_1000` 与访问 `0x8013_1000` 得到的 `raddr` **完全相同**——
别名归一化（清 bit21）在 `perip_bridge` 里一次做完。

DMA 侧只**新增**了 `mt_dma_read/mt_dma_write` 两个 DPI 函数，不动既有代码。

FPGA 分支通过 `ifdef __VERILATOR__` 保留原来的 16 位字地址，
所以 Vivado 那边的 65536×32 BRAM IP 不受影响。

---

## 4. MMIO 寄存器

| 偏移 | 名称 | 方向 | 语义 |
| --- | --- | --- | --- |
| `0x00` | `MT_INSTR` | W | 32-bit custom-0 指令字 |
| `0x04` | `MT_RS1` | W | `register.rs[0]` 的值 |
| `0x08` | `MT_RS2` | W | `register.rs[1]` 的值 |
| `0x0C` | `MT_KICK` | W | 写 1 把当前 INSTR/RS1/RS2 **入队**（队列深 8） |
| `0x10` | `MT_STATUS` | R | bit0 busy（队列非空或正在执行）/ bit1 done（队列排空且末条完成）/ bit2 err / bit3 accept_err / bit4 kick_err；**仅在 busy=0 时读会清除标志** |

> 队列是 Y4 加的：Mundus 上 MMIO **写只要 2 拍**（进 store buffer 就返回），
> 但 **读要 11 拍**，所以"每条命令轮询一次"比命令本身还贵。软件用
> `mt_push()` 连续入队、`mt_drain()` 批量等待，实测 MT_LOAD 从 90 拍降到 **25 拍**。
| `0x14` | `MT_RESULT` | R | `result.data`（当前恒 0） |

---

## 5. standalone 复现

```bash
cd $MUNDUS_HOME/miniTensor
SRCS="rtl/interface/core_v_xif.sv rtl/common/minitensor_pkg.sv rtl/tensor/tensor_pkg.sv \
 rtl/vector/vpu_pkg.sv rtl/vector/vpu_vector_regfile.sv rtl/vector/vpu_vector_alu.sv \
 rtl/control/vpu_vector_controller.sv rtl/tensor/MXU/Systolic_Array/tensor_pe.sv \
 rtl/tensor/MXU/Systolic_Array/tensor_systolic_array.sv \
 rtl/tensor/MXU/INT8_GEMM/tensor_gemm_core.sv rtl/tensor/tensor_controller.sv \
 rtl/tensor/Epilogue/tensor_epilogue_core.sv rtl/tensor/Epilogue/tensor_epilogue_controller.sv \
 rtl/memory/unified_buffer.sv rtl/memory/vpu_dma.sv rtl/top/mini_tensor_top.sv"
verilator --binary --timing -Wno-fatal --top-module tb_mt_shim $SRCS \
  integration/npc/mt_cvxif_shim.sv integration/npc/mt_dma_bridge.sv \
  integration/npc/tb_mt_shim.sv integration/npc/mt_dpi_mem.cpp \
  --Mdir integration/npc/obj_shim -o mt_shim
./integration/npc/obj_shim/mt_shim
```

---

## 6. 环境前置与坑（全部实测踩过）

### 6.1 必须先装/生成

```bash
cd $MUNDUS_HOME
export MUNDUS_HOME=$PWD

git submodule update --init rtthread-nano   # nvboard 可选，本流程不需要

# mill 0.12.4 —— 注意组织名是 com-lihaoyi（带连字符）
curl -fL -o npc/mill \
  https://github.com/com-lihaoyi/mill/releases/download/0.12.4/0.12.4-assembly
chmod +x npc/mill

cd npc
make -C tools/kconfig NAME=mconf NAME=conf   # 需要 flex/bison/ncurses-dev（本机已有）
make -C tools/capstone                       # 需要网络 clone
```

### 6.2 配置：两个 Kconfig 默认值是陷阱

**必须**用：

```bash
make -C npc ... # 等价于 conf --defconfig
# CONFIG_RVE is not set     <- 默认 y，会让 GPR 地址变 4 位，与 Mundus_DPIC.v 的 5 位冲突
CONFIG_BP_TAGE=y            <- 默认 BP_ALWAYS_NOT_TAKEN，会让 CONFIG_BRANCH_RAS 不可见，
                              而 scsrc 无条件引用它 -> Scala 编译 100 个错误
```

生成配置：

```bash
cd npc
cat > /tmp/mundus_jyd_defconfig <<'EOF'
# CONFIG_RVE is not set
CONFIG_BP_TAGE=y
CONFIG_BRANCH_RAS=y
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

# 注意：Makefile 里是裸 'mill'，不是 $(MILL)，所以要放进 PATH
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))   # 本机 JAVA_HOME 指向 Java 8，mill 会崩
export PATH=$PWD:$PATH
make verilog                                          # 生成 vsrc/build/Mundus.sv
```

### 6.3 构建固件

```bash
cd rtthread-nano/rt-thread/bsp/MundusJyd
make CROSS_COMPILE=riscv64-unknown-elf- \
     MUNDUS_HOME=$MUNDUS_HOME NPC_HOME=$MUNDUS_HOME/npc \
     COREMARK_HW_CRC=0 COREMARK_HW_MATRIX=0 COREMARK_OPT_FLAGS="-Os" image
```

- 必须显式传 `NPC_HOME`：环境里预设了指向 ysyx-workbench 的 `NPC_HOME`，而 Makefile 用的是 `?=`。
- 必须 `-Os` 编 CoreMark：本机是 GCC 13.2（BSP 原本针对 GCC 16.1 + `-mtune=mundus` 调优），
  默认 `-O3` 会让 `.text` 超出 32 KiB IROM 约 1 KB。
- 本机 `riscv64-unknown-elf-gcc` **没有 newlib**，`finsh.h` 需要的 `<stdio.h>` 等由
  `bsp/compat/` 提供极简声明。

### 6.4 跑仿真：必须用 `VERILATOR_RESET=0`

```bash
JYD_CONSOLE_CMDS='mt_gemm;quit' make ... VERILATOR_RESET=0 run
```

> **这是最隐蔽的一个坑。** `npc/Makefile` 原本跑 `+verilator+rand+reset+2`（随机复位值），
> 此时 CPU **一条指令都不退休**：前端正常取指把 IQ 填满，但 issue 永远为 0，
> 10000 拍后 `HIT BAD TRAP`。用 `+verilator+rand+reset+0` 则一切正常。
>
> 这个现象在**最小裸机测试**（`npc/tests/dual_issue`，完全不碰 miniTensor）上同样复现，
> 所以它是这套 RTL 对未初始化状态敏感的问题，**不是 miniTensor 集成引入的**。
> 根因（哪一位未复位状态卡住了 issue）尚未定位，已在 `npc/Makefile` 里做成
> `VERILATOR_RESET` 变量并默认 0。

---

## 7. 一键跑通

```bash
./integration/run_jyd_sim.sh
JYD_CONSOLE_CMDS='help;mt_gemm;quit' ./integration/run_jyd_sim.sh
```
