# 手势训练平台（PC 本地 → 板子迁移）

唯一入口：

    bash pcvision/gesture/gesture.sh <command>

| 命令 | 作用 |
|---|---|
| setup | 建隔离 venv + 依赖（torch cu124 / opencv） |
| doctor | 环境 / CUDA / 摄像头自检 |
| app | 网页工作台：采集 / 训练 / 评估 / 监测 |
| record | 引导式采集（--rounds N，--manual 自由模式） |
| train | 用 data/raw 训练（--epochs 60） |
| eval | 量化导出 + float/位精确评估 |
| all | train → export → eval → pack |
| monitor | 命令行实时监测（HOLD / SWIPE / SEQUENCE） |
| demo | 打印工作台 / 演示页 URL |
| status | 数据、模型、工作区概览 |
| manifest | 刷新安装清单 |
| clean | 清理隔离工作区（--yes 才真删） |
| smoke | 合成数据全链路自检 |

## 最短流程

    cd /home/ccy/Documents/qs/QS/gesture
    bash pcvision/gesture/gesture.sh setup
    bash pcvision/gesture/gesture.sh doctor
    bash pcvision/gesture/gesture.sh app
    # 浏览器：http://127.0.0.1:8765
    # 演示页：http://127.0.0.1:8765/demo

工作台里：先“应用类别”，再“开始引导录制”（每类 3–4 个完整轮次），
“采集背景 6 秒”补负样本，然后训练、评估、监测。监测栏可调
hold / swipe / seq；预览下方有“自拍镜像”开关（默认原始非镜像）。

## 当前状态（2026-11-12）

- 7 类 / 370 帧；float 89.04% / 位精确 89.04% / 一致率 100%；
- 验证是同段数据分层抽样，**偏乐观**，下一步补 2–3 轮 + 背景；
- 动作层 HOLD / SWIPE / SEQUENCE 已接入工作台和 /demo；
- 板子/RV/HDMI 未动。

## 工作区

默认 `$QS_GESTURE_HOME`（仓库外，位置规则见
[../../docs/GESTURE.md](../../docs/GESTURE.md) §2）：venv、data、runs、out 都在这里；
仓库只放代码。gesture.sh manifest 看体积，gesture.sh clean 清理。

主文档：[docs/GESTURE.md](../../docs/GESTURE.md)。

## 内部文件

setup_env.sh、record.sh、run_pipeline.sh、monitor.sh、app.sh、webapp.py、
capture_gestures.py、train_gestures.py、evaluate.py、hw_emulate.py 等
是具体实现；日常只用 gesture.sh。
