# OV5640 → HDMI preview 调试记录

> 目标：**不经过 DDR3**，把 OV5640 画面经 FPGA 内部 640×360 双缓冲直接送 HDMI，
> 先确认采集/显示链路通。
>
> 板卡：盘古 200Pro+（PG2L200H-6IFBB676），PDS 2022.2-SP6.4。
> 顶层：`video_cam_preview_top`（`CAM_SEL=0`，CMOS1 / J2）。
> 构建工程：`C:\Users\BlossilveR\code\ares-video-cam-preview\fpga\pango`。
> 最后更新：2026-10-28 00:45。

---

## 0. 当前状态（TL;DR）

| 项目 | 状态 |
| --- | --- |
| 位流构建 | ✅ 00:38 版 `All Constraints Met` |
| LED / UART | ✅ 与预期一致（PLL、HDMI init、cam init、帧活动） |
| 画面能出、几何正确 | ✅ |
| 颜色/条纹 | ❌ 仍未解决：已知图案（传感器内部彩条）也有条纹 |
| 最近一次上板 | 00:28 **colorbar 诊断版**（**旧采集模块**），仍有条纹 |
| 待验证 | 00:38 版（字节相位修复）**尚未上板确认** |

> 关键点：00:28 的 colorbar 版是在字节相位修复**之前**编的，它用的是旧
> `cmos_8_16bit`，所以“colorbar 有彩色条纹”本身是**预期可复现的故障**，
> 不能用来判断 00:38 的修复是否有效。下一步先烧 00:38 版。

---

## 1. 改动清单

### 1.1 RTL

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `rtl/video/video_cam_preview_top.v` | 新增 `GTP_CLKBUFG u_pixel_clk_bufg`，区域时钟改名 `pixel_clk_io`，写侧改用全局 `pixel_clk` | IOCLKDIV 输出是区域时钟，带不动跨 clock region 的 preview BRAM（`Place-0089`） |
| 同上 | 读地址改为 `(hdmi_x_act+1)[11:1]`，行尾钳位 639 | 数据通路比 DE 通路多一级寄存器，原来整幅图晚一个源像素 |
| `rtl/video/video_capture_wrap.v` | 增加 `RGB_SWAP`（默认 1）：`{d[4:0],d[10:5],d[15:11]}` | OV5640 `0x4300=0x60` 输出 BGR565，vendor/Gowin 都做这个交换 |
| 同上 | DVP `data/href/vsync` 先打一拍（`cam_data_d0` 等） | 与 vendor 顶层一致；同时把 `pdata_o` 相对 `/2 pixel_clk` 的相位调整 180° |
| 同上 | 用 `video_dvp_rgb565` 替换 legacy `cmos_8_16bit` | 旧模块字节相位跨行保持，额外 HREF 脉冲会让后续行字节顺序翻转 |
| `rtl/video/video_dvp_rgb565.v` | **新增**：DVP 8→16，HREF 低电平复位字节相位；保留同样的 `GTP_IOCLKDIV_E2` ÷2 时钟和 3 级输出流水线 | 参考 Gowin `ov5640_data.v` 的 `data_flag <= 0`（HREF low） |
| `rtl/video/sim/GTP_CLKBUFG.v` | **新增**：Verilator 行为模型 | 仿真 preview 顶层 |
| `rtl/video/test/tb_video_capture.v` | 期望值改为 `0xA222`（BGR `0x1234` → RGB） | 跟随 `RGB_SWAP` |
| `rtl/video/test/tb_video_preview.v` | **新增**：3 帧合成 DVP → preview BRAM → HDMI，检查 48 个输出像素 | 覆盖 2× 抽点、2× 放大、双 bank、读流水线 |
| `rtl/video/test/tb_video_dvp_pair.v` | **新增**：额外 HREF 脉冲后第 2 行仍须配对正确 | 回归字节相位问题（旧模块 FAIL，新模块 PASS） |

### 1.2 约束 / 流程

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `fpga/pango/video_preview.fdc` | **新增**：显式命名 `pixel_clk` 生成时钟；只把 `preview_wr_bank → pix_clk` 设为 false path | PDS 自动推断的 `...CLKDIVOUT_Inferred` 没进 `cmos1_pclk` 异步组，CDC 被当同步路径分析（−2.972 ns） |
| `fpga/pango/flow_video_preview.tcl` | `add_constraint video_preview.fdc` | 只给 preview 用，不污染 S0/S1 |
| `fpga/pango/README.md` | 增加 §11（构建、颜色、字节相位） | 现场记录 |
| `rtl/video/README.md`、`legacy/README.md`、`docs/video_subsystem_v1_design.md` | 更正 BGR565 说明、补测试命令 | 文档与实现一致 |

---

## 2. 构建阶段的问题

### 2.1 `Place-0089: REGION_CLOCK`

第一次 PnR 在 Phase 1.2 报：

```text
E: Place-0089: REGION_CLOCK: the loaders driven by
g_capture.g_cam1.u_capture/u_cmos/u_u_/iockdiv_inst
is incompatible with the available resource.
```

`cmos_8_16bit` 里的 `GTP_IOCLKDIV_E2` 输出是**区域时钟**；preview 的两片
640×360×16 BRAM 会铺到多个 clock region，区域时钟带不动。

**修法**：`video_cam_preview_top` 加 `GTP_CLKBUFG`，把 ÷2 时钟提升为全局时钟。
PnR 后 `clock_utilization.txt` 显示该 BUFG 带 281 个 clock load。

### 2.2 CDC 时序违例（−2.972 ns）

加 BUFG 后能布通，但 PDS 把 IOCLKDIV 输出自动推断成
`cmos1_pclk|...CLKDIVOUT_Inferred`，没并入 `cmos1_pclk` 异步组，于是
`preview_wr_bank → preview_wr_bank_sync` 被当同步路径：

```text
cmos1_pclk|...CLKDIVOUT_Inferred -> pix_clk   WNS -2.972  (1 endpoint)
```

**修法**（`video_preview.fdc`）：

```tcl
create_generated_clock -name pixel_clk -source [get_ports {cmos1_pclk}] \
    [get_nets {pixel_clk_io}] -master_clock [get_clocks {cmos1_pclk}] \
    -multiply_by 1 -divide_by 2
set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {pix_clk}]
set_false_path -from [get_clocks {pix_clk}]   -to [get_clocks {pixel_clk}]
```

`cmos1_pclk → pixel_clk` 的 521 个真实数据端点仍然照常分析
（WNS +5.871 / hold 正），只把 bank 握手声明为异步。

---

## 3. 图像问题：四层修复

### 3.1 BGR565 未归一化（颜色整体错）

OV5640 数据手册 table 7-15：`0x4300 = 0x60` → RGB565 + sequence 0：

```text
{b[4:0],g[5:3]}, {g[2:0],r[4:0]}
```

所以 `cmos_8_16bit` / `video_dvp_rgb565` 输出的是 **BGR565**
（`[15:11]=B`、`[4:0]=R`）。vendor 顶层和 Gowin 工程都做：

```verilog
{d[4:0], d[10:5], d[15:11]}   // {B,G,R} -> {R,G,B}
```

`video_capture_wrap` 用 `RGB_SWAP=1`（默认）实现。

### 3.2 DVP 输入少一级寄存器（相位）

vendor 顶层在 `cmos_8_16bit` 前先把 `data/href/vsync` 打一拍。`pixel_clk`
是 pclk 的 ÷2，这一拍会把 `pdata_o` 相对 `pixel_clk` 移相 180°。补齐后
下游 BRAM 写侧的采样相位与 vendor 一致。

### 3.3 preview 读地址 off-by-one（仿真发现）

数据通路：`mem → preview_rd_rgb → rgb_mux/r_q`；DE 通路：`de → de_q`。
数据多一级，所以输出整体晚一个**源像素**。新增的 `tb_video_preview` 实测：

```text
xo=2  期望 mem[1]  实际 mem[0]
xo=100 期望 r=0x90 实际 0x88
```

**修法**：`hdmi_rd_x = (hdmi_x_act+1)`，`[11:1]` 作为列地址。改完 48 点全过。

### 3.4 字节配对跨行保持（彩色条纹根因）

参考 `Gowin_FPGA_CV/CV_acceleration/src/OV5640/ov5640_data.v`：

```verilog
end else begin          // HREF low
  data_flag <= 1'b0;    // 每行重新对齐字节
```

vendor 的 `cmos_8_16bit.v` 里 `cnt` 只在 `!rst_n` 清零，HREF 低时保持不变。
只要空档里多一个 HREF 脉冲、或某行字节数为奇数，后续行的
`{first,second}` 顺序就翻转 → 蓝/青/品红横条。

S1 的 UART 数据是旁证：

```text
V=0x1E = 30/s
L=0x57E4 = 22500/s     22500 / 30 = 750 行/帧（720p 只有 720 有效行）
P=0x1A2B3C4 ≈ 27.47 Mpix/s
```

**修法**：新增 `video_dvp_rgb565.v`，每个 HREF 低电平把 byte phase 清零；
时钟生成、3 级输出流水线、`enble` 逻辑都与 vendor 一致，所以下游相位不变。

回归测试 `tb_video_dvp_pair.v`（第 1 行后插一个额外 HREF 脉冲）：

```text
cmos_8_16bit      : 第2行 = 0x3456   ← 复现故障（字节错位）
video_dvp_rgb565  : 第2行 = 0x1234   ← PASS
```

---

## 4. 验证结果

### 4.1 仿真

| TB | 内容 | 结果 |
| --- | --- | --- |
| `tb_video_capture` | DVP 8→16、字节序、计数器 | PASS（`BGR 0x1234 → RGB 0xA222`） |
| `tb_video_dvp_pair` | HREF 空档额外脉冲后的字节相位 | 新模块 PASS；旧模块 FAIL（0x3456） |
| `tb_video_preview` | 3 帧合成 DVP → 640×360 双缓冲 → HDMI，48 点 r/g/b | PASS |
| `verilator --lint-only`（preview 顶层） | — | 0 error |

### 4.2 时序 / 资源（00:38 版）

| Clock | Requested | WNS |
| --- | --- | --- |
| `sys_clk` | 27.000 MHz | 30.729 ns |
| `cmos1_pclk` | 84.000 MHz | 8.683 ns |
| `pix_clk` | 37.125 MHz | 15.508 ns |
| `cfg_clk` | 10.000 MHz | 96.236 ns |
| `cam_clk` | 24.750 MHz | 37.962 ns |
| `cmos1_pclk → pixel_clk` | — | 5.871 ns |
| `pixel_clk` | 42.000 MHz | 15.550 ns |

- `Design Summary : All Constraints Met`
- 资源：LUT 2301 + 169、FF 714 + 201、**DRM 257/415（62%）**、USCM 3、GPLL 1

### 4.3 已知告警（非本次引入）

- `Flow-4065`：`cmos2_*`、`ref_clk_*` dangling（preview 不用）。
- `STA-3011` ×45：`u_reg_config` 的 SCCB 时钟，S1 工程同样存在，上板 SCCB 可正常配置。

---

## 5. 位流清单

目录：`C:\Users\BlossilveR\code\ares-video-cam-preview\fpga\pango`

| 文件 | 时间 | 内容 | 上板结果 |
| --- | --- | --- | --- |
| `generate_bitstream/video_cam_preview_top.sbit` | 00:38 | BUFG + 约束 + BGR 交换 + 输入寄存器 + 读地址 + **字节相位修复** | **未确认** |
| `video_cam_preview_top_colorbar.sbit` | 00:28 | 旧采集模块 + OV5640 内部彩条 `0x503D=0x80` | 仍有条纹（旧模块的预期故障） |
| `video_cam_preview_top_rgbfix.sbit` | 00:08（00:21 复制） | 只到 BGR/输入寄存器/读地址，未修字节相位 | 红盒子仍异常 + 噪声（`preview2.jpg`） |

历史：

- 23:36 版：只修了 `Place-0089` 和 CDC，是第一次上板版（`preview1.jpg`，房间场景，颜色失真）。
- 00:08 版：颜色修复，`preview2.jpg`（红盒子，仍异常）。

---

## 6. 当前未决问题

**现象**：colorbar 诊断版（已知的传感器内部 8 色彩条）上仍能看到条纹。

这条信息说明：

- 条纹**不是场景内容**造成的；
- 但 colorbar 版用的是**旧** `cmos_8_16bit`，字节相位问题仍然存在，
  所以它**不能**证明 00:38 的修复无效。

仍需区分两种可能：

1. **DVP 采集/字节配对**（colorbar 也要走 DVP 总线）
   - 00:38 已修字节相位；若仍异常，可能是数据线/时钟的物理层问题。
2. **preview BRAM 写/读通路**（PDS 推断的 DRM、双时钟、读地址）
   - 仿真已过，但 PDS 网表/时序仍需上板确认。

---

## 7. 下一步（按顺序）

1. **先烧 00:38 版**（`generate_bitstream/video_cam_preview_top.sbit`），
   拍一张红盒子/彩条照片，确认条纹是否消失。
2. 若仍有条纹，做 **FPGA 自测图案**诊断版：
   - 保留摄像头 DE/VSYNC 的写地址和时序；
   - 把写入数据换成 `f(cam_x, cam_y)`（如彩色渐变）；
   - 图案干净 → 问题在 DVP 采集；图案仍脏 → 问题在 BRAM/读通路。
3. 若判定为 DVP：
   - 核对 Bank L6 实际 VCCIO（J20=ADJ、J24=2V5）与 `video_top.fdc` 的
     `LVCMOS25` 是否一致；
   - 用示波器看 PCLK/D0..D7 的过冲/串扰；
   - 试 PCLK 降频（`0x3036/0x3824`）或换短排线。
4. 若判定为 BRAM/读通路：
   - 检查 PDS 推断的 DRM 端口时钟（写 `pixel_clk`、读 `pix_clk`）；
   - 检查双 bank 选择与读地址；
   - 必要时改成显式双口 RAM 原语，避免推断差异。

---

## 8. 复现命令

构建（Windows）：

```bat
cd C:\Users\BlossilveR\code\ares-video-cam-preview\fpga\pango
set PANGO_LICENSE_FILE=D:\PDS_2022.2-SP6.4\LICENSE\new_pds_4c23380ca8a1.lic
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_preview.tcl -project_name video_preview
```

烧写（JTAG 服务先起）：

```bat
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl ^
  -args {<...>\generate_bitstream\video_cam_preview_top.sbit}
```

仿真（Linux / Verilator，仓库根目录）：

```bash
# 字节相位回归
verilator --binary --timing --assert -DVIDEO_SIM -Irtl/video \
  --top-module tb_video_dvp_pair -Mdir /tmp/tb_pair -o tb_video_dvp_pair \
  rtl/video/video_dvp_rgb565.v rtl/video/sim/GTP_IOCLKDIV_E2.v \
  rtl/video/test/tb_video_dvp_pair.v
/tmp/tb_pair/tb_video_dvp_pair

# preview 全链路
verilator --binary --timing --assert -DVIDEO_SIM -Irtl/video \
  --top-module tb_video_preview -Mdir /tmp/tb_prev -o tb_video_preview \
  rtl/video/video_cam_preview_top.v rtl/video/video_clk_reset.v \
  rtl/video/video_hdmi_wrap.v rtl/video/video_pattern_gen.v \
  rtl/video/video_capture_wrap.v rtl/video/video_dvp_rgb565.v \
  rtl/video/video_status.v rtl/video/sim/video_ip_pll_sim.v \
  rtl/video/sim/GTP_IOCLKDIV_E2.v rtl/video/sim/GTP_CLKBUFG.v \
  rtl/video/legacy/sync_vg.v rtl/video/legacy/ms7210_ctl.v \
  rtl/video/legacy/iic_dri.v rtl/video/legacy/power_on_delay.v \
  rtl/video/legacy/reg_config.v rtl/video/legacy/i2c_com.v \
  rtl/video/test/tb_video_preview.v
/tmp/tb_prev/tb_video_preview
```

> 注意：`rtl/video/legacy/cmos_8_16bit.v` 已经不再被 `video_capture_wrap`
> 例化，仅作 vendor 参考保留；新 RTL 用 `video_dvp_rgb565.v`。
