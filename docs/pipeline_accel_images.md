# Pipeline 单发射 SoC 加速镜像（CRC / 矩阵 / 状态机）

> 状态：M4 加速镜像已在 pipeline-single-issue 分支实现并通过 100-iteration
> Verilator 仿真。Pango PDS 综合/实现/上板仍未执行。
> 适用计划：[pipeline_single_issue_plan.md](pipeline_single_issue_plan.md) 的 M4。
> 复用来源：[coremark_crc_acceleration.md](coremark_crc_acceleration.md)、
> [coremark_matrix_engine.md](coremark_matrix_engine.md)、
> [coremark_state_engine.md](coremark_state_engine.md)。

## 1. 范围

在同一份 EEMBC CoreMark 源码上，通过构建期符号重命名和新 TU 提供三个加速
变体，不修改 tests/benchmarks/coremark/src/*.c：

| 变体 | 软件入口 | 硬件入口 | 约束 |
| --- | --- | --- | --- |
| CRC | scripts/build_coremark_crc.py 生成的 src/crc_hw.c | custom-0 CRC8 指令 | 精确匹配 crcu8() |
| 矩阵 | --matrix-engine 生成的 src/matrix_hw.c | 0xA000_1000 MMIO 窗口 | N == 9，其它 N 回退 |
| 状态机 | --state-engine 生成的 src/state_hw.c | 0xA000_2000 MMIO 窗口 | blksize <= 1024、step > 0、seed1 == seed2，否则回退 |

三者在 pipeline SoC 中与 OoO 主线共用同一套软件构建脚本和同一组引擎 RTL，
pipeline 侧只增加 CRC 指令译码和 MMIO 适配层。

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

## 4. 100-iteration 仿真结果

同一 pipeline_isa 仿真器、同一 100 MHz 时钟、同一组 CoreMark 参数
（100 iterations、TOTAL_DATA_SIZE=2000、seeds 0/0/0x66）。表中 cycles 为
CoreMark 计时区间（Total ticks），不是仿真尾部总周期。

| 镜像 | timed cycles | retire | CoreMark/MHz | 相对基线 |
| --- | ---: | ---: | ---: | ---: |
| 基线 | 43,597,126 | 31,368,631 | 2.293729 | 1.000x |
| CRC | 37,356,886 | 25,703,107 | 2.676882 | 1.167x |
| CRC + 矩阵 | 24,507,356 | 16,754,426 | 4.080407 | 1.779x |
| CRC + 状态机 | 23,312,540 | 17,576,660 | 4.289536 | 1.870x |
| CRC + array list + 矩阵 + 状态机 | 12,632,638 | 8,268,956 | 7.916002 | 3.451x |

四个变体的 UART 报告均出现：

    [0]crclist       : 0xe714
    [0]crcmatrix     : 0x1fd7
    [0]crcstate      : 0x8e3a
    [0]crcfinal      : 0x988c
    CoreMark PASS

说明 CRC 指令、矩阵引擎和状态机扫描器的结果都与参考软件逐位一致。

> 上表是 I-cache 尚未接入时的历史结果。当前 `USE_ICACHE=1` 的全加速镜像为
> `13,286,278` ticks / `7.526562` CoreMark/MHz；I-cache 增加命中延迟和
> refill，IPC/CM-MHz 下降属于预期，CRC 仍全对。

## 5. 验证记录

| 检查 | 结果 |
| --- | --- |
| make pipeline-isa | 36/36 PASS |
| make pipeline-lint | 0 errors（保留导入代码既有 warning） |
| make pipeline-console | CONSOLE PASS errors=0 |
| make pipeline-pango-lint | elaborates pipeline_board_top，0 errors |
| PDS compile | `compile -system_verilog` PASS（含 I-cache，2026-10-31） |
| PDS synthesize | PASS（14m25s）；49,361 LUT（30.89%）/ 24,767 FF（7.75%）/ 79.5 DRM（19.16%）/ 8 APM |
| PDS dev_map/PnR/上板 | 未执行 |
| 四个加速镜像 100-iteration | 全部 CoreMark PASS，CRC 全对 |
| 全加速镜像 100-iteration | 含 I-cache：ticks 13,286,278，7.526562 CoreMark/MHz；无 I-cache 参考 12,452,732 / 8.030366，CRC 全对 |
| pipeline_image.py 拆分 | CRC/矩阵/状态机/全加速镜像均可拆分 |
| 全加速镜像 IROM 占用 | 7984 / 8192 words（约 31.2 KiB / 32 KiB） |

全加速镜像 IROM 余量只有约 208 words（832 B）。后续继续增加软件或展开循环时
需要先检查 pipeline-image 的 nonzero words，必要时裁剪代码或扩大 IROM，不能
默认它能继续放下。

## 6. 关键路径与流水化说明

1. CRC 不在单拍内完成 8 级串行运算：EX1/EX2 各 4 级，2 拍结果延迟；
   这是本次唯一的 core 数据通路改动。
2. 矩阵/状态机不进入 CPU 组合路径：它们是独立时钟域内（同 clk）的
   多周期引擎，CPU 只做 MMIO store/load 和轮询。
3. 适配层只增加一级寄存器：页译码是 20-bit 比较，响应是 2:1 mux + 1 个
   寄存器；没有把引擎内部的 9 个 MAC 或 1024 B 存储阵列接进 CPU 的
   load-use 路径。
4. 引擎内部保持原实现：矩阵 9 个 INT16 PE、串行 matrix_sum，状态机
   逐字节 DFA；其吞吐由状态机保证，不靠拉长单周期组合逻辑。

## 7. 限制

- 本文只覆盖 M4 的加速镜像；双核/四核与写失效一致性已在
  [pipeline_multicore.md](pipeline_multicore.md) 单独实现和验证，中断/RT-Thread
  仍未包含。
- 已执行 Pango PDS 2022.2-SP6.4 `compile -system_verilog` 和
  `synthesize -ads`（约 14m25s，`USE_ICACHE=1`）并通过；资源为
  49,361 LUT / 24,767 FF / 79.5 DRM / 8 APM。`dev_map -> pnr ->
  gen_bit_stream`、时序和上板分数尚未执行。两个加速器已改成 PDS 可接受的
  组合逻辑（无 SV enum/return/function），仿真与综合使用同一份 `.sv`。
- 矩阵引擎只对 N == 9 精确；状态机只对文档列出的参数范围精确，其它输入
  由软件回退到原函数。
- 加速镜像仍是 CoreMark accelerated variant，不能与官方 EEMBC 分数直接比较。
