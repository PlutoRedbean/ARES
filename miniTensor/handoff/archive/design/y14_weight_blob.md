# Y14：权重从 .rodata 搬进外部加载的 blob —— 解除镜像容量限制

> 到这一轮为止，**真正的瓶颈已经不是算法而是容量**：tiny-yolov3 的 13 个卷积需要
> **8.85 MB** 权重，而固件可用的 DRAM 只有 **192 KiB**。再想多跑几层就会撑爆镜像。
> 真实的嵌入式部署不会把权重编进固件 —— 它们从外部存储加载。这一轮把那条路打通。

---

## 1. 做法：利用已有的加载路径

仿真器的 `program_ROM` 已经很合适（`mem.cpp:78-86`）：

```c
/* The flat image spans 0x8000_0000 upwards, so 0x8010_0000 lands at file
 * offset 0x100000.  Read to end-of-file: the firmware carries its own data,
 * and any appended weight blob is picked up automatically. */
fseek(bin, 0x100000, SEEK_SET);
for (i = 0; i < (int)DRAM_SIZE; i++) { ... dram[i] = c; }
```

所以只要把权重放进**平坦镜像的更高地址**，它就会被自动读进 `dram[]`。而 12 MiB 的
扩展窗口 `0x8040_0000-0x80FF_FFFF` 正好是**非缓存**的 —— DMA 直接可见，不需要任何
cache 维护。

于是：

1. `linker.ld` 增加一个区域和一个段：

```ld
WEIGHTS (rw) : ORIGIN = 0x80400000, LENGTH = 8M
...
.weights : ALIGN(16) { __weights_start = .; KEEP(*(.weights)) __weights_end = .; } > WEIGHTS
```

2. Makefile 用 `objcopy -I binary` 把打包器产出的 `models/yc_weights.bin` 变成一个
   目标文件（**只在 blob 存在时才参与链接**，所以没有模型也能编译）：

```make
$(OBJCOPY) -I binary -O elf32-littleriscv -B riscv \\
  --rename-section .data=.weights,alloc,load,readonly,data,contents $< $@
```

3. 固件用 `yc_stage_blob()` 把每层的权重从 blob 拷进 scratch（两端都非缓存，纯字节拷贝）。

---

## 2. 一个必须记住的坑

第一次链接直接报 `MundusJyd DRAM overflow`。原因是：

**`> WEIGHTS` 会把位置计数器移到权重区域**，而 `linker.ld` 里 `__heap_start = .` 在
`.weights` 之后，于是 `__heap_start` 变成了 0x8040_xxxx，`__heap_start < __stack_top`
这条断言当然失败。

修法是把 `.weights` **放到 SECTIONS 的最后**，并写上注释说明原因。

---

## 3. 结果

| 项 | 改前 | 改后 |
| --- | ---: | ---: |
| `.rodata` | 159 KB | **134.6 KB** |
| 平坦镜像 | 0.19 MB | 4.22 MB（权重在 0x8040_0000） |
| 权重容量上限 | ~30 KB（DRAM 余量） | **8 MB**（专用区域） |

链本身仍然逐比特通过：

```
  weight blob at 0x80400000, 25504 bytes staged from the uncached window
  conv0p    9216 bytes  ok
  conv0     9216 bytes  ok
  conv1     4608 bytes  ok
  conv2     3072 bytes  ok
miniTensor real YOLO chain PASSED (45129 commands, 4217564 cycles)
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
| `mt_yolo` | ✅ 16384/16384 |
| `mt_yolocnn`（权重改为从 blob 加载） | ✅ 全对 |

---

## 5. 这一步解锁了什么

现在**权重容量不再是瓶颈**：tiny-yolov3 全部 13 个卷积的 8.85 MB 可以完整放进 8 MB 的
权重区域。剩下的两个障碍是：

1. **激活缓冲区仍然只能在 64 KiB 的 scratch 里** —— 层的 `src_off`/`out_off` 都是相对
   `MT_BUF_BASE` 的偏移。要让激活也搬到扩展窗口（128×128 输入时第一层输出就有 262 KB），
   需要把层描述符里的偏移改成**绝对地址**。这是下一步的第一件事。
2. **Concat / Upsample / MaxPool-stride-1** 的调度。

之后就能跑完整 tiny-yolov3 @128×128（约 0.11 GMAC，端到端约 14 分钟仿真）。
