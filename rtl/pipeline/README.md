# ARES 顺序单发射流水线 SoC

当前配置以 Mundus 核为基础，取指采用 req/rsp/flush 握手，译码至提交分为
ID、ISS、EX1–EX4、WB。上游分支名 `5-stage-pipeline` 是导入来源，不作为当前
流水级数量。最终提交文档为 [技术报告](../../docs/technical/technical_report.tex)。

## 来源与核生成

| 部分 | 来源 | Commit |
| --- | --- | --- |
| Core | npc `5-stage-pipeline` | `1d839c86c8eee76c7540298a467700e065432e93` |
| SoC | npc `jyd` | `31f47241393120a9092527b65892b010e6e38234` |
| Base | ARES `pipeline` | `0eea64d62877ccd9f59a139b6fa49b931519030f` |

Chisel 源码在 `core/scsrc/`，核生成配置在 `gen/configs/scsrc/autoconf.scala`，
本地 mill 工程在 `gen/`，生成文件为 `core/vsrc/build/Mundus.sv`：

```bash
make pipeline-core-gen
```

生成配置关闭 NPC 的 DPIC/difftest 插桩。Verilator 裸机测试使用独立 DPI 存储器，
板级与 RTOS 仿真使用推断 BRAM。`MANIFEST.sha256` 记录导入快照；当前 RTL 的
哈希随核改动而变化，结果记录应保存实际使用文件的哈希。

## 当前结构

| 配置 | IROM / ICache | 数据路径 | 协作方式 |
| --- | --- | --- | --- |
| 单核 `student_top` | 32 KiB IROM；默认 4 KiB 四路 ICache、32 B 行 | 8 KiB 两路单字 DCache；默认 256 KiB DRAM | 裸机或独立 RTOS 固件 |
| AMP `pipeline_amp_top` | 每 hart 私有 32 KiB IROM；默认 16 KiB 四路 ICache、64 B 行 | 每 hart 私有 DRAM / MMIO / 加速器，DRAM 默认 32 KiB | 共享 uncached mailbox |
| AMP 板级 / 全加速 MT | 每 hart 私有 32 KiB IROM、32 KiB 四路 ICache | 同 AMP | 独立报告或 MULTITHREAD 聚合报告 |
| 共享 L2 实验线 `pipeline_mc_soc_top` | 每 hart 私有 IROM，经直通适配器取指 | 私有 DCache、共享写回 L2 / DRAM | 写失效 + epoch |

AMP 当前在各 `student_top` 内使用主线 `pipeline_icache`：
`EXTERNAL_IROM=0`、`ICACHE_SETS=ICACHE_LINES/4`、`ICACHE_WAYS=4`。
旧 `pipeline_amp_icache` 和共享 IROM 仲裁器保留在源码中，当前 AMP 不实例化它们。

单核 ICache 的 `USE_ICACHE=0` 选择一拍直通路径；`ICACHE_PIPE_HITS=1`
允许两拍命中延迟下每拍接收一条请求，置 0 用于串行命中对照。
IFU 使用两项在途元数据队列和八项前端队列。DCache 为 1024 组 × 2 路 × 4 B，
写直达、写命中更新、写不分配；目录与 LRU 用 1024 拍顺序初始化。

共享 L2 实验线中，远端 store 使目标组的两路 valid 失效；在途 refill 若 epoch
已改变则不安装。AMP 数据存储私有，不启用该一致性侧带。

## 指令与外设

- RV32I / RV32M / Zicsr；ECALL、MRET 和机器定时器中断。
- FENCE 等待 LSU 和外设桥排空；FENCE.I 暂复用屏障，没有 ICache 失效功能。
- EBREAK 经 `retire_is_ebreak` 观察，退休后由 sticky halt 停机。
- custom-0 CRC8 分 EX1/EX2 两阶段，每阶段处理四个 bit step。
- `retire_valid/pc/pc_next/rd_wen/rd/wdata/is_ebreak` 经 Mundus、myCPU、student_top 导出。

| 窗口 | 功能 |
| --- | --- |
| `0x8000_0000`，32 KiB | 只读指令存储 |
| `0x8010_0000`，单核默认 256 KiB | 数据存储；AMP 通过 `DATA_OFFSET=h*0x8000` 访问私有窗口 |
| `0x8020_xxxx` | 原生 IO、定时器、中断 pending、UART TX/RX/状态 |
| `0xA000_0050/54` | 64-bit CPU 周期数低/高字 |
| `0xA000_03F8` | UART TX 别名 |
| `0xA000_03FC` | bit1=TX busy、bit0=RX valid；原生 UART 状态 bit1 为 TX ready |
| `0xA000_0FF0/0FF4` | Hart ID / hart 数 |
| `0xA000_1000/2000/3000` | 矩阵 / 状态机 / 链表引擎，各 4 KiB MMIO 页 |
| `0xA000_F000`，256 B | AMP 共享 mailbox，4 槽 × 16 字 |

原生地址、CSR 与接口时序见技术报告；加速器细节见
[pipeline_accel_images.md](../../docs/pipeline_accel_images.md)。

## 构建与验证

在仓库根执行：

```bash
make pipeline-lint
make pipeline-smoke
make pipeline-isa-images
make pipeline-isa
make pipeline-div-test
make pipeline-mult-test
make pipeline-dcache-test
make unit-mtx9 unit-state9 unit-list9
make coremark-image
make pipeline-coremark
make coremark-full-image
make pipeline-coremark-full
make pipeline-coremark-full-mt CORES=2
make pipeline-coremark-full-mt CORES=4
```

`pipeline-coremark-full-mt` 固定总迭代默认 200，2 核每 context 100 次，4 核每
context 50 次，打印一份聚合报告。`pipeline-coremark-mc CORES=2|4` 则让各
hart 分别运行 MULTITHREAD=1 并打印独立报告。两类报告不能混用总迭代或分数。

软件计时以 UART 输出的 `Total ticks` 为准；测试台 `cycles` 还包括启动与收尾。
当前复测结果、软件镜像哈希及 PDS 报告摘要集中在技术报告与同目录的
`results.json`；旧版无链表引擎、共享 IROM 的结果属于各专项文档中的历史记录。

## Pango 板级

| 项 | 实现 |
| --- | --- |
| CDC / 复位 | `soc/pango/pipeline_cdc.v`：同步器、gray counter、四相邮箱；按时钟域异步置位/同步释放 |
| 存储 | `soc/jyd/irom_bmem32.sv`、`soc/pango/pipeline_bram.v` 推断并用 HEX 初始化 BRAM |
| 时钟 | 27 MHz 输入，默认 CPU 100 MHz / 外设 50 MHz；AMP 数据通路与 UART 均用 CPU 域 |
| 单核板级 | `board/pipeline_board_top.v`、`pipeline_pango.f`、`fpga/pango/pipeline/flow_pipeline.tcl` |
| AMP 板级 | `board/pipeline_amp_board_top.v`（默认 2 hart）、`pipeline_amp_pango.f`；专用 PDS flow 在外部工程 |
| 串口 | CoreMark 顶层仅 TX C24；MSH 专用顶层 RX B24 / TX C24，115200 8N1 |

```bash
make pipeline-image
make pipeline-console
make pipeline-pango-lint
make pipeline-amp-pango-lint
make pipeline-amp-board-sim
```

`pipeline-amp-image` 生成独立报告镜像；`pipeline-amp-image-mt` 生成单份聚合
镜像，当前 Make 入口限定板级默认 CORES=2。4-hart MT 的 SoC 仿真入口已支持，
4-hart 板级运行还需同步顶层参数和镜像入口。

现存 PDS 2025.2 报告来自 4-hart、每 hart 256 KiB DRAM 的构建：70 MHz 下
setup WNS +0.945 ns，200 MHz 下 -5.449 ns。当前每 hart 32 KiB DRAM 配置
尚无对应 PnR 报告。流程与引脚见
[fpga/pango/pipeline/README.md](../../fpga/pango/pipeline/README.md)。

## RTOS 与已知问题

独立 RT-Thread Nano 自检与 MSH 固件使用 `build/rtos/`、`build/rtos_shell/`，
测试覆盖启动、ECALL 现场、定时器抢占、tick 补偿、延时与 UART；MSH 另验证
双向 UART、连续输入和命令处理。构建与日志见
[pipeline_rtos.md](../../docs/pipeline_rtos.md)。

当前待处理项：ICache valid 上电初始化、FENCE.I 失效、共享 L2 CoreMark 读响应
顺序，以及当前配置的 PDS 时序和实板验收。ICache 安装与 flush 同拍、短复位下
流水线 valid 残留两项已修复，回归入口为 `make pipeline-icache-test` 与
`make pipeline-reset-pulse`。技术报告按配置记录已通过项与缺口。
