# Y16：绝对寻址做对了 —— Y15 的谜题也解开了

> Y15 的重构失败并撤回。这一轮**先解开了当时的谜题**，然后用一种不会重蹈覆辙的方式重做，
> 最后证明了新能力：**整条真实 YOLO 链现在完全跑在扩展窗口里**。

---

## 1. Y15 到底错在哪

当时我把访问器改成绝对寻址：

```c
static uint8_t net_rd8(uint32_t addr) { return *(volatile uint8_t *)(uintptr_t)addr; }
```

**但忘了 `net_rd8` 原来是这样实现的**：

```c
static volatile uint8_t *const net_buf = (volatile uint8_t *)(uintptr_t)MT_BUF_BASE;
static uint8_t net_rd8(uint32_t off) { return net_buf[off]; }   /* 已经加了基址 */
```

于是引擎里 `B + L->src_off` 和 `net_buf[off]` **各加了一次基址** —— 每个地址都被算了
两遍。测试自己的 `*_stage` 辅助函数也一样（常量改成绝对值后仍然通过 `*_buf` 索引），
所以七个测试**同时**炸掉，而且症状（`0x83430000` 这种地址）看起来完全不像「多加了一个基址」。

**一个地址被加两次基址，得到的地址低 16 位往往是 0** —— 这正是当时那条线索，
我看到了却没有读出它的含义。

---

## 2. 这次的做法：加一个默认值等于 scratch 的 base

不改任何既有约定，只给层描述符加一个字段：

```c
uint32_t base;   /* 所有 *_off 的绝对基址；0 表示 MT_BUF_BASE */
```

引擎里每个地址只加一次：

```c
uint32_t B = L->base ? L->base : MT_BUF_BASE;
... net_rd8(B + L->src_off + d) ...
... mt_push(MT_LOAD, B + wbase + i * 16u, ...) ...
```

**访问器改成接受绝对地址**（`net_rd8`/`net_wr8`/`net_wr32`），
**引擎之外的调用者自己加 `MT_BUF_BASE`**。

这个约定要成立，就必须把所有「引擎之外、传相对偏移」的地方找齐。`grep` 一查，
**只有 6 处，而且全在 `mt_net.c` 里**：`net_pack_weights` 的 4 处、`net_check` 的 1 处、
`net_run` 的图像填充与读回 2 处。其余测试文件都用各自的 `*_buf` 指针，不受影响。

### 为什么这次不会重蹈覆辙

`base` 默认 0 → 引擎用 `MT_BUF_BASE` → **既有的七个测试一个字都没改，全程保持全绿**。
换成绝对寻址这个动作被推迟到「某个测试主动把 `base` 指向别处」时才发生。

定位手段也换了一个：在命令里打进度标记（`[a]`…`[h]`）二分，一条 `grep` 就定位到
故障在 `net_pad(&L1)` 里面 —— 比上一轮反汇编快得多。

---

## 3. 证明新能力：整条链搬出 scratch

`mt_yolocnn` 现在把 `YC_BASE` 指向 **0x80C00000**（12 MiB 非缓存扩展窗口里，权重 blob
之后的一段），层描述符的 `base` 也指向它：

```
miniTensor real YOLO backbone slice: convs #0,#1,#2 of tiny-yolov3, 24x24 input.
  conv0p    9216 bytes  ok
  conv0     9216 bytes  ok
  conv1     4608 bytes  ok
  conv2     3072 bytes  ok
miniTensor real YOLO chain PASSED (3 real convs + 2 pools, 45129 commands, 4550222 cycles)
```

**激活、权重、padding 全部搬到了 64 KiB scratch 之外**，逐比特仍然一致。
把 `YC_BASE` 换回 `MT_BUF_BASE` 就是原来那个 scratch 版本 —— 同一个测试，两种放置方式。

---

## 4. 回归状态（七个测试全绿）

| 测试 | 状态 |
| --- | --- |
| `mt_conv` | ✅ 144/144 字节 |
| `mt_net` | ✅ 6/6 阶段 |
| `mt_detect` | ✅ 8/8 图 |
| `mt_wide` | ✅ 3072/3072 |
| `mt_res` | ✅ 1024/1024 |
| `mt_yolo` | ✅ 16384/16384 |
| `mt_yolocnn`（**缓冲区在扩展窗口**） | ✅ 全对 |

---

## 5. 这一步解锁了什么

现在三个容量限制都解除了：

| 资源 | 上限 | 就绪手段 |
| --- | --- | --- |
| 权重 | **8 MB** | Y14 的 blob（层直接从 blob 读，不再需要暂存拷贝） |
| 激活 | **12 MiB 窗口** | Y16 的 `base`（本轮证明） |
| 激活行宽 | 4 的倍数即可 | Y13 的 `wpad` |

于是 **128×128 的完整 tiny-yolov3 骨干（13 个卷积 + 6 次池化）已经具备全部条件**：
stem 的 256 KB 激活放扩展窗口，8.85 MB 权重放 blob，宽度不整除 4 的层用 wpad 补。
剩下的是调度：把 13 层按表跑一遍，以及 `MaxPool stride 1`（第 11 层）。
