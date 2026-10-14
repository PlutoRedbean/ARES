# Y10：LeakyReLU 其实不需要改 RTL —— 我上一轮的结论是错的

> Y9 里我写：真正剩下的第一个硬障碍是激活函数，它需要动 miniTensor 的 RTL。
> **这句话是错的。** 这一轮把它推翻了，并且用真实训练权重验证了。

---

## 1. 错在哪

我当时的推理是：epilogue 只有一位 ReLU，LeakyReLU 是分段线性，所以需要 LUT。
漏掉的是**恒等式**：对 0 < a < 1，

```
leaky(x) = max(x, a*x)
```

而硬件里已经有两块正好合适的东西：

1. epilogue 的 multiplier 是 **signed 16-bit** 字段（`tensor_epilogue_core.sv:4`）；
2. VPU 的 `MAX8` 是**有符号** max（`vpu_vector_alu.sv:23`）。

于是：**对同一个 C tile 跑两次 epilogue** —— 一次用 `mult`，一次用 `round(mult*a)` ——
再用 `MAX8` 合并，就精确得到 LeakyReLU。**不需要第二次卷积，也不需要改任何 RTL。**
代价只是每个 tile 多一次 epilogue 加一次 MAX8。

### 一个必须注意的细节

**两次 epilogue 都必须关掉 ReLU。** 如果主分支开了 ReLU，负数已经被钳成 0，
`max(relu(v), a*v)` 在 v<0 时会得到 0 而不是 `a*v`，结果就错了。

---

## 2. 在真实模型上验证

tiny-yolov3 的 stem（3→16, 3×3），真实训练权重加折进的 BN，**跑真实的 LeakyReLU(0.1)**：

```
miniTensor on a real YOLO layer: tiny-yolov3 stem, 3->16 conv 32x32, run at 32x32.
  channels padded 3->4 for MT_GEMM, nmt=2, leaky=1
    (real LeakyReLU, done with 2 epilogues + MAX8)
miniTensor real YOLO layer PASSED (16384/16384 bytes, 17033 commands, 1159285 cycles)
```

打包器实测 `mult=55, mult*a=6`，**55.1% 的数值走 a*x 分支** —— 这条路径确实被用到了。

| | 命令数 | cycles |
| --- | ---: | ---: |
| 只跑卷积（Y9） | 14985 | 1047919 |
| **卷积加真实 LeakyReLU** | 17033 | 1159285 |
| 代价 | **+13.7%** | **+10.6%** |

### 精度上的注意点

`mult2 = round(mult * a)` 必须**足够大**，否则会塌成 0 或 1。本层用 `shift=14` 让
`mult=55`，于是 `mult2=6`，等效 a = 0.109 而不是 0.100（9% 偏差）。如果 shift 取小，
比如 mult=7，那么 mult2 = round(0.7) = 1，等效 a = 0.143 —— 偏差 43%。
**所以负斜率的精度取决于 requant 的 shift 取得够不够大**，这是一个真实的量化约束。

---

## 3. 修正后的可行性结论

重新跑 `onnx_feasibility.py`：

```
VERDICT
  convolutions needing an activation LUT (hard blocker): 0 of 13
  convolutions needing only toolchain/scheduler work    : 13 of 13
  reasons: [('leaky=2ep+MAX8', 11), ('pad channels to /4', 3), ('pool2/1', 1)]
```

对比 Y9 的「13 of 13 需要改动、其中 11 个是 LeakyReLU」，**现在是 0 个硬阻塞**。

| 项 | Y9 的判断 | 现在 |
| --- | --- | --- |
| LeakyReLU | 需要 LUT | **`max(x, a*x)`，2 epilogue + MAX8，已在真实权重上验证** |
| 通道 %4 | 需要填充 | 同一个测试里已验证（3→4 补零） |
| Sigmoid / SiLU | 不支持 | **仍然是真的不支持**（非线性，无法用 max 组合） |
| MaxPool stride 1 | 不支持 | 可调度（多次移位 MAX8），未实现 |
| Concat / Resize | 缺调度 | 可表达（相邻 group 块 / 行拷贝），未实现 |

**对 tiny-yolov3 来说：它就是 LeakyReLU，所以 13 个卷积全部可表达。**
而 YOLOv5 / v8 用的是 SiLU，那才是真正需要 LUT 的那一类。

---

## 4. 回归状态（六个测试全绿）

| 测试 | 状态 |
| --- | --- |
| `mt_conv` 单层 3×3 卷积 | 144/144 字节 |
| `mt_net` 4 层网络 | 6/6 阶段 |
| `mt_detect` 打包权重检测器 | 8/8 图逐比特 |
| `mt_wide` 9× UB 宽层 | 3072/3072 字节 |
| `mt_res` 残差块 | 1024/1024 字节 |
| `mt_yolo` 真实 YOLO 卷积加真实 LeakyReLU | 16384/16384 字节 |

---

## 5. 教训

宣布硬件不支持之前，先问一句：**现有原语能不能组合出来？**

我当时看到「只有 ReLU」就跳到「需要 LUT」，漏掉了两件已经查过的事实（signed multiplier、
signed MAX8）正好构成恒等式。这不是 RTL 的缺口，是我想得不够。
顺带一提，这个组合恰好只在 0 < a < 1 时成立，而 LeakyReLU 的 a 定义域正是如此。

## 6. 仍然剩下的

1. **Concat / Upsample / MaxPool-stride-1 的调度** —— 可表达，未实现。
2. **仿真时间**：1.157 GMAC 端到端约 2.75G cycles，本机 Verilator 约 2.5 小时每次。
   降到 128×128 约 14 分钟，那才是能跑完整模型的路径。
3. **SiLU 类激活**（YOLOv5/v8）—— 这一类才是真正需要 epilogue LUT 的。
