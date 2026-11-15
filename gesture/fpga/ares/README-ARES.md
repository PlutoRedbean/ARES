# ARES

**ARES** (AI-accelerated RISC-V Embedded SoC): a single-issue, 5-stage RISC-V
pipeline SoC with CoreMark accelerators, targeting the Pangu **PG2L200H-6IFBB676**
FPGA (PDS 2022.2 / 2025.2).

---

## 主线：单发射流水线 SoC

| 层 | 实现 | 位置 |
| --- | --- | --- |
| 核 | Mundus 5-stage in-order（Chisel 生成 + 手写包装） | `rtl/pipeline/core/` |
| 存储层次 | 4 KiB 4 路 I$ + **8 KiB 2 路组相联 D$**（写直达 + 写失效一致性） | `rtl/pipeline/core/`、`rtl/pipeline/soc/ip/DCache*_BRAM.v` |
| SoC | JYD `student_top`：IROM/DRAM、perip_bridge、UART、timer、LED/SEG | `rtl/pipeline/soc/jyd/` |
| 平台层 | 去 XPM 的 CDC、可综合 BRAM、PLL/复位、板级顶层 | `rtl/pipeline/soc/pango/`、`rtl/pipeline/board/` |
| 加速器 | `mtx9_engine`（9-PE INT16 矩阵）、`state9_engine`（token 扫描）、`list9_engine`（链表 find/reverse/MTF）、custom-0 CRC8 | `rtl/accel/` |
| 多核 | `pipeline_amp_top` 2/4-hart AMP：共享 IROM + 私有 I$ + 共享 mailbox | `rtl/pipeline/soc/amp/` |
| 时钟 | 27 MHz → PLL → CPU 100 MHz / 外设 50 MHz | `rtl/pipeline/board/pipeline_pll.v` |

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

最近一次 Verilator 结果：单核全加速 **13.381925 CoreMark/MHz**
（100 iterations，7,525,556 cycles）；4-hart 全加速 `MULTITHREAD=4`
**57.242704 CoreMark/MHz**（200 iterations，3,630,085 cycles），4 份
`crclist/crcmatrix/crcstate` 全对，`a0=0`，`CoreMark PASS`。链表引擎见
[docs/coremark_list_engine.md](docs/coremark_list_engine.md)。

### 软件镜像链

```bash
make coremark-full-image          # EEMBC + 加速 TU -> build/coremark_full/*.elf
make pipeline-image \
    PIPELINE_IMAGE_ELF=$PWD/build/coremark_full/coremark-riscv32-ares.elf \
    PIPELINE_IMAGE_OUT=$PWD/build/pipeline
# -> build/pipeline/irom.hex (8192 x 32) / dram.hex (65536 x 32) / image.json
```

全加速镜像必须带 `--small-code`（`make PIPELINE_COREMARK_IMAGE_FLAGS=--small-code
coremark-full-image`），否则放不进 32 KiB IROM；拆分窗口和校验规则见
[fpga/pango/pipeline/README.md](fpga/pango/pipeline/README.md)。

### Pango PDS

单核：`fpga/pango/pipeline/flow_pipeline.tcl`（`compile → synthesize -ads →
dev_map → pnr -seed 2 → report_timing → gen_bit_stream`），约束
`pipeline_board.fdc`（时钟/IO）+ `.pcf`（物理约束），下载用
`fpga/pango/program.tcl`。

> 2-hart AMP 的板级顶层 `rtl/pipeline/board/pipeline_amp_board_top.v` 和板级
> 仿真 TB 已在本仓库（`make pipeline-amp-pango-lint` /
> `pipeline-amp-board-sim`），源文件表是 `rtl/pipeline/pipeline_amp_pango.f`；
> PDS 工程侧的 `flow_pipeline_amp.tcl` 仍维护在 PDS 工程里。
> `pipeline-amp-board-sim` 装载的就是 PDS `$readmemh` 用的
> `build/pipeline/*.hex`，不上板也能确认板级镜像。

最近一次 PnR（PG2L200H-6，100 MHz）：CLMA 34%、FF 11%、DRAM36K 38%、APM 3%，
WNS **−1.527 ns**、TNS −3,167 ns，瓶颈在 `u_mtx9_engine` 的阵列读/写通路；
分析与下一步见 [docs/pango_amp_floorplan.md](docs/pango_amp_floorplan.md)。

## 仓库布局

| Path | Contents |
| --- | --- |
| `rtl/pipeline/` | 核（Chisel 源 + 生成 RTL）、SoC、平台层、板级顶层、文件表、TB |
| `rtl/accel/` | `mtx9_engine` / `state9_engine` 及单元 TB |
| `fpga/pango/pipeline/` | PDS 流程、FDC 约束、上板说明 |
| `tests/benchmarks/coremark/` | vendor 的 EEMBC CoreMark + ARES port |
| `tests/abstract-machine/` | 裸机运行时与链接脚本（`ares-linker*.ld`） |
| `tests/cpu-tests/` | ISA 回归（也可只编镜像：`images`） |
| `scripts/` | 镜像构建/拆分/测试工具 |
| `docs/` | 流水线、加速器、CoreMark 与 Pango 相关文档 |

## 文档索引

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
- 4-hart 全加速 `MULTITHREAD=4` 聚合镜像现在可以链接进 32 KiB IROM
  （list engine 把 text 压到约 30 KiB）；AMP 板级仍走每 hart 分档镜像。
- 共享 L2 的 `pipeline_mc_soc_top` 的 CoreMark 仍有读响应顺序问题（实验线）。
- AMP 板级顶层与 PDS 流程尚未入库（见上）。
- 板级没有 UART RX 引脚，`rx` 接 1；CoreMark 只依赖 TX。
