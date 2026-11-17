# QS

`guard/` —— 隐私守门人（PII 脱敏网关）线。

```
QS/
├── .git/                 # 仓库根：追踪整个 QS 工程
├── .gitignore
├── .gitattributes
└── guard/                # L1 规则 + L2 INT4 语义脱敏（见 guard/README.md）
```

## 入口

```bash
cd guard
make test        # 本机平台：金标 + Verilator 一致性仿真
```

## 文档

- [guard/README.md](guard/README.md)
- 规划 [guard/docs/plan-pii-gateway.md](guard/docs/plan-pii-gateway.md)
- 任务清单 [guard/TODO.md](guard/TODO.md)
- **已上板**（串口进 → 脱敏 → 串口出，盘古 200Pro+，115200 8N1）：
  操作手册 [guard/docs/board-bringup.md](guard/docs/board-bringup.md)，
  设计与验证 [guard/docs/board-uart.md](guard/docs/board-uart.md)
