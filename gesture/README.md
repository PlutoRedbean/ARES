# ScreenSense

> **主线：线 B（展示）—— FPGA 实时手势/动作识别 demo。**
> 它不参与游戏控制；手机 IMU + MediaPipe 的线 A 是独立控制线，本线不依赖、不修改。
> 训练平台先在本机 PC 跑通，效果满意后再迁移到板子。

**两条互不依赖的线，跑在同一颗 FPGA 上。**

- **线 A（控制）** 加速度计/手机 → FPGA/PC → 虚拟手柄 → 游戏（另一条线，本文不涉及）。
- **线 B（展示）** 摄像头/PC 画面 720p60 → FPGA CNN → OSD/UART → 实时 UI。
- **动作层（线 B 内）** 单帧手势 → HOLD / SWIPE / SEQUENCE，PC 上先跑，
  以后由 RV 调度器接；不依赖手机 IMU。

目标形态：盘古 200Pro+（PG2L200H）上，线 B 用 11 层 CNN + 自研 RISC-V 核
（Mundus，8 级流水）做帧级调度，展示 CNN + CPU + OSD 的协同。

---

## 架构

    线 B（展示，本线）
      HDMI 720p60 ─► 11 层 CNN ─► frame_argmax ─► box_overlay ─► HDMI OUT
                                                └─► rv_mmio ─► RV32 调度器 ─► UART/OSD

    线 A（控制，另一条独立线）
      加速度计/手机 ─► 串口/UDP ─► PC ─► vgamepad ─► 游戏

---

## 快速开始（PC 本地）

唯一入口：**pcvision/gesture/gesture.sh**

    cd /home/ccy/Documents/qs/QS/gesture
    bash pcvision/gesture/gesture.sh setup
    bash pcvision/gesture/gesture.sh doctor
    bash pcvision/gesture/gesture.sh app

浏览器打开 **http://127.0.0.1:8765**（工作台）和
**http://127.0.0.1:8765/demo**（展示页）。

常用命令：

    bash pcvision/gesture/gesture.sh record --rounds 4   # 引导式采集
    bash pcvision/gesture/gesture.sh train --epochs 60   # 训练
    bash pcvision/gesture/gesture.sh eval                # 量化 + 位精确评估
    bash pcvision/gesture/gesture.sh monitor             # 命令行实时监测
    bash pcvision/gesture/gesture.sh status              # 数据/模型/工作区
    bash pcvision/gesture/gesture.sh manifest            # 安装清单
    bash pcvision/gesture/gesture.sh clean               # 清理（--yes 才删）

数据/模型/venv 都在仓库外的 **../../gesture-env**（更名前的 `../gesture-env` 仍兼容），仓库只放代码；
删除工作区即可释放空间，不影响代码。

详细流程、阈值、数据要求见 **[docs/GESTURE.md](docs/GESTURE.md)**。

---

## 当前状态（PC 本地，2026-11-12）

| 项 | 当前值 |
|---|---|
| 数据 | 7 类 / 370 帧（background、fist、open_palm、point、victory、thumbs_up、ok） |
| 切分 | 1 个完整轮次 + 部分轮次；当前验证是分层抽样，**89% 偏乐观** |
| 模型 | float **89.04%** / 位精确 **89.04%** / 一致率 **100%** |
| 阈值 | none（没有干净分界，不启用） |
| 动作 | HOLD / SWIPE_L/R/U/D / SEQUENCE 已接入 /demo，参数可调 |
| 板子 | 未动；RV/HDMI/PDS 仍暂停 |

下一步：补 2–3 个完整手势轮次 + 3–4 次背景采集，重训后看**新 session**的
准确率和实时误报；动作层先做语义映射/调参。详见
[docs/GESTURE.md](docs/GESTURE.md) 的当前状态与动作层章节。

---

## 目录

    ScreenSense/
    ├── pcvision/gesture/     手势训练平台（唯一入口 gesture.sh）
    ├── ml/                   模型模板 / .mat 导出 / 硬件打包
    ├── cam/                  摄像头 → DDR3 → HDMI 视觉链路
    ├── fpga/                 rtl_pds（11 层 CNN）/ python_script / ares 核
    ├── pc/host/              线 A：手机 IMU + MediaPipe 控制器（独立，不涉及）
    ├── docs/                 GESTURE.md（主指南）/ MODEL.md / PROGRESS.md
    ├── bitstreams/           本地 PnR 位流（不入库，按需创建）
    └── tools/                构建与烧写脚本

## 关键事实

| 项 | 值 |
|---|---|
| 器件 | PG2L200H-6IFBB676（盘古 200Pro+） |
| 视觉输入 | 1280×720@60 硬约束（H_TOTAL 1650 / V_TOTAL 750） |
| 网络 | 11 层 conv/ReLU/maxpool，输出 80×45 |
| 推理延迟 | 1.14 ms @148.5 MHz |
| 工具链 | PDS 2025.2-SP3 |
| 历史资源 | LUT 54.35%、DRM 58%、APM 38%（含 RV 的旧位流；当前分支未带 RV RTL） |
| 位流 | 不入库；旧车牌位流已删除，手势位流待生成 |
| 当前阶段 | **PC 本地**：手势训练 + 动作层；板子/RV 未动 |

---

## 构建（Windows，板子迁移时用）

    # 视觉基线
    powershell -File tools/make_build_tcl.ps1
    cd fpga/prj_pds
    D:/Pango/PDS_2025.2-SP3-EN-ads/bin/pds_shell.exe -file ../../tools/build_full.tcl

    # RV 版本：fpga/rtl_rv 已从当前分支清理，需先从历史版本恢复
    # （dc4be28^）再跑 tools/build_rv.tcl；详见 docs/PROGRESS.md

当前 PC 本地阶段不需要 PDS。

---

## 边界

- 线 B 只做展示：HDMI 框/颜色 + UART 事件，不接游戏/手柄；
- 线 B 的动作只由单帧手势 + 格子时序推导（HOLD/SWIPE/SEQUENCE），
  不用手机 IMU / MediaPipe / Pose；
- 线 A 的手机/手柄控制是另一条独立线，不依赖、不修改；
- 不做多目标 NMS、精确 bbox、目标跟踪、中文 OSD。

## 文档

- [docs/GESTURE.md](docs/GESTURE.md) — 平台入口、采集、训练、评估、演示、板子迁移
- [docs/MODEL.md](docs/MODEL.md) — 模型合同
- [docs/PROGRESS.md](docs/PROGRESS.md) — 进度与实测
