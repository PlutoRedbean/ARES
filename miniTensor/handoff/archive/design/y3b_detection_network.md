# Y3b：在 miniTensor 上跑通一个 YOLO 形状的检测网络

> 从"单层卷积"推进到"完整多尺度检测网络"，全部逐层与 CPU 参考比对通过。

---

## 1. 结果

```text
msh >mt_net
miniTensor YOLO-shaped net (32x32x4 -> 8x8x8 head).
  L1 conv: OK (8192 bytes)
  L1 pool: OK (2048 bytes)
  L2 conv: OK (4096 bytes)
  L2 pool: OK (1024 bytes)
  L3 conv: OK (1024 bytes)
  L4 head: OK (512 bytes)
miniTensor net PASSED (all stages match the CPU reference).
  16823 accelerator commands, 2505519 accelerator cycles
  745472 MACs => 148 cycles per 64-MAC command
msh >quit
HIT GOOD TRAP
```

### 拓扑

| 层 | 类型 | 形状 | K | MACs |
| --- | --- | --- | ---: | ---: |
| L1 | conv 3×3 pad1 + ReLU | 32×32×4 → 32×32×8 | 36 | 294912 |
| — | maxpool 2×2 | 32×32×8 → 16×16×8 | | |
| L2 | conv 3×3 pad1 + ReLU | 16×16×8 → 16×16×16 | 72 | 294912 |
| — | maxpool 2×2 | 16×16×16 → 8×8×16 | | |
| L3 | conv 3×3 pad1 + ReLU | 8×8×16 → 8×8×16 | 144 | 147456 |
| L4 | head 1×1 | 8×8×16 → 8×8×8（4 box + 1 obj + 1 cls，补齐到 8） | 16 | 8192 |

**实测**：745472 MACs / 2505519 cycles = **0.30 MAC/cycle**，@300 MHz 约 **8.4 ms/次**。

### 外推到 YOLOv5n

按 0.30 MAC/cycle 线性外推 2.25 GMAC：**约 7.5e9 cycles ≈ 25 s @300 MHz**。
结论不变：能跑通、可验证，不是实时。

---

## 2. 关键设计：A 放激活、B 放权重（免 im2col）

MT_GEMM 是 `C[i][j] = Σ_k A[i][k]·B[k][j]`，A、B 各占**一条 16 字节 UB 行**
（A 行内 `4i+k`，B 行内 `4k+j`）。

取 **i = 空间位置，j = 输出通道，k = 输入通道**，则 `A[i][k] = x[空间 i][输入通道 k]`。
激活按 **NHWC、每 4 通道一组**存放时，通道 k 在空间位置 i 的字节正好是 `4i+k`
—— 与 A 行布局一致，而且 **4 个连续空间位置就是 16 个连续字节**。

所以：

- 激活操作数是**一次线性 MT_LOAD**，完全不需要 im2col；
- 权重行很小（`(C/4)·(C_out/4)·k·k` 条），整层常驻 UB；
- 卷积退化成 `for ky, kx, g: LOAD A; for mg: GEMM(acc)`。

### 踩坑：kx 偏移破坏 16 字节对齐

MT_LOAD 要求 **16 字节对齐**，而"从 w = t*4 + kx 开始"对 kx≠0 就不对齐了。
解法是把 kx **预烘进激活缓冲**：`net_pad` 生成 `[kx][g][h][w][4]`，
每个 A 行起点是 `16·(((kx·ng+g)·PH + ho+ky)·(W/4) + t)`，天然对齐。

代价是激活缓冲 ×k 份（k=3 时 3 份），对 L1 是 13 KB —— 64 KiB scratch 完全放得下。

---

## 3. 顺带发现的两个平台约束

### 3.1 IROM 装不下 CoreMark + 加速器

加完加速器驱动后 `.text` 到 **32660 / 32768**，只剩 108 字节。
在 BSP Makefile 里加了 `MT_WITH_COREMARK=0`（用 `mt_main.c` 代替
`competition_app.c` 提供 `main`），镜像降到 **15188 字节**，释放 17.5 KB。

### 3.2 固件 `.bss` 不能太大（根因未定位）

给参考模型加 6 个 per-stage 快照数组（+17 KB `.bss`，总量 30656 → 39360）后，
**固件在打印完 banner 后再也不响应任何 shell 命令**——连 `mt_gemm` 都不响应，
不只是 `mt_net`。同一进程里 CPU 跑满但无输出。

已验证的事实：
- 去掉 `mt_net.c`（`.bss` 10208）→ 正常；
- 保留 `mt_net.c` 但把命令体 stub 掉（`.bss` 10208）→ 正常；
- 恢复命令体但**不加**快照数组（`.bss` 30656）→ 正常，且网络全部通过。

内存映射本身是干净的：`.bss` 结束于 `0x8010a730`，`__stack_top = 0x80130000`，
链接期 `ASSERT(__heap_start < __stack_top)` 通过。对照检查过
`ref_conv/ref_pool2` 的写入范围，全部在数组内。

**当前做法**：参考模型改成"每层现算现比"的乒乓结构（只用 `ref_a`/`ref_b`），
`.bss` 保持在 30656。**根因待查**——这属于平台侧的一个真实隐患，
将来固件变大时还会撞上。

---

## 4. 复现

```bash
cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd
make CROSS_COMPILE=riscv64-unknown-elf- \
     MUNDUS_HOME=$MUNDUS_HOME \
     NPC_HOME=$MUNDUS_HOME/npc \
     MT_WITH_COREMARK=0 image
cd $MUNDUS_HOME/npc
JYD_CONSOLE_CMDS='mt_net;quit' ./build/MundusJyd +verilator+rand+reset+0
```

---

## 5. 下一步

| 项 | 说明 |
| --- | --- |
| Y4 性能优化 | 命令 FIFO 降低 MMIO 往返（149 cycles/命令 vs 加速器侧 24.5）；DMA 与计算重叠 |
| 更大规模 | 当前是 32×32 输入、4 层。要逼近真实 YOLO 需扩到更多层/更多通道，并解决 `.bss` 约束 |
| 权重打包工具链 | 现在权重由 LCG 在片内生成；真实模型需要 PyTorch/ONNX → INT8 → 本布局的离线打包 |
| `.bss` 根因 | 定位 3.2，避免后续再撞 |
