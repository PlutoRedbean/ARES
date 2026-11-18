# 上板：串口进 → L1 脱敏 → 串口出（盘古 200Pro+）

> 2026-11-15。板级 RTL + PDS 流程 + Verilator 端到端仿真都已就位。
> **只想上手操作**（出位流 → 烧写 → 串口验收）看
> [board-bringup.md](board-bringup.md)；这份讲设计与验证细节。
> 本文只讲**上板这一层**怎么用、怎么验；规则层与金标见 [../README.md](../README.md)。
>
> 复现仿真：`cd guard && make board-sim`（18 个用例，位级 UART 在环）。

---

## 0. 一句话

板子上跑的是 PC 上验证过的同一条 `l1_redact_top`（mask 策略、1:1 长度），
外面加一层 UART 桥：**上位机发文本，板子边收边回脱敏后的文本，一帧结束时回一行审计摘要**。
只有一个时钟域（27 MHz 晶振 → PLL → 25 MHz），没有 DDR3、不需要 RISC-V 镜像。

```
上位机 ──(115200 8N1, B24)──► 板子 ──(C24)──► 上位机
            uart_rx ─► RX FIFO ─► l1_redact_top ─► TX FIFO ─► uart_tx
                                          │
                                          └─ 每帧一行 [guard] n=... 摘要
```

一次真实会话（等价于 `serial_host.py --text`，字节流由金标算出）：

```
发：手机 13800138000，邮箱 a@b.co，身份证 11010519491231002X
回：手机 *******8000，邮箱 **b.co，身份证 **************002X
    [guard] n=003 id18=001 id15=000 mobile=001 bank=000 email=001 ipv4=000 uscc=000 plate=000 ovf=000
```

---

## 1. 板子上跑的是什么

| 能力 | 状态 | 说明 |
|---|---|---|
| L1 全 RTL 检测（8 类） | ✅ | 与 PC 上 `make test` 同一条 RTL |
| RTL 合并 + mask 替换 | ✅ | 1:1 长度，无变长输出 |
| 每帧审计摘要（UART） | ✅ | 固定宽度数字，一行一条 |
| 串口收/发（含 8× 过采样） | ✅ | 分数分频波特率，25 MHz 下无累积误差 |
| 帧边界 = LF 或空闲超时 | ✅ | 空闲 300000 位时间（≈2.6 s @115200） |
| token 策略（`[MOBILE_1]`） | ⬜ | 变长输出需要反压/令牌表，仍在 host（M2 下一刀） |
| L2 INT4 语义层 | ⬜ | M3，与本次上板解耦 |
| 关键词提示上板 | ✅ | 摘要行里带 `kw=`（命中次数）与 `kwm=`（位图） |
| 降级档位输出头 | ✅ | 摘要行 `mode=1`（T1：L1 生效）；T0 直通开关预留 |
| 3 Mbaud 通路 | ✅ 仿真 | `make board-sim-3m`（8× 过采样，18 例全过）；要 USB-UART 支持 3 Mbaud |
| **真板验收** | ✅ 2026-11-17 | USB-UART 枚举成 **CP210x → COM9**；`sample.txt` **PASS 1334/1334 B**，5 倍拼接 **PASS 6670/6670 B**（35 帧、无 ovf） |

---

## 2. 资源与时序（PDS 2025.2-SP3）

`synthesize -ads` + `dev_map` + `pnr` 实测（`guard_board_top`，核心 **25 MHz**）：

| 资源 | 用量 | 器件占比 | plan 预算 |
|---|---|---|---|
| LUT | **4,785** | 2.99% | 12–15k |
| FF | **2,947** | 0.92% | — |
| DRM36K | **0.5** | 0.12% | 25 |
| APM（18×18） | **10** | 1.35% | 0–8 |
| PLL（GTP_GPLL） | 1 | — | — |

| 时序 | 结果 |
|---|---|
| 时钟 | 27 MHz（D18）→ GTP_GPLL（VCO 1000 / 40）→ **25 MHz** 核心 |
| 最差 setup slack（WNS） | **+5.0 ns（MET）**，TNS = 0 |
| 最差 hold slack（WHS） | +0.037 ns（MET），THS = 0 |
| 推算 Fmax | ≈ 28.7 MHz（40 ns − 5.0 ns） |

位流：`guard/generate_bitstream/guard_board_top.sbit`。

> 上表是 2026-11-17 把三个文本引擎改成逐字节增量校验之后的数字；
> 之前是 10 MHz / 6,912 LUT / +15.1 ns（见 §2.1 的过程）。

### 2.1 时序是怎么从 10 MHz 抬到 25 MHz 的（关键路径定位）

第一次直接上 27 MHz，PnR 出来 **WNS = −38.2 ns**（最差路径约 75 ns），
规则层不收敛。PC 上 `make bench` 测的是**吞吐**（1 字节/拍）与命中时延，
**从没测过 Fmax**；README 那句"150 MB/s @150 MHz"是吞吐折算，不是时序结论。

**第一步：分块量一遍**（每个块单独做成顶层，27 MHz 约束下跑 PnR）：

| 块 | WNS @27 MHz | 结论 |
|---|---|---|
| `l1_digit_engine` | +13.6 ns | 不是它 |
| `l1_merge` | +5.5 ns | 不是它 |
| `l1_text_engines` | **−37.9 ns** | **就是它**（路径 ≈75 ns，和整板 −38.2 ns 吻合） |

**第二步：看文本引擎为什么慢**。它们都是"游程结束那一拍，对整个缓冲做组合校验"：

- 邮箱：64 次迭代的 `ok` / `nat` / `ndots` / `last_dot` 串行链（每轮改值、下一轮依赖）；
- IPv4：16 级的分组状态链（`val = val*10 + d`、`ndig`/`lead_zero` 一路带着走）；
- USCC：17 项加权和的加法链。

**第三步：改成逐字节增量校验**（2026-11-17）。每来一个字节只更新几个小寄存器，
游程结束时只看寄存器做几次比较：邮箱维护 `nat/at/bad/lab/tld/tlda/ndots`，
IPv4 维护 `grp/ndig/val/lead/bad`，USCC 维护 16 位加权和 + 是否含字母 + 校验位字符；
"尾部 `.` 裁掉"用**快照**实现（每遇到一个非 `.` 的字节就把状态拷进 `g_*`）。
语义与金标逐条一致，由 1000 例语料 + 43 例边界 + 200 例端到端兜住。

结果：文本块 **−37.9 ns → +22.4 ns**；整板 27 MHz 只剩 merge 的 31.5 ns 路径，
25 MHz（40 ns）下 **WNS +4.7 ns**、LUT 从 6,912 降到 4,749、FF 从 2,578 降到 2,947、APM 37 → 10（含 L2）。
25 MHz + 8× 过采样还能跑 3 Mbaud（`make board-sim-3m` 已验证）。

下一步还可以把 `l1_merge` 的 5 路插入拆成流水（现在是整板最深的 31.5 ns），
那样能回到 50 MHz；但 25 MHz 已经比 UART 快 2000 倍以上，不着急。

### 2.2 综合还顺手抓出两个仿真看不出来的问题

1. **`l1_merge` 的临时数组被推成锁存器**：`free_list[0:7]`（`int` 数组）
   在 `always_comb` 里只被部分赋值，ADS 给每个元素推了一个 **latch**，
   PDS 报 32 条 `gopLATCH.CLK has no clock`（锁存器不参与时序分析，
   行为也可能和 Verilator 不一致）。改成"扫描取编号最小的空槽"后逻辑等价，
   LUT 从 8,317 降到 7,200（最终 10 MHz + PLL 版是 6,912），锁存器消失。
2. **`guard_report` 的 BCD 是 25 级串行**：最初用"循环 25 次减 10"做
   十进制转换，综合成 25 级依赖链，直接成为关键路径。改成比较树 + 一次减法
   （并把余数截到 4 位）。为了兜住这类错误，加了 `sim/tb_guard_report.sv`：
   对 0..255 **每个值**核对整行输出（`make report-sim`）。
3. **块级时序定位**（§2.1）：整板 −38.2 ns 时，先把 digit/merge/text 各自做成
   顶层量一遍，才定位到文本引擎；不然很容易误以为是 merge 或 UART 桥。

## 3. 硬件

| 信号 | 引脚 | 说明 |
|---|---|---|
| `clk_27m` | D18 | 27 MHz 板载晶振，进 PLL |
| `rst_n` | C22 | 低有效复位（板载按键） |
| `uart_rx` | **B24** | USB-UART 接收（ARES 的 MSH/RTOS 顶层用过这个脚） |
| `uart_tx` | C24 | USB-UART 发送，115200 8N1 |
| `led[7:0]` | A20 C18 C19 E18 A17 A18 C17 B17 | 见下 |

**LED 语义**（活动类会拉长约 105 ms，方便肉眼看见）：

| LED | 含义 |
|---|---|
| 0 | 收到串口字节 |
| 1 | 发出串口字节 |
| 2 | 出错（粘滞）：RX FIFO 溢出 / 输出丢字节 / 帧错误 |
| 3 | 当前帧未结束（flush/report/reset 中都算） |
| 4 | 本帧提交过 span |
| 5 / 6 | 0 |
| 7 | **PLL 锁定**（上电常亮；不亮说明时钟/复位有问题，见 [board-bringup.md](board-bringup.md) §4.3） |

**时钟**：27 MHz（D18）→ `guard_pll`（GTP_GPLL）→ **25 MHz** 核心；
`clk_27m` 只进 PLL，全部逻辑都在 25 MHz 域。PLL 未锁定或按键复位都保持复位，
进核心域后同步释放。

**为什么是 25 MHz**：见 §2.1（文本引擎重写后 27 MHz 只剩 merge 的 31.5 ns，25 MHz 留 5.2 ns 余量）。UART 桥本身
与时钟频率无关（`CLK_FREQ` / `BAUD` / `OV` 三个参数），要 3 Mbaud 时
把 `OV` 降到 8 或换更快的 PLL 输出即可。

---

## 4. 数据流与三个机制

`guard/rtl/board/guard_uart_core.sv`：

1. **冲刷（帧边界）**：L1 引擎只有看到 `in_last` 才会关闭当前数字/字符串游程，
   也才会把 64 字节回退窗口里的尾巴冲出来。收到 LF 后（或空闲超过
   `IDLE_BITS` 个位时间），打一拍 `in_last`，等 `done`，再发摘要。
2. **流控**：脱敏器输出没有反压、1 字节/拍；串口发是 1 字节/86.8 µs。用一条
   不变量保证 TX FIFO 永不溢出：

   ```
   txq_level + inflight <= 256-2   且   inflight < 128
   ```

   `inflight` = 已进脱敏器 − 已出脱敏器（就是它 128 字节缓冲里的字节数）。
   只有不变量成立时才把 RX 的字节送进流水线；出队不改变左边之和。这样**
   不用改已验证的 `l1_redact.sv`**，也不用给输出加反压。
3. **帧间软复位**：`l1_merge`/`l1_redactor` 的 `flush_q`/`eos_q` 在 `in_last`
   之后一直保持，没有"重新开始"的入口。每帧结束后把流水线软复位 8 拍，
   下一帧从干净状态开始（TX/RX FIFO 不受影响，已脱敏的字节继续发）。

---

## 5. 串口协议

**只有一条规矩：发文本，收脱敏文本 + 一行摘要。**（ASCII，115200 8N1，无握手线）

### 5.1 帧边界

| 触发 | 说明 |
|---|---|
| 收到 `LF`（0x0A） | 立即结束当前帧 —— 交互/按行发送走这条 |
| 空闲 ≥ `IDLE_BITS` 位时间 | 兜底：最后一行没有换行也能出结果（≈2.6 s @115200，够慢慢打字） |

一帧结束后依次输出：本帧 mask 后的文本 → 一行审计摘要。
**摘要行固定格式**（计数一律 3 位零填充、超过 255 截到 255；档位是 1 位）：

```
[guard] n=NNN id18=NNN id15=NNN mobile=NNN bank=NNN email=NNN ipv4=NNN uscc=NNN plate=NNN kw=NNN kwm=NNN l2=NNN l2m=NNN ovf=NNN mode=N
```

- `n` = 本帧提交的 span 总数；
- `kw` / `kwm` = 关键词提示的命中次数 / 位图（bit k = `host/golden/keywords.py` 的 kid k）；
- `l2` / `l2m` = L2 语义层（miniTensor MXU）判成 PII 的游程数 / 类别位图（bit1=id18 bit2=bank bit3=mobile）；
- `ovf` = 本帧是否出过错（1 = RX FIFO 溢出 / 输出丢字节 / 帧错误）；
- `mode` = 降级档位（1 = T1 规则层生效；0 = T0 直通，开关预留）。
- 行首若要换行，板子只发 `LF`，由 TX 整形统一补成 `CRLF`（见 5.2）。
- 若上一帧输出不是以 LF 结尾（例如没有换行的最后一帧），摘要行前会自动补一个 `CRLF`，
  不会粘在正文行尾。

### 5.2 LF → CRLF

板子把**每一个** `LF` 补成 `CR LF` 再发（终端友好），所以：

- 输出字节数 = 输入字节数 + 输入里的 LF 个数 + 摘要行字节数；
- 想看逐字节透明，把 `LF_TO_CRLF` 参数置 0（`guard_board_top` 的参数）。

### 5.3 会话示例

```
$ python3 tools/serial_host.py -p COM3 --text "手机 13800138000，邮箱 a@b.co，身份证 11010519491231002X"
── 板子回显（脱敏后）────────────────────────────────────────
手机 *******8000，邮箱 **b.co，身份证 **************002X

── 审计行（板子发的）──────────────────────────────────────
 #     n  id18 id15  mob bank mail ipv4 uscc plate  ovf
 1     3     1    0    1    0    1    0    0     0    0
```

### 5.4 溢出（ovf=1）

摘要行让**输出字节数 > 输入字节数**（一帧 130 字节文本约多出 99 字节摘要），
而板子只有 256 B RX FIFO + 256 B TX FIFO。上位机若照线速猛灌，板子消费不过来，
RX FIFO 会溢出：`ovf=001`、LED2 亮、正文缺字节。

结论：**上位机要跟着回读走**。`tools/serial_host.py` 默认按
`host/golden/board_proto.py:output_thresholds()` 的节奏发（允许领先 32 字节），
`make board-sim` 的 TB 用的是同一份 `.pace` 门槛。
用裸终端 `cat big.txt > /dev/ttyUSB0` 这种写法会溢出——这是已知限制，见 §9。

---

## 6. 上位机 `tools/serial_host.py`

```bash
pip install pyserial                       # 只依赖这一个（./run.sh serial ... 也可以）
python3 tools/serial_host.py --ports       # 列出串口
python3 tools/serial_host.py -p COM3 --text "手机 13800138000"
python3 tools/serial_host.py -p COM3 --file examples/sample.txt --check
python3 tools/serial_host.py -p COM3 --file examples/sample.txt --check --json audit.json
python3 tools/serial_host.py -p COM3 --repl        # 交互：输入文本 → 回车 → 脱敏+审计；:q 退出（空行也退）
```

| 选项 | 作用 |
|---|---|
| `--check` | 收到的字节流和板级金标（`board_proto.expected_stream`）逐字节比对，打印 PASS/FAIL |
| `--json FILE` | 把审计行（每帧一条）写成 JSON |
| `--raw` | 打印原始字节（hex），调试用 |
| `--no-pace` | 不按回读节奏发（用来看 ovf=1 长什么样） |
| `-q` | 只打印脱敏文本 |

`--check` 的期望值和 `make board-sim` 用的是**同一份实现**，所以：

> 板上 `--check` PASS ⇔ 仿真 `board-sim` PASS ⇔ PC 上 `make test` PASS

---

## 7. 构建与烧写

### 7.1 一条命令（Windows + PDS 2025.2-SP3）

```powershell
powershell -ExecutionPolicy Bypass -File guard\tools\build_guard.ps1
# 产物：guard\generate_bitstream\guard_board_top.sbit（flow 从 prj_tasks 里抄过来）
# 日志：guard\build\pds_guard.log
```

> 如果 `generate_bitstream\` 里没有位流，真正的文件在
> `guard\prj_tasks\pnr_1\generate_bitstream\guard_board_top.sbit`。

脚本会先生成 `build/gen/l1_keywords_pkg.sv`（关键字表），再跑
`fpga/pango/flow_guard.tcl`：`set_arch` → `add_constraint guard_board.fdc` →
`compile -verilog_standard SystemVerilog` → `synthesize -ads` → `dev_map` →
`pnr -seed 2` → 报告 → `gen_bit_stream`。

直接用 `pds_shell` 也行：

```bat
D:\Pango\PDS_2025.2-SP3-EN-ads\bin\pds_shell.exe ^
    -file guard\fpga\pango\flow_guard.tcl -project_name guard_board
```

> PDS 2022.2 把 `-verilog_standard SystemVerilog` 换成 `-system_verilog`
> （设环境变量 `PDS_VERILOG_STD=2022` 即可，flow 里已经分支）。

### 7.2 烧写

```powershell
powershell -ExecutionPolicy Bypass -File guard\tools\program_guard.ps1
# 或指定：-Bitstream guard\generate_bitstream\guard_board_top.sbit
```

走 JTAG：自动起 `cdt_js`（60000 端口）→ `cdt_cfg` → `fpga/pango/program_guard.tcl`。
**路径要用正斜杠**（`cdt_cfg -args` 会吃掉反斜杠），脚本已经转了。

---

## 8. 上板验收清单

> 逐步操作版（含烧写命令与故障表）见 [board-bringup.md](board-bringup.md)。

1. **上电/复位**：`led[7]` 应常亮（PLL 锁定），`led[3]` 应常灭（空闲），
   `led[0]/[1]` 在收/发时闪。
2. **回环冒烟**（1 分钟）：串口助手 115200 8N1，发 `abc\n` → 应回 `abc` + 一行
   `[guard] n=000 ...`。回显正常说明 RX/TX/时钟/复位都对。
3. **脱敏**：发 `手机 13800138000\n` → 应回 `手机 *******8000` + `n=001 mobile=001`。
   `led[4]` 会闪一下。
4. **整份样例**：
   ```bash
   python3 guard/tools/serial_host.py -p COM3 --file guard/examples/sample.txt --check
   → PASS  收到 1334 B，期望 1334 B
   ```
5. **异常**：`--no-pace` 发大文件应看到 `ovf=001` 且 LED2 亮（说明溢出检测是活的），
   换回默认（pacing）应恢复 `ovf=000`。

---

## 9. 仿真验证（不用板子）

```bash
cd guard
make board-vectors     # 生成 build/board（18 例 / 10491 B / 309 span）
make board-sim         # 位级 UART 回放 + 逐字节比对
→ PASS: board UART end-to-end matches golden
```

`sim/tb_guard_uart.sv` 干的事：按真实 UART 位定时驱动 `uart_rx`，从 `uart_tx`
逐位收回来，和 `.exp` 逐字节比。仿真用 1 Mbaud（27 个 27 MHz 周期/位 = 25 个核心时钟/位，8× 过采样，和板上同一条通路）；
另有 `make board-sim-3m` 同套向量跑 3 Mbaud（9 个周期/位）。空闲冲刷参数取小值
（4000 位时间）以免仿真等 2.6 秒。覆盖：

| 用例 | 盯的是什么 |
|---|---|
| `sample.txt` / `clean.txt` | 多帧、无 PII 原样透传 |
| `no-trailing-lf` | 空闲冲刷（没有换行的最后一行） |
| `pii-at-frame-start` / `id18-at-frame-start` | 回归：帧首就是 PII（曾经漏脱敏，见 §10.1） |
| `empty-lines` | 空帧也要回摘要 |
| `crlf` | CRLF 行尾 |
| `pii-at-ends-no-lf` | 没换行且以 PII 结尾 |
| 8× `scene` | 合成聊天文本（8 类 PII + 干扰项） |
| `scenes-joined` | 连续 8 帧，帧间软复位 |
| `long-stream` | 7168 B 长流，流控 + pace 规则 |

`make test` 已经把 `board-sim` 串进去了（PC 侧全部回归 + 板级端到端）。

> **Windows 上没有 `make`**：仿真这套要在 WSL/Linux 里跑（Verilator + make）。
> 上板这条链不依赖 make —— `build_guard.ps1`（PDS）、`program_guard.ps1`（JTAG）、
> `serial_host.py`（Python）在 Windows 原生就能跑。脚本里用的是 `python`，
> 只有 `py` 的机器把 `build_guard.ps1` 里那行改一下即可。

---

## 10. 这一轮修掉的问题（都会复发，记下来）

### 10.1 帧尾 span 漏脱敏（真 bug，`l1_redact.sv`）

**现象**：`13800138000` 单独一帧（帧首就是 PII）时输出原样、`done` 永不置位。
**根因**：`eos_q` 在 `in_last` 后 1 拍就置位，替换器立刻 1:1 泄流；而最后一个
span 要晚 1–2 拍才由合并器提交。等 span 进队列时，它的起点早就发过去了 →
既漏脱敏，又让队列永远排不空（`done` 卡死）。
**修法**：`l1_redactor` 增加 `s_hold`：合并器 `quiet` 连续保持 4 拍才允许
eos 快速泄流。正常通路有 66 字节余量，行为不变（1000 例 + 200 例 demo-check 全过）。
**为什么以前没发现**：随机语料都从中文前缀开头，span 起点不在 0–66，正好躲过。

### 10.2 摘要行出现 `\r\r\n`

**根因**：TX 整形把**每个** LF 补成 CRLF，摘要行里又手写了一个 CR。
**修法**：摘要行只发 LF（`guard_report.sv`），CR 统一由 TX 整形补。

### 10.3 帧首那行摘要多一个 CRLF

**根因**：`done` 和"最后一个文本字节入 FIFO"是同一拍，摘要模块采样到的是
`at_line_start` 的旧值（0）。**修法**：用组合的 next 值
（`txq_push ? (txq_din==LF) : at_line_start`）喂给摘要模块。

### 10.4 上位机猛灌导致 RX FIFO 溢出

见 §5.4。**修法**：金标里算"发送门槛"（`board_proto.output_thresholds`），
TB 和 `serial_host.py` 共用；同时把空闲冲刷从 40 位时间提到 300000 位时间
（≈2.6 s @115200），否则上位机等回读、或者人打字稍慢，都会被误判成帧尾。

### 10.5 工具链小坑（Verilator / WSL）

- Verilator **5.020** 的 `--build` 把相对路径原样写进生成的 makefile，
  `make -C <Mdir>` 就找不到 C++ 源了（5.040 正常）。Makefile 里改成 `$(abspath ...)`，
  两边都对。
- WSL 里 `-j 0` 触发 Verilator 5.020 的线程池 bug（`attempted to destroy locked
  Thread Pool`）。Makefile 加了 `JOBS ?= 0`，受限机器用 `make JOBS=2 test`。

### 10.6 烧写链路（cdt_cfg）的坑——只有真烧一次才会遇到

1. **tcl 里的中文注释会让变量消失**：`cdt_cfg` 的 Tcl 用系统代码页读脚本，
   UTF-8 注释里的多字节序列会"吃掉"换行，于是 `set port 60000` 被并进注释，
   报 `can't read "port": no such variable`。→ `program_guard.tcl` 改成 **ASCII-only**。
2. **tcl 里只能有一个 `%s`**：`cdt_cfg` 拿 `-args` 的个数去对占位符个数，注释里
   再写一个就报 `User input args nums can not fixed user tcl '%s' nums`。
3. **`cdt_cfg.exe` 是 GUI 子系统程序**：用管道调用拿不到输出、拿不到退出码，
   它的日志写在 **当前目录的 `log\cfg.log`**。→ 脚本改用 `Start-Process -Wait`，
   再读 `guard\log\cfg.log` 判定（判据：出现 `PG2L200H` 且没有 `E:` 行）。
   顺带：`-file` 和 `-args` 都必须给**绝对路径**（相对路径报 `couldn't read file`），
   `-args` 还要正斜杠。

这四条都写进了脚本和 [board-bringup.md](board-bringup.md) §6 的故障表。

---

### 10.8 2026-11-17：第一次上板（真板）暴露的上位机 bug

位流烧进去、`led[7]` 常亮、发 `abc` 立刻回 `abc\r\n` + 摘要行 —— 但
`serial_host.py -p COM9 --file examples/sample.txt --check` 报
`等回读超时（已写 0/375 B，收到 0 B）`。

原因在**上位机的 pace 循环**：原来按"这一块最后一个字节的门槛"等待，第一块
64 字节还没发出去，就要求已经收到 61 B 回读（门槛按 `k - lag` 算），直接自己
锁死。仿真 TB 用的是自己的 `.pace` 文件逻辑，完全绕过了这段代码，所以
`make board-sim` 全绿也照样有这个 bug —— **只有真板能暴露**。

修法：门槛按**即将写的那个字节** `gates[i]` 判断，并且"当前回读量能放行多少
就写多少"（新增纯函数 `next_chunk_end`），并用 `tests/test_serial_pace.py`
5 个单测钉住（含"第一个字节不得有回读前提"）。

修完的结果：

```
$ python tools/serial_host.py -p COM9 --file examples/sample.txt --check
PASS  收到 1229 B，期望 1229 B
$ python tools/serial_host.py -p COM9 --file build_bulk.txt --check   # 375 B x 5
PASS  收到 6145 B，期望 6145 B
```

### 10.7 2026-11-17：把时钟从 10 MHz 抬到 25 MHz（+ 摘要行 v2）

1. **分块时序定位**：整板 −38.2 ns 时先把 digit / merge / text 各自做成顶层量一遍，
   发现是 `l1_text_engines`（−37.9 ns）。教训：别猜，逐块量。
2. **三个文本引擎重写成逐字节增量校验**（邮箱/IPv4/USCC），文本块 −37.9 → +22.4 ns；
   整板 25 MHz 收敛（+5.0 ns），LUT 6,912 → 3,893、FF 2,578 → 2,113、APM 37 → 10。
   重写过程中踩到两个 RTL 平移 bug（新游程忘了置 `run_q`、命中没按 `run_q` 门控），
   都是 1000 例向量立刻抓出来的——这类错误光看"模型对着金标"是抓不到的
   （模型对 ≠ RTL 对）。
3. **摘要行 v2**：加了 `kw=`（关键词命中次数）、`kwm=`（8 词位图）和
   `mode=`（档位，1 = T1）。金标/上位机/TB 三处都从 `board_proto.kw_stats` 取，
   仍然是一份实现；`tb_guard_report` 的期望长度/偏移跟着更新（120 B/行）。
4. **3 Mbaud 通路**：OV 16 → 8（25 MHz 下够 3.125 Mbaud），`make board-sim-3m`
   用同一套 18 例向量跑通；板级环回还要 USB-UART 支持 3 Mbaud。

## 11. 已知限制 / 下一步

**限制**

1. 只有 **mask** 策略、长度 1:1；token（`[MOBILE_1]`）仍是 host 侧（M2 下一刀）。
2. 输出比输入多（摘要行），**上位机必须 pace**；裸终端灌大文件会 `ovf=001`。
   想根治：XON/XOFF 软流控，或把摘要累积到帧尾按需查询（都是接口变更）。
3. `IDLE_BITS`（默认 300000 ≈ 2.6 s）是编译期常量；改空闲窗口要重新出位流。
4. 关键词提示已经上串口（`kw=`/`kwm=`），但只做"出现过没有"，不做上下文判定（那是 L2 的事）。
5. 波特率默认 115200（`BAUD` 参数）；25 MHz 核心 + 8× 过采样可跑 3 Mbaud
   （`make board-sim-3m` 已验证；板级环回要 USB-UART 也支持 3 Mbaud）。
6. 核心 25 MHz，处理带宽 ~25 MB/s（仍是 115200 线速的 2000 倍以上）；
   没有 DDR3/网口，也就没有 L2 的重量级通路（M3 再说）。
7. 档位只有 `mode=1`（T1）：T0 直通的 RTL 参数已留（`MODE_T1`），但没有运行时控制通道，
   想真切换得先做软流控/成帧协议（下面第 4 条）。

**下一步（建议顺序）**

1. 上板跑 `--check`，把 18 个向量在真板子上过一遍（LED2 应该是灭的）。
2. `l1_merge` 的 5 路插入流水化 —— 现在是整块最深的 31.5 ns；拆成两拍就能上 50 MHz。
3. token 策略进 RTL（变长输出 + 反压），摘要行加 token 计数。
4. XON/XOFF 或"先发长度再发内容"的成帧协议：既能灌大文件，也能当 T0/T1 的运行时开关。
5. 板级 3 Mbaud 环回（USB-UART 支持 3 Mbaud 的型号）+ 网口形态（更接近"网关"叙事）。
6. 把 L2（INT4 语义层）接在 L1 之后，档位头 `X-Privacy-Mode` 进摘要行。
7. 分隔符快照只保留"最后一个分隔符之前"的前缀：三个以上号码被空格连在一起时
   （`13800138000 13800138001 13800138002`）中间那个仍会丢，要根治得缓存两段数字，
   见 TODO。