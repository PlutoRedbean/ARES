# QS

ScreenSense 工程仓库：`gesture/` 是原来的手势/FPGA 项目，`guard/` 是隐私守门人
（PII 脱敏网关）线，两线共用同一个 git 仓库。

```
QS/
├── .git/                 # 仓库根：追踪整个 QS 工程
├── .gitignore
├── .gitattributes
├── gesture/              # 线 B：FPGA 实时手势/动作识别（原项目，含 README）
└── guard/                # 隐私守门人：L1 规则 + L2 INT4 语义脱敏（见 guard/README.md）
```

两线各有自己的入口文档：

```bash
# 手势线（PC 本地工作台）
cd /home/ccy/Documents/qs/QS/gesture
bash pcvision/gesture/gesture.sh doctor

# guard（本机平台：金标 + Verilator 一致性仿真）
cd /home/ccy/Documents/qs/QS/guard
make test
```

- 手势线：[gesture/README.md](gesture/README.md)、[gesture/docs/GESTURE.md](gesture/docs/GESTURE.md)；
  训练/数据工作区在仓库外（`$QS_GESTURE_HOME`，位置规则见 GESTURE.md §2）。
- guard 线：[guard/README.md](guard/README.md)、规划 [guard/docs/plan-pii-gateway.md](guard/docs/plan-pii-gateway.md)、
  任务清单 [guard/TODO.md](guard/TODO.md)。
