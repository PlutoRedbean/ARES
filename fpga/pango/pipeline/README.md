# fpga/pango/pipeline — 单发射流水线 SoC 的 PDS 流程

> 目标器件：Pangu 200Pro+ / **PG2L200H-6IFBB676**，PDS 2022.2-SP6.4 或
> PDS 2025.2-SP3-EN，综合用 `synthesize -ads`。本目录服务
> `pipeline_board_top`（单核）和 `pipeline_amp_board_top`（2-hart AMP/MT），
> 不影响 `../flow_video_fb.tcl`、`../flow_bist.tcl` 等既有视频/DDR3 流程。
>
> PDS 2022.2 的 `compile` 用 `-system_verilog`；PDS 2025.2 用
> `-verilog_standard SystemVerilog`。仓库里的 flow 是 2022.2 写法；
> 2025.2 工程可参考 `D:\code\ares_amp_pds2025\synth_pds2025.tcl`。

## 1. 这套流程需要什么

在 Linux/构建主机上先准备两块本地存储的初始化文件。**全加速 CoreMark**
镜像必须带 `--small-code`，否则放不进 32 KiB IROM：

```bash
# 全加速：CRC8 + array list + matrix engine + state scanner
make PIPELINE_COREMARK_IMAGE_FLAGS=--small-code coremark-full-image

# 拆成 Pango 的两块本地存储器。flow_pipeline.tcl 固定读 build/pipeline/，
# 所以这里用默认输出目录，不要写到 build/pipeline_full/ 后忘记复制。
make pipeline-image \
    PIPELINE_IMAGE_ELF=$PWD/build/coremark_full/coremark-riscv32-ares.elf \
    PIPELINE_IMAGE_OUT=$PWD/build/pipeline
```

全加速镜像的参考占用是 `irom: 7984/8192` words、`dram: 356/65536` words，
只剩约 208 words 的 IROM 余量；改动软件后先看 `build/pipeline/image.json` 的
`nonzero_words`。基线镜像则用 `make pipeline-image` 的默认 ELF。

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

## 4. 上板验收

软件里的 `COREMARK_CLOCK_HZ` 冻结为 100 MHz，所以 CPU 必须是 100 MHz；
若改 PLL，必须同步重建镜像。

用 `make pipeline-coremark-full` 在本地先确认全加速镜像：

```text
Total ticks     : 12452732
Iterations      : 100
CoreMark/MHz    : 8.030366
[0]crclist      : 0xe714
[0]crcmatrix    : 0x1fd7
[0]crcstate     : 0x8e3a
[0]crcfinal     : 0x988c
CoreMark PASS
```

上板应看到同样的 CRC 和 `CoreMark PASS`，分数应接近 8.0 CoreMark/MHz
（最终值以 PnR 后的 100 MHz 时序为准）。烧写：

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
5. 确认 `image.json` 的 `irom.nonzero_words` 不是旧基线镜像（全加速应约 7984）。

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

实测输出：

```text
Iterations      : 200
CoreMark/MHz    : 16.150655
Parallel ares-mt-mbox : 2
[0]crclist      : 0xe714
[1]crclist      : 0xe714
...
CoreMark PASS
[amp-board] CoreMark PASS seen: 563 chars, led=01
[amp-board] uart_done=1 led=01 time=178183754 ns PASS
```

`pipeline-amp-board-sim` 默认用 2 核 MT 镜像
（`build/coremark_full_mt2/coremark.bin`），并加 `-DARES_SIM_REAL_UART`，
让 `perip_bridge` 走真实 UART 握手；普通
`make pipeline-coremark-full-mt` 仍然走原来的 `$write` 路径。

```bash
# 生成 coremark_full_mc ELF，并把 32 KiB 数据区按 0x8000 复制到每个 hart
# 的私有 DRAM 窗口（0x0000/0x8000/0x10000/0x18000）
make pipeline-amp-image
make pipeline-amp-pango-lint

# 先跑 AMP 仿真，确认 2 核都 PASS
make pipeline-coremark-mc CORES=2
```

PDS：

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

- `pipeline-amp-image` 使用 `coremark-full-mc-image` 的 `--small-code`；否则
  full 镜像会超出 32 KiB IROM。
- `dram.hex` 必须是 **每个 hart 一份 32 KiB 复制**。`pipeline_image.py
  --replicate-dram-words 8192` 就是做这个；不要直接用单核 `pipeline-image`
  生成的 `dram.hex`，否则 hart1 的私有窗口是空的。
- 板级只引 hart0 UART。用 AMP 镜像（`build/coremark_full_mc`）时，hart0 打印
  自己的独立报告；用 MT 镜像（`build/coremark_full_mt2`）时，hart0 打印两核
  聚合报告。hart1 的串口只用于仿真，要看它需要在 board top 里再加 UART/引脚。
- 板级仿真已经验证 TX 链路（C24、115200 8N1、`CoreMark PASS`）；RX 仍未接。

## 5. 首次 PDS 构建要重点确认

- `GTP_GPLL` 参数被 PDS 接受，100/50 MHz 生成时钟报告正确；
- `IROM_BMEM32` / `BRAM` 被推断为 DRM（BRAM），且 `$readmemh` 初始化生效；
- `-include_path` 能找到 `autoconf.vh` / `common_para.vh` / `inst_para.vh`；
- 资源是否容纳（LUT/FF/DRM/DSP），100 MHz setup/hold 是否闭合；
- 首次生成 bitstream 后先跑短镜像或 LED/串口冒烟，再跑完整 CoreMark。

> 2026-10-31 已在本机 PDS 2022.2-SP6.4 跑通
> `compile -system_verilog` + `synthesize -ads`（16m13s，含 I-cache）：
> 49,361 LUT（30.89%）、24,767 FF（7.75%）、79.5 DRM（19.16%）、8 APM。
> `USE_ICACHE=1`，`pipeline_icache` 已 elaborate；`dev_map` / `pnr` /
> `gen_bit_stream` 仍需在 PDS 主机上执行。
