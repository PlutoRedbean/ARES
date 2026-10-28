# 视频子系统 v1 设计（OV5640 → DDR3 → HDMI，盘古 200Pro+）

> 状态：**S2 已完成并上板验证**（2026-10-28，`picture8.jpg`）。
> 目标板：盘古 200Pro+ / `PG2L200H-6IFBB676`。
> 独立比特流顶层：`video_fb_top`；后续 SoC 复用同一视频通路。
> DDR3：官方 200Pro `2_9` IP，1000 Mbps，`DEVICE_100H_EN=false`，原始 DQ 顺序。
> 详细调试记录：`fpga/pango/S2_DEBUG.md`；模块级说明：`rtl/video/README.md`。

---

## 1. 范围

v1 做一条**独立的**摄像头视频通路：

```text
OV5640（单目，DVP 8-bit）
    │ pclk 84 MHz / vsync / href / data[7:0]
    ▼
video_dvp_rgb565：8→16 bit RGB565，pclk/2 = 42 MHz
    ▼
vendor fram_buf：wr_buf → DDR3 双缓冲 → rd_buf
    ▼
video_hdmi_wrap：720p30（37.125 MHz）
    ▼
MS7210 并行 RGB → HDMI
```

不接 SoC、不做 1080p/scaler/OSD、不做 CPU MMIO/AXI4 寄存器、不做双目同时采集。
SoC 阶段预留：视频通路的 AXI 主接口和状态/控制扁平总线。

---

## 2. 硬件与引脚

| 项目 | 值 |
| --- | --- |
| FPGA | `PG2L200H-6IFBB676`，-6 |
| 系统时钟 | 27 MHz，D18 |
| 复位 | C22，低有效 |
| UART | TX=C24，RX=B24，115200 8N1 |
| LED | `led[7:0]` = B17/C17/A18/A17/E18/C19/C18/A20 |
| DDR3 | 2×4 Gbit x16 拼 32-bit，1 GB；参考时钟 125 MHz 差分 N3/N2 |
| HDMI PHY | MS7210，I2C `0xB2`，SCL=K22，SDA=K23，复位=G25 |
| 摄像头 | Double_OV5640，插 MES-FMC-LPC-IO J2（40-pin，Bank L6） |
| 模组时钟 | 模组自带 24 MHz 有源晶振，XCLK 共享 |
| 摄像头 PWDN | 不在 FPGA 引脚表，模组侧处理；v1 只控制 RESET |

摄像头 Bank L6 必须按官方要求设置 **J20=ADJ、J24=2V5（2.5 V）**；S2 调试中
J13 跳线位置错误曾导致 DVP 数据位错误（彩色横条、越用越严重），已修正。

摄像头/HDMI/DDR3 的具体 ball 见 `fpga/pango/video_top.fdc`、
`fpga/pango/official_ddr3.fdc`；DDR3 引脚只出现在后者，不要复制进
`video_top.fdc`。

---

## 3. 架构

```text
                    clk_27m  rst_n  ref_clk_p/n
                         │        │
                  ┌──────▼────────▼──────┐
                  │ video_clk_reset      │  PLL: pix 37.125 / cfg 10 / cam 24.75
                  │ video_ip_pll         │  per-domain reset + phy_rstn
                  └──┬───────┬───────┬───┘
                     │       │       │
        ┌────────────▼──┐    │   ┌───▼────────────────┐
        │ video_capture │    │   │ video_hdmi_wrap    │
        │  SCCB/reg_cfg │    │   │ sync_vg 720p30     │
        │  DVP 8→16     │    │   │ pattern mux        │
        │  42 MHz       │    │   │ RGB565→RGB888      │
        └──────┬────────┘    │   │ MS7210 init        │
               │ 16b/42MHz   │   └───┬────────┬───────┘
        ┌──────▼────────┐    │       │        │
        │ fram_buf      │◄───┘       │        ▼
        │ wr_buf/rd_buf │            │      MS7210
        │ vendor DRM    │            │
        └──┬────────┬───┘            │
           │ AXI    │                │
           ▼        ▼                │
     ┌──────────┐  ┌──────────────┐  │
     │ BIST mux │  │ video_fb_    │◄─┘
     └────┬─────┘  │ status       │
          ▼        │ LED + UART   │
   ┌──────────────┐└──────────────┘
   │ ddr3_test    │  ← 官方 2_9，实例 I_ips_ddr_top
   └──────┬───────┘
          ▼
        DDR3 pins
```

### 3.1 时钟域

| 时钟 | 来源 | 频率 | 用途 |
| --- | --- | --- | --- |
| `clk_27m` | D18 | 27.0 MHz | 控制、状态、UART、PLL 参考 |
| `clk_pix` | PLL | 37.125 MHz | 720p30、HDMI 输出 |
| `clk_cfg` | PLL | 9.995 MHz | MS7210 I2C（400 kHz） |
| `clk_cam` | PLL | 24.75 MHz | OV5640 SCCB |
| `cmos_pclk` | OV5640 | 84 MHz | DVP 字节时钟 |
| `pixel_clk` | `cmos_pclk`÷2 | 42 MHz | DVP 像素、framebuf 写侧 |
| `ddr_core_clk` | DDR3 IP | 125 MHz | framebuf 读侧/AXI、BIST |

### 3.2 复位域

- 顶层只有 `rst_n`（C22，低有效）。
- `video_clk_reset` 为每个域生成 **async assert / sync release** 的 active-high
  `rst_*`；legacy 边界取反成 active-low。
- `phy_rstn` 在 `clk_cfg` 域产生：PLL lock 后计 1 ms，驱动 MS7210 的 `RSTN_OUT`。
- DDR3：`ddr3_test.resetn = phy_rstn`；`fram_buf.ddr_rstn = ddr_init_done`。

---

## 4. 模块

| 文件 | 模块 | 职责 |
| --- | --- | --- |
| `video_fb_top.v` | `video_fb_top` | S2 板级顶层：IP 实例、framebuf、HDMI、状态 |
| `video_defs.vh` | — | 参数、状态位、地址 |
| `video_clk_reset.v` | `video_clk_reset` | PLL + 每域复位 + `phy_rstn` |
| `video_ip_pll.v` | `video_ip_pll` | `GTP_GPLL` 薄封装（27→37.125/10/24.75） |
| `video_capture_wrap.v` | `video_capture_wrap` | `power_on_delay` + `reg_config` + `i2c_com` + DVP |
| `video_dvp_rgb565.v` | `video_dvp_rgb565` | 8→16 bit 字节配对 + 3 级流水 + HREF 相位复位 |
| `video_hdmi_wrap.v` | `video_hdmi_wrap` | `sync_vg` + 图案 mux + RGB565→RGB888 + MS7210 初始化 |
| `video_pattern_gen.v` | `video_pattern_gen` | 彩条/棋盘/移动块 |
| `video_fb_status.v` | `video_fb_status` | 8 LED + 115200 UART 状态（M/N/V/L/X） |
| `legacy/fram_buf.v` | `fram_buf` | 双缓冲帧缓存顶层 |
| `legacy/wr_buf.v` / `rd_buf.v` | `wr_buf`/`rd_buf` | 写/读行缓冲 |
| `legacy/wr_ctrl.v` / `rd_ctrl.v` | `wr_ctrl`/`rd_ctrl` | AXI 读/写控制 |
| `legacy/wr_cmd_trans.v` / `wr_rd_ctrl_top.v` | — | 写命令转换/读写仲裁 |
| `legacy/wr_fram_buf.v` / `rd_fram_buf.v` | — | 行缓冲 DRM（`ipm2l_sdpram`） |
| `legacy/ipm2l_sdpram_v1_10_*.v` | — | Pango SDPRAM 原语（`GTP_DRM36K_E1`） |
| `legacy/sync_vg.v` | `sync_vg` | 720p30 时序、DE/HS/VS |
| `legacy/ms7210_ctl.v` / `iic_dri.v` / `i2c_com.v` | — | MS7210 初始化/I2C |
| `legacy/reg_config.v` | `reg_config` | OV5640 寄存器表 |
| `legacy/power_on_delay.v` | `power_on_delay` | 上电延时/摄像头复位 |
| `ip/ddr3/ddr3_test` | `I_ips_ddr_top` | 官方 200Pro 2_9 DDR3 IP（1000 Mbps） |

`legacy/` 的 vendor 模块保持原样；新增 RTL 全部 Verilog-2001，不使用
SystemVerilog。

---

## 5. 数据通路

### 5.1 采集

- OV5640 8-bit DVP，`pclk=84 MHz`；`reg_config` 配置 `0x4300=0x60`（RGB565，
  BGR 顺序）。
- `video_capture_wrap` 先在 `cam_pclk` 打一拍（`cam_data_d0`/`cam_href_d0`/
  `cam_vsync_d0`），再进 `video_dvp_rgb565`。
- `video_dvp_rgb565`：
  - HREF 低时把字节相位强制回 0，保证每行从第一个字节开始；
  - 每两个字节拼成 `{first, second}`，3 级流水输出 `pdata_o`/`de_o`；
  - `GTP_IOCLKDIV_E2` 输出 `pclk/2 = 42 MHz`。
- `video_capture_wrap` 把 BGR565 归一化为 RGB565（`RGB_SWAP=1`）。

### 5.2 写帧缓存

- `fram_buf` 的 `wr_clk = pixel_clk`，`wr_en = pixel_de`，`wr_data = RGB565`。
- `wr_buf` 行缓冲 → `wr_ctrl`/`wr_cmd_trans` → DDR3 AXI 写。
- `wr_fsync = pixel_vsync`（像素域）。

### 5.3 读帧缓存

- `fram_buf` 的 `vout_clk = clk_pix`，`rd_en = sync_vg.de_re`，
  `rd_fsync = sync_vg.vs_out`（vendor 顶层行为，不额外加 `init_done` 闸门）。
- `rd_buf` 行缓冲 → HDMI 像素流。
- `vout_de` 直接作为 HDMI 的 DE（`USE_EXT_DE=1`）。

### 5.4 双缓冲

- `wr_buf`/`rd_buf` 用帧位（bit22/bit23 区域）区分两帧；
- 写侧持续写当前帧，读侧读另一帧；
- 首帧之前读侧可能短暂显示空行缓冲，属于正常上电行为。

### 5.5 图案注入

- `video_hdmi_wrap` 的 `pattern_gen` 可覆盖 HDMI 输出（彩条/棋盘/移动块）；
- `video_fb_top` 的 `INJECT_PATTERN=1` 可在**写侧**用纯色竖条替换摄像头数据，
  用于隔离 framebuf/DDR3/HDMI 与摄像头 DVP；正常出图保持 0。

### 5.6 RGB 顺序

- 传感器输出 BGR565；`video_capture_wrap` 用
  `{d[4:0], d[10:5], d[15:11]}` 转成 RGB565；
- HDMI 侧 `{rgb[15:11],3'b0}` / `{rgb[10:5],2'b0}` / `{rgb[4:0],3'b0}` 扩展到
  RGB888。

---

## 6. DDR3

### 6.1 IP 与约束

- 官方 200Pro `2_9` `ddr3_test` IP，**1000 Mbps**，`DEVICE_100H_EN=false`；
- 约束：`fpga/pango/official_ddr3.fdc`（2_9 官方引脚/时钟/CPD/multicycle 子集）；
- IP 实例名必须是 `I_ips_ddr_top`；参考时钟端口 `ref_clk_p/ref_clk_n`；
- 顶层 DQ 顺序使用 2_9 原始顺序，**不要**再做 DQ24..31 反转；
- `axi_wlast` 接 IP 的 `axi_wusero_last`（vendor 顶层行为）；
- 不附加旧的 100H/600 Mbps PHY 摆放 PCF。

### 6.2 帧缓冲地址

- framebuf 帧位/行步进由 `fram_buf` 内部地址逻辑产生；
- `wr_buf`/`rd_buf` 的行缓冲为 16 KB 级，DDR3 侧 256-bit AXI；
- 两帧间距按 vendor 链的帧位，不在顶层重新计算。

### 6.3 已知风险

- 1000 Mbps 对 PHY 摆放/温度敏感；当前 2_9 BIST 与 S2 均通过；
- 若后续出现随温度加重的数据错误，优先检查 DDR3 温度/PHY 摆放，
  再考虑降速（800 Mbps 重新生成 IP 需同步更新 PHY/PLL 配置，不要只改
  `DFI_CLK_PERIOD`）。

---

## 7. 约束

- `video_top.fdc`：板级引脚/时钟/CDC；摄像头 Bank L6 为 **2.5 V/LVCMOS25**
  （J20=ADJ、J24=2V5）；HDMI 3.3 V。
- `video_fb.fdc`：pixel/DDC/CDC 约束。
- `official_ddr3.fdc`：DDR3 引脚/时钟/CPD/multicycle。
- 摄像头/HDMI 的 `set_input_delay`/`set_output_delay` 已移除，与官方 100H
  相机工程一致；如换板/换 FMC，再按实测恢复 I/O timing。
- PnR：`flow_video_fb.tcl` 使用 `seed 5`；改 RTL 后先确认 `D=1`。

---

## 8. 构建与烧写

```bat
cd fpga\pango
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_fb.tcl -project_name video_fb
```

产物：

```text
generate_bitstream/video_fb_top.sbit
```

烧写：

```bat
cd D:\PDS_2022.2-SP6.4\bin
cdt_cfg.exe -file C:\...\fpga\pango\program.tcl ^
  -args "{C:\...\fpga\pango\generate_bitstream\video_fb_top.sbit}"
```

期望状态行：

```text
S2 P=1 D=1 H=1 C=1 F=1 B=1 R=1 E=1 G=1 M=... N=...
```

- `D=1`：DDR3 init done；
- `B=1/R=1/E=1/G=1`：framebuf 正常；
- `M≈N`：摄像头中心像素与 framebuf 读回一致。

---

## 9. 状态与调试

- UART 115200：`M`（摄像头中心 RGB565）、`N`（framebuf 读回中心）、
  `V/L/X`（帧/行/像素计数）；
- LED：心跳 + 各阶段 done/error；
- 隔离手段：
  - `INJECT_PATTERN=1`：写侧纯色竖条，判断 framebuf/DDR3/HDMI 是否干净；
  - `video_pattern_gen`：HDMI 侧图案，不经过 framebuf；
  - BIST：独立 DDR3 写读（`I=1/G=0`）。

---

## 10. 验证结果

- 官方 2_9 BIST 1000 Mbps：`I=1 F=0 A=0 G=0 D=1 E=0 C=0`，`P` 持续增长；
- S2 上板（`picture8.jpg`）：画面干净、无彩色横条、无抖动；
  `D=1 B=1 H=1 C=1 F=1`，`M≈N`；
- 注入竖条干净，证明 framebuf/DDR3/HDMI 数据通路正常；
- 根因记录：
  1. **J13 跳线位置错误**（物理）→ DVP 数据位错误、彩色横条、越用越严重；
  2. 旧 DDR3 IP 用 100H 配置（`DEVICE_100H_EN=true`）+ DQ3 反转 → 官方
     200Pro `false` + 原始 DQ 顺序；
  3. vendor `cmos_8_16bit` 字节相位 bug → `video_dvp_rgb565` 的 HREF 复位；
  4. 800 Mbps 重新生成 IP 更差（PLL/PHY 配置不匹配）→ 回到 1000；
  5. 读闸门 / 2.0 ns I/O delay → 去掉。

---

## 11. SoC 接入

视频通路可以原样复用：

```text
camera capture → framebuf/DDR3 → HDMI
```

SoC 阶段建议：

- 把 `video_fb_top` 拆成 `video_subsys`（capture + framebuf + hdmi + status），
  顶层只做板级/IP 实例；
- framebuf 的 AXI 主接口接 SoC 的 AXI interconnect/DDR 控制器；
- 状态/控制用扁平 `cfg_*`/`status_*` 或 AXI-Lite 寄存器；
- 保持 `video_dvp_rgb565`、`fram_buf`、`video_hdmi_wrap` 不变，减少回归面。

---

## 12. 参考

- `fpga/pango/S2_DEBUG.md`：S2 调试记录、位流、隔离测试；
- `fpga/pango/README.md`：板级/DDR3/BIST/S2 状态；
- `rtl/video/README.md`：模块/目录/构建/仿真说明；
- 官方 200Pro `2_9_ddr3_test`、`HDMI_DDR3_OV5640_100h`、`4_12_HDMI_IN_DDR3_HDMI_OUT`。
