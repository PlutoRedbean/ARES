# fpga/pango — 盘古 200Pro+ / PG2L200H-6IFBB676

> 本文件说明**现在怎么用**这套视频/DDR3 工程。
> 调试过程、被推翻的早期结论和完整时间线在 [TEST_LOG.md](TEST_LOG.md)；
> S2 的详细记录在 [S2_DEBUG.md](S2_DEBUG.md)。以本文件的当前基线为准。
>
> 器件：`PG2L200H-6IFBB676`，PDS 2022.2-SP6.4；只能用 `synthesize -ads`
>（PDS 自带 Synplify 无 license）。Verilog-2001。

---

## 0. 当前可用基线（TL;DR）

| 项 | 值 |
| --- | --- |
| DDR3 速率 | **1000 Mbps，已上板验证**（官方 200Pro 2_9 IP） |
| DDR3 IP | `ip/ddr3/ddr3_test`（官方 2_9 精简版：`DEVICE_100H_EN=false`，`DFI_CLK_PERIOD=8000`） |
| DDR3 约束 | `official_ddr3.fdc`（官方 2_9 `pnr/ddr_test.fdc` 的引脚/时钟/CPD/multicycle 子集） |
| PHY 摆放 | **不再手工追加**：官方 IP + FDC 自动摆放，1000 Mbps 时序 All Constraints Met |
| 顶层实例名 | **`ddr3_test I_ips_ddr_top`**（必须） |
| 参考时钟 | `ref_clk_p=N3`、`ref_clk_n=N2`，125 MHz 差分 |
| BIST 流程 | `flow_bist.tcl`（seed 2） |
| S2 流程 | `flow_video_fb.tcl`（摄像头 → DDR3 双缓冲 → HDMI 720p30，独立运行，不接 SoC；seed 5） |
| BIST 结果 | 1000 Mbps：`I=1 F=0 A=0 G=0 D=1 E=0 C=0`，`P` 持续增长，30 s 0 错 |
| S2 结果 | `D=1 B=1`，摄像头白天场景可见；纯色竖条注入时 framebuf/DDR3/HDMI 数据干净 |

**不要再用 100H/600 Mbps 的旧方案。** 旧 IP（`DEVICE_100H_EN=true`）在 200Pro+ 上
1000 Mbps 静态时序为负、800 Mbps init 随 PnR 翻转，只能退到 600 Mbps。官方 2_9
的 `DEVICE_100H_EN=false` 是这块板的正解。旧文件全部在
`ip/ddr3/archive_100h_600m/`（见该目录 README）。

---

## 1. 复用 DDR3：最小步骤

### 1.1 文件

```text
ip/ddr3/
├── ddr3_test/                 # 官方 2_9 IP（1000 Mbps，DEVICE_100H_EN=false）
│   ├── ddr3_test.idf
│   ├── rtl/                   # 加密 .vp + ddrphy
│   ├── ddr3_test.v / ddr3_test_ddrphy_top.v
│   └── pnr/ddr_test.fdc       # 官方 FDC 源（实际使用 ../../official_ddr3.fdc）
├── archive_100h_600m/         # 旧 100H/600 Mbps（不要用）
└── README.md
```

`official_ddr3.fdc` 在 `fpga/pango/` 下，是官方 `pnr/ddr_test.fdc` 去掉示例
`free_clk`/UART/LED 后的引脚/时钟/CPD/multicycle 子集。

### 1.2 顶层例化（名字不能改）

```verilog
wire ref_clk_125m;
GTP_INBUFGDS u_refclk_buf (
    .O  (ref_clk_125m),
    .I  (ref_clk_p),
    .IB (ref_clk_n)
);

ddr3_test I_ips_ddr_top (
    .ref_clk            (ref_clk_125m),
    .resetn             (phy_rstn),        // 低有效，见 §3
    .core_clk           (ddr_core_clk),
    .ddr_init_done      (ddr_init_done),
    ...
);
```

**两个硬性名字**：

1. 实例必须叫 **`I_ips_ddr_top`**，且必须是顶层直接子实例；`official_ddr3.fdc`
   里的 `i:I_ips_ddr_top...` 是绝对路径。
2. 参考时钟端口必须叫 **`ref_clk_p` / `ref_clk_n`**。

### 1.3 约束顺序

官方 FDC 自带 CPD/PHY 约束，**不需要**在 `dev_map` 后追加 PHY 摆放 PCF：

```tcl
set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# 先加 IP fdc：它创建 ddrphy_sysclk，后面的 CDC 约束会引用它
add_constraint [file join $here "official_ddr3.fdc"]
add_constraint [file join $here "video_top.fdc"]   ;# BIST 用 bist_top.fdc
add_constraint [file join $here "video_fb.fdc"]    ;# 仅 S2

# ... add_design / compile / synthesize ...
dev_map
pnr -seed 5                                         ;# BIST 用 seed 2
report_timing -max_path 20
gen_bit_stream -create_bit true
```

`flow_bist.tcl` 和 `flow_video_fb.tcl` 已经是这个写法。

> 旧方案（把 `ddr3_phy_place_2255_in.pcf` 在 `dev_map` 后追加到工程 PCF）是
> 100H/600 Mbps 时代的 workaround，已不再使用；文件在
> `ip/ddr3/archive_100h_600m/`。

---

## 2. AXI 约定（重要）

Pango HMIC_S IP 是**裁剪过的 AXI**，不是标准 AXI4：

| 项 | 约定 |
| --- | --- |
| 数据位宽 | 256 bit（32 个 32-bit 字） |
| 地址 | 28 bit，**32-bit 字地址**，不是字节地址 |
| burst | 固定 16-beat INCR，`axi_awlen = 4'd15` |
| 写响应 | **没有** `bvalid/bresp`；`axi_bready` 不需要 |
| `axi_wlast` | 由 IP 的 `axi_wusero_last` 驱动（vendor 顶层就是这么接） |
| `axi_rready` | framebuf 内部给；读数据 `rdata[255:0]` + `rvalid/rlast` |
| `awid/arid` | IP 使用 4-bit；framebuf 给 0 |

framebuf 的 `wr_rd_ctrl_top` 就是按这套 vendor 约定写的；标准 AXI 主设备不能直接接。

---

## 3. 时钟、复位、初始化

| 域 | 时钟 | 说明 |
| --- | --- | --- |
| `ref_clk` | 125 MHz differential | `ref_clk_p=N3` / `ref_clk_n=N2` |
| `ddr_core_clk` | IP 输出 | 1000 Mbps 配置 |
| `clk_pix` | 37.125 MHz | HDMI 720p30，PLL 27×11/8 |
| `pixel_clk` | 42 MHz | OV5640 PCLK 84 / 2 |
| `clk_cam` | 24.75 MHz | SCCB 配置 |
| `clk_cfg` | 10 MHz | 状态/配置 |
| `clk_27m` | 27 MHz | 系统输入 |

- `ddr_rstn = ddr_init_done`；`phy_rstn` 由 `video_clk_reset` 产生。
- `apb_clk=0 / apb_rst_n=1` 已验证可用；APB 不是 init 必需。
- INI 失败时顶层有可选 `dbg_ddrphy_rst_n` 重试；不是当前 S2 的必要条件。
- 改 RTL/约束后重新确认 `S2 ... D=1` 或 BIST `I=1`。

---

## 4. 速率与 IP 重新生成

当前 `ip/ddr3/ddr3_test` 是官方 2_9 的 **1000 Mbps** 配置：

```text
ACTUAL_RATE        = 1000.000
DESIRED_DDR3_RATE  = 1000.000
DFI_CLK_PERIOD     = 8000       # 速率/8，单位 ps
DEVICE_100H_EN     = false      # 200H PHY 配置，关键
```

要改速率时，改上面几个字段，然后用 IP Generator 重新生成：

```bat
D:\PDS_2022.2-SP6.4\bin\ip_generate.exe ^
  -i C:\...\ip\ddr3\ddr3_test\ddr3_test.idf -ads
```

**必须保持 `DEVICE_100H_EN=false`。** 生成后检查
`ddr3_test_ddrphy_top.v` 里的 `DFI_CLK_PERIOD`，并重新跑 BIST。

---

## 5. 约束 / PHY 摆放

官方 2_9 IP 的 FDC 已经包含：

- `ref_clk` 8.0 ns、`ddrphy_sysclk` / `phy_dq_sysclk_*`、`set_multicycle_path`；
- `DDRPHY_CPD_729_772` + 两个 `ddrphy_ioclk_gate` 的 `PAP_LOC`；
- 全部 DDR3 引脚（`mem_dq[31:0]`、`mem_dqs*`、`mem_ck`、`mem_addr/ba/cs/ras/cas/we/odt`）。

`official_ddr3.fdc` 是上述内容的可综合子集（删掉示例 `free_clk`/UART/LED）。
用官方 IP + 这份 FDC，BIST（seed 2）和 S2（seed 5）都能在 1000 Mbps 达到
**All Constraints Met**，`D=1`。

**DQ 顺序**：官方 200Pro 2_9 使用原始顺序（`mem_dq[24]=F2 ... mem_dq[31]=C2`）。
旧 100H 工程的 `DQ24↔31` 反转是 100H PHY 配置下的 workaround，不要套回来。

**PnR seed**：BIST 用 `seed 2`，S2 用 `seed 5`。这是当前已验证的
`D=1` 组合；换 RTL 后仍建议重新确认 `D=1`。

**官方 4_12 视频工程**（`4_12_HDMI_IN_DDR3_HDMI_OUT`）在同一块 200Pro 上使用
`DEVICE_100H_EN=true` + PHY CPD `369_466`，是 HDMI-in→DDR3→HDMI-out 的完整
视频参考。当前 S2 用 2_9 的 `false` + `729_772` 已经出图；如果后面 DDR3
数据/时序还有问题，可以再对照 4_12 的 IP/CPD。

---

## 6. BIST：上板确认 DDR3 是否真的通过

流程：

```bat
cd fpga\pango
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_bist.tcl -project_name video_bist
```

烧写后 UART（115200 8N1，`uart_tx` C24）每 ~0.5 s 输出：

```text
BIST I=1 F=0 A=0 G=0 D=1 E=0 P=00000435 C=00000000 X=0000000 B=0 Y=00000000 Z=00000000
```

| 字段 | 含义 | 通过值 |
| --- | --- | --- |
| `I` | `ddr_init_done` | 1 |
| `F` | `dbg_ddrphy_init_fail` | 0 |
| `A` | `align_error` | 0 |
| `G` | `dbg_error_status`（0 无错，1 write leveling，2 read pattern，3 gate，4 read training，5 write training，6 eye） | 0 |
| `D` | BIST 至少完成一轮 | 1 |
| `E` | BIST 错误（锁存） | 0 |
| `P` | 完成轮数 | 持续增长 |
| `C` | 错误 beat 数 | 0 |
| `X` | 首错 32-bit 字地址 | 0（无错时） |
| `B` | 首错 burst 内 beat | 0 |
| `Y/Z` | 首错 beat 的 expected/actual 低 32 位 | 0 |

**2026-10-28 结果（官方 2_9 / 1000 Mbps / seed 2）**：

- `I=1 F=0 A=0 G=0 D=1 E=0 C=0`；
- 30 s 连续读取 `P` 0x34B → 0x493，0 错误；
- 连续重烧两次均 `I=1`；时序 All Constraints Met。

BIST 是两阶段：先写完整 8 MiB（2 × 4 MiB，地址 0 和 0x0040_0000 word），
drain 16384 周期，再整体读回比较；四种数据图案轮换。**不要改回“一个 burst
写完立刻读”**，那会受 IP 内部写读顺序影响，出现假错/假过。

LED（BIST 顶层）：

```text
led[0] 心跳   led[1] 系统 PLL   led[2] DDR3 PLL   led[3] cpd_lock
led[4] init_done   led[5] init_fail   led[6] BIST error   led[7] BIST pass
```

> 旧的 100H/600 Mbps 结果（2720 轮 0 错）保留在
> [TEST_LOG.md](TEST_LOG.md) 和 `ip/ddr3/archive_100h_600m/`，只作历史对照。

---

## 7. S2：摄像头 → DDR3 双缓冲 → HDMI

顶层：`rtl/video/video_fb_top.v`；流程：`flow_video_fb.tcl`。

- **摄像头**：`video_capture_wrap` + `video_dvp_rgb565`（CMOS2 / J2；OV5640
  RGB565；PCLK 84 → pixel_clk 42）。
- **双缓冲**：`legacy/fram_buf.v` + `wr_buf`/`rd_buf` +
  **vendor `wr_fram_buf`/`rd_fram_buf`（`GTP_DRM36K_E1` SDPRAM）**。
  `rtl/video/alt/video_dpram.v` 是推断 RAM，只用于仿真/对照，不进入当前综合流程。
- **HDMI**：`video_hdmi_wrap` + `ms7210_ctl`，720p30（37.125 MHz）；
  `USE_EXT_DE=1`，用 framebuf 的 `vout_de` 作输出 DE。
- **DDR3**：官方 2_9 IP，1000 Mbps。
- **读侧**：与 vendor `hdmi_ddr_ov5640_top` 一致，`rd_en = sync_vg.de_re`、
  `rd_fsync = sync_vg.vs_out`，**不再用 `fb_init_done` 闸门**；首帧可能是
  未写区域，之后由双缓冲接管。
- **写侧**：`axi_wlast` 由 IP 的 `axi_wusero_last` 驱动。

状态 UART（115200 8N1，~0.5 s 一行）：

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
| `N` | framebuf 读回 (640,360) 的 RGB565（在 `fb_vout_de` 有效时采样） |
| `V/L/X` | 采集 vsync / line / pixel 计数 |

### 7.1 当前结果

| 项目 | 状态 |
| --- | --- |
| DDR3 1000 Mbps BIST | ✅ 30 s 0 错，`G=0` |
| S2 DDR3 init | ✅ `D=1`（seed 5；官方 IP/FDC） |
| 摄像头 SCCB / DVP | ✅ `C=1`，`M` 随场景变化 |
| HDMI init / 720p30 | ✅ `H=1` |
| framebuf 首帧写入 | ✅ `B=1` |
| framebuf 读回 | ✅ 白天场景可见 |
| **纯色竖条注入** | ✅ **4 条红/绿/蓝/白干净**（framebuf/DDR3/HDMI 数据通路正确） |
| 剩余问题 | ⚠️ 摄像头数据有随机彩色横条；画面边缘/整屏有轻微抖动 |

### 7.2 隔离测试：`INJECT_PATTERN`

`video_fb_top.v` 里 `INJECT_PATTERN=1` 时，写侧数据改成 4 条 320 px 竖条
（红/绿/蓝/白），摄像头只提供 `pixel_de`/`pixel_vsync` 时序。结果：

- 竖条干净 → **framebuf / DDR3 / HDMI 读写数据正确**；
- 竖条上仍有噪声横条 → framebuf/DDR3 行读写问题。

2026-10-28 实测：竖条干净（`N=07E0` 稳定在绿条），因此彩色横条来自
**摄像头 DVP 数据**，不是 DDR3/framebuf 读回。竖条边缘有轻微波浪/抖动，
是注入用 `cap_x` 的逐行计数（以及 720p30 在 4K 显示器上的缩放）造成，
**不代表摄像头画面本身**。

### 7.3 摄像头横条与画面抖动（下一步）

1. **摄像头 DVP 数据**：S2 的 `video_top.fdc` 相机 IO 是 **2.5 V / LVCMOS25**
   （200Pro+ FMC），而官方 100H 相机工程是 **3.3 V / LVCMOS33**。两者是同一
   FMC 相机卡、不同核心板 VADJ。若横条仍在，先确认 200Pro+ FMC 的实际
   VADJ，再决定是否改成与官方一致的 3.3 V。
2. **输入时序**：S2 原来加过 `set_input_delay 2.0` / `set_output_delay 2.0`，
   官方 100H 相机工程没有。当前 `video_top.fdc` 已注释掉这两条（最新实验
   `build_cam_nodelay`），上板结果待确认。若横条仍在，下一步回到
   2.0 ns 或尝试 `cmos_8_16bit` + 官方输入寄存器结构做对照。
3. **HDMI 720p30**：官方 demo 也是 720p30，但 4K 显示器对 720p30 的缩放/
   FreeSync 可能造成边缘抖动。若需要，可改 720p60（`clk_pix` 74.25 MHz，
   H/V total 按 CEA-861），代价是 framebuf 读侧 60 Hz、DDR3 读带宽翻倍。
4. **`cap_x` 波浪**：仅注入测试使用；如需更干净的测试条，把 `cap_x` 改成
   在 `!pixel_de` 时清零，而不是只在 `cap_x==1279` 回零。

---

## 8. 目录

```text
fpga/pango/
├── README.md                 # 本文件（当前基线）
├── S2_DEBUG.md               # S2 详细调试记录
├── TEST_LOG.md               # S0/S1/DDR3 BIST/S2 历史时间线
├── flow_bist.tcl             # DDR3 BIST（官方 2_9 / 1000 Mbps / seed 2）
├── flow_video_fb.tcl         # S2 摄像头→DDR3→HDMI（官方 2_9 / seed 5）
├── official_ddr3.fdc         # 官方 2_9 FDC 的引脚/时钟/CPD/multicycle 子集
├── video_top.fdc             # S2 板级引脚/时钟（相机/HDMI/PLL/CDC）
├── video_fb.fdc              # S2 pixel_clk / CDC 约束
├── bist_top.fdc              # BIST 顶层 LED/UART
├── program.tcl               # JTAG 烧写
├── archive/                  # S0/S1/preview 流程 + PREVIEW_DEBUG（历史）
└── ip/ddr3/
    ├── ddr3_test/            # 官方 2_9 IP（1000 Mbps，DEVICE_100H_EN=false）
    ├── archive_100h_600m/    # 旧 100H/600 Mbps（不要用）
    └── README.md

rtl/video/
├── video_fb_top.v            # S2 顶层
├── video_bist_top.v          # DDR3 BIST 顶层
├── video_capture_wrap.v      # OV5640 SCCB + DVP 8→16
├── video_dvp_rgb565.v        # DVP 字节配对 + 3 级流水
├── video_hdmi_wrap.v         # sync_vg + MS7210（720p30，USE_EXT_DE）
├── video_clk_reset.v / video_ip_pll.v
├── video_fb_status.v / video_bist_status.v / video_ddr3_bist.v
├── video_pattern_gen.v
├── video_defs.vh
├── legacy/                   # vendor framebuf/hdmi/i2c 原样（见 legacy/README.md）
├── alt/video_dpram.v         # 推断 RAM，仅仿真/对照
├── archive/                  # S0 / preview 顶层与 TB（历史）
├── sim/                      # PLL/IOCLKDIV 行为模型
└── test/                     # tb_fram_buf / tb_video_capture / tb_video_dvp_pair
```

---

## 9. 已知坑（按优先级）

1. **必须用官方 2_9 IP（`DEVICE_100H_EN=false`）**。旧 100H IP
   （`DEVICE_100H_EN=true`）在 200Pro+ 上 1000 Mbps 时序不收敛，800 Mbps
   init 随 PnR 翻转。旧 FDC 的 DQ3 反转也只适用于旧 IP。
2. **不要再用 `ddr3_phy_place_2255_in.pcf`**。官方 2_9 FDC 的 CPD + 自动摆放
   已经能在 1000 Mbps 过时序；旧 3356 实例摆放是 100H/600 的 workaround。
3. **摄像头 IO 电平/时序**：S2 是 2.5 V / LVCMOS25，官方 100H 相机工程是
   3.3 V / LVCMOS33。先确认 200Pro+ FMC 的 VADJ；不要直接把 3.3 V 套到
   2.5 V bank。
4. **`set_input_delay`/`set_output_delay`**：S2 原加 2.0 ns，官方 100H
   工程没有；当前实验已注释，结果待确认。
5. **HDMI 720p30 + 4K 显示器**：可能出现边缘轻微抖动/缩放波纹；需要时
   改 720p60。
6. **`INJECT_PATTERN` 的 `cap_x`**：逐行计数波浪只影响测试条，不代表
   摄像头画面。
7. **`N` 采样**：`video_fb_top` 现在在 `fb_vout_de` 有效时采样；早期在
   `hdmi_rd_en` 采样会偏早 2 拍，不能据此判断读回错误。
8. **`dev_map` 覆盖 PCF**：如果以后还要手工追加摆放，必须在 `dev_map` 后、
   `pnr` 前追加；直接 `add_constraint` 无效（`Public-4010`）。
9. **`ConstraintEditor-2002` share-pin**：DDR3 引脚的 share-pin 提示，不是
   错误；不要据此改引脚。
10. **`SCBV has not been set`**：200H 可忽略（只对 100H/390H）。
11. **没有 `bvalid/bresp`**：标准 AXI 主设备不能直接接；用原生 256-bit
    接口或 vendor `wr_rd_ctrl_top` 约定。
12. **改 RTL 后重新确认 `I=1` / `D=1`**：即使官方 IP 也要跑一遍；报告里
    始终附 BIST/S2 状态行。

---

## 10. 相关文档 / 资料

- [S2_DEBUG.md](S2_DEBUG.md)：S2 详细调试记录、当前位流、隔离测试、下一步。
- [TEST_LOG.md](TEST_LOG.md)：S0/S1/DDR3 BIST/S2 的历史时间线（含被推翻的结论）。
- [archive/README.md](archive/README.md)：S0/S1/preview 历史流程。
- [ip/ddr3/README.md](ip/ddr3/README.md)：官方 2_9 IP、FDC、重新生成。
- [ip/ddr3/archive_100h_600m/README.md](ip/ddr3/archive_100h_600m/README.md)：旧 100H/600 方案。
- `rtl/video/README.md`：RTL 模块、仿真、lint、S2/BIST 入口。
- `rtl/video/legacy/README.md`：vendor framebuf/hdmi/i2c 原样说明。
- `rtl/video/alt/README.md`：`video_dpram` 推断 RAM（仅仿真/对照）。
- `rtl/video/archive/README.md`：S0/preview RTL 归档。
- `docs/video_subsystem_v1_design.md`：整体设计、阶段、CDC、地址规划。
- 官方资料：`D:\BlossilveR\Download\200pro`（2_9 DDR3、4_12 HDMI→DDR3→HDMI、
  8_MES-FMC-LPC-IO 相机 demo、硬件/原理图）。
- `HMIC_S_P_User_guide.pdf`（UG042003 V1.14）：IP 端口、`dbg_error_status`、
  `dbg_slice_status` 定义。

---

## 11. 快速开始

```bat
:: BIST
cd fpga\pango
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_bist.tcl -project_name video_bist
:: 烧 generate_bitstream\video_bist_top.sbit，UART 115200 COM5
:: 期望 I=1 F=0 A=0 G=0 D=1 E=0 C=0，P 增长

:: S2
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_fb.tcl -project_name video_fb
:: 烧 generate_bitstream\video_fb_top.sbit，HDMI 接 720p 显示器
:: 期望 S2 P=1 D=1 H=1 C=1 B=1
```

烧写用 `program.tcl` + `cdt_cfg.exe`（见 `S2_DEBUG.md` §8）。

## 12. S2 成功（2026-10-28）

S2（OV5640 → DDR3 双缓冲 → HDMI）已跑通，最终画面见
`/mnt/c/Users/BlossilveR/code/ares-video-s2-fb/fpga/pango/picture8.jpg`
（干净，无彩色横条/抖动）。

最终配置：官方 200Pro `2_9` DDR3 IP（1000 Mbps，`DEVICE_100H_EN=false`，
原始 DQ 顺序）、`official_ddr3.fdc`（CPD `729_772`）、vendor
`wr_fram_buf`/`rd_fram_buf` SDPRAM、`video_dvp_rgb565`（HREF 相位复位）、
`USE_EXT_DE=1`、`axi_wlast=axi_wusero_last`、无读闸门、无
`set_input_delay`/`set_output_delay`、相机 2.5 V、`seed 5`、
`INJECT_PATTERN=0`。

根因：

1. **J13 跳线帽位置错误**（物理）→ DVP 数据位错误、彩色横条、越用越严重；
2. **DDR3 用了 100H 配置**（`DEVICE_100H_EN=true`）+ DQ3 反转 → 官方
   200Pro `false` + 原始 DQ 顺序；
3. **vendor `cmos_8_16bit` 字节相位 bug** → `video_dvp_rgb565` HREF 复位；
4. 800 Mbps 重新生成 IP 更差 → 回到 1000；
5. 读闸门 / 2.0 ns input/output delay → 去掉。

隔离证据：`INJECT_PATTERN=1` 纯色竖条干净 → framebuf/DDR3/HDMI 正常；
100H `cmos_8_16bit` 整行颜色翻转 → 相位问题；官方 `2_9` BIST 1000 Mbps
`I=1/G=0/C=0`。

下一步：S2 standalone 完成，接 SoC。
