# 手势训练全链路（PC → 上板）

本文件描述在本机 Ubuntu 上，用本机摄像头采集手势、训练、量化、位精确验证，
最后再在 Windows 上打包上板的完整流程。

核心原则：**先在本机把算法和量化跑对，再上板**。`pcvision/gesture/hw_emulate.py`
按 RTL 的整数语义实现（算术右移 + 舍入 + 饱和/ReLU + 全帧 argmax），
所以 PC 上看到的量化结果与板端一致；它仍建议在上板后用真实画面复核一次。

## 0. 统一入口

日常只用 **pcvision/gesture/gesture.sh**；其他 .sh/.py 是内部实现。

| 命令 | 作用 |
|---|---|
| gesture.sh setup | 建隔离 venv + 依赖 |
| gesture.sh doctor | 环境 / CUDA / 摄像头自检 |
| gesture.sh app | 网页工作台 + 演示页 |
| gesture.sh record | 引导式/手动采集 |
| gesture.sh train | 训练 |
| gesture.sh export / eval | 量化导出 / float+位精确评估 |
| gesture.sh all | train → export → eval → pack |
| gesture.sh monitor | 命令行实时监测 |
| gesture.sh status / manifest / clean | 状态 / 清单 / 清理 |
| gesture.sh smoke | 合成数据自检 |

### 最短路径（推荐工作台）

```bash
cd /home/ccy/Documents/qs/QS/gesture
bash pcvision/gesture/gesture.sh app
# 工作台 http://127.0.0.1:8765 ／ 演示页 http://127.0.0.1:8765/demo
```

一个网页里完成：摄像头预览 → 采集 → 训练 → 量化+评估 → 实时监测，
右侧有日志和重置按钮。流程：

1. 在“1 采集”里填手势名（例如 `fist,open_palm,point`），点“应用类别”；
2. 点“开始引导录制”，按画面提示做动作；每类 4 轮，背景轮空手；
3. “2 训练”点“开始训练”（默认 60 epoch）；
4. “3 量化 + 评估”点“导出 .mat 并评估”，看两个准确率和阈值；
5. “4 实时监测”点“开始监测”，实时看类别/置信度/框；
6. 打开 http://127.0.0.1:8765/demo 是**纯展示页**：大标签 + 7 帧多数投票 + 动作事件。

> 本地展示先跑顺，再迁移到板子；板子/RV/HDMI 现在不碰。
> 背景误报多时，用“采集背景 6 秒”按钮，点 3–4 次（空场景/手自然放/不同位置）。

> 工作台只是把下面这些 CLI 包了一层，两者可以混用。
> 不想开网页时：
>
> ```bash
> bash pcvision/gesture/gesture.sh doctor
> bash pcvision/gesture/gesture.sh record --rounds 4 --names fist,open_palm,point
> bash pcvision/gesture/gesture.sh all
> bash pcvision/gesture/gesture.sh monitor
> ```

---

## 0.5 当前状态（2026-11-12 快照）

| 项 | 当前值 |
|---|---|
| 类别 | 7 类：background / fist / open_palm / point / victory / thumbs_up / ok |
| 数据 | 370 帧；1 个完整轮次 + 部分轮次 |
| 模型 | float 89.04% / 位精确 89.04% / float-int 一致率 100% |
| 阈值 | none（无干净分界，监测不启用阈值） |
| 动作层 | HOLD / SWIPE_L/R/U/D / SEQUENCE；工作台可调参数 |
| 镜像 | 工作台“自拍镜像”开关；默认不勾=原始非镜像，勾选=左右翻转 |
| 板子 | 未动；RV/HDMI/PDS 暂停 |

注意：89.04% 是**同一段录制的分层验证**，实时泛化会下降。下一步是补
2–3 个完整轮次 + 3–4 次背景采集，再看新 session 的准确率和实时误报；
动作层先做语义映射/调参，不急着上板。

---

## 1. 两条边界，先看清楚

| 能力 | 跑在哪 | 说明 |
|---|---|---|
| **静态手势分类**（拳头 / 张掌 / 指 / 剪刀手 …） | **PC 训练 → FPGA 推理** | 硬件是单帧 80×45 逐格分类，天然支持 |
| **手势动作**（按住、左划、右划 …） | **PC 后处理**（`actions.py`） | 需要多帧历史；今天是 PC 策略层，以后可搬进 RV 核 |
| 连续动作分割 / 时序网络 | 不在本期 | 现有 RTL 没有时序单元 |

类别约定：**class 0 = 背景/无手势**，手势从 1 开始，最多 **15 个手势**
（头部层固定 16 通道，`pack_model.py` 会自动补齐到 16）。

> 手机 IMU + MediaPipe 的 5 个游戏动作（攻击/治疗/举盾/弹反/闪避）是**另一条线**，
> 对应 pc/host；它不使用本页的手势 CNN，也不能直接跑在 FPGA 上。
> 本平台不读取、不修改线 A。

### 和旧车牌内容的关系

这条链路**不读取**旧车牌的权重、图片、标注或 LPRNet 支路。旧车牌只存在于
历史视觉 demo（`cam/`、`fpga/rtl_pds` 的 LPRNet）里；旧位流已删除；手势训练只复用
**11 层 conv/ReLU 的单帧 80×45 骨架**。上板打包时 `pack_model.py` 直接用你的
手势权重覆盖 11 层的 `.mem/.vh`，不会把车牌权重带进去。

是否把 LPRNet/车牌资产从仓库里**物理删除**，见第 11 节。

---

## 2. 环境隔离（重要）

训练环境**完全隔离**在仓库之外的一个工作区，不污染系统 Python、不写 `~/.cache`：

    /home/ccy/Documents/qs/gesture-env/      # 本机默认 $QS_GESTURE_HOME
    ├── env/            Python venv（torch cu124 + opencv …）
    ├── cache/          pip / torch / xdg 缓存（全部重定向到这里）
    ├── data/           classes.json、raw/ 图片与 labels.csv
    ├── runs/           checkpoint、训练日志
    ├── out/            .mat、eval.json、打包文件、冒烟测试
    ├── MANIFEST.md     自动生成的“装了哪些东西 + 各占多大”
    └── install_manifest.tsv

**工作区位置规则**（`env.sh` 与 `common.py` 同一套，本文档是唯一出处）：
显式设置 `QS_GESTURE_HOME` 时直接用它；否则优先 `<repo>/../gesture-env`，
不存在再回退到 `<repo>/../../gesture-env`。仓库收进 `QS/gesture/` 之后，
本机实际命中的就是 `/home/ccy/Documents/qs/gesture-env`。
其他文档一律写 `$QS_GESTURE_HOME` 并指向本节，不再重复具体路径。
**仓库只保留脚本，不存图片和权重。**

> 工作区要放在 **ext4 本地盘**（默认就是）。不要放到 NTFS / `/mnt/e`
> 或 WSL 挂载上：venv 的权限位和文件锁会出问题，速度也差很多。

### 首次安装

```bash
cd /home/ccy/Documents/qs/QS/gesture
bash pcvision/gesture/gesture.sh setup          # CUDA 版（本机 RTX 4060）
bash pcvision/gesture/gesture.sh doctor             # 包 / CUDA / 摄像头 / 显示 自检
```

没有 NVIDIA 显卡时用 `--cpu`。安装脚本会把重定向的缓存目录、venv、
pip 包清单都记进工作区清单。

### 查看清单 / 清理

```bash
bash pcvision/gesture/gesture.sh manifest           # 刷新 MANIFEST.md（含体积与包清单）
bash pcvision/gesture/gesture.sh clean            # 只预览，不删除
bash pcvision/gesture/gesture.sh clean --yes      # 删除整个工作区
bash pcvision/gesture/gesture.sh clean --yes --keep-data   # 只删环境，保留数据
```

清理脚本只动 `$QS_GESTURE_HOME`，并拒绝删除仓库内路径。系统层面**没有**
安装任何 apt 包；如果以后装了（如 `v4l-utils`），手册里会补记。

---

## 3. 采集数据集

### 3.1 想清楚要几个手势

先改类别名（默认 6 个：fist / open_palm / point / victory / thumbs_up / ok）：

```bash
bash pcvision/gesture/gesture.sh record --names fist,open_palm,point,victory
```

第一次运行会把类别写进 `data/classes.json`；之后不要再改，否则标签对不上。

### 3.2 引导式录制（推荐）

```bash
bash pcvision/gesture/gesture.sh record --rounds 4
```

流程：每个类别按一次 **Space** → 3 秒倒计时 → 自动录 `--seconds` 秒
（默认 8 秒 × 5 帧/秒 = 40 张）→ 自动进入下一类。最后会自动录一类
**背景（无手势）**。一轮结束后自动开始下一轮；**每轮是独立 session**，
用于可信的训练/验证切分。窗口里绿框是建议手部区域，十字是标签中心。

录制要点：
- 手放在绿框内，**距离 0.3–0.6 m**，让手掌约占画面 1/5；
- **至少 3 个完整轮次**（40 张/轮），最好 4–8 轮，换角度、距离、背景、
  光照，**总样本 150–300 张/类**。只录 1 轮时，验证集看着高但实时很容易
  误报/认错——第一版 7 类数据就是 1 个完整轮次，实时会把普通画面判成 fist；
- 背景类建议分 2 轮录（空画面 + 有手但不做手势），合计 80 张以上；
- 每轮录制是一个独立 `session`；**验证集按 session 切分**，避免同一段视频
  泄漏进验证集；
- 保持光照稳定，避免逆光和强背光。

采集工具选项：

| 选项 | 作用 |
|---|---|
| `--manual` | 自由模式：1–9 选类、Space 保存、0 背景、b 连拍、u 撤销 |
| `--camera N` | 换摄像头 |
| `--seconds 10 --save-fps 4` | 引导式录制的时长/帧率 |
| `--names a,b,c` | 覆盖类别名（仅首次） |
| `--roi 440` | 绿框大小 |
| `--tracker mediapipe` | 可选：自动跟踪手心（需另装 mediapipe） |

> 不装 mediapipe 时标签中心=画面中心/点击位置；训练用高斯软标签
> （σ=2 格，约 32 px）并对平移做增强，所以手小幅漂移不会毁掉标签。
>
> 想让标签自动跟手，可另装（会带 opencv-contrib，装完重跑 `gesture.sh doctor`）：
>
> ```bash
> $QS_GESTURE_HOME/env/bin/pip install "mediapipe==0.10.35"
> ```
>
> 然后 `gesture.sh record --tracker mediapipe`；检测不到手的帧会自动跳过。

先确认摄像头通路（不录手势、不弹窗，只存 3 张背景图）：

```bash
$QS_GESTURE_HOME/env/bin/python pcvision/gesture/capture_gestures.py --selftest 3 \
    --out $QS_GESTURE_HOME/out/selftest
# 看 out/selftest/selftest/*.jpg 正常后删掉：
rm -rf $QS_GESTURE_HOME/out/selftest
```

### 3.3 镜像（自拍 / 非镜像）

工作台预览下方有 **“自拍镜像”** 复选框；CLI 对应 `--mirror`。

- **不勾**：原始画面，文字正常，像别人看你（非镜像）；
- **勾选**：左右翻转，像照镜子（自拍镜像）。

勾选后 **预览和新录制的帧一起翻转**；已有数据方向不变。切换后建议重新录一轮，
保持训练/推理方向一致。录制过程中不要切换。

### 3.4 数据长什么样

`data/raw/labels.csv`：

    file,cls,x,y,session
    g_s20261112_190000_..._c1.jpg,1,642,355,s20261112_190000
    g_s20261112_190000_..._c0.jpg,0,-1,-1,s20261112_190000

图片是 **1280×720** 的 letterbox 结果，和板子输入几何一致；jpg 质量 95。

---

## 4. 训练

```bash
bash pcvision/gesture/gesture.sh train
# 或自定义：
bash pcvision/gesture/gesture.sh train --epochs 80 --batch 4 --lr 3e-4
```

- 网络：`ml/model_template.py` 的 **MundusDet**（conv/ReLU/maxpool，无 BN，
  无残差，无上采样），输出 80×45×K；
- 损失：逐格 focal loss（CenterNet 式）+ **整帧交叉熵**。整帧项直接优化
  “全帧 argmax 的类别”，因为板子就是这么判决的；
- 增广：旋转 ±8°、缩放 0.9–1.1、平移 ±36 px、亮度/对比度/HSV/模糊/噪声/JPEG；
  默认**不做水平翻转**（左右手含义会变，确需可加 `--hflip 0.1`）；
- 归一化：训练用 `(x-128)/128`；导出与 RTL 用 `x-128`。两者相差一个
  正标量，逐层量化缩放由 `shift_k` 吸收；偏置与舍入会带来少量偏差，
  **准确率以第 5 节的位精确评估为准，不要只看 float**；
- 自动按 session 切 20% 验证集，保存验证集整帧准确率最好的 checkpoint；
- 早停 patience 20；产物：`runs/gesture.pt`、`runs/gesture.json`、
  `runs/gesture.csv`、`runs/gesture_last.pt`。

看日志里的 `frame-acc`：整帧类别判对的比例。**先到 90%+ 再谈上板**。

---

## 5. 量化 + 位精确评估（这一步不能跳）

```bash
bash pcvision/gesture/gesture.sh export   # 用真实帧做量化校准
bash pcvision/gesture/gesture.sh eval     # float + 位精确对比
```

- `export` 会用 `data/raw` 里按类别均衡抽样 8 张做校准，逐层选幂次移位
  `shift_k`，并打印每层峰值与裁剪比例；
- **偏置按累积激活尺度修正**（默认 `--bias-mode corrected`）。这一步不能省：
  第一版导出器只按 `1/scale` 缩放偏置，7 类手势模型量化后**全判背景**
  （int 11%）；修正后 float/int 都是 **89.04%**、一致率 **100%**。
  只有复现旧结果时才用 `--bias-mode legacy`；
- `eval` 同时报告 **PyTorch float** 和 **hw_emulate 整数** 的准确率、
  每类召回、负样本误报率、混淆矩阵；
- 两者差距大 = 量化不可接受，先回到训练（加数据/调 `--sigma`），不要上板。

### 训练/验证切分（`--split-mode`）

- `auto`（默认）：优先整 session 切分；如果某个 session 不完整（缺少类别）
  或验证集超过一半，则退回**按类别分层抽样**；
- `session`：只按 session 切，绝不泄漏相邻帧，但数据少时验证集可能缺类；
- `stratified`：每类随机抽，保证验证集覆盖所有类别。

> 分层抽样的验证帧与训练帧来自同一段录制，**89% 是偏乐观的**；真实泛化
> 要看新录的 session。工作台/训练日志会打印验证集类别，务必确认没有缺类。

### 置信度阈值（必须一起看）

背景帧偶尔会被判成手势，但通常分数很低。`eval` 会自动找“最强负样本”
和“最弱真手势”之间的分界，报告**带阈值**的准确率：

    == bit-exact ... threshold 53.5 (clean gap) ==
    samples 32  frame-accuracy 100.00%

- `clean gap` = 负样本分数全部低于真手势，阈值能完全分开；
- **没有负样本/正样本，或分数重叠时，阈值为 `none`（不启用）**，不会
  硬塞一个 0.0。早期版本把阈值设成 0.0，而模型 logit 是负数，实时监测
  就把所有检测都当成“no gesture”藏掉了；
- 阈值写进 `out/eval.json` 的 `threshold` 字段（可能为 `null`）；
  `live_demo.py` / 工作台只在 `clean_separation=true` 时自动采用；
  板端对应 `frame_argmax` 的 `CONF_THRESH`（或 RV/PC 后处理）；
- 强制指定：`bash pcvision/gesture/gesture.sh eval --thresh 50`。

结果：`out/eval.json`、`out/eval.csv`（逐帧 float/int 对照）。

单独校验每层 .mat 里存的 input/output 参考对与模拟器逐位一致
（这是导出器 ↔ 模拟器的自洽性检查，不是跑 RTL 仿真）：

```bash
$QS_GESTURE_HOME/env/bin/python pcvision/gesture/hw_emulate.py \
    --mat $QS_GESTURE_HOME/out/mats --verify
# 期望最后一行：ALL MATCH
```

---

## 5.5 线 B 展示语义（PC 本地 → 板子）

- 本地：工作台 + /demo；显示前 7 帧多数投票，动作由 actions.py 的
  HOLD / SWIPE_L / SWIPE_R / SWIPE_U / SWIPE_D / SEQUENCE 产生；
- 工作台第 4 栏可调：按住 s（默认 0.8）、滑动格（6）、序列 s（1.2）；
  SEQUENCE = 两个**不同**手势在窗口内直接切换，冷却 1 s；
- /demo 会在大标签上方用黄色横幅显示最新动作，右侧保留事件列表；
- 展示动作只来自单帧手势 + 格子时序，**不用手机 IMU / MediaPipe / Pose**；
- 板子迁移（效果满意后）：PC HDMI 720p60 → 板子 CNN → frame_argmax →
  OSD/UART；RV32 调度器做去抖/hold/swipe。当前阶段不碰板子/RV/HDMI；
- 不接游戏/手柄；表里的 5 个游戏动作属于线 A，不是本平台验收项。

## 6. 实时监测（训练完成后）

工作台第 4 栏直接点“开始监测”即可。命令行方式：

```bash
bash pcvision/gesture/gesture.sh monitor
# 等价于：
# $QS_GESTURE_HOME/env/bin/python pcvision/gesture/live_demo.py \
#     --ckpt $QS_GESTURE_HOME/runs/gesture.pt
```

- 实时显示类别、置信度、命中的格子与框；显示前做 **7 帧多数投票**（4/7 才稳定），减少闪烁；
- 工作台的“采集背景 6 秒”会快速补 class 0 负样本，专门压实时误报；`/demo` 是展示用大屏页面；
- `actions.py` 把逐帧结果变成 **hold / swipe_left / swipe_right / swipe_up /
  swipe_down / sequence** 事件；按 `s` 存截图，`p` 暂停，`r` 清状态，`q` 退出；
- `--events out/events.jsonl` 落盘事件；
- `--threshold T` 可提高“报告手势”的门槛（板子端对应 frame_argmax 的阈值）。

动作层参数在 `pcvision/gesture/actions.py` 的 `ActionConfig`：投票窗口 7 帧、
锁定 5 票、按住 0.8 s、滑动 6 格（96 px）/0.35 s、冷却 0.7 s、序列窗口 1.2 s /
冷却 1 s。工作台的输入框会覆盖这些默认值。模型输出是原始 logit（可能为负），
动作层默认不过滤分数；只有设置阈值时才按阈值过滤。单元测试：

```bash
$QS_GESTURE_HOME/env/bin/python pcvision/gesture/test_actions.py
```

---

## 7. 上板（Windows，训练满意之后再做）

> **当前 PC 本地阶段不执行本节。** 这里只是效果满意后的迁移方案；
> 板子/RV/HDMI/PDS 仍暂停。

### 7.1 在 PC 上打包

```bash
bash pcvision/gesture/gesture.sh pack
```

产物在 `$QS_GESTURE_HOME/out/hw/`：

    header/    layer*.vh（结构参数）
    mem_data/  weight_*.mem、bias_*.mem（权重/偏置）
    conv_data_hex_pds/  仿真激励 hex

K 类会自动补齐到 16 通道，多余通道偏置 −2²⁰，永远赢不了 argmax。

### 7.2 在 Windows 侧覆盖并综合

把 `out/hw/header/*` 和 `out/hw/mem_data/*` 拷到 Windows 仓库对应目录，
覆盖车牌权重（这正是“换模型”）。先备份，再覆盖：

```powershell
# 在 Windows 仓库根目录（先备份旧权重）
robocopy fpga\rtl_pds\data_process\header fpga\rtl_pds\data_process\header_backup /E
robocopy fpga\rtl_pds\data_process\mem_data fpga\rtl_pds\data_process\mem_data_backup /E
# 覆盖（源目录改成你从 PC 拷过来的 out\hw）
robocopy Z:\gesture-env\out\hw\header  fpga\rtl_pds\data_process\header  /E
robocopy Z:\gesture-env\out\hw\mem_data fpga\rtl_pds\data_process\mem_data /E
```

如果还要跑 RTL 仿真，把 `out/hw/conv_data_hex_pds` 一并拷到
`fpga/rtl_pds/conv_data_hex_pds`。

然后按原流程综合、烧写：

```powershell
powershell -File tools/make_build_tcl.ps1
D:/Pango/PDS_2025.2-SP3-EN-ads/bin/pds_shell.exe -file ../../tools/build_full.tcl
powershell -File tools/program.ps1 -Bitstream bitstreams/<xxx>.sbit
```

### 7.3 上板后必须做域适配

PC 摄像头 ≠ 板子 HDMI 输入（曝光、白平衡、镜头、噪声都不同）。
上板后录 100–200 帧板子输入画面，加入数据集做一次**微调**：

```bash
bash pcvision/gesture/gesture.sh train --data $QS_GESTURE_HOME/data/board --epochs 20
```

（把板子采集帧和 labels.csv 放到 `data/board`；类别顺序必须与
`classes.json` 一致。）

### 7.4 板端行为

- 每帧输出全帧最强格：`{class, cell, conf}`；
- 框固定 64×40，画在格中心；
- class 0 或 conf 低于阈值时视为“无手势”；
- 动作（hold/swipe）目前由 PC 侧 `actions.py` 产生，若要板上闭环，需把
  同一状态机写进 RV 调度器固件（接口就是逐帧 class/cell/conf）。

---

## 8. 冒烟测试（不碰真实数据）

```bash
bash pcvision/gesture/gesture.sh smoke
```

自动生成合成数据 → 训练 4 epoch → 量化校准 → 逐位校验 → float/int 评估
→ 打包 → 动作层单测。全程在 `out/smoke`，不会污染 `data/raw`。

> 4 epoch 只验证“链路通”，准确率数字没有意义（合成任务 20 epoch 可到 100%）。
> 冒烟通过后，用真实数据重新训练。

---

## 9. 排错

| 现象 | 先查 |
|---|---|
| 打不开摄像头 | 是否被浏览器/会议软件占用；`ls -l /dev/video*`；`gesture.sh doctor` |
| 画面全黑 / 绿 | 换 `--camera 1`；确认不是 IR 摄像头；`--width/--height` 换原生分辨率 |
| 训练 loss 不降 | 类别是否只录了背景；`labels.csv` 的 cls 是否 1..K-1；学习率降到 1e-4 |
| 验证准确率高、实拍差 | 数据太少/太单一；补录不同背景、距离、光照；检查 session 切分 |
| float 好、位精确差 | `export` 的 `clip%` 是否过高；增加校准帧；回训练降低激活范围 |
| 所有帧都判背景 | 先看 `eval.json` 的 `bit_exact`：若 int 远低于 float，用默认 `--bias-mode corrected` 重导；若两者都低，补正样本/背景 |
| 实时有类别但没框 | 阈值被设成 0 且 logit 为负；把阈值留空（`null`），或看“最近检测”里的 conf |
| 实时一直判某个手势 | 该类样本过多/背景太少；补 2–3 轮背景和不同角度，别只录同一姿势 |
| 上板无框/全错 | 先跑 `python pcvision/gesture/hw_emulate.py --mat <mats> --verify`；确认输入真是 720p60；再查域差异 |
| 训练很慢 | 确认 `gesture.sh doctor` 里 CUDA available=True；`--workers 4`；batch 提到 8 |

---

## 10. 文件一览

    pcvision/gesture/
    ├── gesture.sh           唯一入口（setup/doctor/app/record/train/eval/...）
    ├── README.md            快速参考
    ├── app.sh / webapp.py   网页工作台 + /demo
    ├── capture_gestures.py  摄像头采集与标签
    ├── common.py / dataset.py
    ├── train_gestures.py / evaluate.py / hw_emulate.py
    ├── actions.py / live_demo.py
    ├── smoke_test.py / test_actions.py
    └── setup_env.sh / doctor.sh / manifest.sh / cleanup.sh / record.sh /
        run_pipeline.sh / monitor.sh    内部实现（由 gesture.sh 调用）

---

## 11. 彻底移除旧车牌资产（可选，建议跑通实时监测后再做）

手势链路本身不依赖旧车牌；但仓库里仍有历史 demo 的资产。要变成“纯手势工程”，
按下面清单裁剪，**不要动 11 层卷积骨架**：

| 保留（手势复用） | 删除（车牌专属） |
|---|---|
| `fpga/rtl_pds/top_yolo` 的 11 层 conv/ReLU | LPRNet 支路（layer20–31、char decode、crop） |
| HDMI 收发、DDR 帧缓冲、`frame_argmax` | 车牌测试图、车牌标注、车牌文档段落 |
| RV 调度器 / UART（动作层以后要用） | 旧车牌位流（已删除） |
| `.vh/.mem` 覆盖机制 | 旧车牌权重 `.mem`（打包时本来就会被覆盖） |

步骤建议：

1. 先用手势模型跑通 `gesture.sh monitor`（PC 侧完全不碰 RTL）；
2. 在 Windows 工程里注释/删除 LPRNet 例化与约束，只保留 11 层视觉骨架 + 输出；
3. 覆盖手势 `.vh/.mem`，重跑 PDS，出 **gesture-only** 位流；
4. 重新测资源/时序（删掉 LPRNet 后 LUT/DRAM 会更宽松，但要以 PDS 报告为准）。

> 删除 `cam/`、LPRNet 或旧位流会影响原车牌 demo 的可复现性；建议在确认不再
> 需要车牌后，单独开一个分支做裁剪，不要和手势训练混在一起。
