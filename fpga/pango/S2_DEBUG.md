# S2 摄像头 → DDR3 双缓冲 → HDMI 调试记录

> 目标：独立（不接 SoC）OV5640 → DDR3 双缓冲 → HDMI 720p30。
> 板卡：盘古 200Pro+（PG2L200H-6IFBB676），PDS 2022.2-SP6.4。
> 顶层：`video_fb_top`；构建工程：`C:\Users\BlossilveR\code\ares-video-s2-fb\fpga\pango`。
> 最后更新：2026-10-28（官方 200Pro 2_9 IP 已替换旧 100H/600 方案）。

---

## 0. TL;DR

| 项目 | 状态 |
| --- | --- |
| DDR3 1000 Mbps BIST（官方 2_9 IP） | ✅ 30 s 0 错，`I=1 G=0 E=0` |
| S2 DDR3 init | ✅ `D=1`（官方 IP + 官方 FDC + `flow_video_fb` seed 5） |
| 摄像头 SCCB / DVP | ✅ `C=1`，`M` 随白天场景变化 |
| HDMI 初始化 / 720p30 | ✅ `H=1` |
| framebuf 首帧写入 | ✅ `B=1` |
| framebuf 读回 | ✅ 白天场景可见（不是白屏/纯噪声） |
| 纯色竖条注入（`INJECT_PATTERN=1`） | ✅ 红/绿/蓝/白 4 条干净 → framebuf/DDR3/HDMI 数据通路正确 |
| 剩余问题 | ⚠️ 摄像头数据有随机彩色横条；画面边缘/整屏有轻微抖动 |

**结论**：DDR3 和 framebuf 已经不再是瓶颈。彩色横条来自**摄像头 DVP 数据**，
抖动需要区分是**摄像头行时序**还是**720p30 在 4K 显示器上的缩放/FreeSync**。
下一步按 §7 做摄像头 IO/时序对照，不要再抽 PnR seed。

---

## 1. 关键转折：官方 200Pro 2_9 IP

早期的 S2 使用从 100H 工程继承的 IP（`DEVICE_100H_EN=true`，600 Mbps，
DQ3 反转），表现为：

- 1000 Mbps 静态时序 −4 ns；
- 800 Mbps init 随 PnR 翻转；
- 600 Mbps BIST 能过，但 S2 画面白屏/彩色噪声，D 对网表变化极敏感。

切换到官方 200Pro 资料包
`2_Demo/2_9_ddr3_test/.../ipcore/ddr3_test/` 后：

| 差异 | 旧 100H/600 | 官方 2_9 |
| --- | --- | --- |
| `DEVICE_100H_EN` | `true` | **`false`** |
| 速率 | 600 Mbps | **1000 Mbps** |
| `DFI_CLK_PERIOD` | 13333 | **8000** |
| DQ3 组 | `DQ24↔31` 反转 | **原始顺序** |
| 约束 | `ddr3_ip.fdc` + 手工 PHY 摆放 | **`official_ddr3.fdc`**（CPD/自动） |
| 1000 Mbps 时序 | 负 | **All Constraints Met** |
| BIST | 600 Mbps | **1000 Mbps `I=1/G=0`** |

旧文件全部归档在 `fpga/pango/ip/ddr3/archive_100h_600m/`，不再参与当前流程。

---

## 2. 当前配置

- **DDR3 IP**：`ip/ddr3/ddr3_test`（官方 2_9，1000 Mbps，`DEVICE_100H_EN=false`）。
- **DDR3 FDC**：`fpga/pango/official_ddr3.fdc`（官方 `2_9/pnr/ddr_test.fdc` 的
  引脚/时钟/CPD/multicycle 子集；去掉示例 `free_clk`/UART/LED）。
- **framebuf**：vendor `legacy/fram_buf.v` + `wr_buf`/`rd_buf` +
  `legacy/wr_fram_buf.v`/`rd_fram_buf.v` + `GTP_DRM36K_E1` SDPRAM。
  `rtl/video/alt/video_dpram.v` 只用于仿真。
- **写侧**：`video_capture_wrap` + `video_dvp_rgb565`（CMOS2 / J2，OV5640 RGB565，
  PCLK 84 → pixel_clk 42）。
- **读侧**：`video_hdmi_wrap` + `ms7210_ctl`，720p30；`rd_en = sync_vg.de_re`，
  `rd_fsync = sync_vg.vs_out`，**不再用 `fb_init_done` 闸门**（与 vendor
  `hdmi_ddr_ov5640_top` 一致）。
- **HDMI DE**：`USE_EXT_DE=1`，用 framebuf 的 `vout_de` 采样 `vout_data`。
- **`axi_wlast`**：由 IP 的 `axi_wusero_last` 驱动。
- **流程**：`flow_video_fb.tcl`，`pnr -seed 5`。
- **BIST**：`flow_bist.tcl`，`pnr -seed 2`。

---

## 3. 当前 S2 状态行

115200 8N1，~0.5 s 一行：

```text
S2 P=1 D=1 H=1 C=1 F=1 B=1 R=1 E=1 G=1 M=7A09 N=9B4D V=... L=... X=...
```

| 字段 | 含义 |
| --- | --- |
| `P` | 系统 PLL lock |
| `D` | DDR3 `ddr_init_done` |
| `H` | HDMI init |
| `C` | 摄像头 SCCB init |
| `F` | 采集帧活动 |
| `B` | framebuf 首帧写入（`init_done`） |
| `R` | 读回数据非零（sticky） |
| `E` | HDMI `rd_en` 出现过 |
| `G` | framebuf `vout_de` 出现过 |
| `M` | 摄像头 (640,360) 原始 RGB565 |
| `N` | framebuf 读回 (640,360) 的 RGB565；**现在在 `fb_vout_de` 有效时采样** |
| `V/L/X` | 采集 vsync / line / pixel 计数 |

> 早期 `N` 在 `hdmi_rd_en` 采样，比 `vout_de` 早 2 拍，值不能直接和 `M` 比较。
> 当前 RTL 已改为 `fb_vout_de && (x==640) && (y==360)`，重新构建后 `N` 才代表
> 实际显示的中心像素。仓库里的 `video_fb_top.v` 是修正后的版本；板上旧位流
> 的 `N` 仍可能是旧的采样点。

---

## 4. 上板现象（2026-10-28）

| 文件 | 配置 | 现象 |
| --- | --- | --- |
| `picture2.jpg` | 官方 IP + `video_dpram` + 读闸门 | 白天场景可见，粉色调，少量横条 |
| `picture3.jpg` | 官方 IP + vendor DRM + 无闸门 | 场景更亮，随机彩色横条明显 |
| `picture4.jpg` | 官方 IP + vendor DRM + `INJECT_PATTERN=1` | 4 条红/绿/蓝/白**干净**，边缘轻微波浪/抖动 |

- `picture2/3` 证明 **DDR3、framebuf、HDMI、摄像头都在跑**，场景不再是白屏。
- `picture4` 是决定性隔离：**framebuf/DDR3/HDMI 数据通路干净**，横条来自摄像头数据。
- `picture4` 的竖条边缘波浪来自注入用 `cap_x` 的逐行计数（以及 720p30 在 4K
  显示器上的缩放），不是 framebuf 数据错误；摄像头真实画面的边缘抖动另见 §6。

---

## 5. 已排除 / 高置信项

- **DDR3 物理读写**：官方 2_9 IP，1000 Mbps，30 s BIST 0 错，`G=0`。
- **framebuf 地址/多 burst/行缓冲/DPRAM 映射**：Verilator TB 纯色 0 bad，
  x 图案 0.2%（集中在开头 prefetch），主体正确。
- **framebuf 写读数据通路**：`INJECT_PATTERN=1` 时竖条干净。
- **vendor DRM vs 推断 RAM**：两者都能出场景；当前用 vendor DRM（官方 demo 同款）。
- **读侧闸门**：vendor 顶层不闸；S2 已去掉闸门，仍能出场景。
- **`axi_wlast`/`ext_de`**：已按 vendor 接法修正。
- **摄像头 SCCB/DVP**：`M` 随场景变化，`V/L/X` 计数正常。

---

## 6. 剩余问题

### 6.1 摄像头数据随机彩色横条

现象：场景整体正确，但有随机整行/半行彩色噪声。

已确认：

- 不是 DDR3/framebuf/HDMI（竖条注入干净）；
- 不是 `M` 采样（摄像头中心像素正常）；
- 可能是 DVP 数据位/字节配对/采样时序。

待排查（按优先级）：

1. **IO 电平**：S2 `video_top.fdc` 相机引脚是 **2.5 V / LVCMOS25**；
   官方 100H 相机工程是 **3.3 V / LVCMOS33**。同一 FMC 相机卡、不同核心板
   VADJ。先确认 200Pro+ FMC 的实际 VADJ，再决定是否改成 3.3 V。
2. **输入时序**：S2 原来加 `set_input_delay 2.0` / `set_output_delay 2.0`，
   官方 100H 工程没有。当前 `video_top.fdc` 已注释（`build_cam_nodelay`），
   上板结果待确认；若仍在，回到 2.0 或试 `cmos_8_16bit` + 官方输入寄存器结构。
3. **字节配对**：`video_dvp_rgb565` 在 `!de_i` 时清 `phase`；若 HREF 有
   glitch/少一个低电平，相位可能翻。可对照 Gowin OV5640 参考
   （`ov5640_data.v` 在每个 HREF 低清 `data_flag`）。
4. **传感器/PCLK**：84 MHz 8-bit DVP 在 FMC 上的信号完整性；可降低 PCLK
   （OV5640 PLL/分频）做对照，确认是否高速采样问题。

### 6.2 画面抖动 / 边缘波浪

- 720p30（37.125 MHz）不是所有 4K 显示器都友好；`LEGION` 4K + FreeSync
  可能出现缩放波纹/轻微抖动。
- 需要时改 **720p60**：`clk_pix=74.25 MHz`、CEA-861 H/V total，
  framebuf 读侧 60 Hz；摄像头仍 30 fps，读侧读同一帧两次，DDR3 读带宽翻倍
  （1000 Mbps 足够）。
- 注入测试的 `cap_x` 波浪是测试条自身的问题；摄像头画面不受 `cap_x` 影响。

### 6.3 `N` 采样

- 已改为 `fb_vout_de` 有效时采样；需要重新构建/烧写后确认 `M≈N`。
- 旧位流的 `N` 仍是 `hdmi_rd_en` 采样，偏早 2 拍。

---

## 7. 下一步

1. **确认摄像头 IO**：查 200Pro+ FMC VADJ；若为 3.3 V，把 `cmos2_*`
   的 `PAP_IO_VCCIO/STANDARD` 改成 `3.3/LVCMOS33` 做对照。
2. **输入时序对照**：`build_cam_nodelay` 结果；必要时恢复 2.0 ns 或试
   `cmos_8_16bit`（官方）替代 `video_dvp_rgb565`，只改数据配对，不改 framebuf。
3. **HDMI 720p60**：若抖动仍在，改 `clk_pix`/`sync_vg`/PLL，验证 4K 显示器。
4. **`cap_x` 清零**：若还要用注入条做回归，改成 `!pixel_de` 清零。
5. **回归**：每次改 RTL 后先跑 BIST（`I=1/G=0`），再跑 S2（`D=1/B=1`）；
   记录状态行和截图。

---

## 8. 复现命令

构建（Windows，PDS）：

```bat
cd C:\Users\BlossilveR\code\ares-video-s2-fb\fpga\pango
set PANGO_LICENSE_FILE=D:\PDS_2022.2-SP6.4\LICENSE\new_pds_4c23380ca8a1.lic

:: BIST（1000 Mbps，seed 2）
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_bist.tcl -project_name video_bist

:: S2（1000 Mbps，vendor DRM，seed 5）
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_fb.tcl -project_name video_fb
```

烧写：

```bat
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl ^
  -args {<...>\generate_bitstream\video_fb_top.sbit}
```

UART：`COM5`，115200 8N1。BIST 行以 `BIST` 开头，S2 行以 `S2` 开头。

> 仓库路径与 Windows 构建目录是两份拷贝；当前位流在
> `C:\Users\BlossilveR\code\ares-video-s2-fb\fpga\pango\generate_bitstream\`。
> 仓库只保留源码/约束/流程，不提交 `.sbit`。

---

## 9. 仓库同步状态（本次整理后）

- `rtl/video/video_fb_top.v`：S2 顶层；vendor DRM；`wlast`；`ext_de`；
  **读侧不闸**；`M/N` 中 `N` 改在 `fb_vout_de` 采样；`INJECT_PATTERN` 默认 0。
- `rtl/video/video_hdmi_wrap.v`：`USE_EXT_DE`/`ext_de`（S0/S1 默认 0）。
- `rtl/video/video_dvp_rgb565.v` / `video_capture_wrap.v`：DVP 配对 + 输入寄存器。
- `rtl/video/legacy/`：vendor framebuf/hdmi/i2c 原样；含
  `wr_fram_buf.v`/`rd_fram_buf.v`/`ipm2l_sdpram_v1_10_*.v`。
- `rtl/video/alt/video_dpram.v`：推断 RAM，仅仿真/对照。
- `rtl/video/archive/`：S0/preview 顶层与 TB。
- `fpga/pango/flow_bist.tcl`：官方 2_9 / 1000 Mbps / seed 2。
- `fpga/pango/flow_video_fb.tcl`：官方 2_9 / 1000 Mbps / vendor DRM / seed 5。
- `fpga/pango/official_ddr3.fdc`：官方 2_9 FDC 子集。
- `fpga/pango/ip/ddr3/ddr3_test`：官方 2_9 IP（`DEVICE_100H_EN=false`）。
- `fpga/pango/ip/ddr3/archive_100h_600m`：旧 100H/600 IP/FDC/PHY 摆放。
- `fpga/pango/archive/`：S0/S1/preview 流程 + `PREVIEW_DEBUG.md`。
- 传感器彩条补丁只存在于构建工程 `ares-video-s2-fb/rtl/video/legacy/reg_config.v`
  （`356: 0x503D80`）；仓库保持原厂 register 表。

---

## 10. framebuf 仿真结果（2026-10-28）

测试平台：`rtl/video/test/tb_fram_buf.sv`
实例化 vendor `fram_buf` + `alt/video_dpram.v` + 1M/8M 字 AXI slave；
`H=1280`、`V=720`、`PIX_WIDTH=16`。

| 测试 | 结果 |
| --- | --- |
| 写/读纯色 `0xF800` | `rd_pixels=496846`，`bad=0`，**PASS** |
| 写/读 x 图案 `{4'hA,x[7:0],4'h5}` | `rd_pixels=496846`，`bad=971`（0.2%，集中在开头读缓冲/检查起点），主体正确 |

AXI 活动：`aw=16215`、`w=259440`、`ar=11617`、`r=185867`；
`mem[0x400000]=f800f800`/`a015a005`，说明写地址、帧位、行步进、256-bit 打包都正确。

**结论：framebuf 的地址/多 burst/行缓冲/DPRAM 映射本身没有问题。**

复现：

```bash
verilator --binary --timing -Irtl/video \
  --top-module tb_fram_buf_pat rtl/video/test/tb_fram_buf.sv \
  rtl/video/alt/video_dpram.v \
  rtl/video/legacy/{fram_buf,wr_buf,rd_buf,wr_ctrl,rd_ctrl,wr_cmd_trans,wr_rd_ctrl_top}.v
./obj_dir/tb_fram_buf_pat
```

---

## 11. 官方 4_12 视频工程（备用参考）

`2_Demo/4_12_HDMI_IN_DDR3_HDMI_OUT` 是同一块 200Pro 的 HDMI-in → DDR3 →
HDMI-out 视频工程：

- `ipcore/ddr3_test` 使用 `DEVICE_100H_EN=true`、1000 Mbps；
- `device_map/hdmi_ddr_ov5640_top.pcf` 里 PHY CPD 是 `369_466`；
- 顶层是 HDMI 输入，不是摄像头，但 framebuf/HDMI 输出链路与 S2 同源。

当前 S2 用 2_9 的 `false` + `729_772` 已经出场景；如果后面 DDR3 数据/时序
还有问题，可以再对照 4_12 的 IP/FDC/CPD 做一版，但不要同时改多个变量。

---

## 12. S2 成功（2026-10-28）

**最终位流**：`/mnt/c/Users/BlossilveR/code/ares-video-s2-fb/fpga/pango/generate_bitstream/video_fb_top.sbit`
（13:35，`All Constraints Met`）。
**最终画面**：`picture8.jpg`，OV5640 → DDR3 双缓冲 → HDMI，干净、无彩色横条、无抖动。

### 12.1 最终配置

| 项 | 值 |
| --- | --- |
| DDR3 IP | 官方 200Pro `2_9` `ddr3_test`，1000 Mbps，`DEVICE_100H_EN=false` |
| DDR3 约束 | `official_ddr3.fdc`（2_9 官方，CPD `729_772`） |
| DDR3 引脚 | 2_9 原始 DQ 顺序（无 DQ24..31 反转） |
| framebuf | vendor `wr_fram_buf`/`rd_fram_buf` + `ipm2l_sdpram`（DRM） |
| 相机拼接 | `video_dvp_rgb565`（HREF 低电平复位字节相位） |
| HDMI DE | `USE_EXT_DE=1`，framebuf `vout_de` |
| AXI | `axi_wlast = axi_wusero_last` |
| 读侧 | 不 gate `rd_en`/`rd_fsync`（vendor 顶层行为） |
| 时序 | 无 `set_input_delay`/`set_output_delay`（与官方 100H 相机工程一致） |
| 相机 IO | 2.5 V / LVCMOS25（200Pro+ J24=2V5，J13 正确） |
| PnR | `seed 5` |
| 注入 | `INJECT_PATTERN=0` |

### 12.2 根因

1. **J13 跳线帽位置错误**（物理）→ 摄像头 DVP 数据位错误、彩色横条、且随温度/时间加重；改正后 picture8 干净。
2. **DDR3 IP 用了 100H 配置**（`DEVICE_100H_EN=true`）+ DQ3 反转 → 官方 200Pro `false` + 原始 DQ 顺序；官方 `2_9` BIST 1000 Mbps `I=1 F=0 A=0 G=0 D=1 E=0 C=0`。
3. **vendor `cmos_8_16bit` 字节相位 bug**（`cnt` 不随 HREF 复位）→ `video_dvp_rgb565` 的 HREF 相位复位；picture7（vendor 原版）整行颜色翻转，picture5（我们的版本）仅细横条，证明相位逻辑有效。
4. **800 Mbps 重新生成的 IP 反而更差**（PLL/PHY 配置不匹配）→ 回到 1000 Mbps。
5. 读闸门 / 2.0 ns input/output delay → 去掉。

### 12.3 隔离证据

- `INJECT_PATTERN=1` 纯色竖条：画面干净 → framebuf/DDR3/HDMI 数据通路正常。
- 100H `cmos_8_16bit`：整行颜色翻转 → 字节相位问题，不是 DDR3。
- 官方 `2_9` BIST 1000 Mbps：`I=1`，`P` 持续增长，`C=0`。

### 12.4 下一步

S2 standalone 目标完成；下一步接 SoC（视频流/寄存器接口）。
