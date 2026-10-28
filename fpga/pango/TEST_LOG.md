# fpga/pango 测试日志（历史记录）

> 本文件保留原始 bring-up / 调试记录（S0、S1、DDR3 BIST、摄像头 preview 等），
> 按时间顺序记录当时的判断和结果。**当前使用说明见 [README.md](README.md)。**
> 部分早期结论后来被推翻（例如 22:55 的 “BIST error=0” 并不代表读写通过），
> 以 README 和本文件后面的 §12 为准。

# fpga/pango — 盘古 200Pro+ 视频工程

> 目标：`PG2L200H-6IFBB676`（FBB676，-6），PDS 2022.2-SP6.4。  
> 设计：`docs/video_subsystem_v1_design.md`。  
> 工具链限制：PDS 自带 Synplify **没有 license**，只能 `synthesize -ads`。

---

## 1. 目录

```text
fpga/pango/
├── README.md
├── video_top.fdc          // 板级引脚 + 时钟（不含 DDR3）
├── flow_video.tcl         // PDS 全流程
├── program.tcl            // JTAG 烧写（从 5-stage-baseline 复制）
└── ip/ddr3/               // 从 5-stage-baseline 复制
    ├── ddr3_test/         // .idf + 生成 RTL + 加密 .vp
    ├── ddr3_ip.fdc        // DDR3 参考时钟/PHY/71 根引脚
    ├── ddr3_ports.csv
    └── DDR3_IP_NOTES.md
```

---

## 2. 复制已验证的 DDR3 IP

```bash
mkdir -p fpga/pango/ip
cp -r /mnt/c/Users/BlossilveR/code/5-stage-baseline/fpga/pango/ip/ddr3 \
      fpga/pango/ip/
```

检查：

```bash
grep -E "<device>|<package>|<speedgrade>" \
  fpga/pango/ip/ddr3/ddr3_test/ddr3_test.idf
# 期望：PG2L200H / FBB676 / -6
```

不要修改 `.idf` 的器件头；不要重新跑 GUI IP Compiler（它的自动 pin assignment 曾把
DQ/DQS/DM 分到重复 ball）。详见 `DDR3_IP_NOTES.md`。

---

## 3. 约束

### 3.1 两个 FDC 分工

| 文件 | 内容 |
| --- | --- |
| `video_top.fdc` | `clk_27m` 27 MHz、`cmos1_pclk` 84 MHz、PLL 生成时钟、摄像头/HDMI/LED/UART 引脚、异步组、IO delay |
| `ip/ddr3/ddr3_ip.fdc` | `ref_clk` 125 MHz、DDR3 PHY 生成时钟、PHY placement、71 根 DDR3 引脚 |

**不要把 DDR3 引脚复制进 `video_top.fdc`**，否则会重复约束。

### 3.2 两个硬性名字

1. 顶层 DDR3 实例必须叫 **`I_ips_ddr_top`**：
   ```verilog
   ddr3_test I_ips_ddr_top (...);
   ```
   `ddr3_ip.fdc` 里的 `define_attribute {i:I_ips_ddr_top...}` 是绝对路径。

2. 参考时钟端口必须叫 **`ref_clk_p` / `ref_clk_n`**：
   ```tcl
   create_clock -name {ref_clk} [get_ports {ref_clk_p}] -period {8.0}
   ```

### 3.3 引脚事实

见设计文档 §2 和 `rtl/video/README.md`。关键几组：

- `clk_27m` D18；`rst_n` C22。
- CMOS1（J2）：`pclk` Y22、`vsync` Y23、`href` W18、`scl` W21、`sda` U14、`reset` T20。
- CMOS2（J2）：`pclk` U21、`vsync` V23、`href` W23、`scl` W19、`sda` V16、`reset` Y20。
- HDMI：`pix_clk` T24、`de/hs/vs` N19/R20/R21、RGB 24 根、`iic` K22/K23、`rstn_out` G25。
- LED `led[7:0]` = B17/C17/A18/A17/E18/C19/C18/A20。
- UART `uart_tx` C24。

> 当前板卡摄像头接 **J2**（MES-FMC-LPC-IO 40-pin），与官方
> `HDMI_DDR3_OV5640_100H` 例程一致。J2 在 **Bank L6**，官方要求
> `J20=ADJ`、`J24=2V5`，即 **2.5 V**；`video_top.fdc` camera pins 使用
> `LVCMOS25` / 2.5 V。上板前实测 Bank L6 电压。

> 100H FBG676 与 200H FBB676 的共有球位功能一致（300 个共有球，BANK/功能名差异 0）；
> 已用 PK04008 引脚手册核对 100H HDMI 例程用到的 138 个 ball。`b_out` 位序在部分
> 厂商工程里整体取反，上板若颜色顺序不对，只改 FDC，不改 RTL。

---

## 4. 流程

```bash
cd fpga/pango
D:/PDS_2022.2-SP6.4/bin/pds_shell.exe -file flow_video.tcl
```

`flow_video.tcl` 做：

```text
set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_constraint video_top.fdc
add_constraint ip/ddr3/ddr3_ip.fdc
add_design  rtl/video/*.v
add_design  rtl/video/legacy/*.v
add_design  ip/ddr3/ddr3_test/ddr3_test.idf
compile -top_module video_top
synthesize -ads
dev_map
pnr
report_timing -max_path 20
gen_bit_stream -create_bit true
```

- 不用 `-system_verilog`：视频新增代码是纯 Verilog-2001。
- 不用 Synplify：无 license。
- 阶段选择：改 `rtl/video/video_defs.vh` 的 `VIDEO_STAGE_SEL` 默认值，或在
  `compile` 的 `-compiler_directives` 里传宏（PDS 对带值宏支持不稳，优先改默认值）。

---

## 5. 上板前检查

- [ ] PDS 器件 `PG2L200H / FBB676 / -6`（不是 `FBG676`）。
- [ ] Bank L6/L7 VCCIO 与 `video_top.fdc` 一致。OV5640 文档写 `J20=ADJ、J24=2V5`
      （2.5 V），vendor FDC 写 3.3 V；**实测跳线后再定 IO 标准**。
- [ ] FMC-LPC-IO 插在底板 FMC 座，Double_OV5640 插 **J2** 40-pin（J20=ADJ、J24=2V5）。
- [ ] HDMI 显示器接 HDMI-OUT；MS7210 27 MHz 晶振在底板上。
- [ ] DDR3 参考时钟 N3/N2 = 125 MHz 差分。
- [ ] 复位 C22。
- [ ] 首次上板先跑 S0 彩条，再跑 BIST，再跑 S2。

---

## 6. 烧写

```powershell
# 终端 A：JTAG 服务常驻
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420

# 终端 B
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl `
  -args {<repo>\build\pango\syn\generate_bitstream\video_top.sbit}
```

DONE 灯亮即成功；UART 115200 8N1 看状态行。

---

## 7. 已知问题

| 问题 | 说明 |
| --- | --- |
| DDR3 读写 | **600 Mbps 已通过**（2026-10-28）：8 MiB 两阶段写读回环，30 s 连续 2720 轮 0 错；800 Mbps 在本板处于边缘，易受摆放影响 |
| DFI↔PHY -4.1 ns | 20:35 旧 FDC 丢了 vendor multicycle；20:56 起补回后 `ddrphy_sysclk→phy_dq` +1.5/+1.6，全过 |
| 2_9 group 3 DQ 位序 | group 3 write leveling 失败；`DQ24↔31/25↔30/26↔29/27↔28` 后通过；DQS P/N 不能交换 |
| DDR3 ref_clk 引脚组 | IP 生成器 `pnr` 默认 M21/M22；200Pro+ 实际 N3/N2；不改会 `Place-0094` |
| 两套 DDR3 DQ/DQS/DM | `2_9_ddr3_test` vs `HDMI_DDR3_OV5640`；BIST 判定 |
| ADS 推断 bug | 颜色/图案常量 mux 合成单个 `reg [23:0]` 临时量 |
| `GTP_IOCLKDIV_E2` | 200H 可用；但输出是区域时钟，跨 region 的 BRAM 必须过 `GTP_CLKBUFG`（见 §11.1） |
| Synplify license | 只能用 ADS；不要按 SV 写视频代码 |

---

## 8. S0 构建记录（2026-10-26）

**状态：位流已生成，未烧录（板子未连接）。**

- 流程：`flow_video_s0.tcl`（`compile` → `synthesize -ads` → `dev_map` → `pnr` → `report_timing` → `gen_bit_stream`）
- 工程：`C:\Users\BlossilveR\code\ares-video-s0\fpga\pango\video_s0.pds`
- 位流：`...\generate_bitstream\video_top.sbit`（9,188,552 B）  
  header：`Logos2-PG2L200H--6-FBB676 / video_top`
- 时序：**All Constraints Met**

| Clock | Requested | WNS | Estimated Fmax |
| --- | --- | --- | --- |
| `sys_clk` | 27.000 MHz | 32.093 ns | 202.3 MHz |
| `pix_clk` | 37.125 MHz | 16.342 ns | 94.4 MHz |
| `cfg_clk` | 10.000 MHz | 95.940 ns | 246.4 MHz |

- 资源：LUT **311** / FF **270** / DRM **0.5** / APM 0 / USCM 3（利用率 1%）
- S0 约束取舍：
  - `ddr3_pins_s0.fdc` 把 DDR3 引脚的差分 `HSTL15D_I` 改成单端 `HSTL15_I`，因为 PDS 200H 在这些 bank 上拒绝差分标准；S0 只把这些脚当静态/高阻。S2/BIST 必须用 IP 的 `ddr3_ip.fdc` 并解决同样的标准问题。
  - 摄像头输入在 S0 是 dangling，PDS 报 `Flow-4065` 并忽略其 pin 约束；S1 接上采集后自然消失。

接板后烧录：

```powershell
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl `
  -args {C:\Users\BlossilveR\code\ares-video-s0\fpga\pango\generate_bitstream\video_top.sbit}
```

板上预期：HDMI 720p30 彩条；`led[1]`=PLL、`led[3]`=HDMI init；UART 115200 8N1 每 ~0.5 s 输出 `V1 S0 OK`。

---

## 9. S1 构建记录（2026-10-26）

**状态：位流已生成，未烧录（板子未连接）。**

- 摄像头接 **J3** 40-pin；`CAM_SEL=0`（模组 CMOS1 FPC）。若摄像头插在模组的 CMOS2 FPC，改 `CAM_SEL=1` 重编。
- 流程：`flow_video_capture.tcl`，工程 `video_s1`
- 位流：`C:\Users\BlossilveR\code\ares-video-s1\fpga\pango\generate_bitstream\video_top.sbit`（9,188,552 B）
- 时序：**All Constraints Met**

| Clock | Requested | WNS | Estimated Fmax |
| --- | --- | --- | --- |
| `sys_clk` | 27.000 MHz | 30.832 ns | 161.2 MHz |
| `cmos1_pclk` | 84.000 MHz | 8.480 ns | 292.0 MHz |
| `pix_clk` | 37.125 MHz | 16.460 ns | 95.5 MHz |
| `cfg_clk` | 10.000 MHz | 95.850 ns | 241.0 MHz |
| `cam_clk` | 24.750 MHz | 37.744 ns | 375.9 MHz |

- 资源：LUT 608 / FF 760 / DRM 1 / USCM 5（1%）
- **CDC 修正**：S1 计数在 `cmos1_pclk` 域，`pixel_clk` 只给 S2；此前 pixel→sys 的 -0.471 ns / 19 端点 setup 违例已消除，`Design Summary : All Constraints Met`。
- 网表含 `u_capture` / `u_reg_config` / `u_power`，摄像头 SCCB 配置和复位序列都在。
- PDS 报 `Flow-4065`（`cmos1_data[*]`、`cmos2_*`、`ref_clk_*`）：S1 只做计数，`pixel_rgb565` 未使用，数据通路被裁剪；摄像头 data 脚不参与放置是预期。S2 接 framebuf 后会用上。
- 未烧录：板子未连接；`cdt_cfg` 返回 255。
- 位流已于 18:44 重编，修复 S0 `video_status` 的 UART bug（原来每个**字节**之间等 0.5 s，现在整行 37 字节连续发完后才等 0.5 s），并把 S1 计数移到 `cmos1_pclk` 域。

接板后烧录：

```powershell
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl `
  -args {C:\Users\BlossilveR\code\ares-video-s1\fpga\pango\generate_bitstream\video_top.sbit}
```

板上预期：

- HDMI 继续显示 720p30 彩条；
- `led[4]`（cam init）在约 **1.5 s** 后点亮（357 条 SCCB 写，10 kHz）；
- `led[5]`：正式 S1 为帧活动慢闪；**当前诊断版为 PCLK 活动快闪（约 5 Hz）**；
- UART 115200 8N1 每 ~0.5 s 输出：
  ```text
  S1 V=000000xx L=0000xxxx P=xxxxxxx
  ```
  V 约 30/s 增长，L 约 22500/s，P 约 27.6M/s。

### 9.1 J2 相机重建（20:09 / 20:11）

摄像头回到 **J2 / Bank L6 / 2.5 V**（J20=ADJ、J24=2V5），`video_top.fdc` 已从 J3 改回 J2 并改成 `LVCMOS25`：

| FPC | 位流 |
| --- | --- |
| CMOS1（`CAM_SEL=0`） | `C:\Users\BlossilveR\code\ares-video-s1-j2\fpga\pango\generate_bitstream\video_top.sbit`（20:09） |
| CMOS2（`CAM_SEL=1`） | `C:\Users\BlossilveR\code\ares-video-s1-j2-cam2\fpga\pango\generate_bitstream\video_top.sbit`（20:11） |

两版都 `All Constraints Met`，LED5 恢复为 vsync 帧活动慢闪，UART `S1 V/L/P`。

> J2 S1 的 `led[2]` 是 `ddr_init_done`，S1 没有 DDR3 IP，**恒 0 是预期**；不要和 19:45 BIST 诊断版的 `led[2]`（DDR3 IP PLL）混淆。
> 板上预期：`led[1]`=PLL、`led[3]`=HDMI init、`led[4]`=cam init（约 1.5 s）、`led[5]`=vsync 慢闪；UART V/L/P 增长。

诊断版位流（J3 历史，LED5 = PCLK 活动）：

| 摄像头 FPC | 位流 |
| --- | --- |
| CMOS1 | `C:\Users\BlossilveR\code\ares-video-s1\fpga\pango\generate_bitstream\video_top.sbit`（19:10） |
| CMOS2 | `C:\Users\BlossilveR\code\ares-video-s1-cam2\fpga\pango\generate_bitstream\video_top.sbit`（19:12） |

- LED5 快闪 → 有 `cam_pclk`；若 UART V=0，说明 PCLK 有但 vsync 没进来。
- LED5 不闪 → 没有 `cam_pclk`，先查供电/PWDN/XCLK/VCCIO/FPC。

排查顺序：

1. `led[4]` 不亮 → J3 的 `VCCIO` 是否与 FDC 的 3.3 V 一致、摄像头 FPC 是否插好、模组 24 MHz XCLK 是否起振、I2C 是否有上拉。
2. `led[4]` 亮但 V/L/P 不动 → `CAM_SEL` 是否选错 FPC；`cmos1_pclk`/`vsync`/`href` 是否在 J3 对应脚；摄像头是否输出 720p30 DVP。
3. V/L/P 增长但数值不对 → 用示波器看 pclk（约 84 MHz）、vsync/href 极性；S2 接 framebuf 后再看像素数据。


---

## 10. DDR3 BIST 构建记录（2026-10-27 19:32）

**状态：1000/800 均已上板；22:55 的 800 调试版已 `ddr_init_done=1`，BIST done 尚未单独指示。**

- Top：`video_bist_top`（`video_clk_reset` + `ddr3_test I_ips_ddr_top` + `video_ddr3_bist`）
- 流程：`flow_bist.tcl`
- 位流：`C:\Users\BlossilveR\code\ares-video-bist2\fpga\pango\generate_bitstream\video_bist_top.sbit`（19:45 诊断版）
- IP 的 compile / synth / dev_map / pnr 全部通过，已出 `.sbit`。
- 资源：LUT 4099 / FF 4005 / DistRAM 34 / USCM 4（DRM 0）
- 时序（已知 200H DFI/PHY 风险）：

| Path | WNS | Failing endpoints |
| --- | --- | --- |
| `sys_clk` | 33.370 ns | 0 |
| `rst_clk` | 4.558 ns | 0 |
| `ddrphy_sysclk` | **-0.652 ns** | 2 |
| `ddrphy_sysclk → phy_dq_sysclk_0` | **-3.527 ns** | 184 |
| `ddrphy_sysclk → phy_dq_sysclk_1` | **-4.051 ns** | 420 |

这与设计文档 §6.2 / §12 的 200H DFI↔PHY 风险一致。BIST 先按 1000 Mbps 试；若 `ddr_init_done` 不亮或 BIST 错，回退 800 Mbps 或补 200H PHY placement。

BIST 结果只看 LED（UART 仍是 S1 行，BIST 不解析）。**19:45 诊断版映射**：

| LED | 含义 |
| --- | --- |
| `led[0]` | 心跳 |
| `led[1]` | 系统 PLL lock |
| `led[2]` | DDR3 IP `pll_lock` |
| `led[3]` | `ddrphy_cpd_lock`（PHY 校准锁） |
| `led[4]` | `ddr_init_done` |
| `led[5]` | `dbg_ddrphy_init_fail` |
| `led[6]` | `align_error` |
| `led[7]` | BIST error（锁存；BIST done 未上 LED） |

19:45 版同时把 DDR3 IP 的 APB 按厂商顶层改成 `apb_clk=0 / apb_rst_n=1`。BIST 自动在 `ddr_init_done` 后对前 4 MiB 做地址即数据写/读。

### 10.1 1000 Mbps 上板结果（2026-10-27 20:00 左右）

用户回报：`led[0]` 心跳，`led[1..3]` 亮，`led[4]` 灭，`led[5]` 亮，没有彩条。

判读：

- 系统 PLL、DDR3 IP PLL、`ddrphy_cpd_lock` 都锁；
- `ddr_init_done=0` 且 `dbg_ddrphy_init_fail=1` → **DDR3 PHY 初始化失败**；
- BIST 没有启动，故 `led[7]` 不亮；
- **BIST 顶层没有 HDMI 通路，没有彩条是预期**；彩条请看 J2 S1 位流，不是 BIST。

这与 1000 Mbps 的 `ddrphy_sysclk → phy_dq_sysclk_0/1` −3.527/−4.051 ns 一致，按设计文档回退 800 Mbps。

### 10.2 800 Mbps 回退构建（2026-10-27 20:35）

- 在 `C:\Users\BlossilveR\code\ares-video-bist-800` 用 `ip_generate.exe -ads` 重新生成 IP：`DFI_CLK_PERIOD=10000`（100 MHz）、`DDR3_CL=6`、`DDR3_CWL=5`。
- 第一次 PnR 报 `Place-0094: MREGION_CLOCK`：`u_clkbufm/clkbufm_inst` 与 `i_dqs_bank[0].u_clkbufr/goprclk` 不兼容。换 seed 无效。
- **根因不是 PHY 摆放集**：IP 生成器的 `pnr/ddr_test.fdc` 把 `ref_clk_p/n` 放在 **M21/M22**（Pango 参考工程的右手 DDR3 组）；200Pro+ 底板实际是 **N3/N2**。1000 Mbps 的 `ddr3_ip.fdc` 注释里已经写明 M21/M22 会触发这个 `Place-0094`。
- 把 800 Mbps 的 `ddr3_ip.fdc` 改成 `ref_clk_p=N3`、`ref_clk_n=N2`；不要再对 `u_clkbufm`/`u_clkbufr` 加 `PAP_LOC`（PnR 插入的时钟 buffer 在约束视图里找不到对象）。之后 **PnR + 位流成功**。
- 位流：`C:\Users\BlossilveR\code\ares-video-bist-800\fpga\pango\generate_bitstream\video_bist_top.sbit`（20:35，9,188,552 B）。
- 时序（20:35 旧约束）：`ddrphy_sysclk` **+0.193 ns**；`ddrphy_sysclk → phy_dq_sysclk_0/1` 仍为 **−3.564 / −4.113 ns**（184/420 端点），`Not All Constraints Met`。**20:56 补回 vendor `set_multicycle_path 2` 后全过**：`ddrphy_sysclk` +0.579、`ddrphy_sysclk→phy_dq_sysclk_0/1` +2.049/+1.587，0 failing；后续 21:22/22:55 等版本也全过。之前看到的 −4 ns 是 IP-only FDC 丢了 vendor 多周期约束，不是真实 PHY 时序失败。
- 上板只看 `led[4]`/`led[5]`：`led[4]` 亮、`led[5]` 灭 → DDR3 init 过，BIST 继续；`led[5]` 亮 → PHY init 仍失败。
- **20:56 上板结果**：`led[4]=0`、`led[5]=1`、`led[7]=0`。静态时序已干净，所以这次不是 −4 ns；PHY 初始化/校准失败。
- 现在剩两个 200H 专属问题：① `2_9` DDR3 引脚表来自 **100H 例程**（100H 上验证过），200H 参考是 notes §7.3 的 `200h_ddr3_676_x72.fdc`；② 对应的 **200H PHY placement set** 还没拿到。注意 `board_pinmap` 第二列 `F4...` 是 notes §1.2 里那个 DQ/DQS 球位重复（`G9/H6/B5/C1`）的错误 `.idf` `PAD_*`，不是可用的 200H 表。需要用 `200h_ddr3_676_x72.fdc`/Pango 200H PHY 摆放集重生成，不能再用 100H 的 `2_9` 直接上板。
- `HMIC_S_P_User_guide.pdf`（UG042003 V1.14）的关键结论：
  - §2.8.4：**IP `.fdc` 里内部模块的 location 约束不能改**，只能按实际走线修改 routing。我们 1000/800 的 `ddr3_ip.fdc` 只保留了 `DDRPHY_CPD_729_772` + 两个 reset gate，不是完整的 IP 摆放；这与 PHY init 失败一致。必须用完整的、匹配 `2_9` 的 placement set。
  - §2.9.1/2.9.2 + §2.5.5：失败阶段看 **`debug_calib_ctrl[33:30]` = `dbg_error_status`**：0 无错、1 write leveling、2 read pattern、3 gate training、4 read training、5 write training、6 eye training；`dbg_slice_status` 再看 `wrlvl_error_tmp`/`rdel_calib_error`/`gate_cal_error`/`rddata_check_pass_tmp`。当前 BIST 只接了 `init_fail`/`align_error`，没接这些；下一步应把它们接到 BIST 的 UART/LED。Example Design 的 `ips2l_uart_ctrl` 是 115200 串口，Pango AE 另有调试脚本。
  - §2.8.6：SCBV 只对 **PG2L100H/PG2T390H**；200H 不适用，PDS 的 `SCBV has not been set` 警告可忽略。§2.2.1/§2.5.3.1：APB 只用于低功耗/MRS/状态读取，不是 init 必需；`apb_clk=0 / apb_rst_n=1` 不是这次 init fail 的原因。§2.8.4 还要求 VCCIO 1.5、DQS `SSTL15D_I`、DQ `SSTL15_I`、VREF INT、`DDR_TERM_MODE`/`CP_DYN_TERM` ON；§2.3.1.2.3 的 200H FBB676 默认 PLL/CA bank L5、数据 bank L6/G1，200Pro+ 实际是 R4/R5，必须 custom pin/bank。
- PDS 自带参考 FDC 已找到，但**不能直接用于 200Pro+ `2_9`**：
  - `/mnt/d/PDS_2022.2-SP6.4/ip/system_ip/ips2l_hmic_s/ips2l_hmic_eval/ips2l_hmic_s/pnr/200h_ddr3_676_x72.fdc`：`mem_dq` 从 `Y22...`，`DDRPHY_CPD_9_466`，8 个 DQS group（右手组）。
  - `.../200h_ddr3_484_x32.fdc`：`mem_dq` 从 `C2...`，`DDRPHY_CPD_369_466`（FBB484，不是 FBB676）。
  - 200Pro+ `2_9`：`mem_dq` 从 `G5...`，`DDRPHY_CPD_729_772`，4 个 DQS group（左下组）。参考 placement 的 `DDR_PHY_9_*`/`PPLL_7_*`/`CPD_9_466` 对应右手 PHY，套到 `2_9` 会放错位置。需要 Pango 针对 `2_9`/FBB676 x32/左下组的 200H PHY placement set。
- BIST 仍无 HDMI，彩条仍用 J2 S1 位流。

### 10.3 200H 调试与 DQ3 修复（2026-10-27 21:22–22:55）

**调试版本线（800 Mbps，`ares-video-bist-800`）：**

| 时间 | 调试改动 | 上板现象 | 判读 |
| --- | --- | --- | --- |
| 21:22 | `debug_calib_ctrl[33:30]` → `led[3:0]` | `led[0]+led[5]` | `dbg_error_status=1` = **write leveling** |
| 21:49 | `dbg_slice_status` 每组 `wrlvl_error_tmp` → `led[3:0]` | `led[3]+led[5]` | 只有 **DQS group 3** write leveling 失败 |
| — | 核对 `MES2L676-200HP-CORE-V1.2` | — | group 3 球位与 `2_9` **完全一致**（DQ24–31 `F2/D1/G1/A2/E1/A3/G2/C2`，DQS `C1/B1`，DM `E2`），不是球位错 |
| — | 只交换 group 3 DQS P/N | PDS `device_map` 拒绝 | `IOBS/IOBD` 差分对固定，软件不能换 DQS3 P/N |
| 22:24 | group 3 DQ 位序：`DQ24↔31`、`25↔30`、`26↔29`、`27↔28` | `led[5]` 单独亮 | 4 组 write leveling **全部通过** |
| 22:39 | `dbg_error_status` → `led[3:0]` | `led[1]+led[5]` | `dbg_error_status=2` = **read pattern** |
| 22:46 | 每组 `rddata_check_pass_tmp` → `led[3:0]` | `led[5]` 单独亮 | 4 组读检查全 0 |
| 22:55 | gate/read 聚合调试 | `led[0]` 心跳，`led[1..4]` 亮，`led[5..7]` 灭 | **`ddr_init_done=1`、`init_fail=0`、align=0、BIST error=0** |

**结论：**

- **唯一功能性修复是 group 3 的 DQ 位序交换**（`dq[24..31]` 反向）。之后的 22:39/22:46/22:55 只是调试 LED 映射不同，不改变 DDR3 逻辑；22:55 的 init 通过可能还叠加了 PnR 自动 placement/seed 的差异。
- `led[0]` 在 22:55 版本里是**心跳**：`led[3:0]` 只在 `init_fail=1` 时显示调试位；`init_fail=0` 时回到 `video_status` 正常映射，`led[0]=beat[23]`。
- `led[7]` 只表示 **BIST error**，不表示 **BIST done**；`led[7]` 不亮可能是 BIST 通过，也可能是 BIST 尚未完成。下一步必须加 `bist_done` 指示。
- 22:55 位流：`C:\Users\BlossilveR\code\ares-video-bist-800\fpga\pango\generate_bitstream\video_bist_top.sbit`。

### 10.4 当前状态与下一步（DDR3 线）

- 800 Mbps 22:55：`ddr_init_done=1`、`init_fail=0`；但旧 BIST 有握手 bug，`BIST error=0` 不代表读写通过，见 §12。
- 1000 Mbps 19:45：旧位流，`ddr_init_done=0`、`init_fail=1`，已被 800/DQ3 版本取代；1000 的 `ddr3_ip.fdc` 也补了 vendor multicycle，但未重编。
- 100H demo `3_10_HDMI_IN_DDR3_gamma`：`.pds` 是 200H FBB676，但 IP 仍是 100H/FBG676，FDC 是 100H `2_9` + 200H 484 placement，**不能作为 200Pro+ 200H 的 DDR3 测试**；`ConstraintEditor-2002` 是 share-pin 警告，`BUS_KEEPER`/484 placement 是错误。
- 200H PHY placement：已从 22:55 位流导出 3356 个 PHY 实例 + 6 个 `u_clk_reset` 实例（`ip/ddr3/ddr3_phy_place_2255_in.pcf`）；`dev_map` 后追加，见 §12。
- 下一步：见 §12 —— DDR3 已用 600 Mbps 真正验证通过；接下来进入 S2 framebuf（摄像头 → DDR3 双缓冲 → HDMI）。

---

## 11. 摄像头直出 HDMI preview 构建记录（2026-10-27 23:36）

**目的：不经过 DDR3，把 OV5640 画面直接送 HDMI，先确认采集/显示链路通。**
DDR3 引脚仍由 `ddr3_pins_s0.fdc` 静态约束、顶层 tie-off，不实例化 DDR3 IP。

- Top：`video_cam_preview_top`（`CAM_SEL=0`，CMOS1 / J2）
- 流程：`flow_video_preview.tcl`；新增 `video_preview.fdc`（只给 preview 用）
- 位流：`C:\Users\BlossilveR\code\ares-video-cam-preview\fpga\pango\generate_bitstream\video_cam_preview_top.sbit`（9,188,552 B）
- 时序：**All Constraints Met**（setup 和 hold 全部 0 failing）

| Clock | Requested | WNS | Estimated Fmax |
| --- | --- | --- | --- |
| `sys_clk` | 27.000 MHz | 30.336 ns | 202.5 MHz |
| `cmos1_pclk` | 84.000 MHz | 8.637 ns | 314.2 MHz |
| `pix_clk` | 37.125 MHz | 15.520 ns | 87.9 MHz |
| `cfg_clk` | 10.000 MHz | 94.813 ns | 234.6 MHz |
| `cam_clk` | 24.750 MHz | 37.788 ns | 377.2 MHz |
| `pixel_clk` | 42.000 MHz | 15.379 ns | 118.6 MHz |

- 资源：LUT 2301 + 169、FF 714 + 201、**DRM 257 / 415（62%）**、USCM 3（BKCL 6/10）。
  DRM 大头是两片 640×360×16 双缓冲（`preview_fb0/fb1`，2×230400×16 bit）。
- 数据通路：OV5640 1280×720 → `cmos_8_16bit`（RGB565）→ 2× 抽点写
  `preview_fb0/1`（640×360）→ HDMI 720p30 读侧 2× 放大 → RGB888。
- 帧切换：写 bank 在 `pixel_clk` 域按 camera vsync 翻转，读 bank 在 `pix_clk`
  域按 HDMI vsync 锁存 `~preview_wr_bank`；`preview_wr_bank → pix_clk` 是 2FF CDC。

### 11.1 两个构建失败与修法

1. **`E: Place-0089: REGION_CLOCK`**
   `cmos_8_16bit` 里的 `GTP_IOCLKDIV_E2` 输出的是**区域时钟**，而 preview 的
   两片 BRAM 跨多个 clock region 放置，PnR 在 Phase 1.2 直接报
   `loaders driven by .../iockdiv_inst is incompatible with the available resource`。
   修法：`video_cam_preview_top` 里加 `GTP_CLKBUFG u_pixel_clk_bufg`，
   BRAM 写侧改用全局版本 `pixel_clk`（原区域时钟改名 `pixel_clk_io`）。
   仿真模型在 `rtl/video/sim/GTP_CLKBUFG.v`（不进 PDS 综合）。

2. **`cmos1_pclk → pixel_clk` CDC 违例**
   加 BUFG 后 PnR 能过，但 PDS 把 IOCLKDIV 的输出自动推断成
   `.../CLKDIVOUT_Inferred`，没有并入 `video_top.fdc` 里 `cmos1_pclk` 的异步组，
   于是 `preview_wr_bank → preview_wr_bank_sync` 被按同步路径分析，
   setup −2.972 ns、fast-corner −2.048 ns（各 1 个端点）。
   修法：`video_preview.fdc` 显式命名该生成时钟：

   ```tcl
   create_generated_clock -name pixel_clk -source [get_ports {cmos1_pclk}] \
       [get_nets {pixel_clk_io}] -master_clock [get_clocks {cmos1_pclk}] \
       -multiply_by 1 -divide_by 2
   set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {pix_clk}]
   set_false_path -from [get_clocks {pix_clk}]   -to [get_clocks {pixel_clk}]
   ```

   `cmos1_pclk → pixel_clk` 的 521 个真实数据端点仍照常时序分析
   （WNS +6.038 / hold +0.226），只把 bank 握手声明为异步。
   若以后编 `CAM_SEL=1`，`video_preview.fdc` 的 `-source` 要改成 `cmos2_pclk`。

### 11.2 预期现象 / 上板排查

- `led[1]`=PLL、`led[3]`=HDMI init、`led[4]`=cam init（约 1.5 s）、
  `led[5]`=帧活动（V 计数 bit5，≈1 Hz 慢闪）、`led[2]`=DDR3 init **恒 0 是预期**。
- HDMI 应显示 640×360 放大的实时画面（2× 双线性关，最近邻放大）。
- `Flow-4065`（`cmos2_*`、`ref_clk_*` dangling）和 45 条 `STA-3011`
  （`u_reg_config` 的 SCCB 时钟）与 S1 完全一致，是既有告警，不是本次引入。
- 若 LED 正常但画面全黑/花屏：
  1. `led[4]` 不亮 → SCCB 没配成功（J2 2.5 V、FPC、XCLK、I2C 上拉）；
  2. `led[5]` 不闪 → 没有 camera vsync，查 `cmos1_vsync`/PCLK；
  3. 画面撕裂/上下错位 → 先看 camera 输出是否真是 1280×720@30，
     抽点前提是 `cam_x/cam_y` 每行 1280、每帧 720；
  4. 颜色通道反 → 只改 `r_out/g_out/b_out` 接线或 FDC，不改 RTL。

### 11.3 颜色失真修复（2026-10-28 00:08）

上板结果：LED 全部符合预期，画面能出且几何正确，但颜色严重失真
（整体偏绿/青，并有横向彩色条纹；照片 `preview1.jpg`）。

对照 vendor `HDMI_DDR3_OV5640_100H` 顶层后发现三处差异，全部修掉：

1. **BGR565 未归一化（主因：整体色偏）**
   `reg_config` 写 `0x4300=0x60`，OV5640 数据手册 table 7-15：
   RGB565 + sequence 0 = `{b[4:0],g[5:3]}, {g[2:0],r[4:0]}`，
   所以 `cmos_8_16bit` 的 `pdata_o` 是 **BGR565**（`[15:11]=B`）。
   vendor 顶层明确做了 `{d[4:0],d[10:5],d[15:11]}` 变成 RGB565，我们漏了。
   → `video_capture_wrap` 增加 `RGB_SWAP`（默认 1），输出标准 `{R,G,B}`。

2. **DVP 输入少了一级寄存器（主因：横向彩色条纹）**
   vendor 顶层先把 `cmos1_data/href/vsync` 打一拍再进 `cmos_8_16bit`。
   我们的 RTL 直接进。`pixel_clk` 是 pclk 的 ÷2，这一拍会让
   `pdata_o` 相对 `pixel_clk` 移相 180°；少了它，BRAM 写侧正好在
   `pdata_o` 翻转的时钟沿采样，属于 PDS 时序模型看不到的竞争
   （PDS 报 +6 ns，实际可能采到旧值/亚稳态，表现为数据相关的彩色条纹）。
   → `video_capture_wrap` 加 `cam_data_d0/cam_href_d0/cam_vsync_d0`，
   与 vendor 完全一致。

3. **preview 读地址差 1 个源像素（sim 发现）**
   数据通路比 DE 通路多一级：`mem → preview_rd_rgb → rgb_mux/r_q`，
   而 `de → de_q`。原来 `x_act[11:1]` 会让输出整体晚一个源像素
   （最左 4 个输出像素都显示源像素 0）。
   → 读地址改成 `(hdmi_x_act+1)[11:1]`，行尾钳位到 639。

验证：

- `rtl/video/test/tb_video_capture.v`：字节序 + `BGR 0x1234 → RGB 0xA222` 通过。
- 新增 `rtl/video/test/tb_video_preview.v`：三帧 1280×4 合成 DVP，
  检查 (0/2/100/1278, 0..3) 共 48 个输出像素的 r/g/b，**PASS**。
  它同时验证了 2× 抽点、2× 放大、读写 bank 和读流水线对齐。
- 位流：`C:\Users\BlossilveR\code\ares-video-cam-preview\fpga\pango\generate_bitstream\video_cam_preview_top.sbit`
  （00:08，9,188,552 B），时序 **All Constraints Met**
  （sys 31.192 / cmos1 8.826 / pix 15.791 / cfg 95.578 / cam 38.021 /
  cmos1→pixel 6.139 / pixel_clk 16.388 ns）。

### 11.4 彩色条纹根因：DVP 字节配对跨行保持（2026-10-28 00:38）

用户提供参考工程 `Gowin_FPGA_CV`（同样 OV5640，Gowin 器件），其
`ov5640_data.v` 在 HREF 低电平时把字节相位清零：

```verilog
end else begin          // HREF low
  data_flag <= 1'b0;    // every line starts on a byte boundary
```

vendor 的 `cmos_8_16bit.v` 相反：`cnt` 只在 `!rst_n` 时清零，HREF 拉低时
保持不变。因此只要出现一次奇数个字节的行、或空档里多一个 HREF 脉冲，
后续行的 `{first,second}` 字节顺序就会翻转：

- 正常：`{byte0,byte1}` = BGR565 → 红盒子显示红色
- 翻转：`{byte1,byte2}` → 字段错位 → 蓝/青/品红条纹

S1 的 UART 曾经就是证据：`V=0x1E (30/s)`、`L=0x57E4 (22500/s)`，
22500/30 = **750 行/帧**，而 720p 只有 720 个有效行——说明 HREF 有空档脉冲，
正好会触发上面这个相位翻转。

处理：

- 新增 `rtl/video/video_dvp_rgb565.v`：与 vendor 相同的 `GTP_IOCLKDIV_E2`
  ÷2 时钟、相同的 3 级输出流水线，但**每个 HREF 低电平都把 byte phase 清零**。
- `video_capture_wrap` 改为例化它；`cmos_8_16bit.v` 仍保留在 legacy/ 作参考。
- 新增回归测试 `rtl/video/test/tb_video_dvp_pair.v`：在第 1 行后插入一个
  额外 HREF 脉冲，要求第 2 行仍然配对为 `0x1234`。
  - `cmos_8_16bit`：第 2 行变成 `0x3456`（复现故障）
  - `video_dvp_rgb565`：第 2 行仍是 `0x1234`（PASS）

位流：

| 文件 | 说明 |
| --- | --- |
| `generate_bitstream/video_cam_preview_top.sbit` | **当前版本**（00:38，字节相位修复） |
| `video_cam_preview_top_rgbfix.sbit` | 00:21 版（只修 RGB 顺序/输入寄存器/读地址） |
| `video_cam_preview_top_colorbar.sbit` | 00:28 诊断版：OV5640 `0x503D=0x80` 内部彩条，用来单独验证 DVP/配色 |

00:38 版时序 **All Constraints Met**（sys 30.729 / cmos1 8.683 / pix 15.508 /
cfg 96.236 / cam 37.962 / cmos1→pixel 5.871 / pixel_clk 15.550 ns）。


---

## 12. DDR3 读写验证通过（2026-10-28 00:38）

**状态：600 Mbps 位流已上板；init + 8 MiB 两阶段写读回环稳定通过。**

- 位流：`C:\Users\BlossilveR\code\ares-video-ddr3-600\fpga\pango\generate_bitstream\video_bist_top.sbit`
- IP：600 Mbps，仓库内 `ip/ddr3/ddr3_test` 已同步为 600 版
  （`DFI_CLK_PERIOD=13333`，CL6/CWL5）。
- 关键结论：

  1. **旧 BIST 有握手 bug**：`awvalid`/`wvalid`/`arvalid` 与对应 ready 在同一个
     时钟沿判断；从设备本来 ready 时会漏掉握手。旧版可能一直卡在 `S_W`，
     此时 `error=0` 不能当作通过。现改为 `valid && ready`。
  2. **单 burst 写后立刻读不可靠**：改为两阶段，先写完整 8 MiB，
     `DRAIN_WAIT=16384`（约 131 µs）后整体读回比较。
  3. **800 Mbps 在本板是边缘状态**：只增加约 100 LUT 就会从 init 通过变成
     `G=1` write leveling 失败；改 600 Mbps 后余量足够。
  4. **22:55 的 init 成功依赖 DDR3 PHY 摆放**。`dev_map` 会把 project PCF
     覆盖成生成的 IO/CPD 约束，所以必须在 `dev_map` 之后、`pnr` 之前，把
     `ip/ddr3/ddr3_phy_place_2255_in.pcf`（22:55 的 3356 个 PHY 实例 +
     6 个 `u_clk_reset` 实例）追加到 `ip/ddr3/ddr3_place.pcf`。
     直接 `add_constraint` 该 PCF 是无效的（会被 dev_map 重写）。

- 上板结果：

  - `I=1 F=0 A=0 G=0 D=1 E=0 C=0`
  - 30 s 连续读取：59 行，0 错误，`P` 2203→4923
    （2720 轮，约 43.5 GiB 流量）
  - 连续重烧 2 次均 `I=1`，`P` 正常增长

- UART 行（115200 8N1）：

  ```text
  BIST I=1 F=0 A=0 G=0 D=1 E=0 P=0000089B C=00000000 X=0000000 B=0 Y=00000000 Z=00000000
  ```

  `I` init_done，`F` init_fail，`A` align_error，`G` dbg_error_status，
  `D` done，`E` error，`P` 完成轮数，`C` 错误 beat 数，`X` 首错 32-bit
  字地址，`B` 首错 beat，`Y/Z` 首错 beat 的 expected/actual 低 32 位。

- LED（BIST 顶层）：

  | LED | 含义 |
  | --- | --- |
  | `led[0]` | 心跳 |
  | `led[1]` | 系统 PLL lock |
  | `led[2]` | DDR3 IP PLL lock |
  | `led[3]` | `ddrphy_cpd_lock` |
  | `led[4]` | `ddr_init_done` |
  | `led[5]` | `dbg_ddrphy_init_fail` |
  | `led[6]` | BIST error（锁存） |
  | `led[7]` | BIST pass（至少一轮完成且无错） |

- 复现：`flow_bist.tcl` 会自动追加 PHY 摆放，`pnr -seed 2`。
  改动 BIST/状态逻辑后仍建议重新确认 `I=1`：本板 800 Mbps 对摆放/布线
  非常敏感，600 Mbps 已明显稳定。

- 下一步：S2 摄像头 → DDR3 双缓冲 → HDMI，复用 600 Mbps IP 和同一份
  PHY 摆放 PCF。

> 从 `Place-0089` 到当前颜色/条纹问题的完整记录、验证结果和下一步计划：
> 见 [`archive/PREVIEW_DEBUG.md`](archive/PREVIEW_DEBUG.md)。


---

## 2026-10-28 — 官方 200Pro 2_9 IP：DDR3 1000 Mbps 与 S2 出图

### 转折点

用户找到官方盘古 200Pro 资料包（`D:\BlossilveR\Download\200pro`），按要求放弃之前的
100H 资料，改用 `2_Demo/2_9_ddr3_test` 的官方 200Pro DDR3 IP。关键差异：

| 差异 | 旧 100H/600 | 官方 2_9 |
| --- | --- | --- |
| `DEVICE_100H_EN` | true | **false** |
| 速率 | 600 Mbps | **1000 Mbps** |
| `DFI_CLK_PERIOD` | 13333 | **8000** |
| DQ3 组 | DQ24↔31 反转 | **原始顺序** |
| 约束 | `ddr3_ip.fdc` + 手工 PHY 摆放 | **`official_ddr3.fdc`**（CPD/自动） |
| 1000 Mbps 时序 | 负 | **All Constraints Met** |

旧 IP/FDC/PHY 摆放已归档到 `ip/ddr3/archive_100h_600m/`。

### BIST（1000 Mbps）

- 流程：`flow_bist.tcl`，官方 2_9 IP + `official_ddr3.fdc`，`pnr -seed 2`。
- 结果：`I=1 F=0 A=0 G=0 D=1 E=0 C=0`，`P` 0x34B → 0x493（30 s，0 错）。
- 连续重烧两次 `I=1`；时序 All Constraints Met。
- 这是第一次在 200Pro+ 上以官方 200H PHY 配置跑通 **1000 Mbps**，不再需要 600 Mbps。

### S2（1000 Mbps）

- 流程：`flow_video_fb.tcl`，官方 2_9 IP + vendor `wr_fram_buf`/`rd_fram_buf`
  （`GTP_DRM36K_E1`）+ `use_ext_de` + `axi_wusero_last`，`pnr -seed 5`。
- 状态：`S2 P=1 D=1 H=1 C=1 F=1 B=1 R=1 E=1 G=1 M=...`；
  `M` 随白天场景变化，画面不再是白屏/纯噪声。
- 读侧与 vendor `hdmi_ddr_ov5640_top` 一致：`rd_en = sync_vg.de_re`、
  `rd_fsync = sync_vg.vs_out`，去掉早期为白屏加的 `fb_init_done` 闸门。
- 截图：`picture2.jpg`（dpram+gate）、`picture3.jpg`（vendor DRM 无闸门）均为
  白天房间场景，但有随机彩色横条。

### 隔离测试：`INJECT_PATTERN=1`

- 写侧数据替换为 4 条 320 px 竖条（红/绿/蓝/白），摄像头只提供 DE/VSYNC。
- 结果：`picture4.jpg` 4 条竖条**干净**，framebuf 读回中心 `N=07E0` 稳定在绿条。
- **结论：framebuf / DDR3 / HDMI 数据通路正确；彩色横条来自摄像头 DVP 数据。**
- 竖条边缘轻微波浪来自注入 `cap_x` 的逐行计数（以及 720p30 在 4K 显示器上的
  缩放），不是 framebuf 错误；摄像头真实画面的抖动另见 S2_DEBUG §6。

### 剩余问题

1. 摄像头数据随机彩色横条：确认 200Pro+ FMC 的 VADJ（S2 当前 2.5 V/LVCMOS25，
   官方 100H 相机工程 3.3 V/LVCMOS33）；对照 `set_input_delay` 2.0 → 0；
   必要时用官方 `cmos_8_16bit` + 输入寄存器结构对照。
2. 画面抖动：720p30 在 4K 显示器上的缩放/FreeSync；需要时改 720p60。
3. `N` 采样已从 `hdmi_rd_en`（早 2 拍）改为 `fb_vout_de`，需重新构建确认 `M≈N`。

### 文件同步

- `fpga/pango/ip/ddr3/ddr3_test`：官方 2_9 IP（1000 Mbps，`DEVICE_100H_EN=false`）。
- `fpga/pango/official_ddr3.fdc`：官方 FDC 子集。
- `fpga/pango/flow_bist.tcl` / `flow_video_fb.tcl`：官方 IP/FDC，去掉手工 PHY 摆放。
- `rtl/video/video_fb_top.v`：vendor DRM、无读闸门、`N` 在 `fb_vout_de` 采样。
- 旧 S0/S1/preview 流程/RTL 归档到 `fpga/pango/archive/`、`rtl/video/archive/`；
  `video_dpram` 归到 `rtl/video/alt/`（仅仿真）。
