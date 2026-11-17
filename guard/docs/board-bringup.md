# 上板指南（盘古 200Pro+）：出位流 → push 上板 → 串口验收

> 面向"板子在手、从零开始"的操作手册。原理、协议细节、为什么 25 MHz 见
> [board-uart.md](board-uart.md)；这份只讲**怎么做、成功长什么样、出问题查哪里**。
>
> 全程约 15 分钟（其中出位流 ~6 分钟，烧写 ~30 秒）。

---

## 0. 准备清单

**硬件**

| 件 | 说明 |
|---|---|
| 盘古 200Pro+ 板卡 | PG2L200H-6IFBB676 |
| 电源 | 板卡配套的电源适配器；**先上电再烧写** |
| JTAG 下载器 | Pango USB Cable II，插板载 JTAG 接口 |
| USB 线 → 板载 USB-UART | 就是串口那条；在设备管理器里会多一个 COM 口 |
| 杜邦线 | 本设计不用，UART 已经把 RX/TX 引到板载 USB-UART 了 |

**软件**

| 件 | 版本/路径 | 用途 |
|---|---|---|
| PDS | `D:\Pango\PDS_2025.2-SP3-EN-ads` | 出位流、烧写（cdt_js/cdt_cfg） |
| Python | 3.10+（本机 3.14） | 上位机 `serial_host.py`、关键字表生成 |
| pyserial | `pip install pyserial` | 上位机串口 |
| WSL + Verilator | 可选 | 只有跑仿真 `make test` 才要 |

---

## 1. 四条命令（TL;DR）

先做两件物理动作：**板子上电**、**JTAG 下载器 + USB-UART 都插到 PC**。
然后在仓库根目录 `E:\qs\ScreenSense` 下：

```powershell
# 1) 出位流（~6 min）
powershell -ExecutionPolicy Bypass -File guard\tools\build_guard.ps1

# 2) push 到板子（~30 s）
powershell -ExecutionPolicy Bypass -File guard\tools\program_guard.ps1

# 3) 找串口
python guard\tools\serial_host.py --ports

# 4) 验收（把 COM5 换成你的口）
python guard\tools\serial_host.py -p COM5 --file guard\examples\sample.txt --check
```

每步"成功长什么样"在下面逐条说。

---

## 2. 步骤 1：出位流

### 2.1 跑

```powershell
cd E:\qs\ScreenSense
powershell -ExecutionPolicy Bypass -File guard\tools\build_guard.ps1
```

它做三件事：

1. `python tools/gen_keywords.py build/gen/l1_keywords_pkg.sv` —— 生成关键字表 SV package；
2. `pds_shell -file guard\fpga\pango\flow_guard.tcl` ——
   `set_arch` → `add_constraint guard_board.fdc` → `compile` → `synthesize -ads` →
   `dev_map` → `pnr` → `report_timing`/`report_power` → `gen_bit_stream`；
3. 把位流从 `prj_tasks\pnr_1\generate_bitstream\` 抄到稳定路径。

### 2.2 成功的输出

```
[guard] generating keyword package
keywords pkg: 8 keywords -> build\gen\l1_keywords_pkg.sv
[guard] pds_shell -file E:\qs\ScreenSense\guard\fpga\pango\flow_guard.tcl
[guard] build done
  bitstream: E:\qs\ScreenSense\guard\generate_bitstream\guard_board_top.sbit
```

### 2.3 检查点

```powershell
Get-Item guard\generate_bitstream\guard_board_top.sbit | Select-Object Length,LastWriteTime
# 期望 ~9,200,000 B（9.2 MB）；几百 KB 说明没走完 PnR
```

再看三个数（日志 `guard\build\pds_guard.log`）：

```powershell
Select-String guard\build\pds_guard.log -Pattern 'Total LUTs|Total Registers|after finish route' |
    ForEach-Object { $_.Line }
```

期望（本版本基线）：

| 项 | 期望值 |
|---|---|
| LUT | 3,893 / 159,800（2.4%） |
| Registers | 2,113 |
| 时序 | `TNS = 0 ; WNS = +4997`（≈ +5.0 ns，MET） |

> WNS 必须是**正数**。如果是负数，说明你改了 RTL 让组合路径变长了；
> 先把时钟再降（`guard_pll.v` 里 `STATIC_RATIO0` 调大）再上板。

### 2.4 不用脚本、直接跑 PDS

```bat
D:\Pango\PDS_2025.2-SP3-EN-ads\bin\pds_shell.exe ^
    -file guard\fpga\pango\flow_guard.tcl -project_name guard_board
```

前提：`guard\build\gen\l1_keywords_pkg.sv` 已存在；没有就先跑
`python guard\tools\gen_keywords.py guard\build\gen\l1_keywords_pkg.sv`
（flow 里也会在缺文件时自己调 python 生成）。
flow 结束同样会把位流抄到 `guard\generate_bitstream\`，和脚本一致。

---

## 3. 步骤 2：把位流 push 上去（JTAG）

### 3.1 一条命令

板子上电、JTAG 下载器插好，然后：

```powershell
powershell -ExecutionPolicy Bypass -File guard\tools\program_guard.ps1
```

（也可以指定文件：`-Bitstream guard\generate_bitstream\guard_board_top.sbit`）

### 3.2 脚本内部做了什么

```
1. 找位流（默认取 generate_bitstream\ 下最新的一份，没有就退回 prj_tasks 里的）
2. 路径转成"绝对路径 + 正斜杠"           ← cdt_cfg 的 -args 会吃反斜杠，这一步必须
3. 起 cdt_js.exe -port 60000             ← JTAG 服务器（已经起着就复用）
4. cdt_cfg.exe -file guard\fpga\pango\program_guard.tcl -args <sbit>
   tcl 里：cfg_connect(127.0.0.1:60000) → cfg_scan_chain →
           cfg_assign_file(<sbit>) → cfg_program → cfg_disconnect
5. 关掉 cdt_js（-KeepServer 可保留）
```

### 3.3 成功的输出（关键几行）

脚本会先回显 cdt_cfg 的 console 输出，再把 `guard\log\cfg.log` 的尾部打出来：

```
[guard] bitstream : E:/qs/ScreenSense/guard/generate_bitstream/guard_board_top.sbit  (9,188,552 B)
[guard] started cdt_js on port 60000
[guard] cdt_cfg -file fpga\pango\program_guard.tcl ...
Executing : cfg_connect -ip 127.0.0.1 -port 60000
Connect to server[127.0.0.1 : 60000] successfully.
The cable List :
Cable index 0:USB Cable II/fffffffffffffffe
Executing : cfg_scan_chain
PG2L200H
This device configure situation (done bit): 1
Executing : cfg_assign_file -file ...guard_board_top.sbit -device_index 0
Executing : cfg_assign_file ... successfully.
Executing : cfg_program -device_index 0
Executing : cfg_program -device_index 0 successfully.
--- cdt_cfg transcript (tail) ---
  ...
[guard] PROGRAM OK -- 板上 led[7] 应该常亮（PLL 锁定），led[3] 应该灭
        接着按 docs\board-bringup.md 第 4 步做串口第一测。
```

判据：

1. 扫描链里打出 **`PG2L200H`**（没打出来 = 没连上板子）——**最关键的一条**；
2. 没有任何以 `E:` 开头的行，脚本退出码 0；
3. 出现 `cfg_program ... successfully`（不同 PDS 版本措辞可能不同，只作佐证）。

真正的确认在板上：**`led[7]` 常亮** + §4 的串口回显。日志说成功但 LED 不亮，
就是位流/时钟的问题，不是 UART 的问题。

日志：`guard\log\cfg.log`（cdt_cfg 的完整 transcript，脚本会把最后 14 行打出来）
和 `guard\log\jtagserver.log`（cdt_js 的日志，脚本已让它以 `guard\` 为工作目录）。
失败时脚本会打印检查清单并返回退出码 1。

> 注意 `cdt_cfg.exe` 是 GUI 子系统的程序：**用管道调用拿不到输出、也拿不到退出码**。
> 脚本用 `Start-Process -Wait` 等它结束，再读它写的 `log\cfg.log` 判定。

### 3.4 手动分步（脚本出问题时定位用）

```bat
:: 窗口 1：起 JTAG 服务器，保持不关
D:\Pango\PDS_2025.2-SP3-EN-ads\bin\cdt_js.exe -port 60000

:: 窗口 2：烧写
::   -file 和 -args 都必须是**绝对路径**（相对路径 cdt_cfg 会报 "no such file"），
::   -args 还要用正斜杠（反斜杠会被吃掉）
D:\Pango\PDS_2025.2-SP3-EN-ads\bin\cdt_cfg.exe ^
    -file E:\qs\ScreenSense\guard\fpga\pango\program_guard.tcl ^
    -args E:/qs/ScreenSense/guard/generate_bitstream/guard_board_top.sbit
```

> cdt_cfg 是 GUI 子系统的程序：命令行调用要等它自己结束，日志在
> **当前目录的 `log\cfg.log`**，不在 stdout。
>
> 它还会在 tcl 旁边顺手生成 `program_guard_run.tcl`（把 `%s` 换成实际路径的
> 展开副本）、`configuration_tcl.log` 和 `log\` —— 这些都是可随手删的中间物，
> `.gitignore` 已经忽略。

`program_guard.tcl` 就这几行（注释必须 ASCII-only，且只能有一个 `%s` 占位）：

```tcl
set port 60000
cfg_connect -ip 127.0.0.1 -port $port
cfg_scan_chain
cfg_assign_file -file %s -device_index 0
cfg_program -device_index 0
cfg_disconnect
cfg_close
```

### 3.5 两个必须知道的限制

1. **JTAG 直烧是掉电丢失的**：每次重新上电都要再烧一遍。固化到 SPI flash 需要
   Pango 的 `cdt_bts`（bitstream → flash 格式）流程，本机 license 没有
   `fabric_bts` 这一项，**没验证过**，所以本工程只承诺 JTAG 直烧。
2. **SCBV 警告可以忽略**：`gen_bit_stream` 会提示 `SCBV has not been set`。
   仓库里 gesture 线的位流也在同样配置下烧写并跑通过；如果板子烧完不启动，
   再去 PDS 的 bit stream 选项里按板卡配置电压改 SCBV。

---

## 4. 步骤 3：串口连通（第一测）

### 4.1 接线与终端设置

- 板载 USB-UART 插到 PC → 设备管理器 →"端口 (COM 和 LPT)"里会多一个 COM 口
  （`python guard\tools\serial_host.py --ports` 也能列出来）；
- **115200 8N1，无流控，无 XON/XOFF**；
- 用串口助手时勾上"发送新行（\n）"，否则要靠 2.6 s 空闲超时才出结果。

### 4.2 设计上电是**静默**的

没有 banner、没有版本行——**先发东西**才会回。发：

```
abc
```

期望收到（注意 LF 被补成 CRLF）：

```
abc\r\n
[guard] n=000 id18=000 id15=000 mobile=000 bank=000 email=000 ipv4=000 uscc=000 plate=000 kw=000 kwm=000 ovf=000 mode=1\r\n
```

### 4.3 LED 判读

| LED | 含义 | 期望 |
|---|---|---|
| 7 | **PLL 锁定** | 上电就常亮。**不亮 = 时钟/复位有问题，串口不会有任何输出** |
| 3 | 当前帧未结束 | 收到第一个字节后亮，帧结束（摘要发完）后灭 |
| 0 | 收到串口字节 | 发数据时闪 |
| 1 | 发出串口字节 | 回数据时闪 |
| 4 | 本帧命中 span | 发 `手机 13800138000` 时闪一下 |
| 2 | 出错（粘滞） | 正常应该灭；亮了看 §6 的 ovf |

---

## 5. 步骤 4：验收（脱敏+审计）

```powershell
cd E:\qs\ScreenSense

# 单条：看脱敏 + 审计行
python guard\tools\serial_host.py -p COM5 --text "手机 13800138000，邮箱 a@b.co"

# 整份样例：逐字节和金标比
python guard\tools\serial_host.py -p COM5 --file guard\examples\sample.txt --check
# 期望最后一行：PASS  收到 1229 B，期望 1229 B

# 交互
python guard\tools\serial_host.py -p COM5 --repl

# 把审计行存成 JSON
python guard\tools\serial_host.py -p COM5 --file guard\examples\sample.txt --check --json audit.json
```

单条期望看到：

```
── 板子回显（脱敏后）────────────────────────────────────────
手机 *******8000，邮箱 **b.co

── 审计行（板子发的）──────────────────────────────────────
 #     n  id18 id15  mob bank mail ipv4 uscc plate   kw kwm ovf mode
 1     2     0    0    1    0    1    0    0     0    1  08   0    1

── 校验 ────────────────────────────────────────────────
PASS  收到 157 B，期望 157 B
```

`--check` 的期望值来自 `host/golden/board_proto.py`，和 `make board-sim` 是**同一份**
实现——所以板上 PASS 就等于仿真 PASS。

### 5.1 顺手验一下"溢出检测是活的"

```powershell
python guard\tools\serial_host.py -p COM5 --file guard\examples\sample.txt --no-pace
```

`--no-pace` 会照线速猛灌，板子消费不过来 → **大概率**看到 `ovf=001`、LED2 亮、
正文缺字节（文件越大越容易触发；`sample.txt` 375 B 处在临界，没触发就换个大点的文件）。
去掉 `--no-pace` 应该恢复 `ovf=000` —— 这组对照说明流控和溢出标志都是活的。

---

## 6. 故障排查

| 症状 | 最可能的原因 | 处理 |
|---|---|---|
| 烧写脚本报 `找不到 cdt_js.exe` | PDS 不在 `D:\Pango\PDS_2025.2-SP3-EN-ads` | 改 `program_guard.ps1` 里的 `$bin`，或装到该路径 |
| `cfg_connect` 失败 / 连不上 60000 | cdt_js 没起、端口不同、被防火墙拦 | `taskkill /IM cdt_js.exe /F` 后重跑；确认 tcl 里端口也是 60000 |
| `cfg_scan_chain` 没有打印 `PG2L200H` | 板子没上电 / JTAG 线松 / 驱动没装 | 上电、重插下载器、设备管理器里看有没有 Pango USB Cable |
| `cfg_assign_file ... is not readable` | 传了相对路径或反斜杠 | 用绝对路径 + 正斜杠（脚本已处理） |
| `couldn't read file "..."` | `-file` 给了相对路径 | `-file` 也用绝对路径 |
| `can't read "port": no such variable` | `program_guard.tcl` 里混进了非 ASCII 字符（中文注释会吞掉换行） | tcl 保持 **ASCII-only**（仓库里那份就是），别在里面加中文 |
| `User input args nums can not fixed user tcl '%s' nums` | tcl 里有不止一个 `%s`（比如注释里写了） | tcl 里只能有 **一个** `%s` |
| 脚本报 `exit=`（空）+ 没有任何输出 | `cdt_cfg` 是 GUI 子系统 exe，管道调用不会等它 | 脚本已改用 `Start-Process -Wait`；手动跑时等它自己退出 |
| 烧完 **led[7] 不亮**、串口全无 | PLL 没锁 / 时钟没进 | 确认 27 MHz 晶振（D18）与 `create_generated_clock` 层次一致；试着重烧一次 |
| led[7] 亮、串口没回显 | COM 口选错 / 波特率不是 115200 / 发的内容没带回车 | `--ports` 确认口；用 `serial_host.py -p COMx --text abc` 试；串口助手要勾"发送新行" |
| 回显正常但**摘要行没有** | 帧没结束 | 补一个 \n，或等 2.6 s 空闲超时 |
| `乱码` | 波特率不对（板子是 115200 8N1） | 改终端设置；确认没有流控 |
| `serial.SerialException ... 拒绝访问` | COM 口被别的程序占着 | 关掉串口助手 / 另一个 `serial_host.py` 再试 |
| `ovf=001`、缺字节 | 上位机发太快（裸终端灌大文件） | 用 `serial_host.py`（自带 pace），或分小段发 |
| `--check` FAIL，个别字节不同 | 板子/仿真版本不一致 | 重新 `make board-sim` 对比；确认烧的是同一份位流 |
| 上电后要重新烧 | JTAG 直烧，掉电丢失 | 正常现象，见 §3.5 |

**没有板子也想确认链路**：在 WSL 里 `cd guard && make test`，其中 `board-sim`
用真实 UART 位定时回放 18 个用例（含脱敏、审计行、流控），全绿说明 RTL 是对的。

---

## 附录 A：引脚与时钟

| 信号 | 引脚 | 说明 |
|---|---|---|
| `clk_27m` | D18 | 27 MHz 晶振 → `guard_pll` → 25 MHz 核心 |
| `rst_n` | C22 | 低有效复位 |
| `uart_rx` | **B24** | USB-UART → 板子 |
| `uart_tx` | C24 | 板子 → USB-UART，115200 8N1 |
| `led[7:0]` | B17 C17 A18 A17 E18 C19 C18 A20 | 见 §4.3（led[7]=PLL 锁，led[0]=A20） |

> 注意 `led[7]`=B17、`led[0]`=A20，别按位序反着看。

## 附录 B：串口协议速查

```
发：任意文本（UTF-8 字节流）
帧结束：收到 LF（0x0A）；或空闲 ≥ 2.6 s
回：脱敏文本（mask，长度不变，LF→CRLF）+ 一行摘要
摘要：[guard] n=NNN id18=NNN ... plate=NNN kw=NNN kwm=NNN ovf=NNN mode=N
```

- `n` = 本帧命中的 span 总数；`ovf=001` = 本帧出过错（溢出/丢字节/帧错误）。
- `kw`/`kwm` = 关键词提示的命中次数 / 位图；`mode=1` = T1（L1 生效）。
- 摘要行前会自动补 CRLF（当上一帧不以 LF 结尾时），不会粘在正文行尾。

## 附录 C：改 RTL 之后的最小回归

```bash
cd guard
make JOBS=2 test          # 金标单测 + 1000 向量 + 200 demo + 18 板级 + 257 摘要格式
```

改完 RTL 一定要跑这个，再重新出位流、重新烧写（`make test` 里已经包含板级端到端，
它和板上是同一份 RTL + 同一份金标）。