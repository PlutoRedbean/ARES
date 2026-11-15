# 模型插槽（Model Slot）

这份文档定义**你的模型必须长成什么样**，硬件才能直接跑。
除权重以外，前端采集、后处理、OSD、串口、仿真都已经搭好，模型到位即可上板。

---

## 1. 硬约束（硬件决定的，不可协商）

| 项 | 约束 | 原因 |
|---|---|---|
| 输入 | 1280×720 RGB，8 bit/通道 | 摄像头与 DDR 帧缓冲的几何 |
| 算子 | 只有 conv(3×3 / 1×1)、ReLU、maxpool | RTL 只实现了这三种 |
| 归一化 | **不能有 BatchNorm 层** | 必须在导出时折叠进卷积权重 |
| 激活 | **只能是 ReLU**，不能 LeakyReLU | 硬件只有一个 ReLU 通路 |
| 尺度 | **单尺度输出**，80×45 | 没有上采样、没有 FPN |
| 结构 | 只能前馈 + 分支，**不能有 concat / add** | `route` 只能在层间做一次分支 |
| 权重 | 9 bit 有符号，量化后写进 `.mem` | 脉动阵列的数据位宽 |
| 激活值 | 8 bit 有符号 | 层间传递位宽 |
| 量化 | **幂次移位反量化**（shift_k） | 硬件用移位代替乘法 |

**一句话：这是一个只认 conv/ReLU/maxpool 的定点流式网络，不能有 BN、不能有多尺度、不能有残差。**

---

## 2. 固定的骨干结构

```
输入 1280×720×3  (RGB, uint8)
  L0   conv3x3 s2   3 -> 8    ReLU     640×360
  L1   conv3x3 s2   8 -> 16   ReLU     320×180
  L2   conv3x3 s2  16 -> 32   ReLU     160×90
  L3   conv3x3 s2  32 -> 64   ReLU      80×45
  L4   conv3x3 s1  64 -> 64   ReLU      80×45
  L5   conv3x3 s1  64 -> 32   ReLU      80×45
  L6   conv3x3 s1  32 -> 32   ReLU      80×45
  L7   conv1x1 s1  32 -> 16   无        80×45   <- 头 A
  L8   conv3x3 s1  64 -> 32   ReLU      80×45   (输入取自 L4)
  L9   conv3x3 s1  32 -> 32   ReLU      80×45
  L10  conv1x1 s1  32 -> 16   无        80×45   <- 头 B
```

### 你只需要改两件事

1. **最后一层的输出通道数**（L7 / L10 现在是 16）改成 **你的类别数 K**（含背景类）；
2. **权重**全部换成你训练出来的。

中间层通道数可以改，但改了要同步改 PE 参数（见第 5 节），工作量会大很多。
建议第一次就用这套通道数训练。

---

## 3. 输出语义

网络输出是 **80×45 的逐格分类热图**，不是 bbox。

```
每个格子 (x, y) 输出 K 个分数  ->  取最大  ->  {类别, 格坐标, 置信度}
```

- 一个格子对应原图 **16×16 像素**（1280/80 = 720/45 = 16）；
- 后处理 `frame_argmax` 取**全帧最强**的一个格子；
- 再换算成像素坐标，画一个**固定尺寸的框**（当前 64×40，可改）。

### 训练目标怎么造

不是 YOLO 的 (x,y,w,h,obj,cls) 五元组，而是 **逐格热图**：

```
label[y][x][k] = 1   如果目标中心落在格子 (x,y) 且类别为 k
label[y][x][k] = 0   否则
```

也就是把检测问题变成**格子级分类**。这样才不需要 bbox 回归和 NMS。

---

## 4. `.mat` 文件格式

每一层一个 `.mat`，用 `scipy.io.savemat` 写，字段：

| 字段 | 形状 | 说明 |
|---|---|---|
| `weight` | (Cout, Cin, Kh, Kw) | 已量化的整数权重（int，9 bit 有符号范围 −256..255） |
| `bias` | (Cout,) | 已量化的整数偏置 |
| `shift_k` | 标量 | 输出右移位数（幂次反量化） |
| `input` | (1, Cin, H, W) | 训练集里的一张参考输入（用于生成仿真激励） |
| `output` | (1, Cout, H, W) | 对应的量化输出（用于逐位比对） |

> **偏置量化**：`export_mat.py` 默认 `--bias-mode corrected`，偏置按累积激活尺度
> `c_in` 修正。不要用只按 1/scale 缩放的旧做法：7 类手势模型会全判背景
> （int 11%）。修正后 float/位精确都是 89.04%、一致率 100%。只有复现旧结果
> 才用 `--bias-mode legacy`。

### 文件名（必须严格一致）

```
node_conv2d.mat        # L0
node_relu.mat          # L0 的 ReLU 参数（可只含 shift_k）
node_conv2d_1.mat      # L1
node_relu_1.mat
...
node_conv2d_10.mat     # L10（无 ReLU，不配 node_relu_10.mat）
```

规则：L0 用 `node_conv2d` / `node_relu`；L1..L6 用 `node_conv2d_N` / `node_relu_N`；
L7 和 L10 只有 `node_conv2d_N`（无 ReLU）。

---

## 5. 从训练到上板：三步

```
# 1) 训练 —— 用 ml/model_template.py 里的 MundusDet（K <= 16）
#    python3 ml/model_template.py     # 自检，确认形状

# 2) 导出量化 .mat（每个卷积层一个，含 input/output 参考对）
python3 ml/export_mat.py --ckpt build/model.pt --out build/mats --classes K --bias-mode corrected

# 3) 打包成硬件文件（.vh + .mem + 仿真 hex）
python3 ml/pack_model.py \
    --mat build/mats \
    --gen fpga/python_script/CnnHardwareGenerator_pds.py \
    --out-mem fpga/rtl_pds/data_process/mem_data \
    --out-vh  fpga/rtl_pds/data_process/header
```

打包会**直接覆盖**现有车牌权重（那正是“切换模型”的意思）。

### 类别数为什么可以任意（≤16）

两个头层在硬件里固定 16 个输出通道。`pack_model.py` 会把你的 K 类补齐到 16，
多余通道的偏置设成 −2^20，**永远赢不了逐格 argmax**。
所以 K = 2、4、10 都能直接用，**不需要改任何 PE 参数**。

### 已实测的链路

**真实 7 类手势模型**（370 帧，类别 background/fist/open_palm/point/victory/
thumbs_up/ok）：

```
train -> export_mat --bias-mode corrected -> 11 个 .mat
      -> hw_emulate（位精确）: float 89.04% / int 89.04% / 一致率 100%
      -> pack_model: 11 个 .vh + mem_data + 仿真 hex
```

另外用随机初始化的 4 类模型验证过形状/打包链路：11 个 .mat → 11 个 .vh +
mem_data + 仿真 hex，类别通道会补齐到 16。

> 当前 89.04% 是同一段录制的分层验证，偏乐观；上板前要用新 session 复核。

---

## 7. 如果硬件限制卡住你的模型

| 你的模型有 | 处理办法 |
|---|---|
| BatchNorm | 训练后折叠进前一层 conv 的 weight/bias（`torch.fx` 或 `fold_bn` 脚本） |
| LeakyReLU | 训练时直接换成 ReLU。**不要指望导出时替换**，分布会变 |
| 多尺度输出 | 只能用 80×45 这一层；小目标检测把输入裁剪/放大到 720p |
| 残差 add | RTL 不支持。可以改成把两路特征在通道维**拼接**后接一层 1×1 卷积（若通道数允许） |
| 上采样 | 不支持。改用 stride-1 卷积保持 80×45 |
| 类别数 > 16 | 改 L7/L10 的 `CHANNEL_OUT_NUM` 与 PE 参数；注意 APM 余量 |