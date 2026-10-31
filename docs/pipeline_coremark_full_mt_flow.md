# 单发射流水线 SoC：构建 IROM 程序并运行全加速 CoreMark MULTITHREAD

> 适用对象：`pipeline_amp_top`（2/4 hart，Phase 3 的共享 IROM + 每 hart I$）、
> 标准 CoreMark MULTITHREAD 聚合报告、四类加速（CRC8 + array list + matrix +
> state）。
>
> 本文给出从 ELF 到 IROM 的镜像构建、Verilator 运行、结果检查，以及 Pango
> 侧 IROM/DRAM hex 拆分；多 hart 板级顶层与每 hart DRAM 初始化仍属 Phase 4。
> 关联文档：[pipeline_coremark_mt_plan.md](pipeline_coremark_mt_plan.md)、
> [pipeline_single_issue_plan.md](pipeline_single_issue_plan.md)。

## 1. 对象与产物

| 项 | 位置 / 值 |
| --- | --- |
| SoC top | `rtl/pipeline/soc/amp/pipeline_amp_top.sv`（`CORES=2|4`） |
| IROM | 1 份共享 32 KiB bank，`0x8000_0000–0x8000_7FFF`，8192 × 32-bit |
| I$ | 每 hart 私有；全加速镜像使用 512 行 × 64 B = 32 KiB（`ICACHE_LINES=512`） |
| DRAM | 每 hart 私有 32 KiB 窗口，`0x8010_0000 + h*0x8000` |
| DRAM 数据复制 | 仿真 loader 把镜像 DRAM 段复制到每个 hart 的窗口 |
| mailbox | `0xA000_F000 + h*0x40`，hart id `0xA000_0FF0` |
| 镜像目录 | `build/coremark_full_mt2/`（2 hart）、`build/coremark_full_mt4/`（4 hart） |
| 关键文件 | `coremark-riscv32-ares.elf`、`coremark.bin`、`coremark_dmem.hex`、`inputs.json`、`port/` |

镜像中的指令段只有 `.boot + .text`，放到 IROM；`.rodata/.data/.bss/栈` 放到
每个 hart 的私有 DRAM 窗口。因此“IROM 程序大小”看 `.boot + .text`，不是
`coremark.bin` 的约 1 MB（后者是跨过 1 MiB 地址空洞的扁平镜像）。

## 2. 前置条件

- `riscv64-unknown-elf-` 交叉工具链（gcc/ld/objcopy/size）；
- `python3`、`make`、Verilator 5.x（含 `--build`）；
- 不需要网络；EEMBC CoreMark 源码固定在 `tests/benchmarks/coremark/`。

## 3. 构建全加速 MT 镜像

默认 10,000 总迭代（2 hart → 每 context 5,000；4 hart → 每 context 2,500）：

```bash
make pipeline-coremark-full-mt-image CORES=2
```

仿真常用的缩小 profile（2×100 总迭代）：

```bash
make pipeline-coremark-full-mt-image CORES=2 COREMARK_MT_TOTAL_ITERATIONS=200
```

命令内部执行：

```text
build_coremark_crc.py --array-list --matrix-engine --state-engine
    --ldscript tests/abstract-machine/scripts/ares-linker-mc.ld
    --mt-pipe --cores 2 --total-iterations <TOTAL> --out build/coremark_full_mt2
```

- `--mt-pipe` 把 `scripts/coremark_mt_pipe/` 的 port overlay 应用到
  **staged 副本**，并追加
  `CFLAGS += -DARES_MT_CORES=2 -DARES_MT_ITERATIONS=<TOTAL/2>`；
- `MULTITHREAD` 与 `ITERATIONS` 是编译期宏，2/4 hart 镜像不能混用；
- EEMBC 源码树不被改写，全部差异记录在 `inputs.json` 的
  `mt_pipe` / `mt_overlay_sha256` 段。

### 3.1 检查镜像大小

```bash
riscv64-unknown-elf-size -A build/coremark_full_mt2/coremark-riscv32-ares.elf
```

2-hart 全加速 MT 的参考值：

| 段 | 大小 | 位置 |
| --- | --- | --- |
| `.boot` | 316 B | IROM |
| `.text` | 32,116 B | IROM |
| IROM 合计 | **32,432 B / 32,768 B**（8,108 / 8,192 word，余 336 B） | `0x8000_0000` |
| `.rodata + .data` | 2,032 B | 每 hart DRAM |
| `.bss` | 4,172 B | 每 hart DRAM |
| DRAM 合计 | 6,204 B / 32 KiB | `0x8010_0000 + h*0x8000` |

> **4-hart 全加速聚合镜像不可链接**：需要约 33,068 B，超出 32 KiB IROM 300 B。
> `pipeline-coremark-full-mt-image CORES=4` 现在会直接报错。4-hart 全加速请用
> AMP 变体（见 §6），或把 IROM 扩到 64 KiB（Phase 4）。基础（非加速）4-hart MT
> 只有 13,800 B，不受影响。

## 4. 运行仿真

一条命令完成镜像构建、仿真器编译和运行：

```bash
make pipeline-coremark-full-mt CORES=2
```

- 镜像总迭代取 `PIPELINE_MT_SIM_TOTAL`（默认 200）；
- 仿真器固定用 `-GICACHE_LINES=512`（32 KiB I$，覆盖约 31.7 KiB 代码）；
- 运行 `build/pipeline_coremark_full_mt2/pipeline_coremark_full_mt`。

手工复用已编译仿真器：

```bash
build/pipeline_coremark_full_mt2/pipeline_coremark_full_mt \
    build/coremark_full_mt2/coremark.bin 200000000 2
```

最后一个参数是 hart 数；`200000000` 是最大周期数。

### 4.1 预期输出与检查点

```text
Iterations      : 200
CoreMark/MHz    : 15.816722
Parallel ares-mt-mbox : 2
[0]crcfinal      : 0x988c
[1]crcfinal      : 0x988c
CoreMark PASS
ICACHE hart1 refills=... words=...
ICACHE hart0 refills=... words=...
pipeline-coremark-amp: cycles=... cores=2 done=1/1 a0=[00000000,00000000] PASS
```

通过条件（全部满足）：

1. `CoreMark PASS`；
2. `[0]..[N-1]crcfinal` 相同，且与单核同迭代数参考一致
   （100 iter → `0x988c`，50 iter → `0x0158`）；
3. TB 行 `done` 全 1、`a0` 全 0、结尾 `PASS`；
4. 进程退出码为 0。

`ICACHE ...` 行是每 hart 的 refill 统计（行数 / word 数），用于观察 IROM
带宽；全加速 2-hart 参考值约 hart0 337 行 / hart1 231 行。

## 5. 从 ELF 到 IROM（Pango）

链接脚本 [ares-linker-mc.ld](../tests/abstract-machine/scripts/ares-linker-mc.ld)：

```text
irom 0x8000_0000  32 KiB   .boot + .text
dram 0x8010_0000  32 KiB   .rodata + .data + .bss + stack
                        _stack_top = 0x8010_8000
```

拆分 Pango 初始化文件：

```bash
make pipeline-image \
    PIPELINE_IMAGE_ELF=build/coremark_full_mt2/coremark-riscv32-ares.elf
```

输出：

- `build/pipeline/irom.hex`：8192 × 32-bit，从 `0x8000_0000` 起；
- `build/pipeline/dram.hex`：65536 × 32-bit，从 `0x8010_0000` 起；
- `build/pipeline/image.json`：地址/大小/校验信息。

综合 filelist 用 [pipeline_pango.f](../rtl/pipeline/pipeline_pango.f)，其中
`IROM_BMEM32` 在非 Verilator 构建下推断为 BRAM 并从 `irom.hex` 初始化。

> 当前板级顶层 `pipeline_board_top` 仍是单 hart；2/4-hart 板级顶层、每 hart
> DRAM 初始化/复制和 PDS 时序签核属于 Phase 4。上面的 hex 拆分已经可用于
> IROM 部分和后续板级接入。

## 6. 参数与变体

| 变量/目标 | 作用 |
| --- | --- |
| `CORES=2|4` | hart 数；全加速**聚合**镜像目前只支持 2 |
| `COREMARK_MT_TOTAL_ITERATIONS` | 镜像总迭代数，默认 10,000 |
| `PIPELINE_MT_SIM_TOTAL` | `pipeline-coremark-full-mt` 的仿真总迭代，默认 200 |
| `PIPELINE_MT_MAX_CYCLES` | 仿真最大周期，默认 400,000,000 |
| `ICACHE_LINES`（TB 参数） | I$ 行数；全加速镜像用 512 |

其它可运行目标：

```bash
make pipeline-coremark-mt CORES=2          # 基础 MT（16 KiB I$）
make pipeline-coremark-mt CORES=4
make pipeline-coremark-mc CORES=2          # 全加速 AMP（每 hart 一份报告）
make pipeline-coremark-mc CORES=4          # 4-hart 全加速 AMP
```

AMP 与 MT 的区别见 [pipeline_coremark_mt_plan.md](pipeline_coremark_mt_plan.md)；
简言之：MT 是标准 MULTITHREAD 单份聚合报告，AMP 是每 hart 独立跑
`MULTITHREAD=1` 并各自打印。

## 7. 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `region irom overflowed by 300 bytes` | 4-hart 全加速聚合镜像超 32 KiB IROM；用 AMP，或扩 IROM / 裁代码 |
| 仿真很久不结束 | 10,000 迭代在 Verilator 需数小时；保持 `PIPELINE_MT_SIM_TOTAL=200` |
| 没有 UART 输出 | stdout 重定向时按块缓冲；结束后才 flush；先确认进程仍在跑且未超时 |
| 改了源码但结果没变 | 镜像按 `CORES/TOTAL` 分目录并记录在 `inputs.json`；重新执行构建目标 |
| AMP 输出交错 | 4 个 hart 各自打印到同一 stdout；以 TB 的 done/a0 和 CRC 行为准 |
| I$ 命中率差 | 全加速代码约 31.7 KiB，必须用 512 行；基础 MT 用默认 256 行 |

## 8. 参考结果（Verilator，2026-10）

| 配置 | 总迭代 | cycles | CoreMark/MHz | CRC | 结果 |
| --- | --- | --- | --- | --- | --- |
| 2-hart 全加速 MT（512 行 I$） | 200 | 12,717,275 | 15.816722 | 0x988c ×2 | PASS |
| 2-hart 基础 MT（16 KiB I$） | 200 | 43,746,087 | 4.579943 | 0x988c ×2 | PASS |
| 4-hart 基础 MT（16 KiB I$） | 200 | 21,938,513 | 9.166984 | 0x0158 ×4 | PASS |
| 4-hart 全加速 AMP（512 行 I$） | 4×100 | 12,694,279 | 每 hart 约 7.9 | 0x988c ×4 | PASS |
| 4-hart 全加速 MT | — | — | — | — | 不可链接（IROM 溢出 300 B） |

以上是 RTL 仿真值（100 MHz 计数），不是板级实测。
