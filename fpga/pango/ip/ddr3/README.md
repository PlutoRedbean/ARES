# ip/ddr3 — 官方 200Pro 2_9 DDR3 IP（1000 Mbps）

**当前唯一使用的 DDR3 IP。** 来源：官方 200Pro 资料包
`2_Demo/2_9_ddr3_test/.../ipcore/ddr3_test/`（盘古 200Pro+，PG2L200H FBB676 -6）。

| 项 | 值 |
| --- | --- |
| 器件/封装 | `PG2L200H-6FBB676` |
| `DEVICE_100H_EN` | **false**（200H PHY 配置，关键） |
| `ACTUAL_RATE` / `DESIRED_RATE` | **1000.000 Mbps** |
| `DFI_CLK_PERIOD` | **8000** ps |
| 内存 | `MT41K256M16XX`，`MEM_ROW/COL/BANK = 15/10/3` |
| 参考时钟 | `ref_clk_p=N3`、`ref_clk_n=N2`，125 MHz differential |
| 顶层实例名 | **`ddr3_test I_ips_ddr_top`**（必须） |
| 约束 | `../../official_ddr3.fdc`（见下） |

## 目录

```text
ip/ddr3/
├── ddr3_test/                 # 官方 2_9 IP（精简：.idf + rtl/ + pnr/ddr_test.fdc）
│   ├── ddr3_test.idf
│   ├── rtl/                   # 加密 .vp + ddrphy
│   ├── ddr3_test.v / ddr3_test_ddrphy_top.v
│   └── pnr/ddr_test.fdc       # 官方生成的 FDC（源）
├── archive_100h_600m/         # 旧 100H/600 Mbps IP、旧 FDC、旧 PHY 摆放（不要用）
└── README.md
```

## 约束文件

`fpga/pango/official_ddr3.fdc` 是从本目录 `ddr3_test/pnr/ddr_test.fdc` 中提取的
**引脚/时钟/DDRPHY CPD/multicycle** 子集，删除了官方示例的 `free_clk`、UART、LED
约束。包含：

- `ref_clk` 8.0 ns（125 MHz）、`ddrphy_sysclk` / `phy_dq_sysclk_*`；
- `set_multicycle_path`、`set_clock_groups`；
- `DDRPHY_CPD_729_772` + 两个 `ddrphy_ioclk_gate` 的 `PAP_LOC`；
- 全部 `mem_dq[31:0]`、`mem_dqs*`、`mem_ck`、`mem_addr/ba/cs/ras/cas/we/odt` 引脚。

**DQ3 组使用原始顺序**（`mem_dq[24]=F2 ... mem_dq[31]=C2`）。旧 100H 工程里的
`DQ24↔31` 反转是 100H PHY 配置下的 workaround，官方 200Pro 2_9 IP 不需要。

## 使用

BIST：

```bat
cd fpga\pango
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_bist.tcl -project_name video_bist
```

S2：

```bat
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_fb.tcl -project_name video_fb
```

两个流程都直接 `add_design ip/ddr3/ddr3_test/ddr3_test.idf`，加
`official_ddr3.fdc`，**不**追加任何 PHY 摆放 PCF。

## 已验证结果

- BIST 1000 Mbps：`I=1 F=0 A=0 G=0 D=1 E=0 C=0`，`P` 连续增长，30 s 0 错；
  连续重烧两次 `I=1`；时序 **All Constraints Met**。
- S2 1000 Mbps：`D=1`，摄像头场景可见，纯色竖条注入时 framebuf/DDR3/HDMI 数据干净。

## 重新生成

改 `ddr3_test.idf` 的 `ACTUAL_RATE` / `DESIRED_RATE` / `DFI_CLK_PERIOD` 后：

```bat
D:\PDS_2022.2-SP6.4\bin\ip_generate.exe -i ip\ddr3\ddr3_test\ddr3_test.idf -ads
```

**保持 `DEVICE_100H_EN=false`**。不要再用 100H 版 IP（`DEVICE_100H_EN=true`）配 200Pro+：
那会导致 PHY 校准/数据边缘、init 随 PnR 翻转。

## 历史

旧的 100H/600 Mbps IP、`ddr3_ip.fdc`、`ddr3_phy_place_2255_in.pcf` 都在
`archive_100h_600m/`，仅用于对照 S0/S1 和早期 S2 调试记录（见
`../../TEST_LOG.md`、`../../S2_DEBUG.md`）。
