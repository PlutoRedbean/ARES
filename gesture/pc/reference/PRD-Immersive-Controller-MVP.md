# Product Requirements Document: Immersive Controller MVP

## 🎯 Product Overview

**App Name:** Immersive Controller
**Tagline:** 别光按键——把你的身体变成《黑暗之魂》的最强武器。
**Launch Goal:** 实现 <20ms 超低延迟，让玩家能用身体动作流畅游玩《黑暗之魂 3》。
**Target Launch:** MVP 阶段，核心验证。

## 👥 Who It's For (用户画像)

### Primary User: "沉浸感追求者" (The Immersion Seeker)
他们是硬核动作 RPG 玩家（魂类游戏爱好者），觉得传统手柄的“按键-反馈”模式已经不够刺激，想要更深的代入感，但不想花几千块买 VR 设备。

**Current Pain (目前的痛点):**
- 手柄操作只是手指运动，和屏幕里角色的“拼命”动作割裂感强。
- 现有的体感方案（如 Kinect）延迟太高，根本玩不了需要微操的硬核游戏。

**What They Need (需求):**
- **零延迟感**：挥手即砍，不能有滞后。
- **低成本**：利用手边的手机和笔记本电脑就能玩。
- **自定义**：想怎么动就怎么动（比如自己设计一个帅气的弹反动作）。

### Example User Story
"遇见玩家阿强，他是《黑魂》老手。但他总觉得按 `L2` 键弹反很没劲。他需要 **Immersive Controller**，这样当 Boss 攻击时，他可以真实地**挥动手臂**挡开攻击，那一刻的成就感是按键无法比拟的。"

## 🔧 The Problem We're Solving

传统输入设备将复杂的战斗动作简化为“按按钮”，牺牲了物理沉浸感。现有的体感软件大多针对休闲游戏，延迟高、精度低，无法满足“魂类”游戏对 **<20ms 响应速度** 的严苛要求。

## 🎬 User Journey (用户旅程)

### 1. Setup (启动与校准)
- 阿强打开 Windows 端的 **Immersive Controller Server**。
- 打开 Android 手机 App，输入电脑 IP，点击“连接”。
- **关键步骤**：阿强站在笔记本摄像头前，按下手机上的“零点校准”键，系统锁定他的初始姿态。

### 2. Action (战斗循环)
- **移动**：左手拇指在手机屏幕的虚拟摇杆上滑动，控制角色走位。
- **轻攻击**：遇到小兵，右手握着手机**向前挥砍**（手机 IMU 检测加速度），角色立即攻击。
- **战技/弹反**：遇到 Boss，阿强**抬起左手**（摄像头 CV 捕捉骨骼点），角色瞬间使出弹反。

### 3. Safety (安全机制)
- 游戏间隙，阿强需要去倒水。他把手机放下，系统检测到 UDP 心跳包超时，自动释放所有按键，防止角色自己跑下悬崖。

## ✨ MVP Features (核心功能)

### 🔴 Must Have for Launch (P0 - 必须有)

#### 1. 计算机视觉 (CV) 动作录制与映射
- **What:** 一个允许玩家“录制”动作的界面。玩家做动作（如抬手），系统记录骨骼数据，并将其绑定到手柄按键（如 `L2`）。
- **User Story:** "作为玩家，我想录制我自己的‘举盾’姿势，这样我就不用去适应预设的动作了。"
- **Tech Note:** 使用 MediaPipe + Python Multiprocessing 确保不卡顿。

#### 2. Android 混合控制器 (Virtual Joy + Motion)
- **What:** 手机端 App，左侧是虚拟摇杆（映射左摇杆），内部利用陀螺仪/加速度计检测挥动（映射攻击键）。
- **User Story:** "作为玩家，我需要用手机控制移动，同时还能把手机当剑挥舞。"
- **Tech Note:** Android 原生 Java 开发，UDP 高频发送，避免 GC 卡顿。

#### 3. 一键“零点校准” (Zero-Point Calibration)
- **What:** 手机上的物理音量键或大按钮，按下后重置当前的陀螺仪角度和 CV 身体位置中心。
- **User Story:** "作为玩家，当我姿势歪了或者动作识别不准时，我想一键重置，不想去菜单里调。"

### 🚫 NOT in MVP (先不做)
- **游戏菜单导航**：UI 操作太繁琐，MVP 阶段建议玩家直接用鼠标/键盘操作菜单。
- **复杂的 3D 角色预览**：界面保持简单 2D 即可。
- **iOS 支持**：仅限 Android。

## 📊 How We'll Know It's Working (成功指标)

| Metric | Target | Measure |
|--------|--------|---------|
| **端到端延迟** | **< 20ms** | 从手机/摄像头动作发生到 Windows 接收到数据的耗时 |
| **游戏可玩性** | **击败古达** | 能在《黑魂3》中顺利通过灰烬审判者古达（Iudex Gundyr） |
| **连接稳定性** | **0 断连** | 在 30 分钟游玩过程中无意外断开 |

## 🎨 Look & Feel (设计风格)

**Design Vibe:** 简洁、现代 (Simple & Modern)
**UI 描述:**
- **Windows 端**: 干净的深色背景，左侧显示摄像头实时画面（带骨骼线），右侧是简单的“动作-按键”映射列表。没有复杂的装饰。
- **Android 端**: 极简布局，只有高对比度的虚拟摇杆区域和巨大的“连接状态”指示灯。

## ⚡ Technical Considerations (技术核心)

**基于您上传的研究文档：**

1.  **架构**: 
    - **PC**: Python Multiprocessing（CV 进程与 UDP 接收进程分离，通过共享内存通信）。
    - **Input**: ViGEmBus 驱动模拟 Xbox 360 手柄。
2.  **算法**: 
    - 使用 **卡尔曼滤波 (Kalman Filter)** 对手部轨迹进行平滑预测，消除网络抖动。
3.  **硬件限制**:
    - 普通笔记本摄像头（无需深度相机）。
    - Android 手机 + 普通 Wi-Fi。

## 🛡️ Quality Standards (反 Vibe 规则)

**AI 助手必须遵守：**
- **严禁阻塞主线程**：CV 推理和 UDP 接收**绝对不能**写在同一个 `while` 循环里，必须多进程。
- **安全第一**：必须实现“看门狗”机制，如果 500ms 没收到手机数据，必须自动松开所有虚拟按键。

## ✅ Definition of Done for MVP

MVP 完成的标准是：
- [ ] Windows 端能流畅显示摄像头骨骼，且 FPS > 30。
- [ ] 手机端能控制电脑上的 vgamepad 虚拟手柄（在 `joy.cpl` 中可见）。
- [ ] 挥动手机能触发攻击。
- [ ] 可以在游戏中走几步并挥刀，感觉不到明显的滞后。
