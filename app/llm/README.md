# ARES-L 应用一：语言模型（llm）

端侧小型语言模型部署工程：**一颗 ARES 九级顺序核 + 一片 miniTensor INT8 协处理器**，
裸机运行 H112 词级 seq2seq GRU、A0 char-GRU 两套执行路径和 QA 检索知识库，
经 UART 115200 8N1 行协议对话。手势识别工程（`../gesture`）与本工程共用同一份
`rtl/`：同一 CPU、同一 miniTensor、同一 SoC 与运行时。

## 平台与口径

应用部分按技术报告《ARES：面向 FPGA 的 RISC-V 单发射流水线 SoC》第二部分的
应用口径组织：

| 项目 | 本工程实现 |
| --- | --- |
| CPU | ARES 核（Mundus 九级：取指请求/响应、ID、ISS、EX1–EX4、WB），源码取自 ARES 仓库 `rtl/pipeline/core`，见 `rtl/core/README.md` |
| 数据视图 | uncached：全部应用地址都落在核内 0x8010_0000–0x8013_FFFF 可缓存窗口之外，load/store 以单拍 32 bit 事务经 PERIP 出核，CPU 与 DMA 看到同一份物理内存 |
| 加速器 | miniTensor：4×4 INT8 阵列、行式 128 bit UB、向量单元、定点 epilogue；CV-X-IF 兼容 shim + 64 项命令队列 + DMA |
| 加速器窗口 | 0xE000_0000，8 个 32 bit 寄存器（INSTR/RS1/RS2/KICK/STATUS/BSTEP/LO/HI） |
| 前端 | 16 项 Bimodal+BTB、8 项 RAS、四路 ICache（顶层级联 `ares_icache_refill` 从 128 bit L2 回填） |
| 中断 | 机器定时器（CLINT → `timer_irq`）；Mundus 无机器软件中断输入，CLINT 的 MSIP 仅对软件可见 |
| 复位入口 | 0x0000_0000（仿真：ROM 跳板 → 0x8000_0000 镜像；上板：UART loader → 0x8000_0000） |

> 技术报告的应用章节把 CPU 记作“ARES-L 五级应用基线”。本次重构按要求把两个应用
> 统一到 ARES 仓库的 Mundus 九级核；应用侧契约（uncached 数据视图、CV-X-IF shim、
> 0xE000_0000 八寄存器窗口、命令流）保持不变。

## 目录

```
llm/
├── rtl/
│   ├── core/          ARES 核（Mundus.sv + myCPU 包装 + BPU/乘除/DCache BRAM）
│   ├── icache 路径     rtl/core/icache/pipeline_icache.v（四路）
│   ├── minitensor/    INT8 张量加速器（阵列 / 向量 / epilogue / UB / DMA）
│   ├── common/        ares_pkg：地址映射与编码常量
│   ├── soc/           核复合体、L2/MMIO、UART、CLINT、GPIO、DDR 模型
│   │   ├── ares_core_complex.sv   myCPU + ICache + PERIP 桥 + miniTensor + 总线仲裁
│   │   ├── ares_icache_refill.sv  ICache 回填适配（128 bit L2 → 32 bit beat）
│   │   ├── ares_perip_bridge.sv   PERIP ↔ L2（掩码→字节选通、固定两拍读响应）
│   │   └── mt/                    CV-X-IF shim、命令队列、DMA 桥、miniTensor 包装
│   └── board/         板级顶层（CPU + miniTensor + UART）
├── firmware/
│   ├── boot/          UART loader（ROM 跳板）
│   ├── common/        start.S、linker.ld、runtime（printf/UART/陷阱）
│   └── app/           mt 驱动、mt_net、A0/H112/QA 模型与入口
├── fpga/pango/        PDS 流程与引脚约束
├── sim/               Verilator 测试台与 BIN→HEX 工具
├── tools/             pango_prep、mkrom、烧写脚本、核同步/校验脚本
└── docs/              A0 实测、FPGA 规划与本项目复核记录
```

## 快速开始

```bash
make lint        # Verilator lint（ares_soc）
make sim         # 构建 SoC 仿真模型
make fw-h112     # 编译 H112 镜像 -> build/fw/h112/app.hex
make run-h112    # 跑一段并打印 UART
make fw-a0-cpu   # A0 char-GRU 的 CPU 路径（int16 Q15）
make fw-a0-mt    # A0 char-GRU 的 miniTensor 路径（int8 GEMV）
make fw-qa       # QA 检索知识库
```

固件默认按 100 MHz 仿真分频（`UART_DIV=8`）；上板用 `make fw-h112 UART_DIV=234`。
烧写顺序与主仓库一致：**先位流，后固件**。

模型产物以打包后的权重提交在 `firmware/app/*_weights.h`（H112 152,056 B、A0、
QA）。共用的 INT8 量化/打包/golden 格式参考实现在
`../gesture/tools/model/pack_weights.py`；Qwen 教师语料生成与 GRU 训练脚本属于
离线工具，不在本工程内。

## 应用

| 形态 | 结构 | 参数 / 镜像 | 入口 |
| --- | --- | --- | --- |
| A0 | char-GRU：Emb64→GRU96→Linear65 | 57,121 参数 / 62 KB | `main.c`（CPU）、`main_mt.c`（miniTensor） |
| H112 | 词级 seq2seq GRU（V198/E48/H112/rank24） | 126,006 参数 / 152,056 B | `main_seq.c` |
| QA | 检索式知识库 | 10,475 条 / 638,076 B | `main_cpu.c` |
| intent / rule | 意图分类与规则对话 | — | `main_intent.c` / `main_rule.c` |

上述参数量包含权重与偏置，不包含量化比例、LUT 与对齐填充。

miniTensor 把 GEMV 映射为单个空间位置的 1×1 卷积：A 行 0 放 x[4t..4t+3]、行 1–3 补零，B 放
[组][k 组][4k][4out] 权重，C 只取行 0 沿 t 累加。串口行协议与 20 token/s 输出节流
（50 ms/token）是演示节流，不代表算力。

## 内存映射

| 区域 | 地址 | 说明 |
| --- | --- | --- |
| Boot ROM / loader | 0x0000_0000 | 仿真：跳板到 0x8000_0000；上板：UART loader |
| CLINT | 0x0001_0000 | mtime / mtimecmp / msip |
| Scratch | 0x1000_0000 | 192 KiB（miniTensor 窗口与帧缓冲） |
| DDR（uncached 别名） | 0x4000_0000 | 128 bit beat |
| 镜像 / 栈 | 0x8000_0000 | 链接地址；`__stack_top = 0x800F_0000`（保持在核内可缓存窗口之下） |
| UART / GPIO | 0xD000_0000 | TX 0x00、STATUS 0x04、CTRL 0x08、BAUD 0x0C |
| miniTensor | 0xE000_0000 | 8 个寄存器，见 `rtl/common/ares_pkg.sv` |
