# Y6：离线权重打包与 INT8 量化方案

> 前面所有网络的权重都是在固件里用 LCG 现场生成的 —— 能验证硬件，但不是"部署模型"。
> 这一轮补上缺的那一环：**从训练好的模型到加速器内存镜像的完整工具链**，并在硬件上逐比特对齐。

---

## 1. 任务与模型

工具链需要一个真实的、可量化的任务来承载。这里用合成检测任务：

- 输入 32×32 单通道图，含一个 12×12 亮方块，位置随机；
- 输出 8×8 网格（每格 4×4 像素），每格给出**覆盖度**（该格至少一半落在方块内）与尺寸回归；
- 解码 = 覆盖度图的正加权质心 → 框中心。

模型就是 `mt_net` 那套拓扑，逐层一致：

```
conv 3x3  4->8   pad1 [ReLU]   32x32x8
maxpool 2x2                     16x16x8
conv 3x3  8->16  pad1 [ReLU]   16x16x16
maxpool 2x2                      8x8x16
conv 3x3 16->16  pad1 [ReLU]     8x8x16
head 1x1 16->8   (obj, w, h)     8x8x8
```

前三级卷积用**固定随机权重**当特征提取器，只训练 1×1 头 —— 于是训练退化成一次最小二乘，
numpy 秒级完成，不需要 torch。

---

## 2. 量化方案

**对称逐张量 INT8，零点固定为 0**：

```
激活     x_q = round(x_float / s_x),   s_x = max|x| / 127
权重     w_q = round(w / s_w),         s_w = max|w| / 127
累加     acc = Σ x_q · w_q                                  (INT32)
输出     y_q = clamp((acc + b_q) · mult >> shift)           (INT8, 可选 ReLU)
```

其中 `b_q = round(b_float / (s_x·s_w))` 是累加器量纲下的偏置，`(mult, shift)` 就是 epilogue 的定点因子：

```
mult / 2**shift  =  s_x_in · s_w / s_x_out
```

**shift 取"能塞进 int16 的最大值"**，让 requant 精度最高。四个网络层的实测值：

| 层 | s_in | s_w | s_out | mult | shift |
| --- | ---: | ---: | ---: | ---: | ---: |
| L1 | 0.00787 | 0.01420 | 0.02906 | 32275 | 23 |
| L2 | 0.02906 | 0.01730 | 0.11539 | 18267 | 22 |
| L3 | 0.11539 | 0.01746 | 0.43697 | 19334 | 22 |
| L4 | 0.43697 | 0.00015 | 0.01082 | 24767 | 22 |

激活尺度 `s_x` 由校准集（100 张）逐层实测最大值决定。

---

## 3. 打包布局

`pack_weights.py` 直接产出加速器消费的字节：

- **权重行** `(g, ky, kx, mg)`：字节 `4k + j` = `w[in_ch = g·4+k][out_ch = mg·4+j][ky][kx]`；
- **偏置行**：每组 4 行 16 字节，每行 4 个 INT32，重复该组的 4 个通道偏置；
- **配置行**：word0 = `mult | shift<<16 | zp<<21 | relu<<29`。

固件**不重复这些数字**，而是在运行时从打包好的 `det_cfgN` 里把 `mult/shift/zp/relu` 读回填进
层描述符 —— 保证只有一个真值来源。

---

## 4. 一个必须注意的坑：DMA 看不到 cache

`.rodata` 在可缓存的 DRAM 里，而加速器的 DMA 直接读物理内存。所以固件启动时必须把权重
**搬进 uncached scratch**（`mt_detect.c` 的 `det_copy_to_scratch`），否则 `MT_LOAD` 读到的是
陈旧数据。这是整个集成里最容易踩的坑之一。

---

## 5. 结果

| 阶段 | 质心误差 | 3px 内 |
| --- | ---: | ---: |
| 浮点模型 | 0.95 px | 100% |
| **量化 INT8（Python 整数参考）** | **1.27 px** | **100%** |
| **硬件（Verilator）** | **与整数参考逐比特一致，8/8 图** | |

硬件输出与 Python 整数 Golden **完全一致**（每张图 512 字节全等），不是容差比较。逐图检测结果：

| 图 | 方块位置（行/列） | 真值中心格 | 检测中心格 |
| ---: | --- | --- | --- |
| 0 | 2–13 / 0–11 | (1.9, 1.4) | **(1.7, 1.4)** |
| 2 | 20–31 / 18–29 | (6.4, 5.9) | **(5.8, 5.4)** |
| 3 | 9–20 / 2–13 | (3.6, 1.9) | **(3.1, 1.8)** |

体积：`.text` 20.5 KB（IROM 32 KB），`.rodata` 45 KB 与 `.bss` 30 KB 都在 192 KB DRAM 里。

---

## 6. 这一轮抓到的四个 bug

值得单独记下来，因为**四个里有三个在我的参考实现里，硬件一直是对的**：

1. **权重按无符号解码**。`np.where(b > 127, b - 256, b)` 作用在 uint8 数组上会回绕，
   于是整个 Python 参考用 0..255 的权重跑，累加器普遍过大、处处饱和。症状是
   "行 0 对、行 1 错"，很容易误判成硬件地址错。

2. **`[h][w][c]` 与 `[g][h][w][4]` 布局混用**。累加器数组是 `[h][w][c]`，而内存里是
   `[g][h][w][4]`。只在第一阶段对（因为那里恰好等价），往下就静默错位。现在每一步都
   显式 `to_mem()` / `from_mem()` 转换。

3. **合成数据的覆盖度算错**。轴不相交时两个差值都是负数，乘积却是正的，于是整张图上
   到处出现"幽灵覆盖块"。修正后浮点误差从 2.35 px 降到 **0.95 px**，而且 L3 的 ReLU
   选择也翻转了（有 ReLU → 无 ReLU）。

4. **累加标志提升出内层循环**（Y4 引入的真实驱动 bug）。`acc = 1u` 原本在 `mg` 循环里，
   导致第一个 tap 只有 `mg=0` 走覆盖语义，其余输出组累加到上一行的残留值上。
   **这个 bug 在 `mt_net` 里一直没暴露，在检测网络上才现形** —— 说明只跑一个用例的
   回归是不够的。

---

## 7. 复现

```bash
cd $MUNDUS_HOME/miniTensor
python3 integration/tools/train_detector.py     # 训练 -> detector_float.npz
python3 integration/tools/pack_weights.py       # 量化+打包+整数 golden -> mt_detect_weights.h
cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd
make CROSS_COMPILE=riscv64-unknown-elf- MUNDUS_HOME=... NPC_HOME=... \\
     MT_WITH_COREMARK=0 image
cd ../../../../../npc && JYD_CONSOLE_CMDS='mt_detect;quit' ./build/MundusJyd +verilator+rand+reset+0
```

---

## 8. 距离真正的 YOLO 还差什么

现在**工具链是通的、量化方案是明确的、硬件是逐比特对齐的**，剩下的是规模：

1. **权重来源**：换成 PyTorch/ONNX 导出的真实 YOLO 权重（当前环境没有 torch）。打包环节
   不用改，改的是前端导出。
2. **算子覆盖**：YOLO 还需要 residual add、concat、upsample。UB 里的 ADD8/MAX8 已经够用，
   缺的是调度。
3. **容量**：YOLOv5n 约 1.9 MB INT8，当前 12 MiB uncached 窗口放得下；UB 只有 4 KiB，
   所以必须分块流水。
4. **性能**：当前 0.42 MAC/cycle，YOLOv5n 约 18 s @300 MHz，不是实时。
