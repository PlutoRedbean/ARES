# Y17：调度器 —— 真实 YOLO 的四层卷积加三次池化，逐层逐比特

> 前面每一轮验证的都是**一个能力**（一层卷积、一次分块、一次残差、一次定长补齐）。
> 这一轮把它们串成一个**调度器**，跑真实 tiny-yolov3 的连续多级。

---

## 1. 做了什么

`pack_model.py` 从 ONNX 里取出图序前四个卷积，折进 BN，量化打包，并在 numpy 里
逐级算出整数参考；`mt_yolomodel.c` 用一张表调度整个链路：

```
x -> conv3x3(3->16)+leaky   -> pool -> conv3x3(16->32)+leaky
  -> pool -> conv3x3(32->64)+leaky  -> pool -> conv3x3(64->128)+leaky
```

在 64×64 下跑。**这不是一个检测器**（模型是在 416×416 上训练的），目的是验证模型的
层栈能正确执行、并且可以逐比特核对。

运行结果：

```
miniTensor scheduled real YOLO slice: 7 layers from tiny-yolov3, base 0x80c00000.
  layer  0 conv  64x64     4->16    65536 B  ok  (11158009 cycles)
  layer  1 pool  64x64    16->16    16384 B  ok  (  814054 cycles)
  layer  2 conv  32x32    16->32    32768 B  ok  (12377284 cycles)
  layer  3 pool  32x32    32->32     8192 B  ok  (  396861 cycles)
  layer  4 conv  16x16    32->64    16384 B  ok  (11400521 cycles)
  layer  5 pool  16x16    64->64     4096 B  ok  (  205062 cycles)
  layer  6 conv   8x8     64->128    8192 B  ok  (18469589 cycles)
miniTensor model slice PASSED (7 stages, 467504 commands, 58347217 cycles)
```

**权重、输入、激活缓冲、逐级 golden 全部在同一个 base 下**（blob 起点 0x80C00000）。
这不是为了整齐，而是因为层的 `base` 决定了引擎的寻址：既然 DMA 和 CPU 看到的是同一块
内存，层就可以**直接从 blob 里读权重，一次暂存拷贝都不需要**。

---

## 2. 串起来之后暴露的三个真实限制

单层测试发现不了这些 —— 它们只在「宽层 + 深层」同时出现时才暴露。

### 2.1 UB 行空间：宽度超过 32 就溢出

`UB_OUT` 和 `UB_SKIP` 各只有 8 行，因为 UB 一共 256 行，而 `UB_OUT=240`、`UB_SKIP=248`。
一层输出行的 tile 数 `ntiles = W/4`：**W=64 时 ntiles=16**，于是第二次 epilogue 写到
UB 行 248..263 —— 越过 255 回绕到权重行，把整层结果污染成杂乱值。

修法：**把 epilogue+store 按 8 个 tile 一组分块**，C 行不动（它本来就够放）。

### 2.2 输入通道被 64 卡住

原来把每个 tap 的两个基址预先算进 `tap_wrow[]`/`tap_off[]`，表长 `MT_MAX_TAP=160`，
等于把**输入通道限死在 64**（`k=3` 时 `ntap = 9·ng`）。128→256 那层 `ntap=288`，直接
返回 `-5`。

修法：**取消表，每次迭代现算**（6 次整数运算，相对后面的 DMA 和 GEMM 可以忽略）。
限制消失。

### 2.3 权重块放不下 —— 这个还没解决

一块权重需要 `ntap · nmt` 行，而 `UB_WT` 只有 144 行。128→256 那层 `ng=32, k=3` →
**288 行**，即使 `nmt=1` 也放不下。

之前的行为是**静默越界**（写进 C 行区域，结果全 0）；现在加了检查，返回 `-6`：

```c
if ((ntap * nmt) > MT_UB_WT_ROWS) return -6;
```

真正的修法是把权重块**再按 tap 切分**：C 行跨子块累积（第一块用 acc=0，其余 acc=1），
每个 tap 的 A 行和权重行仍然只搬一次，所以**不额外增加流量**。这个改动需要调整循环嵌套
顺序（C 行按 ho 复用，而权重块必须常驻），尚未实现。

因此本轮把链路收在图序前四个卷积（`WHICH = (0,1,2,3)`），**这四层全部通过**。

---

### 2.4 DMA 不译码 bit 21 —— 缓冲区放错位置会静默互相破坏

这是本轮最后、也是最值得记住的一条。两个测试先后跑时，第二个测试的权重读出来是垃圾：

F + "c",
"net_conv: refuse ntap=9 nmt=233 (cin=4 k=3 nm=4)",
F,

单独跑却完全正常。原因是地址：

| 区域 | 地址 | bit 21 |
| --- | --- | --- |
| 模型 blob + 缓冲 | 0x80C0_0000 | 0 |
| 链测试缓冲 | 0x80E0_0000 | **1** |

**DMA 会把地址的 bit 21 清掉** —— 这正是非缓存别名 0x8033_0000 能落到
0x8013_0000 的机制。于是 0x80E0_0000 在加速器眼里就是 **0x80C0_0000**，
两个测试的缓冲区完全重叠，互相覆盖。

CPU 侧的访存是对的（它按真实地址走），所以症状只出现在**加速器读到的东西**上 ——
这也解释了为什么它看起来像"权重损坏"而不是"地址错误"。

**规则：加速器可见的缓冲区，地址必须 bit 21 为 0，或者接受按 2 MiB 取模的别名。**
现在链测试放在 0x80D8_0000（在模型区之上、bit 21 仍为 0）。

两个测试同时跑，都通过：

F,
"miniTensor real YOLO chain PASSED (3 real convs + 2 pools, 45129 commands, 6369452 cycles)",
"miniTensor model slice PASSED (7 stages, 467504 commands, 62171220 cycles)",
F,

---

## 3. 回归状态（八个测试）

| 测试 | 状态 |
| --- | --- |
| `mt_conv` / `mt_net` / `mt_detect` / `mt_wide` / `mt_res` / `mt_yolo` / `mt_yolocnn` | ✅ 全绿 |
| **`mt_yolomodel`（7 级调度，真实权重）** | ✅ **467504 命令 / 58.3M cycles** |

> 小瑕疵：PASSED 那行文案写的是 "5 convs + 4 pools"，实际是 **4 个卷积 + 3 次池化**。
> 只是字符串，未重新烧写验证。

---

## 4. 下一步

1. **按 tap 切分权重块**，解开 2.3 —— 这是跑更宽层的唯一障碍。
2. `MaxPool stride 1`（tiny-yolov3 第 11 层）。
3. 之后就能把 13 个卷积全部纳入调度，在 64×64 或 128×128 下完整跑一遍骨干。

## 6. 恢复工作时的入口

F + "bash",
"# 固件",
"cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd",
"make CROSS_COMPILE=riscv64-unknown-elf- \\",
"  MUNDUS_HOME=$MUNDUS_HOME \\",
"  NPC_HOME=$MUNDUS_HOME/npc MT_WITH_COREMARK=0 image",
"",
"# 仿真（八个测试，约 12 分钟）",
"cd $MUNDUS_HOME/npc",
"JYD_CONSOLE_CMDS='mt_conv;mt_net;mt_detect;mt_wide;mt_res;mt_yolo;mt_yolocnn;mt_yolomodel;quit' \\",
"  ./build/MundusJyd +verilator+rand+reset+0",
"",
"# 重新生成模型夹具",
"cd $MUNDUS_HOME/miniTensor",
".venv/bin/python integration/tools/pack_model.py models/tiny-yolov3.onnx",
F
