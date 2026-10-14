# Y19：完整 tiny-yolov3 在 miniTensor × NPC × RT-Thread 上逐比特跑通

> 从 Y1 到 Y18 跑的都是骨干网的**片段**。这一轮把整张图搬上去：
> **13 个卷积 + 6 次池化 + FPN 上采样 + 通道拼接 + 两个检测头**，
> 全部走真实 Mundus/NPC 核、RT-Thread Nano 和 miniTensor，每一级都与整数 golden 逐字节一致。

---

## 1. 结果

`msh >mt_yolomodel`（`RES=64`，21 个 stage，逐级比对）：

    miniTensor FULL tiny-yolov3: 21 stages from 0x804063a0.
      0 conv 64x64    4->16    65536 B  ok  ( 11561011 cycles)
      1 pool 64x64   16->16    16384 B  ok  (   673401 cycles)
      2 conv 32x32   16->32    32768 B  ok  ( 13247356 cycles)
      3 pool 32x32   32->32     8192 B  ok  (   349206 cycles)
      4 conv 16x16   32->64    16384 B  ok  ( 12344432 cycles)
      5 pool 16x16   64->64     4096 B  ok  (   190858 cycles)
      6 conv  8x8    64->128    8192 B  ok  ( 19304251 cycles)
      7 pool  8x8   128->128    2048 B  ok  (    99677 cycles)
      8 conv  4x4   128->256    4096 B  ok  ( 19249120 cycles)
      9 pool  4x4   256->256    1024 B  ok  (    54206 cycles)
     10 conv  2x2   256->512    4096 B  ok  ( 38156991 cycles)
     11 pls1  2x2   512->512    2048 B  ok  (   118204 cycles)   <- 2x2/1 SAME_UPPER
     12 conv  2x2   512->1024   8192 B  ok  (152004748 cycles)
     13 conv  2x2  1024->256    2048 B  ok  (  8666671 cycles)
     14 conv  2x2   256->128    1024 B  ok  (   717583 cycles)
     15 up    2x2   128->128    2048 B  ok  (    38355 cycles)
     16 cat   4x4   128->256    6144 B  ok  (    92268 cycles)
     17 conv  2x2   256->512    4096 B  ok  ( 38139535 cycles)
     18 conv  4x4   384->256    4096 B  ok  ( 57540599 cycles)
     19 conv  2x2   512->256    2048 B  ok  (  4348004 cycles)   <- head 1
     20 conv  4x4   256->256    4096 B  ok  (  2768880 cycles)   <- head 2
    miniTensor FULL tiny-yolov3 PASSED (21 stages, 3128301 commands, 384352762 cycles)
    HIT GOOD TRAP

图结构（`pack_full.py` 的 `SEQ`）：

    conv3x3 3->16    -> pool2/2 -> conv3x3 16->32   -> pool2/2
    conv3x3 32->64   -> pool2/2 -> conv3x3 64->128  -> pool2/2
    conv3x3 128->256 -> pool2/2 -> conv3x3 256->512 -> pool2/1(SAME)
    conv3x3 512->1024 -> conv1x1 1024->256
        |-> conv1x1 256->128 -> upsample x2 --> concat(., 128->256)
        |-> conv3x3 256->512 -> head1 1x1 512->255
        \-> conv3x3 384->256 -> head2 1x1 256->255

128→256 那层的输出同时喂给上采样分支和 head 分支；拼接把上采样结果与
128→256 的输出按通道接成 384 通道，再进 3x3，这正是 Y17/Y18 缺的 route。

---

## 2. 这一轮新增的能力

### 2.1 引擎（`integration/bsp/mt_net.c` / `.h`）

| 原语 | 作用 |
| --- | --- |
| `net_pool_k_same` | ONNX **SAME_UPPER** 池化。tiny-yolov3 第 11 层是 **2x2 stride 1**，ONNX 给所有池化 `auto_pad=SAME_UPPER`，所以它**保持尺寸**。旧的 `net_pool_k` 按 pads=0 会把 13x13 缩成 12x12，route/upsample 的尺寸就对不上了 |
| `net_upsample2` | `Resize(nearest, floor, asymmetric)` 的 2 倍最近邻上采样 |
| `net_concat2` | `[g][h][w][4]` 布局下按通道组拼接（两段连续块拷贝，无逐像素工作） |

卷积引擎本身**零改动**：1x1、按 tap 分块、按输出组分块、LeakyReLU（两次 epilogue +
有符号 MAX8）全部沿用 Y6–Y18 的实现。

### 2.2 检测头：255 通道补齐到 256

两个 head 是 1x1、`c_out = 3 anchors x 85 = 255`，不是 4 的倍数，而引擎按 4 通道一组做
tile。打包器把权重/偏置补到 256 个输出通道（多出的那一组为零行），golden 也按 256 通道
生成；解码只看前 255 个。没有这一步，`nm = cout/4` 会丢掉最后 3 个真实通道。

### 2.3 夹具与链接

`integration/tools/pack_full.py` 生成：

* `models/ym_weights.bin` —— 8.70 MiB：输入图、全部 INT8 权重/偏置/配置、每一级的整数 golden；
* `integration/bsp/mt_yolomodel_weights.h` —— 21 条 `ym_layer_t`，全部偏移相对 blob 起点。

链接脚本（`rtthread-nano/.../bsp/MundusJyd/linker.ld`）把 `.weights`（旧的 25 KiB 回归
blob）和 `.model`（完整模型 blob）放进**同一个 12 MiB 非缓存窗口** `0x8040_0000-0x80FF_FFFF`，
并导出 `__model_start`。C 侧：

    extern char __model_start[];
    #define YM_BASE ((uint32_t)(uintptr_t)__model_start)

所以打包器**不需要知道 blob 地址**，`models/ym_weights.bin` 换成任意大小/位置都不用重生成。

实测占用 8.94 MiB / 12 MiB；golden 结束在 `+0x8B2CE0`，而小型测试（`mt_yolocnn`）的
scratch 从 `0x80D80000` 开始，两者不重叠。

### 2.4 量化：从「逐比特对」升级到「数值忠实」

第一版照抄 `pack_model.py` 用 `bq = round(b)`，硬件照样逐比特过，但网络**数值上没有意义**
（bias 被丢掉、每层 requant 只按整数范围归一化），解出来的框是垃圾。
现在改为 `pack_weights.py` 那套标定量化：

1. 先用 float 权重跑一遍 `calibrate()`，记录每一级激活的 `max|f|`；
2. `s_x_in = max|f_in|/127`、`s_w = max|w|/127`；
3. `bq = round(b / (s_x_in * s_w))`；
4. `mult/shift` 取使 `mult = round(s_x_in*s_w/s_out * 2^shift) <= 32767`；
5. 于是 `int8 输出 * s_out` 就是 float 模型的值，解码才有意义。

`integration/tools/yolo_decode.py` 读 blob 里两个 head 的 golden，按上面的 `s_out`
反量化，再做标准 YOLOv3 解码（sigmoid xy/obj/类、exp wh、anchor、网格偏移、按类 NMS）。

> **注意**：64x64 不是这个模型的工作点（它在 416x416 上训练，anchor 是 81..344 像素）。
> 在 64x64 下 anchor 相对输入过大、又几乎没有目标，解码结果只能证明**链路数值正确**，
> 不能用来评估识别率。真实识别率需要更大的输入，而仿真代价按面积平方增长
> （416x416 约是 64x64 的 42 倍），这是 `yolo_feasibility.md` 里早就写明的存储/算力硬墙。
> 小的语义识别 demo 仍由 Y6 的 `mt_detect` 承担（8/8 图）。

---

## 3. 踩到的坑

### 3.1 整除指令会让 DUT 的 retire/PC 记账错乱（本次唯一的硬阻塞）

第一次跑 `mt_yolomodel` 时第 0 级通过、第 1 级（`net_pool_k`）崩溃：

    retirement PC discontinuity: expected 0x80001338, got 0x8000133c

`0x80001338` 正是一条 `divu`。`tmp/r19.log` 里上一轮的 `mt_net` 挂在**同一条指令**上——
所以这不是新引入的，而是这套 Verilator 测试台 / MDU 的既有问题（`preview.md` 要求不改
npc 模块，所以只能在软件侧绕开）。`net_conv` 里的 `divu` 能过，但 pooling 路径上的这一条
会把 DUT 的 PC 推进弄得和 retire 事件不同步。

**修法**：pooling 只用到 stride 1 和 2，把 `/` 全部改写成移位/减法：

    if (stride == 1u) { oh = h - k + 1u; ow = w - k + 1u; }
    else              { oh = ((h - k) >> 1) + 1u; ow = ((w - k) >> 1) + 1u; }

`net_pool_k_same` 同样处理。改完 21 级全绿。

### 3.2 其它（已在 Y17/Y18 记过，这里复述）

* 加速器地址 **bit 21 必须为 0**（或接受 2 MiB 别名）；模型区放在 `0x8040_0000` 起，bit21=0。
* `.model` 里 golden 放在可写 scratch 之前，避免与 `mt_yolocnn` 的 scratch 相互覆盖。
* 每个 conv 的输出缓冲按 `wpad`（4 的倍数）步长存，宽度为 2 的层按 4 计算；消费者用
  `src_w` 只读前 `w` 列。

---

## 4. 复现入口

    # 夹具（写 models/ym_weights.bin + mt_yolomodel_weights.h）
    cd $MUNDUS_HOME/miniTensor
    .venv/bin/python integration/tools/pack_full.py

    # 固件
    cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd
    make CROSS_COMPILE=riscv64-unknown-elf- \
      MUNDUS_HOME=$MUNDUS_HOME \
      NPC_HOME=$MUNDUS_HOME/npc MT_WITH_COREMARK=0 image

    # 仿真（约 20-30 分钟；384M cycles）
    cd $MUNDUS_HOME/npc
    JYD_CONSOLE_CMDS='mt_yolomodel;quit' \
      ./build/MundusJyd +verilator+rand+reset+0

    # 解码（读 blob 里两个 head 的 golden）
    cd $MUNDUS_HOME/miniTensor
    .venv/bin/python integration/tools/yolo_decode.py

---

## 5. 下一步

1. **真实图片 + 更高分辨率**：`RES=128` 时 384M cycles 会涨到约 1.5G，仍可在仿真里跑；
   若要在 416x416 做真正的检测，需要先解决存储/外存（`yolo_feasibility.md` 路径 B）。
2. **上板**：仿真里 DMA 是 DPI 客户端；FPGA 上需要真正的第二存储端口/仲裁。
3. **性能**：本轮 3.13M 命令 / 384M cycles 约 123 cycles/命令，瓶颈仍是 MMIO 往返
   （见 `pipeline_report.txt`）。
