# Y8：残差连接 —— 第一次把 VPU 用进真实网络

> YOLOv5 的骨干 CSPDarknet 是**残差堆叠**出来的，所以残差是距离真实 YOLO 最后一个
> 缺失的结构原语。加速器里一直有 ADD8/MAX8/RELU8 三个向量指令，但此前只在 `mt_gemm`
> 自检里用过 —— 这一轮把它接进真正的层流水线。

---

## 1. 实现

层描述符新增两个字段（追加在结构体末尾，不影响既有初始化器）：

```c
uint32_t skip_off;   /* 跳连张量，[g][h][w][4]，与输出同形状 */
uint8_t  skip;       /* 0=无  1=out+=skip  2=out=relu(out+skip) */
```

`net_conv` 在 epilogue 把一行输出写进 `UB_OUT` **之后**、`MT_STORE` **之前**插入跳连：
把对应的 skip 行搬进 `UB_SKIP`(248)，用 MT_VECTOR 合并，再存。

放在这个位置而不是单独跑一遍全张量，好处是每行只多一次 16 字节搬运，而且用到的
`UB_SKIP` 行本来就是空闲的（UB 256 行，输出只用到 240–241）。

测试用的是一个标准 bottleneck 核心：

```
y = relu( conv3x3( relu(conv3x3(x)) ) + x )
```

第一个卷积的 epilogue 带 ReLU，第二个不带（因为加法在它之后，ReLU 只对和做一次）——
这正是 ResNet / CSP 的标准写法，也顺带验证了 epilogue 的 relu 位与向量单元的配合。

---

## 2. 抓到的三件事

### 2.1 ADD8 会回绕，不饱和

```systemverilog
VPU_VEC_OP_ADD8:  result[8*i +: 8] = a[8*i +: 8] + b[8*i +: 8];  // 普通 8 位加
VPU_VEC_OP_RELU8: result[8*i +: 8] = (as > 0) ? as : 8'h00;
```

我最初的参考实现用了 `np.clip(h1+h2, -128, 127)`（饱和），硬件是回绕，于是 805/1024
字节不符。**这是一个真实的部署约束**：残差分支必须缩放得当，溢出会静默翻符号而不是
被钳位。测试里保留了 136 个回绕值，把它钉死成规格。

### 2.2 MT_VECTOR 一次只处理一个 UB 行

一个向量指令作用于**一行 16 字节 = 4 个像素**。一个输出行有 `ntiles` 个这样的行，所以
残差需要 **`ntiles` 次 ADD8**，不是一次。我最初只写了一次，结果正好一半的字节错
（510/1024 ≈ 50%）—— 这个数字本身就是线索。

### 2.3 我的参考用错了跳连张量

残差是 `y = relu(conv2(relu(conv1(x))) + x)`，跳连的是**块的输入 x**，不是中间结果 h1。
两者形状相同，写错了不会报错，只会得到一个看起来合理的 golden。

定位靠的是把中间结果也做成 golden：打印出来后 `conv1: 0 bytes differ`、
`conv2: 0 bytes differ` —— 两个卷积都对，那问题必然在向量通路。**这个二分法值得记住。**

---

## 3. 结果

```
miniTensor residual block: 8x8x16, y = relu(conv2(relu(conv1(x))) + x).
  conv1 nmt=4 relu=1 | conv2 nmt=4 relu=0 skip=2
  conv1 stage: 0 bytes differ
  conv2 stage (no residual): 0 bytes differ
miniTensor residual PASSED (1024/1024 bytes, 9148 commands, 780423 cycles)
```

---

## 4. 回归状态（五个测试全绿）

| 测试 | 状态 |
| --- | --- |
| `mt_conv` 单层 3×3 卷积 | ✅ 144/144 字节 |
| `mt_net` 4 层 YOLO 形状网络 | ✅ 6/6 阶段 |
| `mt_detect` 打包权重的检测器 | ✅ 8/8 图逐比特一致 |
| `mt_wide` 9× UB 宽层（权重分块） | ✅ 3072/3072 字节 |
| `mt_res` 残差块（VPU ADD8/RELU8） | ✅ 1024/1024 字节 |

体积：`.text` 23.4 KB（IROM 32 KB），`.rodata` 84 KB、`.bss` 32 KB（DRAM 192 KB）。

---

## 5. 还差什么

结构原语现在基本齐了：卷积、池化、**残差**、1×1 头、逐比特可验证的量化与打包。
距离跑真实 YOLO，剩下的不再是"机制"：

1. **前端导出**：torch / ONNX → INT8 → 本布局。当前环境没有 torch。
2. **concat / upsample 的调度**：UB 的 ADD8/MAX8 够用，缺的是把它们串成 FPN。
3. **规模与仿真时间**：YOLOv5n 约 2.25 GMAC，@0.42 MAC/cycle 需要约 5.4G 周期；
   本机 Verilator 大约 30 万周期/秒，**单次推理要跑约 5 小时**。这是环境的硬限制，
   不是设计问题 —— 真实模型的分层验证必须在 FPGA 或更快的仿真上做。
