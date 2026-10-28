# rtl/video — 视频子系统 v1（S0/S1/S2/BIST）

> 状态：**S2 已完成并上板验证**（`picture8.jpg`，画面干净、无横条/抖动）；
> DDR3 BIST 也已通过；S0/S1/preview 已归档（`archive/`）。当前主线是
> **S2 摄像头 → DDR3 双缓冲 → HDMI** 和 **DDR3 BIST**。
> 语言：新增代码全部 **Verilog-2001**（`.v` / `.vh`），不使用 SystemVerilog。
> 目标板：盘古 200Pro+ / `PG2L200H-6IFBB676`。
> DDR3：官方 200Pro 2_9 IP，1000 Mbps，`DEVICE_100H_EN=false`，原始 DQ 顺序。
> S2 验证：`D=1 B=1 H=1 C=1 F=1`、`M≈N`；相机 2.5 V（J24=2V5，J13 已修正）；
> vendor DRM；`video_dvp_rgb565`；读侧无闸门；无 I/O delay；seed 5。
> 详细状态/坑：`../fpga/pango/README.md`、`../fpga/pango/S2_DEBUG.md`。

---

## 1. 目录

```text
rtl/video/
├── video_defs.vh           参数/阶段/状态位/地址
├── video_fb_top.v          S2 顶层：摄像头 → DDR3 双缓冲 → HDMI
├── video_fb_status.v       S2 状态 UART/LED（M/N/V/L/X）
├── video_bist_top.v        DDR3 BIST 顶层
├── video_ddr3_bist.v       两阶段 AXI 写读图案测试
├── video_bist_status.v     BIST 状态 UART/LED
├── video_capture_wrap.v    OV5640 SCCB + DVP 8→16
├── video_dvp_rgb565.v      DVP 字节配对 + 3 级流水（替代 cmos_8_16bit）
├── video_hdmi_wrap.v       sync_vg + 图案 mux + MS7210（720p30，USE_EXT_DE）
├── video_pattern_gen.v     彩条/棋盘/移动块（S0 图案，S2 可复用）
├── video_clk_reset.v       PLL + 每域复位 + phy_rstn
├── video_ip_pll.v          GTP_GPLL 薄封装（27→37.125/10/24.75）
├── legacy/                 vendor framebuf/hdmi/i2c 原样（见 legacy/README.md）
├── alt/video_dpram.v       推断 RAM，仅仿真/对照（见 alt/README.md）
├── archive/                S0/preview 顶层与 TB（见 archive/README.md）
├── sim/                    PLL/IOCLKDIV 行为模型（不进综合）
└── test/                   tb_fram_buf.sv / tb_video_capture.v / tb_video_dvp_pair.v
```

`video_framebuf_wrap.v` **没有实现**：S2 直接用 vendor `fram_buf` + `wr_buf`/
`rd_buf`，不额外包一层。

---

## 2. 当前入口

| 入口 | 顶层 | 流程 |
| --- | --- | --- |
| DDR3 BIST | `video_bist_top.v` | `fpga/pango/flow_bist.tcl`（官方 2_9，1000 Mbps，seed 2） |
| S2 摄像头→DDR3→HDMI | `video_fb_top.v` | `fpga/pango/flow_video_fb.tcl`（官方 2_9，1000 Mbps，vendor DRM，seed 5；已上板验证） |

`video_defs.vh` 里的 `VIDEO_STAGE_*` 仍保留 S0/S1/S2/BIST 选择，但当前 PDS 流程
直接指定 `video_fb_top` / `video_bist_top`，不再切 `VIDEO_STAGE_SEL`。

S0/S1/preview 的 `video_top.v`、`video_status.v`、`video_cam_preview_top.v` 和
对应 TB 在 `archive/`；它们的流程在 `../fpga/pango/archive/`。

---

## 3. 时钟 / 复位

| 域 | 时钟 | 复位 |
| --- | --- | --- |
| sys | `clk_27m` | `rst_sys` |
| pix | `clk_pix` 37.125 | `rst_pix` |
| cfg | `clk_cfg` 10 | `rst_cfg` |
| cam | `clk_cam` 24.75 | `rst_cam` |
| vin | `pixel_clk` 42 | `pixel_rst`（`~cam_init_done`） |
| ddr | `ddr_core_clk` | `ddr_rstn` / `ddr_init_done` |

所有新代码复位 **同步、高有效**；legacy 边界取反成低有效。
`clk_pix` 37.125 = 27 × 11/8；HDMI 720p30。若改 720p60，`clk_pix=74.25`，
同时改 `video_hdmi_wrap` 的 H/V total 和 `video_top.fdc` 的 `create_generated_clock`。

---

## 4. 构建

### 4.1 PDS

见 `../fpga/pango/README.md` §11：

```bat
cd fpga\pango
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_bist.tcl -project_name video_bist
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_fb.tcl -project_name video_fb
```

### 4.2 仿真

framebuf + 推断 RAM（`alt/video_dpram.v`）：

```bash
verilator --binary --timing -Irtl/video \
  --top-module tb_fram_buf_pat rtl/video/test/tb_fram_buf.sv \
  rtl/video/alt/video_dpram.v \
  rtl/video/legacy/{fram_buf,wr_buf,rd_buf,wr_ctrl,rd_ctrl,wr_cmd_trans,wr_rd_ctrl_top}.v
./obj_dir/tb_fram_buf_pat
```

DVP 采集单元测试：

```bash
mkdir -p sim/build/video/tb_video_capture
verilator --binary --timing --assert -Wall -DVIDEO_SIM \
    -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-SIDEEFFECT \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-CASEINCOMPLETE -Wno-EOFNEWLINE -Wno-SYNCASYNCNET \
    -Irtl/video --top-module tb_video_capture \
    -Mdir sim/build/video/tb_video_capture -o tb_video_capture \
    rtl/video/video_capture_wrap.v rtl/video/video_dvp_rgb565.v \
    rtl/video/sim/GTP_IOCLKDIV_E2.v rtl/video/test/tb_video_capture.v
./sim/build/video/tb_video_capture/tb_video_capture
```

字节配对回归：

```bash
verilator --binary --timing --assert -DVIDEO_SIM \
    -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-SIDEEFFECT \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-CASEINCOMPLETE -Wno-EOFNEWLINE -Wno-SYNCASYNCNET \
    -Irtl/video --top-module tb_video_dvp_pair \
    -Mdir sim/build/video/tb_video_dvp_pair -o tb_video_dvp_pair \
    rtl/video/video_dvp_rgb565.v rtl/video/sim/GTP_IOCLKDIV_E2.v \
    rtl/video/test/tb_video_dvp_pair.v
./sim/build/video/tb_video_dvp_pair/tb_video_dvp_pair
```

S0/preview 的 `tb_video_top`/`tb_video_preview` 已归档到 `archive/`；命令见
`archive/README.md` 和 `../fpga/pango/TEST_LOG.md`。

### 4.3 Lint

```bash
verilator --lint-only --timing -Wall \
    -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-CASEINCOMPLETE -Wno-EOFNEWLINE \
    -Wno-SYNCASYNCNET \
    -Irtl/video --top-module video_fb_top \
    rtl/video/video_fb_top.v rtl/video/video_clk_reset.v \
    rtl/video/video_hdmi_wrap.v rtl/video/video_pattern_gen.v \
    rtl/video/video_capture_wrap.v rtl/video/video_dvp_rgb565.v \
    rtl/video/video_fb_status.v rtl/video/video_ip_pll.v \
    rtl/video/legacy/sync_vg.v rtl/video/legacy/ms7210_ctl.v \
    rtl/video/legacy/iic_dri.v rtl/video/legacy/reg_config.v \
    rtl/video/legacy/i2c_com.v rtl/video/legacy/power_on_delay.v
```

`legacy/` 的 vendor 代码单独 waiver；新增 RTL 不要引入宽/未用信号问题。

---

## 5. 冻结接口

- `video_fb_top` 端口与 `../fpga/pango/video_top.fdc` 对齐。
- DDR3 引脚只出现在 `official_ddr3.fdc`；顶层实例名必须是 `I_ips_ddr_top`。
- 参考时钟端口叫 `ref_clk_p/ref_clk_n`，不是 `clk_p/clk_n`。
- 没有 `uart_rx`、没有 `cam_pwdn`。
- `video_fb_top` 的 vendor framebuf 读侧直接接 `sync_vg.de_re`/`vs_out`，
  不再有 `fb_init_done` 闸门。
- `video_dpram` 不在当前综合流程里；不要和 `legacy/wr_fram_buf.v`/`rd_fram_buf.v`
  同时加入工程（同名模块）。

---

## 6. legacy / alt / archive

- `legacy/`：vendor framebuf/hdmi/i2c 原样。当前 S2 使用
  `wr_fram_buf.v`/`rd_fram_buf.v`/`ipm2l_sdpram_v1_10_*.v`（`GTP_DRM36K_E1`）
  和 `fram_buf.v`/`wr_buf.v`/`rd_buf.v` 等。
- `alt/video_dpram.v`：推断 RAM，和 vendor DRM 同名模块；**只用于仿真/对照**，
  不进入 `flow_video_fb.tcl`。
- `archive/`：S0/preview 的 `video_top.v`/`video_status.v`/`video_cam_preview_top.v`
  和 TB；历史流程在 `../fpga/pango/archive/`。
- `cmos_8_16bit.v`：vendor 旧模块，保留在 `legacy/` 作对照；当前 S2 使用
  `video_dvp_rgb565`（每个 HREF 低复位字节相位）。

---

## 7. 状态与下一步

S2 已完成并上板验证（2026-10-28，`picture8.jpg`）：

- DDR3：官方 200Pro 2_9 IP，1000 Mbps，`DEVICE_100H_EN=false`，原始 DQ 顺序；
- framebuf：vendor `wr_fram_buf`/`rd_fram_buf` + `ipm2l_sdpram`（DRM）；
- 相机：`video_dvp_rgb565`（HREF 相位复位），2.5 V/LVCMOS25
  （200Pro+ J24=2V5，J13 已修正）；
- 读侧无闸门，无 `set_input_delay`/`set_output_delay`；
- 状态：`D=1 B=1 H=1 C=1 F=1`，`M≈N`。

下一步：

1. 接 SoC（视频流 / 寄存器接口）；
2. 如需更高刷新率，再评估 720p60（当前 720p30 已可用）；
3. 每次改 RTL 先跑 BIST（`I=1/G=0`），再跑 S2（`D=1/B=1`）。
