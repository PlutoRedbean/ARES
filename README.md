# QS

![ARES GUARD](guard/docs/ares-guard-logo.png)

```
    _    ____  _____ ____     ____ _   _    _    ____  ____
   / \  |  _ \| ____/ ___|   / ___| | | |  / \  |  _ \|  _ \
  / _ \ | |_) |  _| \___ \  | |  _| | | | / _ \ | |_) | | | |
 / ___ \|  _ <| |___ ___) | | |_| | |_| |/ ___ \|  _ <| |_| |
/_/   \_\_| \_\_____|____/   \____|\___//_/   \_\_| \_\____/
```

*PII redaction, on the wire —— 串口进，脱敏文本 + 审计行出。*

单仓库单线：`guard/` —— **隐私守门人（PII 脱敏网关）**。PC 金标 + Verilator 一致性 +
已上板的串口原型，目标板 **盘古 200Pro+（PG2L200H）**，25 MHz。

## 快速开始

```powershell
cd guard
make test                  # 本机：金标 + Verilator（11 组，全绿）
make ner-check             # NER 模型 16 条门槛（尺寸/整数一致/可复现/召回/长文档）

.\tools\build_guard.ps1    # 出位流（Windows + PDS 2025.2-SP3）
.\tools\program_guard.ps1  # JTAG 烧板（掉电即丢，重新上电要再烧）

python tools\serial_host.py -p COM9 --repl                 # 交互
python tools\serial_host.py -p COM9 --file examples\demo09_mixed.txt   # 跑样例
```

## 板上实测（当前位流）

| 项 | 值 |
|---|---|
| 资源 | **20,895 / 159,800 LUT（13.08%）· 3,814 FF · 6.0 DRM · 17 APM · 1 PLL** |
| 时序 | WNS **+5.22 ns** @25 MHz（TNS 0）→ Fmax ≈ 28.8 MHz |
| 位流 | `guard/generate_bitstream/guard_board_top.sbit`（9,188,552 B） |
| 串口 | 115200 8N1，帧边界 = LF 或空闲 2.6 s |
| 自检 | `tools/board_smoke.py` **12/12**；`examples/` 10 个演示逐句验过 |

## 文档

| 文件 | 内容 |
|---|---|
| [guard/README.md](guard/README.md) | guard 总览：状态、怎么跑、目录、硬约定 |
| [guard/TODO.md](guard/TODO.md) | 下一步与已知限制 |
| [guard/docs/board-bringup.md](guard/docs/board-bringup.md) | 上板手册：烧写、串口第一测、排障 |
| [guard/docs/board-uart.md](guard/docs/board-uart.md) | 板级设计：协议、掩码策略、资源、bug 日志 |
| [guard/docs/l2-int4.md](guard/docs/l2-int4.md) | L2 语义层 + NER 数据通路与模型 |
| [guard/docs/ubuntu-ner.md](guard/docs/ubuntu-ner.md) | NER 训练交接书（v4 要求、验收门槛） |

## 分工

| 目录 | 作用 |
|---|---|
| `guard/rtl` | 可综合 RTL：`l1/` 规则与替换、`l2/` 语义与 NER、`board/` 串口/摘要/顶层 |
| `guard/host` | 金标（纯 Python/numpy）：规则、合并、掩码、NER 整数推理、板级协议 |
| `guard/tools` | 构建、烧写、训练、评测、串口上位机 |
| `guard/sim` | Verilator testbench |
| `guard/tests` | 单测（pytest/unittest） |
| `guard/data`、`guard/models` | NER 语料与 INT8 模型产物 |
| `guard/vendor` | 第三方（ARES 核等），来源见 `PROVENANCE.md` |

## 约定

- 数字必须可复现：`make test` / `make ner-check` / `tools/board_smoke.py` 三条命令给出所有结论；
- RTL 只写可综合子集（`logic` / `always_ff` / `always_comb` / 函数），不用 interface/struct/动态数组；
- 金标与 RTL 必须逐字节一致，不一致优先信金标并补测试；
- 位流是 JTAG 灌 SRAM，**断电即丢**。
