# Y13：宽度补齐 —— 让真实 YOLO 的层形状可以被表达

> Y12 发现 `net_conv` 按 `ntiles = W/4` 组织，**宽度不是 4 的倍数就完全切不出来**，
> 而 tiny-yolov3 的 13 个卷积里 9 个不满足。这一轮把补齐做进了层引擎并验证。

---

## 1. 先修正一个过度告警

Y12 我把 `H%4` 也标成了问题，**这是错的**：`net_conv` 的行循环是 `for (ho = 0; ho < H; ho++)`，
逐行处理，**H 取任何值都可以**。只有 W 受 4 像素 tile 的约束。

修正后的数字（仍然是 9/13，但原因只剩一个）：

```
convolutions needing an activation LUT (hard blocker): 0 of 13
convolutions whose W is not a multiple of 4          : 9 of 13
convolutions needing only toolchain/scheduler work   : 13 of 13
  reasons: leaky=2ep+MAX8 11, pad channels to /4 3, W%4=6 3, W%4=10 2,
           W%4=414 1, W%4=205 1, W%4=22 1, W%4=9 1, pool2/1 1
```

## 2. 实现：两个新的步长字段

层描述符加两个字段（追加在末尾，既有初始化器不受影响）：

```c
uint16_t src_w;   /* 源缓冲区的行步长（0 表示等于 w） */
uint16_t wpad;    /* 输出的行步长，4 的倍数（0 表示等于 w） */
```

改动的三处：

| 位置 | 改动 |
| --- | --- |
| `net_pad` | 按 `src_w` 读源（只读前 `w` 列，其余补 0），按 `wpad` 写 pad 缓冲 |
| `net_conv` | `ntiles = wpad/4`，store 步长用 `wpad`，跳连也用 `wpad` |
| `net_pool2` | 新增源/目标步长参数，并把目标行的**补齐部分写 0**（否则下游会读到未初始化数据） |

两个字段为 0 时行为与改动前**逐字节相同**，所以既有的五个测试不用改。

关键点：`net_pad` 的越界判断用的是**逻辑宽度 `w`**，所以补齐列读到的是 0；
参考实现里数组的补齐列也是 0，两边一致。

---

## 3. 验证：正是之前失败的那个几何

24×24 输入时第三层输出是 **6 宽**，Y12 里它直接报 `rc=-3`。现在：

```
miniTensor real YOLO backbone slice: convs #0,#1,#2 of tiny-yolov3, 24x24 input.
  conv0p    9216 bytes  ok
  conv0     9216 bytes  ok
  conv1     4608 bytes  ok
  conv2     3072 bytes  ok        <- 6 逻辑列按 8 计算，逐比特一致
miniTensor real YOLO chain PASSED (3 real convs + 2 pools, 45129 commands, 4202116 cycles)
```

`conv2` 的 golden 是 6×8×64 = 3072 字节（按补齐后的宽度），全部对上。

打包器现在会打印每层的 `wpad`：

```
  conv#0 3->16 24x24 (wpad 24)  nmt=2 rows=36   mult=57  a*mult=6  a-path=55%
  conv#1 16->32 12x12 (wpad 12) nmt=4 rows=288  mult=77  a*mult=8  a-path=82%
  conv#2 32->64 6x6 (wpad 8)   nmt=2 rows=1152 mult=499 a*mult=50 a-path=58%
```

---

## 4. 回归状态（七个测试全绿）

| 测试 | 状态 |
| --- | --- |
| `mt_conv` | ✅ 144/144 字节 |
| `mt_net` | ✅ 6/6 阶段 |
| `mt_detect` | ✅ 8/8 图 |
| `mt_wide` | ✅ 3072/3072 |
| `mt_res` | ✅ 1024/1024 |
| `mt_yolo`（真实单层，32×32） | ✅ 16384/16384 |
| `mt_yolocnn`（三层链，24×24，含宽度补齐） | ✅ 9216+9216+4608+3072 全对 |

体积：`.text` 25.8 KB（IROM 32 KB），`.rodata` 159 KB、`.bss` 32 KB。

---

## 5. 下一步

1. **Concat / Upsample / MaxPool-stride-1 的调度** —— 骨干里没有，但检测头需要。
2. **跑完整 tiny-yolov3 @128×128**：约 0.11 GMAC，端到端约 14 分钟仿真。
   宽度补齐已经就位，所以 414/205/22/11 这些形状不再是问题。
3. **SiLU 类激活**（YOLOv5/v8）才真正需要 epilogue LUT；tiny-yolov3 不需要。
