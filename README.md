# QS

ScreenSense 工程仓库。原来的手势/FPGA 项目整体收进了 `gesture/`，
新增的 LLM 线放在 `llm/`，两线共用同一个 git 仓库。

```
QS/
├── .git/                 # 仓库根：追踪整个 QS 工程
├── .gitignore
├── .gitattributes
├── gesture/              # 线 B：FPGA 实时手势/动作识别（原项目，含 README）
└── llm/                  # LLM 线（新，见 llm/README.md）
```

快速开始（沿用原入口，只是路径多一层 `gesture/`）：

    cd /home/ccy/Documents/qs/QS/gesture
    bash pcvision/gesture/gesture.sh doctor
    bash pcvision/gesture/gesture.sh app

详见 [gesture/README.md](gesture/README.md) 与 [gesture/docs/GESTURE.md](gesture/docs/GESTURE.md)。
训练/数据工作区在仓库外（`$QS_GESTURE_HOME`，位置规则见
[GESTURE.md §2](gesture/docs/GESTURE.md)）。
