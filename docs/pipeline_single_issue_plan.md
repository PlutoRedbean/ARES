# ARES FPGA 单发射流水线 SoC 实施计划（PG2L200H）

> 状态：Draft v0.3（M0/M1 完成，ISA 36/36 与基线 CoreMark 仿真通过；Pango 待后续）
> 日期：2026-10-30
> 目标分支：`pipeline-single-issue`（待从 `pipeline` 创建）
> 关联文档：[implementation_plan.md](implementation_plan.md)、[jyd_soc_integration.md](jyd_soc_integration.md)、[coremark_uart_scoring.md](coremark_uart_scoring.md)

---

## 1. 目标与范围

### 1.1 目标

用 ysyx-workbench/npc 的 **单发射顺序流水线核**替换 ARES 当前的多发射 OoO 后端，形成一个可在 **Pango PG2L200H** 上实现和上板的 pipeline SoC，并先跑通 **基线 CoreMark**，从 RTL UART 读取 100-iteration 分数。

### 1.2 本期范围

- 单 hart；
- 基线 `make coremark-image`（100 iterations）；
- 单发射核 + jyd SoC 外设/存储；
- PG2L200H 综合、实现、资源/时序报告、上板 UART 跑分；
- 为后续加速镜像、多核、中断保留接口和文档。

### 1.3 本期不做

- 双核/四核、SMP/AMP、原子操作、缓存一致性；
- 中断、CLINT/PLIC、RT-Thread；
- CRC / 矩阵引擎 / 状态机扫描器等 CoreMark 加速镜像；
- miniTensor、L2/ICache 重构；
- 维护 ARES 主线 OoO 后端的等价功能。

---

## 2. 决策记录

| 编号 | 决策 | 说明 |
| --- | --- | --- |
| D1 | 目标器件为 **PG2L200H-6IFBB676**，沿用 `fpga/pango` 的 Pango PDS 2022.2-SP6.4 + `synthesize -ads` 流程 | Pango 流程当前文档标注为 Verilog-2001；新导入 RTL 的 SystemVerilog 兼容性必须在 M0 用 PDS 实测确认 |
| D2 | Core 源码取 **npc `5-stage-pipeline` 分支**：`scsrc/`、`vsrc/Mundus/`、`vsrc/modules/`、`vsrc/include/`、`vsrc/DPIC/` | 生成 RTL 由 ARES 内的 `rtl/pipeline/gen` 输出到 `rtl/pipeline/core/vsrc/build/Mundus.sv`；不回到 npc 写生成物 |
| D3 | SoC 源码取 **npc `jyd` 分支**：`vsrc/testbench/jyd/`；内存/外设 wrapper 参考 `vsrc/testbench/IP/` | 使用 jyd 原始的 **2-bit `perip_mask`** 外设桥，不使用 ARES 已迁移的 4-bit `wstrb` 版本 |
| D4 | 第一版只做 **单 hart** | 不引入 atomics、`mhartid`、核间中断、L2 一致性；双核/四核作为后续资源允许时的扩展 |
| D5 | 第一版只跑 **基线 CoreMark**（`make coremark-image`，100 iterations） | 不把 CRC/矩阵/状态机加速镜像作为首版验收条件；后续再按同一软件/硬件接口扩展 |
| D6 | **中断 / RT-Thread 不在本期范围** | jyd 的 `timer_irq` 在 pipeline wrapper 中先固定为 0；jyd 的毫秒计数器保留，但不作为 CoreMark 计时源 |
| D7 | **不原样直接使用 Mundus SoC**；以 jyd SoC 为基线，直接修改 SoC | jyd SoC 与 5-stage core 在 IROM 宽度（直接改 32-bit）、`timer_irq`、配置宏、存储器模型上不一致；IROM 不做兼容层，其余按需适配；详见第 5 节 |
| D8 | 第一版保留 CoreMark 的 **`0xA000_xxxx` 软件映射**，在 SoC 内做兼容窗口 | 复用现有 `coremark-image`，不改 `ares.h`；jyd 原生 `0x8020_xxxx` 外设仍保留，后续再考虑原生映射 |
| D9 | ARES `pipeline` 分支上已提交的 MT 改动（`0eea64d`）作为后续优化参考保留 | 单 hart 第一版不合并 MT mailbox/双核路径；避免把双核问题带入 bring-up |
| D10 | 新分支命名为 `pipeline-single-issue`，从 `pipeline@0eea64d` 创建 | 文档和 RTL 导入分开提交；不覆盖现有 `pipeline` 分支 |
| D11 | **IROM 直接改为 32-bit**，不保留 64→32 兼容层/适配器 | 直接修改 jyd `student_top.sv` 的 IROM 实例、地址宽度和 `irom_data` 位宽；`IROM_BMEM32` 取代 64-bit `IROM_BMEM`，SoC 中不出现 64-bit 取指路径 |

### 2.1 已确认的源码版本

| 仓库/分支 | Commit | 用途 |
| --- | --- | --- |
| npc `5-stage-pipeline` | `1d839c86c8eee76c7540298a467700e065432e93` | 单发射 core（Chisel + 手写模块） |
| npc `jyd` | `31f47241393120a9092527b65892b010e6e38234` | jyd SoC / 外设 / 存储 wrapper |
| ARES `pipeline` | `0eea64d62877ccd9f59a139b6fa49b931519030f` | 分支基点；MT 优化参考 |
| firtool | `1.77.0` | 当前 `Mundus.sv` 生成器版本；重新生成时必须记录 |

当前工作树中的 `Mundus.sv`：

- M1 后 3192 行，SHA-256 `4b50ab9388b322afdd2dc15fec6fc9724c78d637fd1365e551da63f05d71c05c`；
- 由 `make pipeline-core-gen` 在 ARES 内生成，目标为 `rtl/pipeline/core/vsrc/build/Mundus.sv`；生成源为 `rtl/pipeline/core/scsrc` + `rtl/pipeline/gen/configs/scsrc`。

---

## 3. 源码导入与目录布局

### 3.1 导入原则

- 不切换 npc 工作树分支；用 `git archive` 从指定 commit 导出，避免污染用户当前 checkout。
- Core 的 **可读源码**（`scsrc`）和 **生成 RTL**（`Mundus.sv`）都要保留；生成 RTL 只作为 build artifact，不手改。
- SoC 使用 jyd 分支原始 RTL；ARES 现有 `rtl/soc/jyd/` 是迁移到 OoO/128-bit 总线后的版本，**不作为本计划的 SoC 源**。
- 所有导入文件记录来源 commit、路径、SHA-256；生成物记录 firtool 版本和生成命令。

### 3.2 建议目录

```text
rtl/pipeline/
├── core/
│   ├── scsrc/                       # 5-stage-pipeline Chisel 源
│   ├── vsrc/Mundus/                 # myCPU/RegisterFile/Bimodal/RAS/...
│   ├── vsrc/modules/                # Adder/MuxKey/Reg/...
│   ├── vsrc/include/                # inst_para.vh / common_para.vh ...
│   ├── vsrc/DPIC/                   # 仅 DPIC 定义时启用
│   └── vsrc/build/Mundus.sv         # 生成物（firtool 1.77.0）
├── soc/
│   ├── jyd/student_top.sv           # 已直接改为 32-bit IROM + 5-stage CPU
│   ├── jyd/irom_bmem32.sv           # 32-bit IROM（取代 64-bit IROM_BMEM）
│   ├── jyd/perip_bridge.sv          # jyd 原始 2-bit mask 版本
│   ├── jyd/{bram_driver,counter,uart,cdc_xpm_nofifo_lib,display_seg,seg7}.sv
│   └── ip/                          # BRAM/DCache/MDU/DPIC 模型
├── test/                            # tb_pipeline_smoke + sim_main.cpp
├── include/
│   ├── pipeline_autoconf.vh         # core + SoC 合并配置
│   └── autoconf.vh                  # jyd include 兼容 shim
├── gen/                             # ARES-local mill build for Mundus.sv
├── pipeline.f                       # Verilator filelist
└── README.md                        # 来源/修改/验证记录
```

### 3.3 `autoconf.vh` 的处理

npc 的 `configs/build/vsrc/include/autoconf.vh` 是构建生成物，且 core 与 jyd SoC 使用的宏集合不同。导入后必须提供一份 **统一的 `pipeline_autoconf.vh`**，至少覆盖：

- core：`CONFIG_MUL_LATENCY`、`CONFIG_DIV_LATENCY`、`CONFIG_BRANCH_BTB_WIDTH`、`CONFIG_BRANCH_BIMODAL_BITS`、`CONFIG_BRANCH_RAS*`、`CONFIG_STORE_BUFFER_DEPTH`、`CORE_ENTRY`；
- SoC：`CONFIG_IROM_ADDR_WIDTH`、`CONFIG_IROM_SIZE_BYTES`、`CONFIG_IROM_CORE_OUTPUT_REGISTER`（如使用）。

32-bit IROM 直接改在 SoC 内：`CONFIG_IROM_ADDR_WIDTH` **保持 jyd 的 64-bit-pair 索引宽度 12**；`inst_addr = pc[CONFIG_IROM_ADDR_WIDTH+2:2]`（13 位），`IROM_BMEM32.addra` 为 13 位，32-bit 深度为 8192。`CONFIG_IROM_DEPTH` 仍记录原始 64-bit pair 的 4096。`CONFIG_SIMULATION` 不定义（避免启用 npc difftest DPIC），`CORE_FREQ` 以数值 100.000 定义。不再保留 64-bit pair 的地址/数据路径。

要求：core 生成参数、手写模块宏、SoC IROM 宏三者一致；M0 用 lint/elaboration 检查，不能靠“能编译”猜测。

### 3.4 `Mundus.sv` 的生成策略

**不直接手改 `core/vsrc/build/Mundus.sv`。** 生成目标已经迁到 ARES：

- Chisel 源码：`rtl/pipeline/core/scsrc`；
- 生成工程：`rtl/pipeline/gen`（`build.sc` + `mill` + `configs/scsrc/autoconf.scala`）；
- 生成命令：`make pipeline-core-gen`；
- 输出：`rtl/pipeline/core/vsrc/build/Mundus.sv`；
- 本地 mill 缓存：`rtl/pipeline/gen/out/`（git-ignored）。

`gen/configs/scsrc/autoconf.scala` 中 `CONFIG_SIMULATION=false`，避免生成 npc difftest/DPIC 钩子。M1 的 `FENCE/EBREAK/retire_*` 已直接改在 `core/scsrc` 并通过该目标重新生成；不再需要回 npc 写文件。

---

## 4. 目标架构

```text
PG2L200H board
  ├─ PLL / UART / pins / constraints
  └─ pipeline_board_top
       └─ pipeline_soc_top
            ├─ pipeline_core_wrapper  (myCPU-like)
            │    └─ Mundus (5-stage, single-issue)
            │         irom:  32-bit addr/data
            │         perip: 32-bit addr/data, 2-bit mask
            ├─ IROM_BMEM32 (32-bit) / Pango BRAM
            ├─ (no 64→32 adapter)
            ├─ pipeline_perip_compat   (0xA000 -> 0x8020, cycle counter, UART status)
            ├─ jyd perip_bridge        (DRAM 0x8010_0000, UART 0x8020_0060, ms counter)
            ├─ BRAM (256 KiB DRAM)
            └─ pipeline_cycle_counter  (64-bit CPU cycles)
```

关键点：

- **保留 jyd 的 32-bit perip 接口和 2-bit mask**，因为 5-stage core 原生就是这个接口；这是选择 jyd SoC 的最大收益。
- **不使用 ARES 的 128-bit `mem_*` / `mmio_*` 适配层**作为第一版路径；那会引入 L2/ICache/总线 bridge 的额外工作。
- **不使用 AXI**；IROM/DRAM 都是本地 BRAM，避免把 jyd SoC 的简单存储路径复杂化。
- Core 的 IROM 取指假设“地址发出后下一拍数据有效”；`IROM_BMEM32` 必须保持 1-cycle 语义。
- **IROM 不做兼容层**：`student_top.sv` 直接使用 32-bit `irom_data` 和 32-bit word 地址；SoC 中不保留 64-bit pair 路径。

---

## 5. 能否直接使用 Mundus 的 SoC？

### 5.1 结论

**不能原样直接使用，但 jyd SoC 是正确的起点。** 直接复用 `student_top.sv`、`perip_bridge.sv`、`bram_driver.sv`、`uart.sv` 的结构是可行的；IROM 不走兼容层，直接把 SoC 改成 32-bit IROM；其余接口和板级实现按下面几项适配。

### 5.2 具体不一致

| 项 | 5-stage-pipeline core | jyd SoC / core | 处理 |
| --- | --- | --- | --- |
| IROM 数据宽度 | 32-bit | `student_top` 使用 64-bit IROM pair | **直接修改 SoC**：`irom_data` 改 32-bit，`inst_addr = pc[..:2]`，实例化 `IROM_BMEM32`；不保留 64→32 适配器 |
| `timer_irq` | 5-stage `myCPU` 没有该端口 | jyd `myCPU` 有 `timer_irq`，`Mundus` 有 `io_interrupt` | pipeline wrapper 先 `timer_irq=0`；后续在 Chisel 中加中断端口 |
| perip mask | 2-bit `perip_mask` | jyd `perip_bridge` 也是 2-bit | **匹配**；但 ARES 迁移版是 4-bit `wstrb`，本计划不使用 |
| 配置宏 | `CONFIG_MUL_LATENCY` 等 | `CONFIG_IROM_ADDR_WIDTH` 等 | 合并成一份 `pipeline_autoconf.vh`；见 3.3 |
| 计时器 | CoreMark 读 `0xA000_0050/54` 的 64-bit cycle counter | jyd `0x8020_0050` 是 **毫秒计数器**，还可写 start/stop | 新增 64-bit cycle counter；不要把 jyd 毫秒计数器接到 CoreMark |
| UART 状态 | CoreMark 期望 `0xA000_03FC` bit0 = busy | jyd `0x8020_0064` bit0 = `console_rx_valid`，bit1 = `console_tx_ready` | 兼容层把 bit0 规范化为 `~console_tx_ready`；或改软件 |
| 地址映射 | `0xA000_03F8` / `0x3FC` / `0x50/54` | `0x8020_0060` / `0x64` / `0x50` | 兼容窗口做地址/状态转换；第一版不改 `ares.h` |
| 存储器模型 | 需要可综合 BRAM | jyd `IROM_BMEM`/`BRAM` 是 DPI 仿真模型 | 新增 `IROM_BMEM32`（仿真 DPI/综合 BRAM 两套）；`BRAM` 用 Pango wrapper |
| CDC | 不涉及 | jyd `counter`/`perip_bridge` 使用 Xilinx XPM | 换成 Pango/通用 2FF、gray-code CDC；M0 先做小规模综合验证 |
| 板级顶层 | 无 | jyd `top.sv` 使用 Vivado `pll`、50 MHz/9600 UART | 新建 Pango `pipeline_board_top`；UART 建议 115200，PLL/引脚按板卡约束 |

### 5.3 可直接复用的部分

- `perip_bridge.sv` 的 DRAM/MMIO/存储队列/2-bit mask 结构；
- `bram_driver.sv` 的 BRAM 读写接口；
- `uart.sv` 的 UART 收发（仅换时钟/波特率参数）；
- `counter.sv` 的毫秒计数器（保留给后续 RT-Thread，不作为 CoreMark 计时）；
- `student_top.sv` 的端口和实例化结构（替换 CPU、直接改 32-bit IROM）；
- `top.sv` 仅作板级连接参考，不能直接作为 Pango 顶层。

### 5.4 不可直接复用的部分

- jyd 的 `myCPU.v`：它是 **64-bit IROM + timer_irq + jyd Mundus** 的 wrapper，不是 5-stage core 的 wrapper；
- jyd 分支的 `Mundus` 生成物：不是 5-stage-pipeline 的 core；
- jyd 的 `autoconf.vh`：不能直接给 5-stage core 用；
- `IROM_BMEM` 的 64-bit/DPI 版本：不再使用；改为 `IROM_BMEM32`，且其 DPI 版本不能综合；
- `cdc_xpm_nofifo_lib.sv` 的 Xilinx XPM：Pango 不可用；
- `top.sv` 的 Vivado PLL/UART 板级实现：Pango 需要重做。

---

## 6. Core 需要新增/修改的功能

以下修改已在 ARES 的 `core/scsrc` 中完成，并通过 `make pipeline-core-gen` 重新生成 `Mundus.sv`。

### 6.1 `FENCE`

- 现状：`IDU.scala` 指令表没有 `FENCE`，落到默认项，实际是 NOP。
- 需求：`FENCE` 必须作为内存屏障，至少保证：
  - 之前的 store 已经离开 store buffer/MMIO 队列；
  - 之后的 load 不会越过屏障；
  - CoreMark 的 `start_time()/stop_time()` 计时边界可信。
- 实现建议：在 `IDU` 识别 `FENCE`，产生 `fence` 控制位；在 `ISU/HZU/LSU` 侧 stall 到 LSU/MMIO idle；不需要实现完整 RISC-V 内存模型，但必须满足单 hart 的强顺序外设语义。

### 6.2 `FENCE.I`

- 现状：`FENCE_I` 常量存在，但 IDU 没有译码；当前无 I-Cache，影响较小。
- 需求：作为 NOP 或 flush 前端/取指队列；为后续 I-Cache/自修改代码留接口。
- 第一版可以按“flush 取指队列 + 清流水线”实现，不引入 I-Cache。

### 6.3 `EBREAK`

- 现状：`envir=ENVIR_EBREAK` 只送给 DPIC；`EXU` 的 `trap_redirect` 只包含 `ECALL/MRET`，所以 EBREAK 不停机、不陷入。
- 需求：CoreMark 的 `halt()` 执行 `ebreak` 后必须：
  - 停止提交后续指令（或按架构陷入 `mtvec`）；
  - 对外给出 `retire_is_ebreak` 事件，供 ARES TB 结束仿真。
- 建议：第一版实现“halt”语义（停止取指/提交，保持 `retire_is_ebreak`），避免 `mtvec=0` 导致跑飞；同时保留后续改为 trap 的选项。

### 6.4 提交/退休观察端口

需要从 `WBU` 暴露（或新增）：

```systemverilog
retire_valid
retire_pc
retire_pc_next
retire_rd_wen
retire_rd
retire_wdata
retire_is_ebreak
```

注意：`WBU` 当前有 `pc_next`，但没有当前 `pc`；需要把 `pc` 从 EX 级带到 WBU，或增加一个退休 PC FIFO。ARES 的 ISA 回归和 CoreMark TB 都依赖这些信号。

### 6.5 可选：`timer_irq` 端口

本期不做中断，但 jyd SoC 有 `timer_irq`。第一版在 wrapper 中固定 0；后续在 Chisel 中增加 `io_interrupt`、`mie/mip` 和异常入口时再接入。

### 6.6 不改的部分

- RV32IM 指令语义、BPU/RAS、D-Cache、store buffer、乘除法时序不变；
- `Mundus_PC` 的复位 PC 保持 `0x8000_0000`；
- 不引入 A 扩展、压缩指令、S 模式。

---

## 7. SoC 需要新增/修改的模块

### 7.1 `student_top.sv` 与 `IROM_BMEM32`（直接修改，不做兼容）

直接修改 jyd `student_top.sv`：

- `logic [63:0] instruction` → `logic [31:0] instruction`；
- `inst_addr` 改为 32-bit word 索引：`pc[`CONFIG_IROM_ADDR_WIDTH+2:2]`（13 位）；
- `IROM_BMEM` → 新增 `IROM_BMEM32`，`addra` 为 `CONFIG_IROM_ADDR_WIDTH+1` 位，`douta` 为 32-bit；
- `myCPU` 使用 5-stage core wrapper；去掉 jyd `myCPU` 的 `timer_irq` 端口连接；
- SoC 中不保留 64-bit pair 的取指路径，也不增加 64→32 适配器。

`IROM_BMEM32` 的地址计算：

```systemverilog
wire [31:0] byte_addr = 32'h8000_0000 + ({addra, 2'b00});
```

时序要求：地址发出后下一拍 `douta` 有效；若综合 BRAM 需要 output register 导致 2-cycle，必须在 core 侧加 fetch stall，不能静默改成 2-cycle。

### 7.2 CoreMark 设备窗口（已直接实现在 `perip_bridge`）

在 `soc/jyd/perip_bridge.sv` 内直接处理 `0xA000_xxxx`，不增加独立兼容模块：

| CoreMark 地址 | 功能 | jyd 目标 |
| --- | --- | --- |
| `0xA000_03F8` | UART TX | `0x8020_0060` |
| `0xA000_03FC` | UART status | `0x8020_0064`，bit0 转成 busy |
| `0xA000_0050` | cycle counter low | 新 64-bit 计数器低 32 位 |
| `0xA000_0054` | cycle counter high | 新 64-bit 计数器高 32 位 |
| 其他 `0xA000_xxxx` | 保留/返回 0 | 可选：透传到 jyd 外设 |

- UART 写通过 `perip_addr_eff` 别名到 `CONSOLE_ADDR`；status 读返回 bit0 = `~console_tx_ready`；
- cycle counter 使用独立 64-bit `cycle_count`，占用 `RESP_CNT` 响应通道但不覆盖 `0x8020_0050` 毫秒计数器；
- 该实现已通过 `make pipeline-coremark` 验证。

### 7.3 `pipeline_cycle_counter`

- 64-bit 自由运行计数器，`cpu_clk` 域，复位清零；
- 每个时钟加 1；高低 32 位分别可读；
- 与 CoreMark 的 `COREMARK_CLOCK_HZ=100000000` 对应；实际板级 CPU 频率必须与软件常量一致，否则分数换算错误。

### 7.4 `pipeline_soc_top`

- 实例化 5-stage core wrapper、`IROM_BMEM32`、jyd perip bridge（含 CoreMark 窗口）、BRAM、cycle counter；
- `timer_irq` 固定 0；
- 保留 jyd 的 `virtual_sw/key/led/seg` 端口（可裁剪）；
- 不实例化 ARES `ares_frontend_l2_top`/`ares_core_top`。

### 7.5 Pango 板级适配

- 用 Pango PLL 替换 jyd `top.sv` 的 `pll`；
- UART 建议 115200（当前 jyd 顶层是 50 MHz/9600；CoreMark 计时不含 UART 传输，但串口太慢会影响上板体验）；
- 用 Pango BRAM wrapper 替换 `IROM_BMEM32`/`BRAM` 的 DPI 模型；
- 用通用 2FF/gray CDC 替换 `cdc_xpm_nofifo_lib.sv` 的 Xilinx XPM；
- 新建 `fpga/pango/pipeline/` 流程和约束，不修改现有 video 流程。

---

## 8. 内存映射与软件契约

### 8.1 第一版（兼容 CoreMark 镜像）

| 地址 | 大小 | 用途 |
| --- | --- | --- |
| `0x8000_0000` | 32 KiB | IROM（32-bit word；`IROM_BMEM32`） |
| `0x8010_0000` | 256 KiB | D-Cacheable DRAM |
| `0x8020_0000` | 4 KiB | jyd 外设（SW/KEY/SEG/LED/ms counter/UART） |
| `0xA000_0050/54` | 8 B | 64-bit CPU cycle counter（兼容窗口） |
| `0xA000_03F8` | 4 B | UART TX（兼容窗口） |
| `0xA000_03FC` | 4 B | UART status，bit0=busy（兼容窗口） |

- 现有 `make coremark-image` 产物直接使用，不改 `tests/abstract-machine/am/src/riscv/ares/include/ares.h`；
- jyd 的 `0x8020_0050` 毫秒计数器保留，CoreMark 不读它；
- 后续如果要使用原生映射，再新增 `ARCH=riscv32-pipeline` 或平台头文件，不在第一版做。

### 8.2 频率/计时

- `COREMARK_CLOCK_HZ` 目前冻结为 100 MHz；Pango 板级 CPU 时钟必须是 100 MHz，或同步修改软件常量并重建镜像；
- CoreMark 的计时区间由 `start_time()/stop_time()` 的 `fence` 和 MMIO 读界定；
- UART 输出发生在计时区间之外；TB/板级仍需等待最后一帧发完。

---

## 9. 构建、仿真与验证

### 9.1 Make 目标

已落地：

```bash
make pipeline-core-gen
make pipeline-lint
make pipeline-smoke
make pipeline-isa       # 36/36
make pipeline-coremark  # baseline 100 iterations
```

后续目标：

```bash
make pipeline-coremark DMEM=$PWD/build/coremark/coremark_dmem.hex
```

必须区分：

- core-only 仿真（无 SoC）；
- pipeline SoC 仿真（IROM/DRAM/UART/cycle counter）；
- Pango 综合/实现。

### 9.2 仿真策略

第一版建议使用 **独立的 pipeline TB**，不要复用 `tb_ares_cpu`/`tb_ares_coremark` 的内部层次引用：

- `tb_ares_pipeline_cpu`：core + 简单 IROM/DPI memory，验证 ISA/retire/ebreak；
- `tb_ares_pipeline_soc`：core + jyd SoC + 兼容层，验证 CoreMark/UART；
- 存储器模型可用 `$readmemh` 或 DPI；UART 用现有 `uart_console_monitor` 解码；
- 必须有 timeout、UART drain、cycle/retire 统计。

### 9.3 验收标准

| 阶段 | 验收 |
| --- | --- |
| M1 | core 语义 smoke + ISA 36/36：`fence` 前后 store、`ebreak` retire/halt 均通过 |
| M2 | 基线 CoreMark 100 iterations：`a0=0`、CRC 正确、UART 打印完整分数；仿真已通过（2.293729 CoreMark/MHz） |
| M3 | Pango 综合/实现通过；资源/时序报告；上板 UART 打印同一分数 |
| M4 | 可选：中断/RT-Thread、加速镜像、双核 |

### 9.4 分数口径

- 只比较 **同镜像、同频率** 的 pipeline 与当前 OoO：基线 vs 基线；
- 当前 7.04 CoreMark/MHz 是加速镜像结果，不能作为单发射基线的直接对比；
- 记录：timed cycles、iterations、CoreMark/MHz、IPC、D-Cache miss、分支 mispredict（如可得）。

---

## 10. 实施阶段

### M0：分支、导入、工具链验证

已完成：

- 从 `pipeline@0eea64d` 创建 `pipeline-single-issue`；
- 用 `git archive` 导入 core/SoC 源码，记录 commit/SHA-256（见 `rtl/pipeline/README.md`）；
- 合并 `pipeline_autoconf.vh` / `autoconf.vh` shim；
- `make pipeline-core-gen`：在 ARES 本地生成 `Mundus.sv`；M1 后 3192 行，哈希见 2.1；
- `make pipeline-lint`：0 errors（warning 仍为导入代码的 timescale/decl-filename/unused 类）；
- `make pipeline-smoke`：8 条指令，`fence` 前后的两次 `sw` 都写入，`ebreak` 被 retire 且 pipeline 停止。

待完成：

- PDS 不在当前 Linux 主机上，PG2L200H 的 SystemVerilog/PDS 兼容性检查、资源/时序评估需要到 Pango 工具环境执行；
- `Mundus.sv` 现在由 `rtl/pipeline/gen` 在 ARES 内生成；miller 缓存 `gen/out` 已忽略。

### M1：core 语义与 ISA

已完成：

- `FENCE/FENCE.I` 译码为 `ENVIR_FENCE` 屏障，在 Decode 等到 `LSU.idle` + `perip_idle`；
- `EBREAK` 通过 `retire_is_ebreak` 可见，并触发 sticky halt；
- `retire_valid/pc/pc_next/rd_wen/rd/wdata/is_ebreak` 从 `Mundus`/`myCPU`/`student_top` 导出；
- `Mundus.sv` 由 ARES 内 `make pipeline-core-gen` 生成；
- smoke 覆盖 `fence` 前后 store、`ebreak` retire/halt；
- `make pipeline-isa` 36/36 通过。

待完成：

- retire PC/GPR 与独立参考模型的逐指令对拍（ISA 结果已通过）。

### M2：pipeline SoC 仿真与 CoreMark

已完成：

- `IROM_BMEM32`、`perip_bridge` 内的 `0xA000` 设备窗口、64-bit cycle counter；
- 基线 CoreMark 100 iterations：`43,597,126` timed cycles，`2.293729` CoreMark/MHz；
- CRCs `e714 / 1fd7 / 8e3a / 988c`，`CoreMark PASS`，`a0=0`。

后续：

- 上板 Pango 实现；
- 加速镜像与多核。

### M3：Pango 实现与上板

- Pango BRAM/CDC/PLL/UART 适配；
- 综合/实现，输出资源/时序；
- 上板跑 100 iterations，UART 分数与仿真一致；
- 形成资源/时序对比报告。

### M4：后续扩展

- 中断/RT-Thread；
- CRC/矩阵/状态机加速镜像；
- 双核/四核与一致性方案；
- 视资源决定是否加 I-Cache/L2。

---

## 11. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| Pango PDS 对 SystemVerilog 支持不足 | jyd/ARES RTL 无法直接综合 | M0 先用最小 SV 文件验证；必要时提供 Verilog-2001 包装层 |
| Xilinx XPM 无法在 Pango 使用 | jyd SoC 的 CDC 不能综合 | 替换为通用 2FF/gray CDC；先做单元仿真 |
| jyd IROM/BRAM 是 DPI 模型 | 无法上板 | 写 Pango BRAM wrapper；仿真/综合两套文件列表 |
| 5-stage core 无 `fence/ebreak/retire` | CoreMark 计时不可信/无法结束 | 在 Chisel 中补；M1 验收 |
| 32-bit IROM 地址/时序错误 | 取指错/跑飞 | `inst_addr = pc[..:2]`，`IROM_BMEM32` 保持 1-cycle；单指令/ISA 回归先验证 |
| UART status 位定义不一致 | 计时包含启动输出 | 兼容层规范化 bit0=busy；TB 等待 UART drain |
| 无 I-Cache，D-Cache 仅 8 KiB | 分数偏低 | 先接受基线；后续按分数/资源决定是否加 I$ 或扩大 D$ |
| 生成物不可复现 | core 修改无法追溯 | 固定 npc commit/firtool；记录 SHA-256；不手改生成物 |
| CoreMark 100 iterations 仿真时间长 | 迭代慢 | 先 1/4 iterations；最终分数用 UART；必要时缩短诊断输出 |
| Pango 资源/时序未知 | 可能放不下/跑不到 100 MHz | M0 先做资源预算；M3 出报告；必要时裁剪外设/显示 |

---

## 12. 待确认项

1. PDS 2022.2-SP6.4 对 jyd/ARES 使用的 SystemVerilog 语法支持范围；是否需要 Verilog-2001 包装层。
2. PG2L200H 板级的 PLL、UART 引脚、时钟频率、复位极性；现有 `fpga/pango` 约束是否可复用。
3. 目标资源预算（LUT/FF/BRAM/DSP）和最低频率；是否以 100 MHz 为验收。
4. 是否允许在 npc 的 `5-stage-pipeline` 上新建 core-fix 分支并重新生成 `Mundus.sv`（本计划假设允许）。
5. 分支名是否用 `pipeline-single-issue`；文档是否需要在 `README.md` 增加入口。
6. UART 波特率：保持 jyd 的 9600，还是改为 115200。
7. 第一版是否接受“兼容窗口 + 不改 `ares.h`”的方案；还是希望直接改成 `0x8020` 原生映射。
8. CoreMark 目标分数/最低可接受分数；是否只记录相对当前 OoO 的比值。

---

## 13. 附录：导入清单

```text
core:
  5-stage-pipeline@1d839c86c8eee76c7540298a467700e065432e93
  scsrc/**
  vsrc/Mundus/{Bimodal,BimodalRas,Divider,Multplier,Mundus_PC,RegisterFile,ReturnAddressStack,myCPU}.v
  vsrc/modules/*.v
  vsrc/include/*.vh
  vsrc/DPIC/*.v            # 仅 DPIC 定义时启用
  vsrc/build/Mundus.sv     # 由 rtl/pipeline/gen 生成；firtool 1.77.0，SHA-256 见 README

soc:
  jyd@31f47241393120a9092527b65892b010e6e38234
  vsrc/testbench/jyd/{student_top,perip_bridge,bram_driver,counter,uart,cdc_xpm_nofifo_lib,display_seg,seg7}.sv
  vsrc/testbench/IP/{BRAM,DCacheData_BRAM,DCacheTag_BRAM,mult,div,xpm_cdc_verilator_stubs}.v
  新增 rtl/pipeline/soc/jyd/irom_bmem32.sv  # 取代 IROM_BMEM，不保留 64-bit 路径
  新增 rtl/pipeline/test/{tb_pipeline_smoke.sv,sim_main.cpp}
  新增 rtl/pipeline/gen/{build.sc,mill,.mill-version,configs/scsrc/autoconf.scala}
```

> DCache/MDU wrapper 取自 5-stage-pipeline（与生成核的索引宽度一致）；BRAM/StoreBuffer_DPIC 取自 jyd SoC。
