# ARES

**ARES** (AI-accelerated RISC-V Embedded SoC): a single-issue, in-order RISC-V
pipeline SoC with CoreMark accelerators, targeting the Pangu **PG2L200H-6IFBB676**
FPGA (PDS 2022.2 / 2025.2).

---

## 主线：单发射流水线 SoC

| 层 | 实现 | 位置 |
| --- | --- | --- |
| 核 | Mundus 顺序单发射：取指握手 + ID / ISS / EX1–EX4 / WB（Chisel 生成 + 手写包装） | `rtl/pipeline/core/` |
| 存储层次 | 单核 4 KiB 4 路 I$ + **8 KiB 2 路 D$**（写直达；写失效侧带用于共享 L2 实验线） | `rtl/pipeline/core/`、`rtl/pipeline/soc/ip/DCache*_BRAM.v` |
| SoC | JYD `student_top`：IROM/DRAM、perip_bridge、UART、timer、LED/SEG | `rtl/pipeline/soc/jyd/` |
| 平台层 | 去 XPM 的 CDC、可综合 BRAM、PLL/复位、板级顶层 | `rtl/pipeline/soc/pango/`、`rtl/pipeline/board/` |
| 加速器 | `mtx9_engine`（9-PE INT16 矩阵）、`state9_engine`（token 扫描）、`list9_engine`（链表 find/reverse/MTF）、custom-0 CRC8 | `rtl/accel/` |
| 多核 | `pipeline_amp_top` 2/4-hart AMP：每 hart 私有 IROM / 四路 I$ / DRAM / 加速器，共享 mailbox | `rtl/pipeline/soc/amp/` |
| 时钟 | 板级默认 27 MHz → CPU 100 MHz / 外设 50 MHz；AMP 数据通路和 UART 均用 CPU 时钟 | `rtl/pipeline/board/pipeline_pll.v` |

加速器挂在 `0xA000_1000` / `0xA000_2000` / `0xA000_3000`，由 `pipeline_accel.sv` 做薄 MMIO 封装；
CRC8 是核内的两拍 custom-0 指令。各变体的 MMIO 时序和分数见
[docs/pipeline_accel_images.md](docs/pipeline_accel_images.md)。

### 快速开始

```bash
make pipeline-core-gen      # 仅在改 Chisel 核时：重新生成 Mundus.sv
make pipeline-lint          # Verilator lint（SoC）
make pipeline-smoke         # 8 条指令的冒烟程序（fence/ebreak）
make pipeline-isa-images    # 编出 tests/cpu-tests 的 *-riscv32-ares.bin
make pipeline-isa           # ISA 回归（36 个 cpu-tests）
make pipeline-div-test      # 除法器单元测试（iverilog）
make pipeline-dcache-test    # 2 路组相联 D$ 定向 + 随机单元测试（Verilator）
make pipeline-coremark      # 基线 CoreMark（100 iterations）
make pipeline-coremark-full # 全加速（CRC + list + matrix + state）
make pipeline-console       # Pango-only CDC/UART/mailbox 定向测试
```

多核：

```bash
make pipeline-coremark-mc CORES=2        # 2-hart 全加速 AMP
make pipeline-coremark-mt CORES=2        # 标准 MULTITHREAD 聚合报告
make pipeline-coremark-full-mt CORES=2   # 全加速 MULTITHREAD（200 iterations）
make pipeline-coremark-full-mt CORES=4   # 4-hart 单份 MULTITHREAD=4 报告
make pipeline-mc-test                    # 2/4-hart 一致性实验（共享 L2）
```

2026-11-03 Verilator 复测：单核全加速 **13.384075 CoreMark/MHz**
（100 iterations，7,471,566 timed ticks，7,524,378 仿真总周期）；2-hart
全加速 MT 为 **28.167228**，4-hart 为 **56.029283 CoreMark/MHz**
（200 总迭代；四核 3,569,562 timed ticks，3,709,479 仿真总周期）。所有 context
CRC 全对、所有 hart `a0=0`、`CoreMark PASS`。参数、镜像哈希与完整结果见
[最终技术报告](docs/technical/technical_report.tex)及同目录的 `results.json`。

### 软件镜像链

```bash
make coremark-full-image          # EEMBC + 加速 TU -> build/coremark_full/*.elf
make pipeline-image \
    PIPELINE_IMAGE_ELF=$PWD/build/coremark_full/coremark-riscv32-ares.elf \
    PIPELINE_IMAGE_OUT=$PWD/build/pipeline
# -> build/pipeline/irom.hex (8192 x 32) / dram.hex (65536 x 32) / image.json
```

`coremark-full-image` 默认启用链表引擎；`pipeline-coremark-full-mt-image`
同时启用 `--small-code`。IROM 容量检查应使用 ELF 的 `.boot + .text` 段大小，
不能用 HEX 非零字数代替；拆分窗口和校验规则见
[fpga/pango/pipeline/README.md](fpga/pango/pipeline/README.md)。

### Pango PDS

单核：`fpga/pango/pipeline/flow_pipeline.tcl`（`compile → synthesize -ads →
dev_map → pnr -seed 2 → report_timing → gen_bit_stream`），约束
`pipeline_board.fdc`（时钟/IO），下载用
`fpga/pango/program.tcl`。

> AMP 板级顶层 `rtl/pipeline/board/pipeline_amp_board_top.v`（默认 2 hart）和板级
> 仿真 TB 已在本仓库（`make pipeline-amp-pango-lint` /
> `pipeline-amp-board-sim`），源文件表是 `rtl/pipeline/pipeline_amp_pango.f`；
> PDS 工程侧的 `flow_pipeline_amp.tcl` 仍维护在 PDS 工程里。
> `pipeline-amp-board-sim` 装载的就是 PDS `$readmemh` 用的
> `build/pipeline/*.hex`，不上板也能确认板级镜像。

现存 PDS 2025.2 报告（2026-11-01，4 hart、每 hart 256 KiB DRAM）：
70 MHz 约束下 setup WNS **+0.945 ns**、TNS 0；200 MHz 约束下 setup WNS
**−5.449 ns**、TNS −86,357.860 ns。当前每 hart 32 KiB DRAM 配置的 PnR
结果待补，报告与当前配置的区别见最终[技术报告](docs/technical/technical_report.tex)。

## 单核最小 RTOS

RT-Thread Nano 3.1.5 使用独立程序和 `build/rtos/` 镜像，共用支持机器定时器中断的 CPU。
`make pipeline-rtos` / `make pipeline-rtos-board-sim` 已验证启动、无 yield 抢占、延时唤醒及 UART。
CoreMark 保持独立裸机运行；四组固定镜像的回归输出和周期与修改前相同。
`make pipeline-rtos-shell` 提供独立 MSH 串口交互固件，支持线程、tick、中断、LED 和 ECALL 命令；
实板 RX B24 / TX C24（3.3V，115200 8N1）的独立 PDS 入口已准备，上板收发尚待验证。
构建、接口和 PDS 验证边界见 [单核 RTOS](docs/pipeline_rtos.md)。

## 仓库布局

| Path | Contents |
| --- | --- |
| `rtl/pipeline/` | 核（Chisel 源 + 生成 RTL）、SoC、平台层、板级顶层、文件表、TB |
| `rtl/accel/` | `mtx9_engine` / `state9_engine` / `list9_engine` 及单元 TB |
| `fpga/pango/pipeline/` | PDS 流程、FDC 约束、上板说明 |
| `tests/benchmarks/coremark/` | vendor 的 EEMBC CoreMark + ARES port |
| `tests/abstract-machine/` | 裸机运行时与链接脚本（`ares-linker*.ld`） |
| `tests/cpu-tests/` | ISA 回归（也可只编镜像：`images`） |
| `scripts/` | 镜像构建/拆分/测试工具 |
| `docs/` | 流水线、加速器、CoreMark 与 Pango 相关文档 |

## 文档索引

- 最终提交文档：[docs/technical/technical_report.tex](docs/technical/technical_report.tex)
- 核与 SoC：[rtl/pipeline/README.md](rtl/pipeline/README.md)
- 指令缓存：[docs/microarch/pipeline_icache.md](docs/microarch/pipeline_icache.md)
- 数据缓存（2 路组相联）：[docs/microarch/pipeline_dcache.md](docs/microarch/pipeline_dcache.md)
- 加速镜像与 MMIO：[docs/pipeline_accel_images.md](docs/pipeline_accel_images.md)
- 链表引擎：[docs/coremark_list_engine.md](docs/coremark_list_engine.md)；
  软件数组影子：[docs/coremark_array_list.md](docs/coremark_array_list.md)
- 多核与一致性：[docs/pipeline_multicore.md](docs/pipeline_multicore.md)、
  [docs/pipeline_coremark_mt_plan.md](docs/pipeline_coremark_mt_plan.md)、
  [docs/pipeline_coremark_full_mt_flow.md](docs/pipeline_coremark_full_mt_flow.md)
- 实施计划：[docs/pipeline_single_issue_plan.md](docs/pipeline_single_issue_plan.md)
- PDS 上板：[fpga/pango/pipeline/README.md](fpga/pango/pipeline/README.md)

## 已知缺口

- 指令缓存没有 `FENCE.I` 失效路径，私有 IROM 只读，暂不支持自修改代码。
- 共享 L2 的 `pipeline_mc_soc_top` 的 CoreMark 仍有读响应顺序问题（实验线）。
- AMP 板级顶层、文件表和仿真已入库；AMP 专用 PDS flow 仍在外部工程。
- CoreMark 板级顶层只引出 TX；MSH 专用顶层另接 RX B24 / TX C24。
