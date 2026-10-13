# Y9：拿真实 YOLO 模型对账 —— 一个卷积层已经跑在硬件上

> 前面所有网络的权重要么是 LCG 生成的，要么来自合成任务。这一轮下载了**真实的
> 训练权重**，写了 ONNX 可行性分析器，并让真实权重在加速器上**逐比特跑通**。

---

## 1. 拿到了什么

网络可用（bash 里 curl 能通），于是：

```bash
python3 -m venv .venv && .venv/bin/pip install onnx numpy
curl -sSL -o models/tiny-yolov3.onnx \\
  https://github.com/onnx/models/raw/main/validated/vision/\
object_detection_segmentation/tiny-yolov3/model/tiny-yolov3-11.onnx
```

35 MB，opset 11，279 个节点：**13 Conv / 11 BatchNorm / 11 LeakyRelu / 6 MaxPool /
15 Concat / 1 Resize / 1 NonMaxSuppression**。这是一个真正的 YOLO。

---

## 2. 可行性分析器

`integration/tools/onnx_feasibility.py`：按拓扑序走图、**把 BatchNormalization 折进
前面的卷积**、推导 NCHW 形状，然后逐层对照硬件**真实**的约束（不是猜的）：

| 约束 | 来源 |
| --- | --- |
| c_in / c_out 必须是 4 的倍数 | MT_GEMM 是 4×4×4 INT8 tile |
| kernel 只能是 1 或 3 | net_pad 的 tap 表 |
| 激活只能是 ReLU | epilogue 只有一位 ReLU，**没有 LUT** |
| 池化 2×2 stride 2 | net_pool2 |
| Concat / Resize / Add | 调度器里没有这些原语 |
| 每块权重行 ≤ 144 | UB_WT 容量（net_conv 按输出组分块重载） |

跑 `tiny-yolov3` 的结果：

```
convolutions      : 13
total conv MACs   : 1,156,623,552 (1.157 GMAC)
conv weight bytes : 8,845,488
activation peak   : 2,742,336 bytes (widest layer)
non-conv ops      : Concat 15, Resize/Upsample 1, eltwise 47

VERDICT -- convolutions that need work: 13 of 13
  reasons: LeakyRelu 11, channels%4 3, pool2/1 1
```

**13 个卷积没有一个能原样执行。** 三个具体障碍：

1. **11 个用 LeakyReLU** —— epilogue 只有 ReLU 位。这是最硬的一条：真实 YOLOv3/v5/v8
   都用 LeakyReLU 或 SiLU，需要在 epilogue 里加 LUT，或者用 ReLU 重训。
2. **3 个通道数不是 4 的倍数**：输入的 3 通道，以及两个检测头的 255 输出。前者可以用
   零填充（本轮的测试就是这么做的），后者要么补到 256 再裁掉，要么改 tile 宽度。
3. **1 个 MaxPool 是 2×2 stride 1**（YOLO 的 SPP 结构），net_pool2 只支持 stride 2。

另外 15 个 Concat 和 1 个 Resize 需要调度器支持 —— 这正是我在 Y5 说过的 FPN 缺口。

### 内存与时间

| 项 | 值 |
| --- | ---: |
| 卷积权重 | 8.85 MB |
| 激活峰值 | 2.74 MB |
| 12 MiB uncached 窗口够吗 | **勉强够**（还需要 2~3 个缓冲，实际会紧张） |

代价有两种算法，**差 4 倍，引用时必须说清是哪一种**：

- **(a) GEMM 下界**：37 cycles / 64-MAC GEMM（`mt_perf` 紧循环实测）→ **0.67G cycles**，
  @300 MHz 约 **2.2 s**；
- **(b) 端到端**：真实网络还要为每个 tap 搬 A 行、每个 tile 跑 epilogue、每行 store。
  `mt_net` 实测 **0.42 MAC/cycle** → **2.75G cycles**，@300 MHz 约 **9.2 s**。

本机 Verilator 约 3×10⁵ cycles/s，所以 (b) 是 **约 2.5 小时**的仿真。这是环境限制。
把输入降到 128×128 则 MACs 降为 1/10.6，约 14 分钟 —— 这才是可验证的路径。

---

## 3. 真实权重已经在硬件上跑通

`pack_real.py` 取出 tiny-yolov3 的 **stem 卷积**（3→16, 3×3），折进 BN，量化打包；
`mt_yolo` 在加速器上执行并逐比特比对：

```
miniTensor on a real YOLO layer: tiny-yolov3 stem, 3->16 conv 32x32, run at 32x32.
  channels padded 3->4 for MT_GEMM, nmt=2, relu=0
    (real activation is LeakyReLU, unsupported)
miniTensor real YOLO layer PASSED (16384/16384 bytes, 14985 commands, 1047919 cycles)
```

**这是项目里第一个权重来自真实训练模型的层。** 两个刻意的处理都写在测试里，
不是藏起来：输入 3 通道零填充到 4；**只跑卷积、不跑激活** —— 因为 LeakyReLU 硬件
不支持，与其假装，不如把这一层跑到逐比特一致，把激活的缺口单独量化出来。

复现：
```bash
.venv/bin/python integration/tools/onnx_feasibility.py models/tiny-yolov3.onnx 416
.venv/bin/python integration/tools/pack_real.py models/tiny-yolov3.onnx
JYD_CONSOLE_CMDS='mt_yolo;quit' ./build/MundusJyd +verilator+rand+reset+0
```

---

## 4. 回归状态（六个测试全绿）

| 测试 | 状态 |
| --- | --- |
| `mt_conv` 单层 3×3 | ✅ 144/144 字节 |
| `mt_net` 4 层网络 | ✅ 6/6 阶段 |
| `mt_detect` 打包权重检测器 | ✅ 8/8 图逐比特 |
| `mt_wide` 9× UB 宽层 | ✅ 3072/3072 字节 |
| `mt_res` 残差块 | ✅ 1024/1024 字节 |
| **`mt_yolo` 真实 YOLO 卷积** | ✅ **16384/16384 字节** |

体积：`.text` 24.0 KB（IROM 32 KB），`.rodata` 106 KB、`.bss` 32 KB（DRAM 192 KB）。

---

## 5. 结论：还差什么（现在是量化的，不是估计的）

| 缺口 | 性质 | 难度 |
| --- | --- | --- |
| **LeakyReLU / SiLU** | RTL：epilogue 加激活 LUT | miniTensor 内部改动 |
| 通道数 %4 | 工具链：零填充 / 检测头补齐 | 已在本轮验证（stem 补 3→4） |
| MaxPool stride 1 | RTL 或调度：`net_pool2` 加 stride 参数 | 小 |
| Concat / Resize | 调度：UB 的向量单元够用，缺串联 | 中 |
| 仿真时间 | 环境：2.5 小时/次 @416×416 | **不是设计问题**；降分辨率或上 FPGA |

结构原语（卷积、池化、残差、1×1 头）、容量（权重分块）、量化打包都已经就位并且
逐比特可验证。

> **更正（见 [y10_leaky_relu.md](y10_leaky_relu.md)）**：本文曾断言 LeakyReLU 需要动
> miniTensor 的 RTL。**这个结论是错的。** 对 0 < a < 1 有 `leaky(x) = max(x, a*x)`，
> 而 epilogue 的 multiplier 是有符号 16 位、VPU 的 MAX8 是有符号 max —— 对同一个 C tile
> 跑两次 epilogue（`mult` 与 `round(mult*a)`）再 MAX8 即得，**不需要改 RTL**。
> 已在真实 tiny-yolov3 stem 权重上逐比特验证（16384/16384），代价 +13.7% 命令。
> 修正后的结论是：**13 个卷积里 0 个存在硬阻塞**；tiny-yolov3 用的是 LeakyReLU，
> 因此它全部可表达。真正需要 LUT 的是 YOLOv5/v8 的 SiLU。
