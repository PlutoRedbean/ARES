# QS

两条线：

| 目录 | 是什么 |
|---|---|
| `guard/` | **隐私守门人（PII 脱敏网关）**：PC 金标 + RTL + 已上板的串口原型（盘古 200Pro+） |
| `gesture/` | 视觉/手势线（历史工程，本线不动它） |

## guard 快速开始

```powershell
cd guard
make test                  # 本机：金标 + Verilator 一致性（80 单测 / 1000 语料 / 48 边界）
make board-sim             # 板级：位级 UART 端到端（18 例，逐字节）

.\tools\build_guard.ps1    # 出位流（Windows + PDS 2025.2）
.\tools\program_guard.ps1  # JTAG 烧到盘古 200Pro+（掉电即丢，重新上电要再烧）
python tools\serial_host.py -p COM9 --repl     # 交互：敲文本 + 回车 → 脱敏结果 + 审计行
```

## 文档

- [guard/README.md](guard/README.md) —— guard 线总览（怎么跑、怎么验、目录结构）
- [guard/docs/board-bringup.md](guard/docs/board-bringup.md) —— 上板手册（烧写、串口第一测、验收、排障）
- [guard/docs/board-uart.md](guard/docs/board-uart.md) —— 板级设计与验证（协议、时序、资源、bug 日志）
- [guard/TODO.md](guard/TODO.md) —— 任务清单与下一步（L2 语义层等）
