# rtl/video/archive — S0 / preview 历史 RTL

早期 S0/preview 顶层和它们的 testbench。当前 S2/BIST 不实例化这些文件。

| 文件 | 阶段 | 说明 |
| --- | --- | --- |
| `video_top.v` | S0 | 彩条/棋盘/移动块 → HDMI 板级顶层 |
| `video_status.v` | S0 | 8 LED + 115200 状态 UART |
| `video_cam_preview_top.v` | preview | 摄像头 → 640×360 BRAM → HDMI（不经 DDR3） |
| `tb_video_top.v` | S0 | S0 顶层 TB |
| `tb_video_preview.v` | preview | preview 全链路 TB |

**当前入口**：

- S2：`../video_fb_top.v`（+ `../video_fb_status.v`）
- BIST：`../video_bist_top.v`（+ `../video_ddr3_bist.v` / `../video_bist_status.v`）
- RTL 说明：`../README.md`
- 历史流程：`../../fpga/pango/archive/`、`../../fpga/pango/archive/PREVIEW_DEBUG.md`

`video_top.v` 的板级引脚仍在 `../../fpga/pango/video_top.fdc` 中，但当前 S2 顶层是
`video_fb_top.v`，不要把它当 S0 使用。
