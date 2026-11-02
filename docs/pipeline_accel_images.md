# Pipeline 单发射 SoC 加速镜像（CRC / 链表 / 矩阵 / 状态机）

> 状态：M4 加速镜像已在 pipeline-single-issue 分支实现并通过 100-iteration
> Verilator 仿真；2026-11-03 已复测当前五种单核镜像。PDS 已有历史布局布线
> 报告，当前配置的 PnR 与实板验收待补，见[技术报告](technical/technical_report.tex)。
> 适用计划：[pipeline_single_issue_plan.md](pipeline_single_issue_plan.md) 的 M4。
> 复用来源：[coremark_crc_acceleration.md](coremark_crc_acceleration.md)、
> [coremark_matrix_engine.md](coremark_matrix_engine.md)、
> [coremark_state_engine.md](coremark_state_engine.md)。

## 1. 范围

在同一份 EEMBC CoreMark 源码上，通过构建期符号重命名和新 TU 提供四类加速
路径，不修改 tests/benchmarks/coremark/src/*.c：

| 变体 | 软件入口 | 硬件入口 | 约束 |
| --- | --- | --- | --- |
| CRC | scripts/build_coremark_crc.py 生成的 src/crc_hw.c | custom-0 CRC8 指令 | 精确匹配 crcu8() |
| 矩阵 | --matrix-engine 生成的 src/matrix_hw.c | 0xA000_1000 MMIO 窗口 | N == 9，其它 N 回退 |
| 状态机 | --state-engine 生成的 src/state_hw.c | 0xA000_2000 MMIO 窗口 | blksize <= 1024、step > 0、seed1 == seed2，否则回退 |
| 链表 | --list-engine，scripts/coremark_array_list.c | 0xA000_3000 MMIO 窗口 | n <= 32；find/reverse/MTF 走引擎 |

CRC、矩阵和状态机沿用早期加速构建流程；全加速目标另启用链表引擎。
当前核内 CRC 数据通路及三个引擎分别由 CPU 指令与 MMIO 访问。

## 2. 硬件结构

### 2.1 CRC8 custom-0 指令（两拍流水）

编码与 OoO 主线一致：

    .insn r 0x0b, 0, 0x00, rd, rs1, rs2
    rd = crc8_step(rs1[7:0], rs2[15:0])

为了避免把 8 级串行 CRC 组合逻辑压进 EX1 的关键路径，pipeline core 把它拆成
两级：

- EX1：处理低 4 bit，结果放入现有 bit_data/bit_aux 流水字段；
- EX2：处理高 4 bit，结果按 WHEN_ABS_EX2 写回/前递。

因此指令延迟为 2 拍，但每一级只有 4 个 CRC bit step。它复用现有 bit-op 的
bit_data/bit_aux 通路，不增加 issue port、队列或 completion 通路。相关文件：

- rtl/pipeline/core/scsrc/bmu/CRC8.scala
- rtl/pipeline/core/scsrc/idu/IDU.scala
- rtl/pipeline/core/scsrc/exu/exu_ex1.scala
- rtl/pipeline/core/scsrc/exu/exu_ex2.scala
- rtl/pipeline/core/scsrc/common/Config.scala

### 2.2 矩阵 / 状态机 MMIO

直接复用 rtl/accel/mtx9_engine.sv 与 rtl/accel/state9_engine.sv，新增
rtl/pipeline/soc/jyd/pipeline_accel.sv 作为薄封装：

- 只做 4 KiB 页译码（0xA000_1xxx / 0xA000_2xxx）；
- 每个引擎保持自己的多周期顺序状态机和私有 SRAM；
- 引擎响应比请求晚 1 拍，封装层再寄存 1 拍，与 perip_bridge 的 2 拍
  response-tag 通路对齐；
- perip_idle 把加速器响应也计入，FENCE 不会在引擎响应未完成时提前放行。

perip_bridge 只把 response tag 从 2 bit 扩到 3 bit，并增加一个 2:1 数据
选择；CPU 侧没有宽组合算术或大 mux 进入关键路径。

### 2.3 MMIO 映射

| 地址 | 用途 |
| --- | --- |
| 0xA000_0050/54 | 64-bit CPU cycle counter（原有） |
| 0xA000_03F8/3FC | UART TX / status（原有） |
| 0xA000_1000..0xA000_1FFF | mtx9_engine（A/B/C、CTRL、STATUS、CRC、SUM） |
| 0xA000_2000..0xA000_2FFF | state9_engine（data、BLKSIZE、SEED、STEP、CRC、计数） |

引擎寄存器偏移与 OoO 文档一致，软件镜像不需要改地址。

## 3. 构建与运行

    # 重新生成 core RTL（修改 scsrc 后必须执行）
    make pipeline-core-gen

    # 基础回归
    make pipeline-lint
    make pipeline-isa
    make pipeline-coremark

    # 构建全部加速镜像（CRC / 矩阵 / 状态机 / 全加速）
    make pipeline-coremark-images

    # 100-iteration 仿真
    make pipeline-coremark-crc
    make pipeline-coremark-matrix
    make pipeline-coremark-state
    make pipeline-coremark-full

    # Pango IROM/DRAM 拆分（默认基线镜像）
    make pipeline-image
    # 全加速镜像：flow_pipeline.tcl 固定读 build/pipeline/，所以直接用默认输出
    make pipeline-image \
        PIPELINE_IMAGE_ELF=$PWD/build/coremark_full/coremark-riscv32-ares.elf

    # 板级同路径检查
    make pipeline-pango-lint
    make pipeline-console

pipeline-coremark-images 复用根 Makefile 已有的 coremark-crc-image /
coremark-matrix-image / coremark-state-image / coremark-full-image，因此
EEMBC 源目录仍然不变。

## 4. 当前单核仿真结果（2026-11-03）

相同 `tb_pipeline_isa`、4 KiB 四路 ICache、8 KiB 两路 DCache、100 MHz、
100 iterations、TOTAL_DATA_SIZE=2000、seeds=0/0/0x66。软件 `Total ticks`
用于计分，测试台 `cycles` 包含启动与收尾。镜像哈希见最终报告同目录 `results.json`。

| 镜像 | timed ticks | 仿真总周期 | CoreMark/MHz |
| --- | ---: | ---: | ---: |
| 基线 | 44,742,474 | 44,798,214 | 2.235012 |
| CRC8 | 38,350,135 | 38,404,960 | 2.607552 |
| CRC8 + 矩阵 | 25,363,720 | 25,416,064 | 3.942639 |
| CRC8 + 状态机 | 24,118,605 | 24,170,878 | 4.146176 |
| CRC8 + 链表 + 矩阵 + 状态机 | 7,472,766 | 7,525,556 | 13.381925 |

五种镜像均输出 CRC `e714/1fd7/8e3a/988c`、`CoreMark PASS`，EBREAK 时 a0=0。
本次全加速相对基线约 5.99 倍。早期无 ICache / 无链表引擎的 7.5–8.0 分数属于
旧配置，不作为当前全加速结果。

## 5. 验证与镜像容量

本次 smoke、ISA 36/36、DCache 1520 项检查及三个加速器单元测试均通过。
单核全加速 ELF 的 `.boot + .text` 为 **28,188 B / 32,768 B**，剩余 4580 B。
两核 / 四核全加速 MT 的相应占用为 21,688 / 21,740 B；MT 构建固定使用
`--small-code`，与单核采用的代码体积选项不同。容量检查使用 ELF 段大小，
HEX 的 `nonzero_words` 仅用于内容检查。

PDS 历史结果、当前复测入口与具体检查数见[技术报告](technical/technical_report.tex)。

## 6. 关键路径与流水化说明

1. CRC 不在单拍内完成 8 级串行运算：EX1/EX2 各 4 级，2 拍结果延迟；
   CRC8 指令编码与参考递推保持一致。
2. 矩阵/状态机/链表与 CPU 同时钟，通过 MMIO 驱动，是独立的
   多周期引擎，CPU 只做 MMIO store/load 和轮询。
3. 适配层只增加一级寄存器：页译码是 20-bit 比较，响应选择三个加速器输出，经 mux + 1 个
   寄存器；没有把引擎内部的 9 个 MAC 或 1024 B 存储阵列接进 CPU 的
   MMIO 响应路径。
4. 引擎内部保持原实现：矩阵 9 个 INT16 PE、串行 matrix_sum，状态机
   逐字节 DFA；其吞吐由状态机保证，不靠拉长单周期组合逻辑。

## 7. 范围与限制

- 中断与 RT-Thread 使用独立固件，见 [pipeline_rtos.md](pipeline_rtos.md)。
- AMP 与共享 L2 实验线分开验证，见 [pipeline_multicore.md](pipeline_multicore.md)。
- 矩阵 N==9、状态机参数及链表规模的边界由对应软件驱动与引擎文档定义。
- 本文分数是 ARES accelerated variant 的仿真测量。
