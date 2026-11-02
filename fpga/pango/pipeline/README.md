# fpga/pango/pipeline — 单发射流水线 SoC 的 PDS 流程

> 目标器件：Pangu 200Pro+ / **PG2L200H-6IFBB676**，PDS 2022.2-SP6.4 或
> PDS 2025.2-SP3-EN，综合用 `synthesize -ads`。本目录服务
> `pipeline_board_top`（单核）和 `pipeline_amp_board_top`（2-hart AMP/MT），
> AMP 顶层默认 2 hart、可参数化为 4；专用 `flow_pipeline_amp.tcl` 仍在外部 PDS 工程。
> 当前复测与历史 PDS 报告摘要见[技术报告](../../../docs/technical/technical_report.tex)。
>
> PDS 2022.2 的 `compile` 用 `-system_verilog`；PDS 2025.2 用
> `-verilog_standard SystemVerilog`。仓库里的 flow 是 2022.2 写法；
> 2025.2 工程可参考 `D:\code\ares_amp_pds2025\synth_pds2025.tcl`。

## 1. 这套流程需要什么

在 Linux/构建主机上先准备本地存储初始化文件。当前全加速 CoreMark 默认
启用链表引擎；单核本次镜像的 `.boot + .text` 为 28,188 B，可放入 32 KiB IROM：

```bash
# 全加速：CRC8 + list engine + matrix engine + state scanner
make coremark-full-image

# 拆成 Pango 的两块本地存储器。flow_pipeline.tcl 固定读 build/pipeline/，
# 所以这里用默认输出目录，不要写到 build/pipeline_full/ 后忘记复制。
make pipeline-image \
    PIPELINE_IMAGE_ELF=$PWD/build/coremark_full/coremark-riscv32-ares.elf \
    PIPELINE_IMAGE_OUT=$PWD/build/pipeline
```

修改软件后，用 `riscv64-unknown-elf-size -A` 检查 ELF 的 `.boot + .text`。
`image.json` 中的 `nonzero_words` 是内容统计，不代表段范围或容量余量。
MT 镜像固定启用 `--small-code`，本次两核/四核占用为 21,688 / 21,740 B。

拆分规则（由 `scripts/pipeline_image.py` 校验）：

| 存储 | 基址 | 容量 | 文件 |
| --- | --- | --- | --- |
| IROM | `0x8000_0000` | 32 KiB（8192 x 32-bit） | `build/pipeline/irom.hex` |
| DRAM | `0x8010_0000` | 256 KiB（65536 x 32-bit） | `build/pipeline/dram.hex` |

ELF 是 `0x8000_0000` 起的稠密镜像；脚本要求所有非零字节都落在上述两个窗口内，
否则直接报错，避免上板时静默丢数据。`build/pipeline/image.json` 记录 ELF/hex
哈希、非零字数和入口。

## 2. 在 PDS 主机上执行

建议先把最小树同步到 Windows 盘，避免 WSL 路径和工程输出污染仓库：

```bash
D=/mnt/d/ares_pipeline
rm -rf "$D" && mkdir -p "$D"
rsync -aR rtl/pipeline rtl/accel fpga/pango/pipeline \
    fpga/pango/program.tcl build/pipeline "$D"/
```

然后在 Windows 的 `D:\ares_pipeline` 下运行（等价地，也可以从 WSL 仓库根直接
调用同一个 `pds_shell.exe`；PDS 会把 `/home/...` 映射成
`//wsl.localhost/Ubuntu/home/...`）：

```bat
cd /d D:\ares_pipeline
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file fpga\pango\pipeline\flow_pipeline.tcl -project_name pipeline_soc
```

流程内部会 `cd` 到仓库根，因此 `irom_bmem32.sv` / `pipeline_bram.v` 里的
`$readmemh("build/pipeline/...)` 相对路径可以解析。输出位流在
`generate_bitstream\pipeline_board_top.sbit`。

流程顺序：

```text
set_arch (Logos2 / PG2L200H / FBB676 / -6)
add_constraint pipeline_board.fdc
add_design      rtl/pipeline/pipeline_pango.f 中的每个文件
compile -top_module {pipeline_board_top} -system_verilog
        -include_path {rtl/pipeline/include rtl/pipeline/core/vsrc/include}
synthesize -ads
dev_map
pnr -seed 2
report_timing -max_path 20
report_power
gen_bit_stream -create_bit true
```

## 3. 时钟、复位、引脚

| 信号 | 值 |
| --- | --- |
| 输入时钟 | `clk_27m` = 27 MHz，D18 |
| CPU 时钟 | 100 MHz（PLL `CLKOUT0`） |
| 外设/UART 时钟 | 50 MHz（PLL `CLKOUT1`） |
| 复位 | `rst_n` C22，低有效；PLL lock 后按域异步置位/同步释放 |
| UART | `uart_tx` C24，115200 8N1 |
| LED | `led[7:0]`：A20/C18/C19/E18/A17/A18/C17/B17 |

PLL 参数（`rtl/pipeline/board/pipeline_pll.v`）：

```text
VCO = 27 MHz * RATIOM(2) * RATIOF(18.5185) = 1000 MHz
CPU    = VCO / RATIO0(10.0) = 100 MHz
PERIPH = VCO / RATIO1(20.0) =  50 MHz
```

约束里的 `create_generated_clock ... u_clk_reset/u_pll/u_gpll/CLKOUT0/1`
必须与这个层次一致。

**UART TX 已经接到 C24（115200 8N1），并且已经用板级 TB 验证过**；
`pipeline_board_top` 和 `pipeline_amp_board_top` 的 hart0 `uart_tx` 都走这条
引脚。本板现有 profile 没有 UART RX 引脚，所以 `rx` 仍接 1；CoreMark 只依赖
TX，若后续需要接收，补 `uart_rx` 引脚并去掉 tie。

## 3.1 每 hart 私有 DRAM 的几何与历史对照

AMP 链接脚本给每个 hart 一个 **32 KiB** 窗口
（[ares-linker-mc.ld](../../../tests/abstract-machine/scripts/ares-linker-mc.ld)，
`DATA_OFFSET = hart * 0x8000`），镜像脚本再把这块数据区复制 8 份填满
256 KiB。也就是说每 hart 的 BRAM 只有 32 KiB 是"活"的。

2026-11-01 的 4-hart 200 MHz 报告里，每 hart 实例化的仍是 **64 个 DRAM36K
（256 KiB）**，4 个 hart 共 256 个，占 415 的 62%；全设计 DRM 329/415 = 80%。
BRAM 被撒满整片器件，最差路径的第一跳（BRAM → 桥）就有 **2.72 ns**。

现在几何是参数化的：

| 参数 | 位置 | 取值 |
| --- | --- | --- |
| `DRAM_AW` | `pipeline_amp_board_top` → ... → `bram_driver` → `pipeline_bram` | AMP 板级默认 **13**（8192×32-bit = 32 KiB）；单 hart profile 16 |
| `DRAM_INIT_FILE` | 同上 | AMP 默认 `build/pipeline/dram_amp.hex`；单 hart `dram.hex` |
| `CORES` | `pipeline_amp_board_top` | 默认 2；4 核构建把它改成 4（PDS 的 `compile` 没有参数覆盖入口，改默认值是唯一的单行开关） |

地址切片在 `soc/pango/pipeline_bram.v`：`mem[addrb[DRAM_AW-1:0]]`。
`addr[16:15]` 是 hart 编号，选的是**另一块物理 BRAM**，必须丢掉；窗口内
的 `addr[14:2]` 正好是 8192 个字的索引。

镜像侧 `pipeline-board-image` 现在出两份：

| 文件 | 尺寸 | 用途 |
| --- | --- | --- |
| `build/pipeline/dram.hex` | 65536 字 | 仿真 DPI 模型的 256 KiB 共享数组；单 hart profile |
| `build/pipeline/dram_amp.hex` | 8192 字 | AMP 板级每 hart 私有 BRAM 的初始化 |

两份内容的一致性由脚本保证（`dram_amp.hex` = 8 份复制的第 1 份）。

**A/B 对照**：把 `pipeline_amp_board_top` 的 `DRAM_AW` 改回 16、`DRAM_INIT_FILE`
改回 `"build/pipeline/dram.hex"`，其余不动，即可重复 2026-11-01 那份
（DRM 329、WNS −5.449）的几何。

**当时为 32 KiB 几何设定的验收目标（尚无对应 PnR 实测）**：

1. `DRM` 使用量：4-hart 应从 329 掉到 ~105（每 hart 8 个 DRAM 而不是 64）；
2. `WNS`：约束保持 200 MHz，预期从 −5.449 收到 −3.5 左右；
3. 最差路径的第一跳：不再出现 `..._1470/CLKB → CLMA_..._990` 这种跨 500 行
   的 2.7 ns 网线，BRAM→逻辑应降到 1 ns 以内。

> 功能验证的顺序：`make pipeline-amp-pango-lint` →
> `make pipeline-amp-board-sim`（板级 CoreMark，镜像就是上板镜像）→
> PDS 综合/布线 → 上板看 CoreMark 分数与 CRC。

## 4. 上板验收

软件里的 `COREMARK_CLOCK_HZ` 冻结为 100 MHz，所以 CPU 必须是 100 MHz；
若改 PLL，必须同步重建镜像。

用 `make pipeline-coremark-full` 在本地先确认全加速镜像：

```text
Total ticks     : 7471566
Iterations      : 100
CoreMark/MHz    : 13.384075
[0]crclist      : 0xe714
[0]crcmatrix    : 0x1fd7
[0]crcstate     : 0x8e3a
[0]crcfinal     : 0x988c
CoreMark PASS
```

上板检查同样的 CRC 与 `CoreMark PASS`，并将 `Total ticks` 与同镜像仿真对照。
运行频率与软件时钟常量应一致，烧写前检查对应 PDS 时序。烧写：

```bat
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file D:\ares_pipeline\fpga\pango\program.tcl ^
    -args {D:\ares_pipeline\generate_bitstream\pipeline_board_top.sbit}
```

UART 115200 8N1，TX C24。若 UART 无输出：

1. 确认 PLL lock（可把 `pll_lock` 临时接到一个 LED）；
2. 确认 `build/pipeline/*.hex` 与本次镜像哈希一致（`image.json`）；
3. 确认串口 115200 8N1、TX C24；
4. 确认流程运行目录是仓库根（否则 `$readmemh` 找不到文件）；
5. 核对 `image.json` 中 ELF / HEX 哈希，确认本次烧录的是目标镜像。

## 4.1 2-hart AMP full 加速 CoreMark

顶层是 `pipeline_amp_board_top`，内部实例化 `pipeline_amp_top`（`CORES=2`，
`DATA_STRIDE=0x8000`，每 hart 32 KiB I$）。两核各自跑一份 full 加速
CoreMark，**hart0 的 UART 已经接到板级 `uart_tx`（C24）**；hart1 的串口只
用于仿真。

板级仿真已经从 **27 MHz -> PLL -> 复位 -> `pipeline_amp_board_top` -> 物理
`uart_tx`** 完整跑通，不再是只看 simulation console 的 `$write`：

```bash
# 在仓库根目录运行
make pipeline-amp-board-sim
```

早期软件数组链表镜像的板级仿真输出（历史记录；hart0 独立报告，hart1 仅进仿真）：

```text
[amp-board] image: irom 5582/8192, dram 2952/65536 nonzero words
[amp-board] reset held for 200 us
Running CoreMark for 100 iterations
Iterations      : 100
CoreMark/MHz    : 7.940888
[0]crclist      : 0xe714
...
CoreMark PASS
[amp-board] CoreMark PASS seen: 431 chars, led=01
[amp-board] uart_done=1 led=01 time=168621774 ns PASS
```

**仿真的镜像就是上板的镜像**：仿真装载的 `build/pipeline/irom.hex` /
`dram.hex` 正是 PDS 里 `IROM_BMEM32` / `BRAM` 的 `$readmemh` 初始化的那两个
文件，`make pipeline-amp-board-sim` 依赖 `pipeline-amp-image` 重新生成，所以
不存在"仿真跑的是一个镜像、烧进板子的是另一个"的可能。`dram.hex` 里已经
包含每 hart 一份的 32 KiB 复制（`--replicate-dram-words 8192`），所以仿真侧
不再自己做复制；装载字数会打印在 `[amp-board] image:` 那一行，与
`build/pipeline/image.json` 的 `nonzero_words` 对应。

另有 `-DARES_SIM_REAL_UART`，让 `perip_bridge` 走真实 UART 握手；普通
`make pipeline-coremark-full-mt` 仍然走原来的 `$write` 路径。

```bash
# 生成 coremark_full_mc ELF，并把 32 KiB 数据区按 0x8000 复制到每个 hart
# 的私有 DRAM 窗口（0x0000/0x8000/0x10000/0x18000）。
# pipeline-amp-board-sim 会自己先跑这一步，手工执行只为在烧板前查镜像。
make pipeline-amp-image
make pipeline-amp-pango-lint

# 先跑 AMP 仿真，确认 2 核都 PASS
make pipeline-coremark-mc CORES=2
```

PDS（在已包含 `flow_pipeline_amp.tcl` 的外部 PDS 工程中执行）：

```bat
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe ^
    -file fpga\pango\pipeline\flow_pipeline_amp.tcl ^
    -project_name pipeline_amp
```

输出：

```text
generate_bitstream\pipeline_amp_board_top.sbit
```

注意：

- `pipeline-amp-image` 使用 `coremark-full-mc-image` 的 `--small-code` 和软件数组链表；
  它与当前启用链表引擎的 `pipeline-coremark-full-mt` 是不同镜像。
- `dram.hex` 必须是 **每个 hart 一份 32 KiB 复制**。`pipeline_image.py
  --replicate-dram-words 8192` 就是做这个；不要直接用单核 `pipeline-image`
  生成的 `dram.hex`，否则 hart1 的私有窗口是空的。
- 板级只引 hart0 UART，所以 `CoreMark/MHz` 是 hart0 自己的单核分数（约
  7.94）；两核聚合的 15.8 来自 MT 镜像（`build/coremark_full_mt2`）在
  `make pipeline-coremark-full-mt` / `pipeline-coremark-mt` 里的报告，不要拿
  两个数字直接比。hart1 的串口只用于仿真，要看它需要在 board top 里再加
  UART/引脚。
- 想上板看 MT 聚合报告，见 4.2。
- 板级仿真已经验证 TX 链路（C24、115200 8N1、`CoreMark PASS`）；RX 仍未接。

## 4.2 用 MT 聚合镜像上板（mt2）

默认镜像槽 `build/pipeline/` 放的是 AMP 镜像（每个 hart 一份独立报告）。
要让板上打印 `MULTITHREAD=2` 的聚合报告，把这个槽换成 MT 镜像即可，**PDS
流程不用改**——`pipeline_bram.v` / `irom_bmem32.sv` 读的就是这两个文件：

```bash
# 2 核聚合镜像，每 context 5000 iterations（共 10000）-> build/pipeline/
make pipeline-amp-image-mt CORES=2

# 烧板前确认槽里放的是哪份镜像
cat build/pipeline/image.json   # elf 指向 build/coremark_full_mt2/...
```

仿真侧用同一个 profile 名就能提前验证同一份布局（为了跑得快，仿真版用
`PIPELINE_MT_SIM_TOTAL`=200 iterations，纯软件差异，布局/复制策略完全一样）：

```bash
make pipeline-amp-board-sim PIPELINE_BOARD_PROFILE=mt
# 以下为早期软件数组链表镜像的历史仿真记录
# [amp-board] image: irom 5984/8192, dram 3016/65536 nonzero words
# Iterations      : 200
# CoreMark/MHz    : 15.863735
# Parallel ares-mt-mbox : 2
# [amp-board] uart_done=1 led=01 time=180427434 ns PASS
```

两个 profile 的差别只在这三点：

| | amp（默认） | mt |
|---|---|---|
| 镜像 ELF | `build/coremark_full_mc`（ITERATIONS=100、MULTITHREAD=1） | `build/coremark_full_mt2`（MULTITHREAD=2） |
| hart0 串口输出 | 自己的独立报告 | 全部 context 的聚合报告，当前两核 SoC 仿真为 28.167228 CoreMark/MHz |
| IROM 占用 | 5582/8192 words | 5984/8192 words |

⚠️ `build/pipeline/` 是**唯一的板级镜像槽**：仿真也会重写它。跑完 `mt` 仿真
后、生成位流之前要重新执行 `make pipeline-amp-image-mt` 把 10000 iterations
的镜像写回槽里（回到 AMP 就执行 `make pipeline-amp-image`）。
`make pipeline-amp-board-sim PIPELINE_BOARD_PROFILE=mt` 用的是 200 iterations
的镜像，**只用于仿真**。

`pipeline_amp_board_top` 的 CORES 是参数，默认 2。当前
`make pipeline-amp-image-mt CORES=4` 仍被 Make 的板级入口拒绝；四核上板需
同步顶层参数、镜像入口和 PDS 约束，并重新进行时序验收。四核 SoC 仿真已支持。

## 4.3 镜像一致性与可复现校验

`pipeline-board-image` 生成 `irom.hex`、`dram.hex` 和 `dram_amp.hex`：

| 消费方 | 使用的镜像 |
| --- | --- |
| 板级仿真 | `irom.hex` / `dram.hex`，装入 DPI 模型 |
| AMP PDS | 私有 IROM 使用 `irom.hex`，每 hart 32 KiB BRAM 使用 `dram_amp.hex` |
| 单核 PDS | `irom.hex` / `dram.hex` |
| 构建清单 | `image.json` 保存 ELF 与各 HEX 的哈希、地址和复制参数 |

构建是确定性的：同一 ELF 重复构建，ELF 与两个 hex 的 SHA-256 都不变
（ELF 里没有 debug 段，只有 `.comment`，所以 hex 不受构建路径影响）。

```bash
make pipeline-amp-image        # 或 make pipeline-amp-image-mt CORES=2
sha256sum build/pipeline/irom.hex build/pipeline/dram.hex
python3 -c "import json; d=json.load(open('build/pipeline/image.json')); \
print(d['irom']['sha256'], d['dram']['sha256'])"
```

拆分规则的独立校验（拿 objcopy 的稠密镜像对照，不依赖拆分脚本自证）：

| 输出 | 期望内容 |
| --- | --- |
| IROM（32 KiB） | `coremark.bin[0x000000:0x008000]` |
| DRAM（256 KiB） | `coremark.bin[0x100000:]` 零填充到 32 KiB，再重复 8 份 |
| `0x008000..0x0fffff` | 全零（非零字节会被脚本拒绝） |

仿真和上板剩下的差别都是"仿真替代不了"的部分：`pipeline_pll_sim` 给的是
理想 PLL/时钟树，CDC/复位是行为级模型，IO 电气和真实时序不在仿真里；存储器容量、初始化内容和 2 拍读延迟两侧一致。

## 5. 首次 PDS 构建要重点确认

- `GTP_GPLL` 参数被 PDS 接受，100/50 MHz 生成时钟报告正确；
- `IROM_BMEM32` / `BRAM` 被推断为 DRM（BRAM），且 `$readmemh` 初始化生效；
- `-include_path` 能找到 `autoconf.vh` / `common_para.vh` / `inst_para.vh`；
- 资源是否容纳（LUT/FF/DRM/DSP），100 MHz setup/hold 是否闭合；
- 首次生成 bitstream 后先跑短镜像或 LED/串口冒烟，再跑完整 CoreMark。

> 2026-10-31 已在本机 PDS 2022.2-SP6.4 跑通
> `compile -system_verilog` + `synthesize -ads`（16m13s，含 I-cache）：
> 49,361 LUT（30.89%）、24,767 FF（7.75%）、79.5 DRM（19.16%）、8 APM。
> `USE_ICACHE=1`，`pipeline_icache` 已 elaborate。此处是单核综合历史记录。
> 后续 2026-11-01 四核 PnR 报告在 70 MHz 下全部约束满足，在 200 MHz 下
> setup WNS -5.449 ns、recovery WNS -0.573 ns；两组均为 256 KiB/hart DRAM，
> 不能代替当前 32 KiB/hart 配置的 PnR 验收。
