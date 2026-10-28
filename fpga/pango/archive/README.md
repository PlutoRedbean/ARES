# fpga/pango/archive — S0 / S1 / preview 历史流程

这里的文件是早期阶段（S0 彩条 → S1 采集计数 → 摄像头 preview 直出 HDMI）的流程和
文档，**不是当前 S2 的构建入口**。保留它们是为了让队友能复现早期结果和对照调试过程。

| 文件 | 阶段 | 说明 |
| --- | --- | --- |
| `flow_video.tcl` | S0 | 彩条/棋盘 → HDMI |
| `flow_video_s0.tcl` | S0 | S0 + 早期 DDR3 引脚表 |
| `flow_video_capture.tcl` | S1 | OV5640 I2C + DVP，只做计数 |
| `flow_video_preview.tcl` | preview | 摄像头直出 HDMI（640×360 BRAM，不经 DDR3） |
| `ddr3_pins_s0.fdc` | S0 | 早期 DDR3 引脚约束 |
| `video_preview.fdc` | preview | preview 专用时钟/CDC |
| `PREVIEW_DEBUG.md` | preview | 摄像头直出调试记录 |

**当前入口**：

- DDR3 BIST：`../flow_bist.tcl`
- S2 摄像头 → DDR3 双缓冲 → HDMI：`../flow_video_fb.tcl`
- 历史调试全过程：`../TEST_LOG.md`、`../S2_DEBUG.md`
- RTL 归档（S0/preview 顶层）：`../../rtl/video/archive/`

S0/preview 流程使用旧的 100H/600 Mbps IP，已归档到
`../ip/ddr3/archive_100h_600m/`；当前 S2/BIST 使用官方 200Pro 2_9 IP（1000 Mbps，
`DEVICE_100H_EN=false`）和 `../official_ddr3.fdc`。
