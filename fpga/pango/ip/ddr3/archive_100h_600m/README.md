# archive_100h_600m — 旧 100H / 600 Mbps DDR3 IP（不要用于当前 S2/BIST）

这里是 2026-10-28 之前使用的旧 DDR3 方案，**已被官方 200Pro 2_9 IP 取代**。
保留仅供复现早期 S0/S1 结果和对照调试记录。

| 文件 | 说明 |
| --- | --- |
| `ddr3_test/` | 100H 版 IP：`DEVICE_100H_EN=true`，600 Mbps（`DFI_CLK_PERIOD=13333`，CL6/CWL5） |
| `ddr3_ip.fdc` | 旧 IP 的时钟/PHY/引脚约束（100H 引脚表、DQ3 反转） |
| `ddr3_place.pcf` / `.after_build` | 旧工程的占位/构建后 PCF |
| `ddr3_phy_place_2255_in.pcf` | 22:55 位流冻结的 PHY 摆放（3356 + 6 实例） |
| `ddr3_ports.csv` | 旧引脚表 |

## 为什么不再用

- **`DEVICE_100H_EN=true` 是 100H PHY 配置**，200Pro+ 应使用官方 2_9 的
  `DEVICE_100H_EN=false`。旧配置在 1000 Mbps 下静态时序为负（−4 ns），
  在 800 Mbps 下 init 随 PnR 翻转，只能退到 600 Mbps。
- 旧方案依赖把 `ddr3_phy_place_2255_in.pcf` 在 `dev_map` 后追加到工程 PCF，
  对 seed/网表变化敏感。
- 官方 2_9 IP 1000 Mbps + `official_ddr3.fdc` 即可做到：
  BIST `I=1/G=0/E=0`，时序 All Constraints Ready；S2 `D=1`、画面出来。
- 旧 FDC 还包含 DQ3（`DQ24..31`）反转；官方 200Pro 2_9 使用原始顺序，无需反转。

## 当前使用

- IP：`../ddr3_test/`（官方 2_9，1000 Mbps，`DEVICE_100H_EN=false`）
- 约束：`../../official_ddr3.fdc`
- BIST：`../../flow_bist.tcl`
- S2：`../../flow_video_fb.tcl`

历史判断和上板结果见 `../../TEST_LOG.md`、`../../S2_DEBUG.md`。
