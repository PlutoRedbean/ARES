# 视频子系统 v1 设计（独立 `video_top`，盘古 200Pro+）

> 状态：v1.0 设计冻结，2026-10-26  
> 上位文档：`docs/video_channel_plan.md`（v0.1）  
> 目标：不接 SoC，独立 `video_top` 烧进 `PG2L200H-6IFBB676` 做板上验证  
> 本阶段交付：设计文档 + 冻结端口/参数 + 目录骨架 + TB 骨架。完整数据通路在下一阶段实现。

---

## 0. 对 plan 的事实修正

以下不是设计偏好，而是查证后与 plan 不一致的事实。v1 以本表为准。

| 项目 | plan v0.1 写法 | 事实 | 依据 |
| --- | --- | --- | --- |
| 器件型号 | `PG2L200H-6IFBG676` | **`PG2L200H-6IFBB676`**（200Pro+，676 球 FBB 封装） | `MES2L676-200HP-CORE-V1.2` 原理图、`5-stage-baseline/fpga/pango/board_pinmap.md` |
| `sys_clk` | 注释 50 MHz，FDC 37 ns | **27 MHz**，D18 | 核心板 U11；board_guide、100H FDC、PLL `CLKIN_FREQ=27.0` |
| 摄像头默认口 | CMOS1 | 厂商 demo 默认 **CMOS2**；v1 默认 **CMOS1**（可参数切换） | `hdmi_ddr_ov5640_top.v` `define CMOS_2` |
| 摄像头 PWDN | 建议 FPGA 驱动 | **PWDN 不在 FPGA 引脚表**，vendor 顶层悬空；v1 只控制 `RESET` | 100H FDC 无 `cmos*_pwdn` |
| 帧缓冲间距 | 2 MiB | vendor 链实际 **bit22 帧位**；在当前地址单位下是 **16 MB** 间距 | `wr_buf.v:303`、`rd_buf.v:137` |
| 需要重生成的 IP | PLL/DDR3/wr_fram_buf/rd_fram_buf | **只需 DDR3** 复用现成 200H IP；PLL 是 `GTP_GPLL` 薄封装；两个 DRAM IP 用推断 RAM 替掉 | 5-stage-baseline `DDR3_IP_NOTES.md`、`ipcore/pll/pll.v` |
| 工具链 | PDS | PDS 2022.2-SP6.4，**自带 Synplify 无 license，只能 `synthesize -ads`** | `5-stage-baseline/stdout.log`、`docs/board_guide.md` |
| 现有 `ares_video.sv` | — | 640×480 TMDS，**与本板 MS7210 并行 RGB 不兼容**，板级构建已 stub | `5-stage-baseline/rtl/soc/video/ares_video.sv` |
| DDR3 IP 状态 | 重新生成 | 200H IP 已生成，过 compile/synth/dev_map/pnr，但**未上板**，DFI↔PHY 约 **-4.1 ns** | `DDR3_IP_NOTES.md`、`board_guide.md §8` |
| 读侧行数 | 720 行 | vendor `rd_buf` 实际只发 **719 行**读请求 | `rd_buf.v:92` |
| `awsize/awburst` | 按 AXI4 | DDR3 IP **没有这些端口**；vendor 链里的 `3'b110` 是死逻辑 | `ddr3_test.v` 端口表 |

---

## 1. 范围

### 1.1 v1 做什么

```text
OV5640（单目，CMOS1/CMOS2 二选一，DVP 8-bit）
        │ pclk 84 MHz / vsync / href / data[7:0]
        ▼
8→16 bit 拼接（RGB565，42 MHz 像素时钟）
        ▼
DDR3 双缓冲帧缓存（1280×720×16bit × 2）
        ▼
720p30 时序（37.125 MHz）
        ▼
24-bit 并行 RGB + DE/HS/VS + PIXCLK
        ▼
MS7210 HDMI PHY
        ▼
HDMI 输出
```

分四个编译期阶段，同一套顶层端口：

| 阶段 | 宏 `VIDEO_STAGE_SEL` | 内容 | 板上验收 |
| --- | --- | --- | --- |
| S0 | `VIDEO_STAGE_PATTERN` | PLL + 720p30 时序 + MS7210 初始化 + 测试图案 | 彩条/棋盘/移动块稳定 720p30 |
| S1 | `VIDEO_STAGE_CAPTURE` | OV5640 I2C + DVP 采集，只做计数/观测，不接 HDMI | `cam_init_done=1`，vsync/行/像素计数递增 |
| S2 | `VIDEO_STAGE_FRAMEBUF` | 摄像头 → DDR3 双缓冲 → HDMI 实时预览 | 第一帧、帧计数、丢帧计数、10k 帧浸泡 |
| BIST | `VIDEO_STAGE_BIST` | 只测 DDR3：图案写/读、pin map、地址单位、时序余量 | 全片/局部写读通过，错误地址可观测 |

### 1.2 v1 不做什么

- 双目同时采集（只选一路）；
- 1080p、scaler、OSD/检测框叠加；
- CPU MMIO、`video_regs`、AXI4 master、NoC/QoS；
- 硬件 cache coherence；
- 直接 TMDS 输出（板上是 MS7210 并行 RGB）；
- UART 命令解析（只做单向状态输出）。

### 1.3 阶段 B 预留

`video_framebuf_wrap` 的 AXI 端口就是未来 `video_axi_master` 的原始接口；`cfg_* / status_*` 扁平总线就是未来 `video_regs` 的接口。v1 不实现 `video_subsys.v` / `video_regs.v` / `video_axi_master.v`。

---

## 2. 硬件事实与引脚

### 2.1 板卡

| 项目 | 值 |
| --- | --- |
| 开发板 | 盘古 200Pro+（MES2L676 核心板 + MES2L676-200HP-BASE-V1.2 底板） |
| FPGA | `PG2L200H-6IFBB676`，-6 速度等级 |
| 系统时钟 | 27 MHz，D18（核心板 U11） |
| 复位按键 | C22，低有效 |
| UART | TX=C24，RX=B24，115200 8N1 |
| LED | `led[7:0]` = B17 / C17 / A18 / A17 / E18 / C19 / C18 / A20 |
| DDR3 | 2×4 Gbit x16 拼 32-bit，共 1 GB；参考时钟 125 MHz 差分 N3/N2 |
| HDMI PHY | MS7210（TX），I2C 地址 `0xB2`，SCL=K22，SDA=K23，复位=G25 |
| 摄像头 | Double_OV5640 模组插 MES-FMC-LPC-IO 的 **J2**（40-pin，Bank L6，2.5 V） |
| 模组时钟 | 模组自带 24 MHz 有源晶振，XCLK 共享 |
| 摄像头 PWDN | **不在 FPGA 引脚表**，模组侧处理；v1 只控制 RESET |

> 200H FBB676 与 100H FBG676 的共有球位功能一致（`board_pinmap.md` 比对 300 个共有球，BANK/功能名差异为 0）；已用 PK04008 引脚手册核对 100H HDMI 例程用到的 138 个 ball，全部存在。100H 例程的 ball map 可直接用于 200H。

### 2.2 CMOS1 / CMOS2 引脚

| 信号 | CMOS1（J2） | CMOS2（J2） |
| --- | --- | --- |
| `pclk` | Y22 | U21 |
| `vsync` | Y23 | V23 |
| `href` | W18 | W23 |
| `scl` | W21 | W19 |
| `sda` | U14 | V16 |
| `reset` | T20 | Y20 |
| `data[7]` | V14 | T18 |
| `data[6]` | V18 | T17 |
| `data[5]` | Y21 | AA23 |
| `data[4]` | T15 | AB25 |
| `data[3]` | W25 | V19 |
| `data[2]` | Y26 | U25 |
| `data[1]` | U20 | U26 |
| `data[0]` | T14 | V21 |

> 当前板卡摄像头接 **J2**（MES-FMC-LPC-IO 40-pin），与官方
> `HDMI_DDR3_OV5640_100H` 例程一致。J2 在 **Bank L6**，官方文档要求
> `J20=ADJ`、`J24=2V5`，即 **2.5 V**。`video_top.fdc` 的 camera pins 使用
> `LVCMOS25` / VCCIO 2.5；上板前实测 Bank L6 电压，不要与 FDC 不一致。

### 2.3 HDMI 输出引脚

| 信号 | 引脚 |
| --- | --- |
| `pix_clk` | T24 |
| `de_out` / `hs_out` / `vs_out` | N19 / R20 / R21 |
| `r_out[7:0]` | P16, K25, K26, L24, L25, L22, L23, N21 |
| `g_out[7:0]` | N22, N23, N24, P23, P24, R25, P25, T25 |
| `b_out[7:0]` | T22, R22, N18, M21, M22, P20, P21, P19 |
| `iic_tx_scl` / `iic_tx_sda` | K22 / K23 |
| `rstn_out` | G25 |

全部 `LVCMOS33` / 3.3 V；`pix_clk`、`vs_out`、`rstn_out` 用 FAST，RGB/DE/HS 用 SLOW。  
`b_out` 的位序在部分厂商工程里整体取反；v1 以 100H `HDMI_DDR3_OV5640` FDC 为准，上板若颜色顺序不对，只改 FDC 位序，不改 RTL。

### 2.4 DDR3

- 引脚、IO 标准、PHY 摆放：**不复制到 `video_top.fdc`**，统一使用
  `fpga/pango/ip/ddr3/ddr3_ip.fdc`。
- IP 实例在顶层必须命名为 **`I_ips_ddr_top`**，否则 `ddr3_ip.fdc` 里的
  `define_attribute {i:I_ips_ddr_top...}` 绝对路径匹配不上。
- 参考时钟端口在顶层命名为 **`ref_clk_p` / `ref_clk_n`**，与 `ddr3_ip.fdc` 的
  `create_clock [get_ports {ref_clk_p}]` 对齐。

---

## 3. 架构

### 3.1 顶层框图

```text
                         clk_27m  rst_n
                              │
                    ┌─────────▼─────────┐
                    │  video_clk_reset  │  PLL: pix 37.125 / cfg 10 / cam 24.75
                    │  + per-domain rst │  phy_rstn = lock + 1 ms
                    └──┬────┬────┬────┬──┘
                       │    │    │    │
        ┌──────────────▼─┐  │    │  ┌─▼──────────────────┐
        │ video_capture  │  │    │  │ video_hdmi_wrap     │
        │  OV5640 I2C    │  │    │  │  sync_vg 720p30     │
        │  DVP 8→16      │  │    │  │  pattern_gen mux    │
        │  42 MHz stream │  │    │  │  RGB565→RGB888      │
        └──────┬─────────┘  │    │  │  MS7210 I2C init    │
               │ 16b/42MHz  │    │  └───┬────────┬────────┘
        ┌──────▼─────────┐  │    │      │        │ pix/rgb/de/hs/vs
        │ video_framebuf │◄─┼────┘      │        ▼
        │  wr_buf/rd_buf │  │           │     MS7210
        │  legacy chain  │  │           │
        └──┬──────────┬──┘  │           │
           │ AXI      │     │           │
           ▼          ▼     │           │
     ┌──────────┐  ┌──────────────┐    │
     │ BIST mux │  │ video_status │◄───┘  status_word
     └────┬─────┘  │ LED + UART   │
          ▼        └──────────────┘
   ┌──────────────┐
   │ ddr3_test    │  ← 200H IP，实例名 I_ips_ddr_top
   │ I_ips_ddr_top│
   └──────┬───────┘
          ▼
        DDR3 pins
```

### 3.2 时钟域

| 时钟 | 来源 | 频率 | 用途 |
| --- | --- | --- | --- |
| `clk_27m` | 板载 U11 / D18 | 27.0 MHz | 控制、状态、UART、PLL 参考 |
| `clk_pix` | PLL CLKOUT0 | 37.125 MHz | 720p30 时序、HDMI 输出 |
| `clk_cfg` | PLL CLKOUT1 | 9.995 MHz | MS7210 I2C（400 kHz） |
| `clk_cam` | PLL CLKOUT2 | 24.75 MHz | OV5640 SCCB（约 9.9 kHz） |
| `cmos_pclk` | OV5640 | 84 MHz | DVP 字节时钟 |
| `pixel_clk` | `cmos_pclk` ÷2 | 42 MHz | DVP 像素、framebuf 写侧 |
| `core_clk` | DDR3 IP | 125 MHz | framebuf 读侧/AXI、BIST |

### 3.3 复位域

- 顶层只有 `rst_n`（C22，低有效）。
- `video_clk_reset` 为每个域生成 **async assert / sync release** 的 active-high `rst_*`。
- legacy 边界取反成 active-low。
- `phy_rstn` 在 `clk_cfg` 域产生：PLL lock 后计 1 ms，驱动 MS7210/MS7200 的 `RSTN_OUT`。
- DDR3：`ddr3_test.resetn = phy_rstn`；`framebuf.ddr_rstn = ddr_init_done`。

### 3.4 模块清单

| 文件 | 模块 | 职责 | v1 状态 |
| --- | --- | --- | --- |
| `video_top.v` | `video_top` | 板级顶层、阶段选择、IP 实例、mux | 端口冻结 |
| `video_defs.vh` | — | 参数、阶段、状态位、地址 | 冻结 |
| `video_clk_reset.v` | `video_clk_reset` | PLL + 复位同步 + `phy_rstn` | 待实现 |
| `video_capture_wrap.v` | `video_capture_wrap` | `power_on_delay` + `reg_config` + `i2c_com` + `cmos_8_16bit` | 待实现 |
| `video_framebuf_wrap.v` | `video_framebuf_wrap` | `fram_buf` + 地址偏移 + 帧计数/丢帧 | 待实现 |
| `video_hdmi_wrap.v` | `video_hdmi_wrap` | `sync_vg` + 图案 mux + RGB 扩展 + MS7210 初始化 | 待实现 |
| `video_pattern_gen.v` | `video_pattern_gen` | 彩条/棋盘/移动块 | 待实现 |
| `video_status.v` | `video_status` | 8 LED + 115200 UART 状态 | 待实现 |
| `video_ddr3_bist.v` | `video_ddr3_bist` | DDR3 图案测试、地址单位探测 | 待实现 |
| `video_ip_pll.v` | `video_ip_pll` | `GTP_GPLL` 薄封装（27→37.125/10/24.75） | 复制/改名 |
| `video_dpram.v` | `wr_fram_buf` / `rd_fram_buf` | 推断双口 RAM，替代两个 DRM IP | 待实现 |
| `legacy/*.v` | 官方原样 | 采集/帧缓存/时序/PHY 配置 | 复制 |
| `test/tb_video_*.v` | — | TB | 骨架 |

**不参与 v1 的文件**：`video_subsys.v`、`video_regs.v`、`video_axi_master.v`、`video_async_fifo.v`（vendor framebuf 内部已有 CDC，v1 不再加一层）。

---

## 4. 冻结接口

### 4.1 `video_top` 端口

```verilog
module video_top #(
    parameter integer CAM_SEL        = 0,                 // 0=CMOS1, 1=CMOS2
    parameter [27:0]  FB_BASE0_BYTE  = 28'h0100_0000,     // 字节地址
    parameter [27:0]  FB_BASE1_BYTE  = 28'h0110_0000,     // 字节地址，= BASE0 + 16 MiB
    parameter integer FB_ADDR_SHIFT  = 2,                 // 字节 → legacy 地址单位；BIST 确认
    parameter integer BIST_BYTES     = 32'h0040_0000,     // 默认测前 4 MiB
    parameter [1:0]   PATTERN_MODE   = 2'd1               // 0=off 1=bar 2=checker 3=moving box
) (
    input  wire        clk_27m,
    input  wire        rst_n,

    // OV5640 CMOS1
    output wire        cmos1_reset,
    inout  wire        cmos1_scl,
    inout  wire        cmos1_sda,
    input  wire        cmos1_pclk,
    input  wire        cmos1_vsync,
    input  wire        cmos1_href,
    input  wire [7:0]  cmos1_data,

    // OV5640 CMOS2
    output wire        cmos2_reset,
    inout  wire        cmos2_scl,
    inout  wire        cmos2_sda,
    input  wire        cmos2_pclk,
    input  wire        cmos2_vsync,
    input  wire        cmos2_href,
    input  wire [7:0]  cmos2_data,

    // DDR3 reference clock / device pins
    input  wire        ref_clk_p,
    input  wire        ref_clk_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_cs_n,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm,

    // HDMI TX (MS7210)
    output wire        pix_clk,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out,
    output wire        rstn_out,
    output wire        iic_tx_scl,
    inout  wire        iic_tx_sda,

    // Board status
    output wire [7:0]  led,
    output wire        uart_tx
);
```

**冻结规则**：

- 端口名与 `ddr3_ip.fdc`、`video_top.fdc` 一致；DDR3 引脚只出现在 `ddr3_ip.fdc`。
- `ref_clk_p/n` 不叫 `clk_p/n`，避免改 IP 约束。
- 没有 `uart_rx`；v1 只做单向状态。
- 没有 `cam_pwdn`；PWDN 不在 FPGA 引脚表。
- `pix_clk` 是 PLL 输出直接出引脚；若 PDS 报专用路由问题，加
  `PAP_CLOCK_DEDICATED_ROUTE FALSE`，不改端口。

### 4.2 内部 `cfg_* / status_*` 总线

v1 没有 CPU，但顶层内部保留一条扁平总线，stage B 的 `video_regs` 直接接：

```text
cfg_enable         1   // 总开关
cfg_capture_en     1
cfg_hdmi_en        1
cfg_double_buffer  1   // v1 固定 1
cfg_pattern        2   // 0=off 1=bar 2=checker 3=moving box
cfg_stage          2   // S0/S1/S2/BIST
cfg_fb_base0      28
cfg_fb_base1      28
cfg_fb_stride     32   // 2560
cfg_fb_width      12   // 1280
cfg_fb_height     12   // 720
status_pll_lock
status_ddr_init_done
status_hdmi_init_done
status_cam_init_done
status_frame_wr_done
status_frame_drop
status_fifo_overflow
status_bist_done
status_bist_error
status_frame_wr_cnt[31:0]
status_frame_drop_cnt[31:0]
status_bist_error_cnt[31:0]
status_bist_error_addr[27:0]
```

### 4.3 关键模块契约

#### `video_clk_reset`

```verilog
module video_clk_reset (
    input  wire clk_27m,
    input  wire rst_n,
    output wire clk_pix,
    output wire clk_cfg,
    output wire clk_cam,
    output wire pll_lock,
    output wire rst_sys,
    output wire rst_pix,
    output wire rst_cfg,
    output wire rst_cam,
    output wire phy_rstn
);
```

- PLL：`video_ip_pll` 复制 vendor `pll.v` 的 `GTP_GPLL` 参数（27 MHz → 37.125/10/24.75）。
- `rst_*`：async assert、sync release；`rst_sys` 在 27 MHz 域。
- `phy_rstn`：`pll_lock` 后 10000 个 `clk_cfg` 周期（1 ms），active low。

#### `video_capture_wrap`

```verilog
module video_capture_wrap (
    input  wire        clk_27m,
    input  wire        clk_cam,         // 24.75 MHz SCCB
    input  wire        rst_sys,
    output wire        cam_reset,       // active low
    inout  wire        cam_scl,
    inout  wire        cam_sda,
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,
    output wire        pixel_clk,       // 42 MHz
    output wire        pixel_rst,       // active high
    output wire        pixel_vsync,
    output wire        pixel_de,
    output wire [15:0] pixel_rgb565,
    output wire        cam_init_done,
    output wire [31:0] dbg_vsync_cnt,
    output wire [31:0] dbg_line_cnt,
    output wire [31:0] dbg_pixel_cnt,
    output wire [31:0] dbg_pclk_cnt
);
```

- `power_on_delay` 用 `clk_27m`；`reg_config` 用 `clk_cam`（24.75 MHz）。
- `cmos_8_16bit.rst_n = cam_init_done`；`pixel_rst = ~cam_init_done` 同步到 `pixel_clk`。
- `pixel_vsync` 是 `cam_vsync` 在 `pixel_clk` 域的 2FF 同步；`pixel_de`/`pixel_rgb565` 来自 `cmos_8_16bit`。
- `dbg_*` 只在 S1 状态观测用；S2 可以保留。

#### `video_framebuf_wrap`

```verilog
module video_framebuf_wrap #(
    parameter [27:0] FB_BASE0_BYTE = 28'h0100_0000,
    parameter integer FB_ADDR_SHIFT = 2
) (
    input  wire        vin_clk,
    input  wire        vin_rst,
    input  wire        vin_vsync,
    input  wire        vin_de,
    input  wire [15:0] vin_rgb565,
    input  wire        ddr_clk,
    input  wire        ddr_rstn,        // = ddr_init_done
    input  wire        vout_clk,
    input  wire        vout_rst,
    input  wire        vout_vsync,
    input  wire        vout_de_re,      // sync_vg.de_re
    output wire        vout_de,
    output wire [15:0] vout_rgb565,
    output wire        init_done,
    output wire        frame_wr_done,   // 外部像素计数到 1280*720 的脉冲
    output wire [31:0] frame_wr_cnt,
    output wire [31:0] frame_drop_cnt,
    // native AXI to I_ips_ddr_top
    output wire [27:0] axi_awaddr,
    output wire [3:0]  axi_awid,
    output wire [3:0]  axi_awlen,
    output wire        axi_awvalid,
    input  wire        axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0] axi_wstrb,
    output wire        axi_wvalid,
    input  wire        axi_wready,
    input  wire [3:0]  axi_bid,
    output wire [27:0] axi_araddr,
    output wire [3:0]  axi_arid,
    output wire [3:0]  axi_arlen,
    output wire        axi_arvalid,
    input  wire        axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire        axi_rvalid,
    input  wire        axi_rlast,
    input  wire [3:0]  axi_rid
);
```

- 内部实例化 legacy `fram_buf`，`ADDR_OFFSET = FB_BASE0_BYTE >> FB_ADDR_SHIFT`。
- `axi_awsize/awburst/wlast/rready/bresp` **不引出**：IP 没有这些端口，vendor 链里的同名信号也不接。
- `frame_wr_done` 由 wrap 自己数 `vin_de` 到 1280×720 产生，不依赖 `frame_wirq`（vendor 未引出）。
- `init_done` = `fram_buf.init_done`，用于放行读侧。
- `frame_wr_cnt` 数 `vin_vsync`；`frame_drop_cnt` 在 `wr_cnt - rd_cnt > 1` 时递增（近似检测，严格仲裁留 stage B）。

#### `video_hdmi_wrap`

```verilog
module video_hdmi_wrap (
    input  wire        pix_clk,
    input  wire        pix_rst,
    input  wire        cfg_clk,
    input  wire        cfg_rst,
    input  wire        phy_rstn,        // active low
    input  wire [15:0] vout_rgb565,
    input  wire [1:0]  pattern_mode,
    output wire        rd_en,           // sync_vg.de_re
    output wire        rd_vsync,        // sync_vg.vs_out
    output wire [11:0] x_act,
    output wire [11:0] y_act,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out,
    output wire        hdmi_init_done,
    output wire        iic_scl,
    inout  wire        iic_sda
);
```

- `sync_vg` 参数固定 1280×720@30：`H_TOTAL=1650, H_SYNC=40, H_BP=220, H_ACT=1280, H_FP=110`；`V_TOTAL=750, V_SYNC=5, V_BP=20, V_ACT=720, V_FP=5`。
- `rd_en = de_re`（比 `de_out` 早 2 px、短 2 px），`rd_vsync = vs_out`。
- `vout_rgb565` 与 `pattern_gen` 输出二选一；S0 用图案，S2 用帧缓存。
- RGB565→RGB888：`R={rgb[15:11],3'b0}`、`G={rgb[10:5],2'b0}`、`B={rgb[4:0],3'b0}`；输出寄存器在 `pix_clk`。
- MS7210 初始化：直接实例化 `ms7210_ctl` + `iic_dri`（**不用** `ms72xx_ctl`，避免未连接的 MS7200 RX 死逻辑），`device_id=8'hB2`，`CLK_FRE=10_000_000`，`IIC_FREQ=400_000`。

#### `video_pattern_gen`

```verilog
module video_pattern_gen (
    input  wire        clk,
    input  wire        rst,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [1:0]  mode,       // 0=off 1=bar 2=checker 3=moving box
    input  wire [31:0] frame_cnt,
    output wire [15:0] rgb565
);
```

- 彩条：8 条 160 px 竖条；棋盘：64×64；移动块：160×120，每帧右移 4 px。
- 图案值用标准 RGB565；摄像头路径保留 vendor 的 `{d[4:0],d[10:5],d[15:11]}` 交换，若上板颜色反了只改采集 wrap，不改图案。

#### `video_status`

```verilog
module video_status (
    input  wire        clk_27m,
    input  wire        rst_sys,
    input  wire [31:0] status_word,
    input  wire [31:0] status_word2,
    input  wire [31:0] cap_vsync_cnt,
    input  wire [31:0] cap_line_cnt,
    input  wire [31:0] cap_pixel_cnt,
    output wire [7:0]  led,
    output wire        uart_tx
);
```

LED 固定映射：

| LED | 含义 |
| --- | --- |
| `led[0]` | 心跳（约 1.5 Hz） |
| `led[1]` | `pll_lock` |
| `led[2]` | `ddr_init_done`（S1 无 DDR3 IP，恒 0；BIST 诊断版含义不同） |
| `led[3]` | `hdmi_init_done` |
| `led[4]` | `cam_init_done` |
| `led[5]` | 正式 S1：帧活动（`cap_vsync_cnt[5]`）；诊断版：PCLK 活动（`cap_pclk_s2[23]`，约 5 Hz） |
| `led[6]` | `frame_drop` 锁存 |
| `led[7]` | `bist_error` 或 `fifo_overflow` 锁存 |

UART：115200 8N1，`UART_DIV=234`（27 MHz），每 500 ms 一行：

```text
S0: V1 S0 OK
S1: S1 V=0000001E L=000057E4 P=01A2B3C4
```

S1 的 V/L/P 是采集 vsync / 行 / 像素计数（`cmos1_pclk` 域快照后 2FF 同步到 27 MHz；`cmos1_pclk` 与 `sys_clk` 在异步组中）。
完整字段版（frame count/drop/bist）在 S2 扩展。

#### `video_ddr3_bist`

```verilog
module video_ddr3_bist (
    input  wire        clk,          // core_clk
    input  wire        rst,          // active high
    input  wire        start,
    output wire        done,
    output wire        error,
    output wire [31:0] error_cnt,
    output wire [27:0] error_addr,
    // native AXI master (same shape as video_framebuf_wrap)
    output wire [27:0] axi_awaddr,
    output wire [3:0]  axi_awid,
    output wire [3:0]  axi_awlen,
    output wire        axi_awvalid,
    input  wire        axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0] axi_wstrb,
    output wire        axi_wvalid,
    input  wire        axi_wready,
    input  wire [3:0]  axi_bid,
    output wire [27:0] axi_araddr,
    output wire [3:0]  axi_arid,
    output wire [3:0]  axi_arlen,
    output wire        axi_arvalid,
    input  wire        axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire        axi_rvalid,
    input  wire        axi_rlast,
    input  wire [3:0]  axi_rid
);
```

测试内容：

1. **地址单位探测**：向 `A` 写 `0x11111111`、向 `A+1` 写 `0x22222222`，读回判断是否别名 → 确认 IP 是 32-bit word 地址还是 byte 地址，写进 `FB_ADDR_SHIFT`。
2. **固定图案**：`0x00000000 / 0xFFFFFFFF / 0x55555555 / 0xAAAAAAAA`，按 16-beat burst。
3. **地址即数据**：每个 256-bit beat 的低 28 位 = 地址。
4. **walking-1**：32 步。
5. **LFSR 伪随机**：可选，长跑用。
6. 默认只测前 `BIST_BYTES`（4 MiB）；长跑时改参数测全 1 GiB。

#### `video_dpram`

用推断 RAM 替代两个 DRM IP，模块名保持 `wr_fram_buf` / `rd_fram_buf`，端口与 vendor 一致：

- `wr_fram_buf`：写 32-bit × 4096，读 256-bit × 512。
- `rd_fram_buf`：写 256-bit × 512，读 32-bit × 4096。
- 实现：8 个 512×32 简单双口 RAM bank；写地址低 3 位选 bank，高 9 位选 word；读侧拼接。
- **不要复位 RAM 数组**，否则推断不出 DRM；`wr_rst/rd_rst` 只复位输出寄存器。

---

## 5. 数据通路

### 5.1 采集

- `cmos_8_16bit` 用 `pclk` 采样两个字节，`pixel_clk = pclk/2`（`GTP_IOCLKDIV_E2`）。
- 输出 `pdata_o[15:11]=B`、`[10:5]=G`、`[4:0]=R`（BGR565：OV5640 0x4300=0x60 为 RGB565 sequence 0），`de_o` 比 `href` 晚 3 个 pclk，与数据对齐。
- `video_capture_wrap` 的 `RGB_SWAP=1`（默认）做 `{d[4:0],d[10:5],d[15:11]}` 归一化，与 vendor 顶层一致。
- `vsync` 上升沿作为新帧；`cam_init_done` 未完成前 `cmos_8_16bit` 保持在复位，不写帧缓存。
- 42 MHz 写侧与 37.125 MHz 读侧由 framebuf 内部异步 FIFO 隔离。

### 5.2 写帧缓存

- 一行 1280×2 B = 2560 B；256-bit AXI 每 beat 32 B → 80 beat/行 → 5×16-beat burst。
- 地址步进：一行 640 个 32-bit 单位；帧位 bit22。
- `frame_wr_done` 由 wrap 数 `vin_de` 到 1280×720 产生；`init_done` 用 `fram_buf.init_done`。

### 5.3 读帧缓存

- `sync_vg.de_re` 作为读使能，提前 2 px；`rd_buf` 内部行预取。
- `vout_data` 与 `vout_de` 对齐；HDMI 输出寄存器仍按 vendor 顶层用 `de_out` 采样 `vout_data`，不要自行改 pipeline。
- 已知 vendor `rd_buf` 只发 719 行读请求；v1 保留该行为，底部可能有一行黑边，属于已知现象，stage B 再修。

### 5.4 双缓冲

- vendor framebuf 内部两个 frame counter 固定错开一帧，读写地址通过 `{frame_bit, line_addr}` 选择 buffer。
- v1 接受 **16 MB 间距**（`FB0=0x0100_0000`，`FB1=0x0110_0000`，预留 32 MB）。
- 外层只做观测：`frame_wr_cnt`、`frame_drop_cnt`；不做 wr/rd 仲裁。
- 严格 `wr_idx != rd_idx`、丢帧策略留 stage B 自研控制器。

### 5.5 图案注入

- **输出侧**：`video_hdmi_wrap` 内的 mux，S0 用，完全绕过 DDR3。
- **写侧**：S2/BIST 用，`video_pattern_gen` 在 `pixel_clk` 域用简单 H/V 计数器产生 1280×720 有效像素，送 framebuf 写侧，验证 DDR3 写读；不要求 30 Hz 精确。
- 摄像头路径与图案路径不会同时使能。

### 5.6 RGB 顺序

- 摄像头：保留 vendor 的 `{d[4:0], d[10:5], d[15:11]}` 交换；上板若 R/B 反了，在 `video_capture_wrap` 里加 `RGB_SWAP` 参数。
- 图案：标准 RGB565。
- HDMI 输出：`{R[4:0],3'b0}` / `{G[5:0],2'b00}` / `{B[4:0],3'b000}`。

---

## 6. DDR3

### 6.1 复用策略

- 复用 `5-stage-baseline/fpga/pango/ip/ddr3/` 的 200H IP：
  - `.idf`：`PG2L200H / FBB676 / -6`，已重生成。
  - `ddr3_ip.fdc`：参考时钟、PHY 时钟、PHY 摆放、71 根 DDR3 引脚。
  - `ddr3_ports.csv`、`DDR3_IP_NOTES.md`。
- 顶层直接实例化 `ddr3_test I_ips_ddr_top`，**不要再包一层改实例名**，否则 FDC 绝对路径失效。
- IP 的 `axi_awuser_id/aruser_id` tie `4'd0`；framebuf/BIST 的 `axi_awid/arid` 不接；IP 的 `axi_wusero_id/last`、`axi_rid` 悬空。
- APB/调试口：`apb_clk=core_clk`，`apb_rst_n=ddr_rstn`，`apb_sel/apb_enable/apb_write=0`，`apb_addr/apb_wdata=0`；所有 `dbg_*` 输入 tie 0，输出悬空。
- `ref_clk_p/n` 经 `GTP_INBUFGDS` 得到 `ref_clk_125m`，送 `ddr3_test.ref_clk`。

### 6.2 已知风险

| 风险 | 现状 | 缓解 |
| --- | --- | --- |
| DDR3 未在 200H 上板验证 | 1000/800 20:56 init fail；22:55 `ddr_init_done=1` | 加 `bist_done` 指示；BIST 通过后进入 S2 |
| DFI↔PHY -4.1 ns | 20:35 旧 FDC 的 −3.5/−4.1 是丢了 vendor multicycle；20:56 起补回后全过 | 保留 `set_multicycle_path 2` |
| DDR3 ref_clk 引脚组 | IP 生成器 `pnr` 默认 M21/M22，200Pro+ 实际 N3/N2；错误会 `Place-0094` | `ddr3_ip.fdc` 覆盖为 N3/N2 |
| 2_9 group 3 DQ 位序 | group 3 write leveling 失败；核心板球位与 `2_9` 一致，DQS P/N 不能换 | 交换 `DQ24↔31/25↔30/26↔29/27↔28` 后 22:55 init 通过 |
| 两套 DQ/DQS/DM 映射 | `2_9_ddr3_test` vs `HDMI_DDR3_OV5640` | BIST 判定；错则用另一套 `PAD_*` 重新生成 |
| 地址单位 word/byte | 文档说法不一致 | BIST 地址别名测试确认 `FB_ADDR_SHIFT` |
| IP 无 `rready/bresp` | vendor 链按 `read_ready=1` 工作 | v1 保持单 outstanding、读侧不反压；stage B 加缓冲 |
| 读侧 719 行 | vendor 已知 | v1 接受，记录 |

### 6.3 帧缓冲地址

| 项 | 值 |
| --- | --- |
| `FB_BASE0` | `0x0100_0000`（字节） |
| `FB_BASE1` | `0x0110_0000`（字节，+16 MiB） |
| 预留 | `0x0100_0000 – 0x013F_FFFF`（32 MiB） |
| legacy 地址单位 | `FB_BASE0 >> FB_ADDR_SHIFT`；`FB_ADDR_SHIFT` 默认 2，BIST 确认 |
| 行 stride | 640 个 32-bit 单位 = 2560 B |

SoC 阶段的 `0x8100_0000/0x8120_0000` 映射留到 stage B；v1 只要求 DDR3 物理地址可达，不与 SoC 地址绑定。

---

## 7. 时钟、复位、CDC、约束

### 7.1 PLL

复制 vendor `ipcore/pll/pll.v` 的 `GTP_GPLL` 参数：

```text
CLKIN_FREQ   = 27.0
STATIC_RATIOI= 1, RATIOM=2, RATIOF=19.25
RATIO0=28  → 37.125 MHz
RATIO1=104 → 9.995 MHz
RATIO2=42  → 24.75 MHz
```

`video_ip_pll` 只是改名 + 端口不变；PDS 综合时用真实 `GTP_GPLL`，Verilator 用 `video_ip_pll_sim.v` 行为模型。

### 7.2 复位

- 每个域 `async assert / sync release`；不要一个异步复位扇出所有域。
- `rst_sys` 用于 27 MHz 控制/状态；`rst_pix`/`rst_cfg`/`rst_cam` 分别用各自 PLL 输出。
- `pixel_rst` 用 `cam_init_done` 同步到 `pixel_clk`。
- `ddr_rstn = ddr_init_done`（framebuf），`ddr3_test.resetn = phy_rstn`。

### 7.3 CDC

| 边界 | 机制 |
| --- | --- |
| `pixel_clk` → `core_clk` | `wr_buf` 内部异步 FIFO/脉冲同步 |
| `core_clk` → `pix_clk` | `rd_buf` 内部异步 FIFO/脉冲同步 |
| `cmos_pclk` → `pixel_clk` | `cmos_8_16bit` 内 ÷2 + 寄存器 |
| `clk_cfg`/`clk_cam` → I2C | 慢速静态，`set_false_path` |
| 各域 → `clk_27m` 状态 | 慢变标志 2FF；计数器用 gray 或握手快照 |

### 7.4 约束计划（`video_top.fdc`）

```text
create_clock -name sys_clk    -period 37.037 [get_ports {clk_27m}]
create_clock -name cmos1_pclk -period 11.905 [get_ports {cmos1_pclk}]   // 84 MHz
create_clock -name cmos2_pclk -period 11.905 [get_ports {cmos2_pclk}]
create_generated_clock -name pix_clk -source [get_ports {clk_27m}] \
    -multiply_by 11 -divide_by 8 [get_pins {u_clk_reset/u_pll/u_gpll/CLKOUT0}]
create_generated_clock -name cfg_clk ... -multiply_by 10 -divide_by 27 ... CLKOUT1
create_generated_clock -name cam_clk ... -multiply_by 11 -divide_by 12 ... CLKOUT2

set_clock_groups -asynchronous \
    -group {sys_clk} -group {pix_clk} -group {cfg_clk} \
    -group {cam_clk} -group {cmos1_pclk} -group {cmos2_pclk}

set_input_delay  -clock cmos1_pclk 2.0 [get_ports {cmos1_data[*] cmos1_href cmos1_vsync}]
set_input_delay  -clock cmos2_pclk 2.0 [get_ports {cmos2_data[*] cmos2_href cmos2_vsync}]
set_output_delay -clock pix_clk    2.0 [get_ports {r_out[*] g_out[*] b_out[*] de_out hs_out vs_out}]
set_false_path -from [get_ports {rst_n}]
set_false_path -from [get_ports {cmos1_scl cmos1_sda}]
set_false_path -from [get_ports {cmos2_scl cmos2_sda}]
set_false_path -from [get_ports {iic_tx_scl iic_tx_sda}]
```

DDR3 的 `ref_clk`、PHY 生成时钟、异步组全部由 `ddr3_ip.fdc` 提供，不重复。

---

## 8. 上板观测

### 8.1 LED

见 §4.3 `video_status` 表。8 个 LED 全部用上，不额外占引脚。

### 8.2 UART

- 115200 8N1，只发不收。
- 每 500 ms 一行，字段固定，方便 `python`/串口助手 grep。
- S0：`pll/ddr/hdmi` 三个 init 位 + `st=0`。
- S1：加 `cam` + vsync/行/像素计数（可放在第二行）。
- S2：加 `frm/drop`。
- BIST：`bist=1 err=N addr=0x...`。

### 8.3 状态字

`status_word[31:0]` 与 `status_word2[31:0]` 的位定义在 `video_defs.vh` 冻结；UART 只打印，不做命令解析。

---

## 9. PDS 工程

### 9.1 目录

```text
ARES/
├── rtl/video/                 // 新写纯 Verilog-2001
│   ├── video_defs.vh
│   ├── video_top.v
│   ├── video_clk_reset.v
│   ├── video_capture_wrap.v
│   ├── video_framebuf_wrap.v
│   ├── video_hdmi_wrap.v
│   ├── video_pattern_gen.v
│   ├── video_status.v
│   ├── video_ddr3_bist.v
│   ├── video_ip_pll.v
│   ├── video_dpram.v
│   ├── legacy/                // 官方原样 + 来源注释
│   ├── sim/                   // PLL/DDR3/IOCLKDIV 行为模型
│   └── test/                  // tb_video_*.v
└── fpga/pango/
    ├── README.md
    ├── video_top.fdc
    ├── flow_video.tcl
    └── ip/ddr3/               // 从 5-stage-baseline 复制
```

### 9.2 复制 DDR3 IP

```bash
mkdir -p fpga/pango/ip
cp -r /mnt/c/Users/BlossilveR/code/5-stage-baseline/fpga/pango/ip/ddr3 \
      fpga/pango/ip/
```

保留 `ddr3_test.idf`、`ddr3_test.v`、`ddr3_test_ddrphy_top.v`、`rtl/*.vp`、
`ddr3_ip.fdc`、`ddr3_ports.csv`、`DDR3_IP_NOTES.md`。不要改 `.idf` 的器件头。

### 9.3 流程

`flow_video.tcl`（草案）：

```tcl
set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_constraint video_top.fdc
add_constraint ip/ddr3/ddr3_ip.fdc
# add_design 所有 rtl/video/*.v + legacy/*.v + ip/ddr3/ddr3_test.v + rtl/*.vp
compile -top_module video_top
synthesize -ads
dev_map
pnr
report_timing -max_path 20
gen_bit_stream -create_bit true
```

- **不要用 Synplify**（无 license），只能 `synthesize -ads`。
- ADS 对 SV 支持有限；视频新增代码全部 Verilog-2001，不引入 `interface/package/typedef`。
- 若 ADS 对 RGB/图案常量 mux 误报多驱动，按 5-stage 经验把颜色合成一个 `reg [23:0]` 临时量，不要拆成三个 8-bit 常量 mux。

### 9.4 上板前检查

- [ ] Bank L6/L7 VCCIO 与 FDC 一致（3.3 V vs 2.5 V 冲突，实测）。
- [ ] FMC 子卡插底板 FMC 座，Double_OV5640 插 **J2** 40-pin（J20=ADJ、J24=2V5）。
- [ ] HDMI 显示器接 HDMI-OUT，MS7210 的 27 MHz 晶振在底板上。
- [ ] `ref_clk_p/n` N3/N2 125 MHz。
- [ ] `rst_n` C22 按下复位。
- [ ] DDR3 两套 pin map 先用 BIST 判定。
- [ ] PDS 器件 `PG2L200H / FBB676 / -6`，不是 `FBG676`。

### 9.5 烧写

复用 5-stage-baseline 的 `program.tcl`：

```powershell
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl `
  -args {<path>\video_top.sbit}
```

---

## 10. 验证

### 10.1 仿真

全部自时钟 TB，`verilator --binary --timing`；厂商加密 IP 不进 Verilator，用 `rtl/video/sim/` 行为模型替换。

| TB | 内容 | 通过标准 |
| --- | --- | --- |
| `tb_video_capture` | DVP 8-bit 流、字节序、vsync/href、8→16 | 像素顺序/RGB565 正确，DE/VS 对齐 |
| `tb_video_hdmi` | `sync_vg` 720p30 | H_ACT=1280、V_ACT=720、DE/HS/VS 位置正确 |
| `tb_video_framebuf` | AXI BFM，写一帧读一帧 | 逐像素一致；写反压不丢；读侧不 underflow |
| `tb_video_ddr3_bist` | 地址单位、固定图案、地址即数据 | 错误计数 0；别名测试给出 `FB_ADDR_SHIFT` |
| `tb_video_pattern` | 彩条/棋盘/移动块 | 颜色/边界/移动步进正确 |
| `tb_video_top` | 三时钟 + 行为 IP，S0/S2 各 ≥3 帧 | 无 X、无死锁、帧计数递增、丢帧 0 |
| `tb_video_status` | UART 位宽/波特率/LED 映射 | 115200 波形正确，字段可解析 |

### 10.2 Lint

- 新增 `rtl/video/*.v` 过 `verilator --lint-only -Wall`，零 warning。
- legacy 原样文件不参与零 warning gate；在 `rtl/video/README.md` 列出 waiver 或单独 lint 目标。
- `rtl/video/sim/*` 只用于仿真，不参与综合 lint。

### 10.3 板上验收

| 阶段 | 验收 |
| --- | --- |
| S0 | 彩条/棋盘稳定 720p30，PLL lock，UART 显示 `pll=1 hdmi=1`，10 分钟无闪屏 |
| BIST | 4 MiB 固定图案/地址即数据通过；全 1 GiB 长跑可选；错误地址可读 |
| S1 | `cam_init_done=1`，vsync/行/像素计数递增，UART 可读 |
| S2 | 摄像头实时预览，帧计数递增，drop=0 持续 10k 帧 |

---

## 11. 里程碑

| 里程碑 | 内容 | 预计 | 退出条件 |
| --- | --- | --- | --- |
| V1-M0 | PDS 工程 + PLL + 720p30 + MS7210 + 彩条 | 2–3 人日 | 板上 HDMI 稳定彩条 |
| V1-M1 | DDR3 BIST（pin map/地址单位/时序） | 2–4 人日 | BIST 通过或明确降速/换 pin map |
| V1-M2 | 摄像头 I2C + DVP 采集（S1） | 2–3 人日 | 计数递增，图像数据可观测 |
| V1-M3 | framebuf 写读 + 单缓冲图案（S2a） | 2–3 人日 | DDR3 图案上屏 |
| V1-M4 | 摄像头 → DDR3 → HDMI 双缓冲（S2b） | 2–3 人日 | 实时预览，drop 计数可观测 |
| V1-M5 | 10k 帧浸泡 + 文档 | 1–2 人日 | 无累积错误 |

> 估算前提：有 Verilog 基础、PDS 流程已跑通；不熟 PDS 乘 1.5–2。

### 11.1 S0 实现与构建记录（2026-10-26）

- **已实现**：`video_clk_reset`、`video_ip_pll`（真实 `GTP_GPLL` + 仿真模型）、`video_hdmi_wrap`、`video_pattern_gen`、`video_status`，以及 legacy `sync_vg` / `ms7210_ctl` / `iic_dri`。
- **仿真**：`tb_video_top` 通过；每帧 DE 像素 **921600**（1280×720），`-DVIDEO_SIM` 用行为 PLL 并跳过 MS7210 I2C 从机模型。
- **PDS**：`flow_video_s0.tcl` 全流程通过，**All Constraints Met**：
  - `sys_clk` 27 MHz：WNS 32.093 ns，估计 Fmax 202.3 MHz
  - `pix_clk` 37.125 MHz：WNS 16.342 ns，估计 Fmax 94.4 MHz
  - `cfg_clk` 10 MHz：WNS 95.940 ns，估计 Fmax 246.4 MHz
  - 资源：LUT 311 / FF 270 / DRM 0.5 / APM 0（1%）
- **位流**：`video_top.sbit`，9,188,552 B，header `Logos2-PG2L200H--6-FBB676 / video_top`；尚未烧录（板子未连接）。
- **约束取舍**：
  - S0 不实例化 DDR3 IP；`ddr3_pins_s0.fdc` 用单端 `HSTL15_I` 锁住 DDR3 ball。PDS 200H 在这些 bank 上拒绝 IP 的 `HSTL15D_I/SSTL15D_I` 差分标准，S2 必须重新处理。
  - 摄像头输入在 S0 是 dangling，PDS 报 `Flow-4065` 并忽略其 pin 约束；S1 接上采集后消失。
- 详细构建/烧录步骤见 `fpga/pango/README.md` §8。

### 11.2 S1 实现与构建记录（2026-10-26）

- **已实现**：`video_capture_wrap`（`power_on_delay` + `reg_config` + `i2c_com` + `cmos_8_16bit`），legacy 摄像头文件已复制；`video_status` 扩展为 `S1 V=… L=… P=…` 状态行；`video_top` 增加 `CAM_SEL` 选择与 J3 引脚映射。
- **相机位置**：Double_OV5640 插 **J2** 40-pin（与官方 `HDMI_DDR3_OV5640_100H` 例程一致），Bank L6，官方要求 2.5 V（J20=ADJ、J24=2V5）。`CAM_SEL=0` 默认模组 CMOS1 FPC。中间调试曾用 J3；最终以 J2 为准。
- **仿真**：
  - `tb_video_capture` 通过：vsync=1、line=2、pixel=2560、首像素 `0x1234`。
  - `tb_video_top`（`-DVIDEO_SIM`）通过：HDMI 仍 921600 DE/帧，`led[4]`（cam init）为 1。
- **PDS**：`flow_video_capture.tcl` 全流程通过，**All Constraints Met**：
  - `cmos1_pclk` 84 MHz：WNS 8.480 ns，估计 Fmax 292.0 MHz
  - `sys_clk` 27 MHz：WNS 30.832 ns，估计 Fmax 161.2 MHz
  - `pix_clk` 37.125 MHz：WNS 16.460 ns，估计 Fmax 95.5 MHz
  - `cfg_clk` 10 MHz：WNS 95.850 ns；`cam_clk` 24.75 MHz：WNS 37.744 ns
  - 资源：LUT 608 / FF 760 / DRM 1 / USCM 5（1%）
  - **CDC 修正**：S1 计数移到 `cmos1_pclk` 域，`pixel_clk` 只给 S2 framebuf；此前 pixel→sys 的 **-0.471 ns / 19 端点** setup 违例已消除。
  - 网表含 `u_capture` / `u_reg_config` / `u_power`，SCCB 配置和复位序列都在。
- **位流**：`video_top.sbit`，9,188,552 B，header `Logos2-PG2L200H--6-FBB676 / video_top`；尚未烧录（板子未连接）。18:44 版本同时修复 S0 `video_status` 的 UART bug（原来每个字节之间等 0.5 s，现在整行连续发完后才等 0.5 s），并把 S1 计数移到 `cmos1_pclk` 域。
- **约束取舍**：
  - S1 只做计数，`pixel_rgb565` 未使用，PDS 裁剪数据通路，`cmos1_data[*]`/`cmos2_*` 报 `Flow-4065` 并忽略 pin 约束；这是预期，S2 接 framebuf 后数据脚会参与布局。
  - J3/L7 的 VCCIO 上板前实测；`video_top.fdc` 当前按 `LVCMOS33`/3.3 V。
- **诊断版（19:10 / 19:12）**：为区分“无 PCLK”和“有 PCLK 无 vsync”，LED5 临时改为 `cam_pclk` 活动指示（`cap_pclk_s2[23]`，约 5 Hz）；UART 仍为 `S1 V=… L=… P=…`。CMOS1/CMOS2 两版位流见 `fpga/pango/README.md` §9。
- 详细构建/烧录步骤见 `fpga/pango/README.md` §9。

### 11.3 DDR3 BIST 构建记录（2026-10-27）

- 已实现 `video_bist_top` + `video_ddr3_bist`，顶层直接例化 `ddr3_test I_ips_ddr_top`，`GTP_INBUFGDS` 接 125 MHz，PLL 产生 `phy_rstn`。
- `flow_bist.tcl` 跑通 compile / synth / dev_map / pnr / bitstream；资源 LUT 4099 / FF 4005 / DistRAM 34 / USCM 4。
- 时序：`sys_clk` 33.370 ns、`rst_clk` 4.558 ns 通过；`ddrphy_sysclk` **-0.652 ns**（2 端点），`ddrphy_sysclk → phy_dq_sysclk_0/1` **-3.527 / -4.051 ns**（184/420 端点）。这是设计文档 §6.2 已知的 200H DFI/PHY 风险。
- 1000 Mbps 上板结果：`led[1..3]` 亮、`led[4]` 灭、`led[5]` 亮 → `ddr_init_done=0`、`dbg_ddrphy_init_fail=1`，**PHY 初始化失败**；BIST 未启动，`led[7]` 不亮。BIST 顶层没有 HDMI 通路，没有彩条是预期；彩条看 J2 S1 位流。
- 位流：`video_bist_top.sbit`，9,188,552 B，header `Logos2-PG2L200H--6-FBB676 / video_bist_top`；19:45 诊断版已上板（结果见上）。
- 19:45 诊断版：APB 按厂商顶层改成 `apb_clk=0 / apb_rst_n=1`；LED 映射改为 `led[2]`=DDR3 IP PLL、`led[3]`=CPD lock、`led[4]`=ddr_init_done、`led[5]`=init_fail、`led[6]`=align_error、`led[7]`=BIST error。UART 仍为 S1 行，不做 BIST 解析。
- **800 Mbps 回退（20:35）**：`ip_generate.exe -ads` 以 `DFI_CLK_PERIOD=10000`（100 MHz）、`DDR3_CL=6`、`DDR3_CWL=5` 重生成 IP。生成器的 `pnr/ddr_test.fdc` 把 `ref_clk_p/n` 放在 **M21/M22**，200Pro+ 底板实际是 **N3/N2**；首次 PnR 因此报 `Place-0094 MREGION_CLOCK`（`u_clkbufm/clkbufm_inst` vs `i_dqs_bank[0].u_clkbufr/goprclk`）。把 `ddr3_ip.fdc` 覆盖为 N3/N2 后 **PnR + 位流通过**。
- 800 时序：`ddrphy_sysclk` **+0.193 ns**（比 1000 好），`ddrphy_sysclk → phy_dq_sysclk_0/1` 仍为 **-3.564 / -4.113 ns**（184/420），`Not All Constraints Met`。位流：`C:\Users\BlossilveR\code\ares-video-bist-800\fpga\pango\generate_bitstream\video_bist_top.sbit`。
- 结论：`Place-0094` 的根因是 `ref_clk` 引脚组选错；DFI↔PHY 的 −4 ns 是 IP-only FDC 丢了 vendor `set_multicycle_path 2`，补回后 800 静态时序全过（`ddrphy_sysclk` +0.579、`ddrphy_sysclk → phy_dq_sysclk_0/1` +2.049/+1.587，0 failing）。
- **20:56 上板结果**：`led[4]=0`、`led[5]=1`、`led[7]=0`。静态时序干净，PHY 初始化/校准仍失败，说明问题已转到 200H PHY 初始化/引脚映射，而不是时序。
- 下一步：1000/800 的 DDR3 引脚表是 **100H 例程的 `2_9` 表**（100H 上验证过）；200H 参考是 notes §7.3 的 `200h_ddr3_676_x72.fdc`，且对应的 **200H PHY placement set** 仍缺。`board_pinmap` 第二列 `F4...` 是 notes §1.2 那个 DQ/DQS 球位重复（`G9/H6/B5/C1`）的错误 `.idf` `PAD_*`，不能当 200H 参考。需要用 `200h_ddr3_676_x72.fdc`/Pango 200H PHY 摆放集重生成 IP，再跑 BIST；不能把 100H 的 `2_9` 当作 200Pro+ 已验证引脚表。
- `HMIC_S_P_User_guide.pdf`（UG042003 V1.14）补充：§2.8.4 明确 IP `.fdc` 的内部模块 location **不能改**，只能改 routing；1000/800 的 `ddr3_ip.fdc` 缺完整 PHY placement，和 init fail 一致。§2.9.2/§2.5.5 给出失败阶段：`debug_calib_ctrl[33:30]` = `dbg_error_status`（1 write leveling、2 read pattern、3 gate、4 read、5 write、6 eye），`dbg_slice_status` 给出每组的 `wrlvl_error_tmp`/`rdel_calib_error`/`gate_cal_error`/`rddata_check_pass_tmp`；当前 BIST 未接这些，下一步应接到 UART/LED。§2.8.6 SCBV 只适用 PG2L100H/PG2T390H，200H 忽略；APB 只用于低功耗/MRS/状态，不是 init 必需；IO 要求 VREF INT、`DDR_TERM_MODE`/`CP_DYN_TERM` ON，200H FBB676 默认 PLL/CA bank L5、数据 L6/G1，200Pro+ 实际 R4/R5。
- PDS 的 200H 参考 FDC 已定位：`ip/system_ip/ips2l_hmic_s/ips2l_hmic_eval/ips2l_hmic_s/pnr/200h_ddr3_676_x72.fdc` 与 `200h_ddr3_484_x32.fdc`。但 `676_x72` 是右手组（`Y22...`、`DDRPHY_CPD_9_466`、8 DQS group），`484_x32` 是 FBB484（`C2...`、`CPD_369_466`）；200Pro+ `2_9` 是左下组（`G5...`、`CPD_729_772`、4 DQS group）。参考 placement 不能直接套，仍需 Pango 针对 `2_9`/FBB676 x32 的 200H PHY placement set。
- **200H 调试与 DQ3 修复（21:22–22:55）**：
  - 21:22 接 `debug_calib_ctrl[33:30]`：`led[0]+led[5]` → `dbg_error_status=1`，write leveling 失败。
  - 21:49 接每组 `wrlvl_error_tmp`：`led[3]+led[5]` → 只有 DQS group 3 失败。
  - 核对 `MES2L676-200HP-CORE-V1.2`：group 3 球位与 `2_9` 完全一致（DQ24–31 `F2/D1/G1/A2/E1/A3/G2/C2`，DQS `C1/B1`，DM `E2`），不是球位错。
  - 只交换 group 3 DQS P/N → PDS `device_map` 拒绝（`IOBS/IOBD` 差分对固定）。
  - 22:24 交换 group 3 DQ 位序（`DQ24↔31`、`25↔30`、`26↔29`、`27↔28`）→ `led[5]` 单独亮，4 组 write leveling 全过。
  - 22:39 `dbg_error_status=2`（read pattern）；22:46 4 组 `rddata_check_pass_tmp` 全 0；22:55 gate/read 聚合版上板 `led[0]` 心跳、`led[1..4]` 亮、`led[5..7]` 灭 → **`ddr_init_done=1`、`init_fail=0`、align=0、BIST error=0**。
  - 22:55 位流：`C:\Users\BlossilveR\code\ares-video-bist-800\fpga\pango\generate_bitstream\video_bist_top.sbit`。
  - 唯一功能性修复是 group 3 DQ 位序交换；后续 22:39/22:46/22:55 只是调试 LED 映射；22:55 通过可能还叠加 PnR 自动 placement/seed 差异。
  - `led[0]` 心跳是因为 22:55 版的调试映射只在 `init_fail=1` 生效；`init_fail=0` 时回到 `video_status` 正常映射，`led[0]=beat[23]`。
  - `led[7]` 只是 BIST error，不是 BIST done；当前 4 MiB BIST 是否真正完成还未确认，下一步加 `bist_done` 指示。
- 100H demo `3_10_HDMI_IN_DDR3_gamma`：`.pds` 是 200H FBB676，但 IP 仍是 100H/FBG676，FDC 是 100H `2_9` + 200H 484 placement；`ConstraintEditor-2002` 是 share-pin 警告，`BUS_KEEPER`/484 placement 是错误，不能作为 200Pro+ 200H 的 DDR3 测试。

---

## 12. 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 200H DDR3 未上板验证 | 22:55 `ddr_init_done=1`；BIST done 未确认 | 加 `bist_done`；BIST 通过后 S2 |
| 2_9 group 3 DQ 位序 | group 3 write leveling 失败 | DQ24–31 位序交换；DQS P/N 不能交换 |
| 两套 DDR3 DQ 映射 | 数据错位 | BIST 判定；错则换 `PAD_*` 重生成 |
| DFI↔PHY -4.1 ns | 20:56+ 补 vendor multicycle 后全过 | 保留 `set_multicycle_path 2` |
| DDR3 ref_clk M21/M22 | 首次 PnR 报 `Place-0094` | `ddr3_ip.fdc` 覆盖为 N3/N2 |
| Bank L6/L7 VCCIO 3.3/2.5 冲突 | 摄像头 IO 损坏/不工作 | 上板前实测跳线，FDC 与实测一致 |
| 摄像头 PWDN 未拉低 | 无图像 | 模组侧检查；不改 RTL |
| MS7210 I2C 初始化失败 | 黑屏 | 先 S0 彩条；UART 报 `hdmi=0`；查 0xB2/400 kHz/复位 |
| vendor rd_buf 719 行 | 底部黑边 | v1 接受；stage B 修 |
| ADS 推断 bug | 综合报多驱动 | 24-bit 单临时量；参考 5-stage 经验 |
| `GTP_IOCLKDIV_E2` 200H 不可用 | 采集时钟无效 | 先查原语；退化为 fabric ÷2 + IOCLKBUF |
| PDS 无 Synplify license | 只能 ADS | 提前按 ADS 限制写 Verilog-2001 |

---

## 13. 下一阶段（stage B，不在 v1）

- `video_axi_master.v`：把 framebuf 原生 AXI 包成标准 AXI4（256-bit、4-bit ID、QoS），或按 SoC 需要做 256→128 宽度转换。
- `video_regs.v`：接上 §4.2 的 `cfg_* / status_*`，实现 plan §10 的 MMIO 表。
- `video_subsys.v`：去掉 DDR3 引脚，改 AXI4 master + MMIO slave + level IRQ。
- 严格双缓冲仲裁、三缓冲、丢帧策略。
- 与 L2 video port 的 128-bit 对齐（见 `docs/multicore_l2_checklist.md`）。

---

## 14. 参考

- `docs/video_channel_plan.md`
- `5-stage-baseline/docs/board_guide.md`
- `5-stage-baseline/fpga/pango/board_pinmap.md`（git commit `9086853`）
- `5-stage-baseline/fpga/pango/ip/ddr3/DDR3_IP_NOTES.md`
- `/mnt/d/code/docs/pango200pro*.pdf`（PK04008 V1.0，PG2L200H_FBB676 引脚定义）
- `/mnt/d/code/docs/MES2L676-200HP-CORE-V1.2原理图.pdf`
- `/mnt/d/code/docs/MES2L676-200HP-BASE-V1.2原理图.pdf`
- `/mnt/d/code/docs/MES-FMC-LPC-IO硬件使用手册_v1.1(0408).pdf`
- 100H 参考工程：`/mnt/d/BlossilveR/Download/ziguang_docs/7_FMC_Expansion_Daughter_Card-Demo/2_Demo/HDMI_DDR3_OV5640_100H`
