# fpga/pango/pipeline — 单发射流水线 SoC 的 PDS 流程

> 目标器件：Pangu 200Pro+ / **PG2L200H-6IFBB676**，PDS 2022.2-SP6.4，
> 综合用 `synthesize -ads`。本目录只服务 `pipeline_board_top`，不影响
> `../flow_video_fb.tcl`、`../flow_bist.tcl` 等既有视频/DDR3 流程。

## 1. 这套流程需要什么

在 Linux/构建主机上先准备两块本地存储的初始化文件：

```bash
make coremark-image   # 若 build/coremark 还不存在
make pipeline-image    # -> build/pipeline/irom.hex, build/pipeline/dram.hex
```

拆分规则（由 `scripts/pipeline_image.py` 校验）：

| 存储 | 基址 | 容量 | 文件 |
| --- | --- | --- | --- |
| IROM | `0x8000_0000` | 32 KiB（8192 x 32-bit） | `build/pipeline/irom.hex` |
| DRAM | `0x8010_0000` | 256 KiB（65536 x 32-bit） | `build/pipeline/dram.hex` |

ELF 是 `0x8000_0000` 起的稠密镜像；脚本要求所有非零字节都落在上述两个窗口内，
否则直接报错，避免上板时静默丢数据。`build/pipeline/image.json` 记录 ELF/hex
哈希、非零字数和入口。

## 2. 在 PDS 主机上执行

把整个仓库（至少包含 `rtl/pipeline/`、`fpga/pango/pipeline/`、`build/pipeline/`）
放到 Windows 的 PDS 环境，从**仓库根目录**运行：

```bat
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file fpga/pango/pipeline/flow_pipeline.tcl -project_name pipeline_soc
```

流程内部会 `cd` 到仓库根，因此 `irom_bmem32.sv` / `pipeline_bram.v` 里的
`$readmemh("build/pipeline/...)` 相对路径可以解析。

流程顺序：

```text
set_arch (Logos2 / PG2L200H / FBB676 / -6)
add_constraint pipeline_board.fdc
add_design      rtl/pipeline/pipeline_pango.f 中的每个文件
compile -top_module {pipeline_board_top} -verilog_standard {SystemVerilog}
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

**UART RX 在本板现有 profile 中没有引脚约束**，board top 暂时把 `rx` 接 1。
CoreMark 只依赖 TX；若后续需要接收，补 `uart_rx` 引脚并去掉 tie。

## 4. 上板验收

软件里的 `COREMARK_CLOCK_HZ` 冻结为 100 MHz，所以 CPU 必须是 100 MHz；
若改 PLL，必须同步重建镜像。

与仿真对照的基准（`make pipeline-coremark`）：

```text
timed cycles     : 43,597,126
CoreMark/MHz     : 2.293729
CRCs             : e714 / 1fd7 / 8e3a / 988c
CoreMark PASS, a0=0
```

上板应看到同样的 CRCs 和分数。若 UART 无输出：

1. 确认 PLL lock（可把 `pll_lock` 临时接到一个 LED）；
2. 确认 `build/pipeline/*.hex` 与本次镜像哈希一致（`image.json`）；
3. 确认串口 115200 8N1、TX C24；
4. 确认流程运行目录是仓库根（否则 `$readmemh` 找不到文件）。

## 5. 首次 PDS 构建要重点确认

- `GTP_GPLL` 参数被 PDS 接受，100/50 MHz 生成时钟报告正确；
- `IROM_BMEM32` / `BRAM` 被推断为 DRM（BRAM），且 `$readmemh` 初始化生效；
- `-include_path` 能找到 `autoconf.vh` / `common_para.vh` / `inst_para.vh`；
- 资源是否容纳（LUT/FF/DRM/DSP），100 MHz setup/hold 是否闭合；
- 首次生成 bitstream 后先跑短镜像或 LED/串口冒烟，再跑完整 CoreMark。
