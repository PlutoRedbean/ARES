# Y18：按 tap 切分权重块 —— 解开最后一层容量限制

> Y17 串起调度器后暴露了三个单层测不出的限制，其中「一块权重放不下」只加了检查没有修。
> 这一轮把它修掉，于是 **tiny-yolov3 的 128→256 层也能跑了**。

---

## 1. 问题

一块权重需要 `ntap · njt` 行，而 `UB_WT` 只有 144 行。

| 层 | `ng` | `k` | `ntap` | 需要行数 | 144 行放得下？ |
| --- | ---: | ---: | ---: | ---: | --- |
| 3→16 | 1 | 3 | 9 | 9 | ✅ |
| 64→128 | 16 | 3 | 144 | 144 | ✅ 刚好 |
| **128→256** | **32** | **3** | **288** | **288** | ❌ |

之前的行为是静默越界（写进 C 行区域，结果全 0）；Y17 加了检查改成返回 `-6`。

## 2. 修法：把 tap 也分块

关键在于**打包器写行的顺序**（`pack_weights.to_rows`）：

```python
q = (g * k * k) + (ky * k) + kx
row = (ti * ntap * nmt) + (q * nmt) + j
```

也就是说，**同一个 tile 里、相邻 tap 的权重行是连续的**。于是：

1. 固件里的 `q` 也按 `g·k² + ky·k + kx` 枚举（原来是 `ky,kx,g` 序）——这样 `row = q`；
2. 每次只加载 `[tc, tc+nq)` 这一段 tap 的权重行：`nq·njt ≤ 144`；
3. 一段权重常驻 UB，把这一行的 GEMM 全部跑完，再换下一段。

```c
uint32_t na = MT_UB_WT_ROWS / njt;      /* 每块多少个 tap */
for (ho ...) {
    for (tc = 0; tc < ntap; tc += na) {
        nq = min(na, ntap - tc);
        /* 权重行 [tc·njt, (tc+nq)·njt) 连续 */
        MT_LOAD(wbase + (tc*njt + i)*16, UB_WT + i, nq*njt);
        for (t ...) for (q in [tc, tc+nq)) {
            MT_LOAD(A 行);
            GEMM(..., acc = (tc == 0 && q == tc) ? 0 : 1);
        }
    }
    /* epilogue + store —— 必须等所有 tap 块都累加完 */
}
```

### 为什么不多花 DMA

每个 tap 的权重行**仍然只搬一次**（它只属于一个块），每个 tap 的 A 行也只搬一次。
积累标志是「本层第一个 tap 才覆盖 C」，所以分块不影响数值。

唯一的代价是**权重块在每个 `ho` 上重新加载一次**（C 行按 ho 复用，权重块必须常驻），
即权重流量 × H。对需要分块的层来说 H 都很小（128→256 那层 H=4），实测这层的总周期
19.3M，与不分块的同规模层相称。

## 3. 结果：九级全部通过

```
miniTensor scheduled real YOLO slice: 9 layers from tiny-yolov3, base 0x80c00000.
  layer  0 conv  64x64     4->16    65536 B  ok  (11562533 cycles)
  layer  1 pool  64x64    16->16    16384 B  ok  (  814833 cycles)
  layer  2 conv  32x32    16->32    32768 B  ok  (13270927 cycles)
  layer  3 pool  32x32    32->32     8192 B  ok  (  397625 cycles)
  layer  4 conv  16x16    32->64    16384 B  ok  (12351271 cycles)
  layer  5 pool  16x16    64->64     4096 B  ok  (  205535 cycles)
  layer  6 conv   8x8     64->128    8192 B  ok  (19308428 cycles)
  layer  7 pool   8x8    128->128    2048 B  ok  (  103539 cycles)
  layer  8 conv   4x4    128->256    4096 B  ok  (19255258 cycles)
miniTensor model slice PASSED (9 stages, 5 convs + 4 pools, 633077 commands, 80947868 cycles)
```

**5 个真实卷积 + 4 次池化，逐级逐比特一致**，输入通道一路做到 128。

顺带说明：Y17 记的那个「文案写成 5 convs + 4 pools 但其实是 4 + 3」的小瑕疵，
现在**文案是对的**了（这次确实是 5 + 4）。

## 4. 至此三个限制都清了

| 限制 | 状态 |
| --- | --- |
| UB 行空间（宽度 > 32） | ✅ Y17 分块 |
| tap 表（输入通道 > 64） | ✅ Y17 取消表 |
| **权重块（`ntap·njt > 144`）** | ✅ **Y18 按 tap 分块** |
| DMA bit 21 别名 | ✅ Y17 记入规则 |

## 5. 下一步

1. `MaxPool stride 1`（tiny-yolov3 第 11 层）。
2. 把剩下 8 个卷积纳入调度（现在是图序前 5 个）。
3. 之后 13 个卷积 + 6 次池化的完整骨干就可以在 64×64 跑通。

## 6. 恢复入口

```bash
# 固件
cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd
make CROSS_COMPILE=riscv64-unknown-elf- \\
  MUNDUS_HOME=$MUNDUS_HOME \\
  NPC_HOME=$MUNDUS_HOME/npc MT_WITH_COREMARK=0 image

# 仿真
cd $MUNDUS_HOME/npc
JYD_CONSOLE_CMDS='mt_conv;mt_net;mt_detect;mt_wide;mt_res;mt_yolo;mt_yolocnn;mt_yolomodel;quit' \\
  ./build/MundusJyd +verilator+rand+reset+0

# 夹具（WHICH 决定取哪几个卷积）
cd $MUNDUS_HOME/miniTensor
.venv/bin/python integration/tools/pack_model.py models/tiny-yolov3.onnx
```