# 上板手册（盘古 200Pro+）

> 目标：从零到"串口里看到脱敏结果 + 摘要行"。全程约 15 分钟（出位流 ~1 分钟，烧写 ~10 秒）。
> 原理与协议见 [board-uart.md](board-uart.md)。

## 0. 准备

**硬件**：盘古 200Pro+ 板卡、12 V 电源、JTAG 下载器（Pango USB Cable II）、USB 线接板载 USB-UART。

> ⚠️ **板子必须上电**。COM 口是 USB 供电的，即使 12 V 没开 COM 也会出现 —— 但 JTAG 扫不到 FPGA。

**软件**

| 件 | 用途 |
|---|---|
| PDS 2025.2-SP3（`D:\Pango\PDS_2025.2-SP3-EN-ads`） | 出位流、烧写 |
| Python 3.10+ + pyserial | 上位机 `tools/serial_host.py` |
| WSL + Verilator（可选） | 只跑仿真才要 |

## 1. 四步

```powershell
cd E:\qs\ScreenSense

powershell -ExecutionPolicy Bypass -File guard\tools\build_guard.ps1     # 1) 出位流
powershell -ExecutionPolicy Bypass -File guard\tools\program_guard.ps1   # 2) 烧到板子

python guard\tools\serial_host.py --ports                                # 3) 找串口
python guard\tools\serial_host.py -p COM9 --file guard\examples\demo1_offer.txt   # 4) 验收
```

成功的标志：第 2 步打印 **`The done bit is 1`**；第 4 步打印脱敏正文 + 一行 `[guard] n=…`。

## 2. 出位流

`build_guard.ps1` 依次做：生成关键字/实体/NER 表 → `pds_shell -file flow_guard.tcl`
（`compile → synthesize → dev_map → pnr → report_timing → generate_bitstream`）。

成功输出末行：

```
Total LUTs: 20879 of 159800 (13.07%)
WNS = 4403 (ps)   TNS = 0
bitstream: guard\generate_bitstream\guard_board_top.sbit
```

日志：`guard/build/pds_guard.log`；时序报告：`guard/prj_tasks/pnr_1/report_timing/guard_board_top.rtr`。

## 3. 烧写

`program_guard.ps1` 起 `cdt_js`（端口 60000）→ `cdt_cfg -file program_guard.tcl` → 停掉 `cdt_js`。

成功输出：

```
This device configure situation (done bit): 0
Finish program .../guard_board_top.sbit
The done bit is 1
```

**两条限制**：位流灌的是 SRAM，**断电即丢**；烧写时别同时开着串口程序。

## 4. 串口第一测

| 项 | 值 |
|---|---|
| 波特率 | 115200 8N1 |
| 引脚 | RX **B24** / TX **C24**（板载 USB-UART，不用杜邦线） |
| 帧结束 | 收到 `LF`，或空闲 ≈2.6 s |

**上电是静默的**：不打印 banner，发一行文本才回应。点亮判断：`led[7]` 常亮 = PLL 锁定，
`led[3]` 灭 = 无错误。

## 5. 验收

```powershell
python guard\tools\serial_host.py -p COM9 --file guard\examples\demo1_offer.txt
python guard\tools\board_smoke.py
```

正常长这样：

```
── masked echo from the board ────
李＊（手机：*******4589，邮箱：***************.com）…地址：＊＊＊…

── audit line(s) ────
frames    n   id18 mobile email name addr ...
     9    5      0      1     1    1    2
```

> `--check`（逐字节比金标）**只对规则版位流（`USE_NER=0`）有效**；NER 版会多遮，
> 字节数自然不同，用 `board_smoke.py` 和 `examples/` 的 demo 验收。

## 6. 故障表

| 现象 | 原因 / 处置 |
|---|---|
| 烧写报 `The cable List :` 为空、`JtagServer-0306` | JTAG 链没扫到 FPGA：**12 V 没开**，或 JTAG USB 要拔插一次，或残留 `cdt_js` |
| 打开 COM 报 `PermissionError(13)` | 端口被占：另一个 `serial_host.py --repl`、或浏览器页面连了串口（点"断开"） |
| 串口无任何回显 | 位流没加载（断电过？）→ 重新烧；或 `led[7]` 不亮 = PLL 没锁 |
| 回显中间插摘要行 | 帧 >64 字节触发提前收帧（已知问题）→ 用 `--file`（上位机自动分帧），别用 `--no-pace` |
| `ovf=001` | 溢出：发太快或板子忙；去掉 `--no-pace` 重试 |

## 7. 改 RTL 后的最小回归

```bash
make test            # 金标 + Verilator（11 组）
make ner-check       # NER 门槛（16 条）
```

上板再跑一次 `board_smoke.py` 与五条 demo。
