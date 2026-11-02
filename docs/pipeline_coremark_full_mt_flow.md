# ARES：全加速 CoreMark MULTITHREAD 构建与运行

当前 `pipeline_amp_top` 支持 2/4 hart，每 hart 私有 IROM、四路 ICache、DRAM
和加速器，通过共享 uncached mailbox 启动并汇总结果。全加速包含 CRC8、链表、
矩阵和状态机引擎。最终结果见 [技术报告](technical/technical_report.tex)。

## 1. 配置与产物

| 项 | 位置 / 值 |
| --- | --- |
| SoC top | `rtl/pipeline/soc/amp/pipeline_amp_top.sv`，`CORES=2|4` |
| IROM | 每 hart 私有 32 KiB，`0x8000_0000–0x8000_7FFF` |
| ICache | 每 hart 四路，完整加速目标使用 512 行 × 64 B = 32 KiB |
| DRAM | 每 hart 私有 32 KiB，AGU 施加 `DATA_OFFSET=h*0x8000` |
| mailbox | `0xA000_F000+h*0x40`；hart ID 在 `0xA000_0FF0` |
| 镜像 | `build/coremark_full_mt2/` 或 `build/coremark_full_mt4/` |
| 文件 | `coremark-riscv32-ares.elf`、`coremark.bin`、`inputs.json`、staged port |

`.boot + .text` 放在 IROM，`.rodata/.data/.bss/栈` 放在 DRAM。扁平 BIN 跨过
IROM 与 DRAM 间的地址空洞，不能用 BIN 文件大小判断 IROM 是否溢出。

## 2. 构建镜像

需要 RISC-V 裸机工具链 `riscv64-unknown-elf-`、Python 3、make、Verilator 和
主机 C++ 编译器。CoreMark 源码已包含在仓库中。

```bash
# 镜像默认总迭代 10000；2/4 核分别生成
make pipeline-coremark-full-mt-image CORES=2
make pipeline-coremark-full-mt-image CORES=4

# 仿真用 200 总迭代镜像
make pipeline-coremark-full-mt-image CORES=4 COREMARK_MT_TOTAL_ITERATIONS=200
```

构建脚本使用 `--list-engine --matrix-engine --state-engine --small-code`、
`--mt-pipe --cores N --total-iterations T` 与 `ares-linker-mc.ld`。
CRC8 指令、三个引擎和 staged MULTITHREAD port 一起链接；`inputs.json`
保存参数、overlay 和镜像哈希，EEMBC 源目录不被改写。

2/4-hart 全加速聚合镜像均已支持。早期软件数组链表版本曾超出 32 KiB IROM，
链表引擎接入后该限制已解除。每次构建检查实际段大小：

```bash
riscv64-unknown-elf-size -A build/coremark_full_mt4/coremark-riscv32-ares.elf
```

## 3. 仿真与通过条件

```bash
make pipeline-coremark-full-mt CORES=2
make pipeline-coremark-full-mt CORES=4
```

`PIPELINE_MT_SIM_TOTAL` 默认为 200；2 hart 各跑 100 次，4 hart 各跑 50 次。
这是独立 context 的吞吐聚合。程序打印一份 `Iterations : 200` 报告，各
context 的 CRC 分别检查。

通过条件为 `CoreMark PASS`、各 hart 的 done=1 / a0=0，以及进程正常退出。
100 次迭代的 `crcfinal=0x988c`，50 次为 `0x0158`；两种迭代数的
`crclist/crcmatrix/crcstate` 均为 `e714/1fd7/8e3a`。

分数使用 UART 的 `Total ticks`，不使用测试台最后打印的总 `cycles`：

```text
CoreMark/MHz = 总迭代数 * 1000000 / Total ticks
```

基础 MT 用 `make pipeline-coremark-mt CORES=2|4`，默认 16 KiB ICache。
独立报告 AMP 用 `make pipeline-coremark-mc CORES=2|4`，各 hart 运行
MULTITHREAD=1；不能把其一份报告当成整个系统的聚合分数。

## 4. Pango 镜像与板级

AMP 板级顶层、文件表和仿真已入库：`pipeline_amp_board_top`、
`rtl/pipeline/pipeline_amp_pango.f`、`make pipeline-amp-board-sim`。
板级默认 2 hart，各 hart 使用 32 KiB 数据 BRAM。

```bash
# 默认 2-hart、10000 总迭代的聚合镜像，供板级使用
make pipeline-amp-image-mt CORES=2

# 独立报告 AMP 镜像
make pipeline-amp-image

# 板级仿真使用 200 总迭代
make pipeline-amp-board-sim
```

`pipeline-board-image` 统一生成：

| 文件 | 规模 | 用途 |
| --- | --- | --- |
| `build/pipeline/irom.hex` | 8192 × 32-bit | 每 hart 的私有 IROM 使用相同代码镜像 |
| `build/pipeline/dram.hex` | 65536 × 32-bit | 仿真 / 256 KiB 数据存储，32 KiB 数据窗口复制 |
| `build/pipeline/dram_amp.hex` | 8192 × 32-bit | AMP 板级每 hart 的 32 KiB 数据 BRAM |
| `build/pipeline/image.json` | 元数据 | 布局、复制参数与 ELF/HEX 哈希 |

`pipeline-amp-image-mt` 的 Make 入口限定 CORES=2；4-hart SoC 仿真已支持，
4-hart 板级运行需同步顶层参数和该镜像入口。AMP 专用 PDS flow 仍在外部工程；
当前配置的时序及实板验收状态见 [Pango 说明](../fpga/pango/pipeline/README.md)。

## 5. 常见问题

| 现象 | 检查 |
| --- | --- |
| IROM 溢出 | 检查 `.boot + .text` 及 `--list-engine --small-code` 是否启用 |
| 仿真耗时长 | 检查是否使用了镜像默认 10000 总迭代；常规仿真用 200 |
| 修改 CORES 后结果错误 | 重建对应 mt2 / mt4 镜像，不能共用二进制 |
| 分数与总 cycles 换算不符 | 采用 `Total ticks`；总周期还包含启动和收尾 |
| 板级加载了错误程序 | 检查 `build/pipeline/image.json` 的 ELF 与 HEX 哈希 |

逐阶段实施记录见 [MULTITHREAD 计划](pipeline_coremark_mt_plan.md)，
共享 L2 实验线见 [pipeline_multicore.md](pipeline_multicore.md)。
