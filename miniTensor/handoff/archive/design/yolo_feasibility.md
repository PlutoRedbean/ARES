# miniTensor 上跑 YOLO 的可行性分析（实测数据）

> 结论先行：**当前 JYD 平台的瓶颈是存储容量，不是算力。**
> 256 KiB 的片上 DRAM 放不下任何真实 YOLO 的权重，但 **Verilator 的内存模型可以低成本扩容**，
> 这是唯一现实可行的"部署运行 YOLO"路径。

---

## 1. 硬约束（全部实测，非估计）

| 资源 | 容量 | 来源 |
| --- | --- | --- |
| IROM | 32 KiB | `npc/configs/Mundus/Kconfig` `IROM_SIZE_32KB` 默认 |
| DRAM | **256 KiB** | BSP README §3；FPGA COE 规格 `65536 x 32` |
| FPGA 外存 | **无** | `npc/constr/digital_twin.xdc` 中 ddr/dram/sdram 匹配数 = 0；`top.sv` 只有 clk/uart/led/seg 引脚 |
| miniTensor UB | 4 KiB | 256 行 × 16 B（`unified_buffer.sv`） |
| 单条 MT_GEMM | 4×4×4 = **64 MAC** | `tensor_pkg.sv` `TENSOR_DIM=4` |

## 2. 实测的每命令开销

**加速器侧**（`integration/npc/tb_mt_shim.sv` 对真实 `mini_tensor_top`）：

```
4x MT_LOAD + MT_GEMM + MT_EPILOGUE + MT_STORE = 196 cycles
=> 平均 24.5 cycles/命令
```

**真实 NPC + RT-Thread 下**（`mt_gemm` 自校验，`mcycle` 计数）：

```
同样的 9 条命令 = 724 cycles
=> 平均 80 cycles/命令
```

差值（≈55 cycles/命令）就是 MMIO 往返 + perip_bridge 强序等待
（`store_empty && !bram_write_valid_q`）的开销。

**一层真实卷积**（`mt_conv`：6×6×4 → 3×3 conv → 6×6×4，K=36，M=4，N=36）：

```
81 GEMM + 9 EPILOGUE + 4 LOAD + 1 STORE = 95 条命令
7495 cycles  =>  79 cycles/命令
5184 MAC / 7495 cycles = 0.69 MAC/cycle（端到端，含全部开销）
```

按 0.69 MAC/cycle 线性外推 YOLOv5n（2.25 GMAC）：**约 3.3e9 cycles ≈ 11 s @300 MHz**。
这个量级只能算"跑得通、可验证"，不是实时推理。

> **结论：优化重点在减少 CPU↔加速器的往返，而不是 MXU 本身。**
> 例如给 shim 加一个命令 FIFO（软件一次写入多条命令再统一轮询），
> 可以把 80 拉回接近 24.5，等效吞吐提升 3 倍以上。
> 另一条路是让 DMA 与计算重叠（现在一条命令跑完才接第二条）。

## 3. 存储：为什么放不下

| 模型 | 参数量 | INT8 权重 |
| --- | ---: | ---: |
| YOLOv3-tiny | 8.7 M | 8.7 MB |
| YOLOv2-tiny | 5.9 M | 5.9 MB |
| YOLOv8n | 3.2 M | 3.2 MB |
| YOLOv5n | 1.9 M | 1.9 MB |
| NanoDet-m | 0.95 M | 0.95 MB |
| **可用预算** | — | **约 150 KiB** |

DRAM 总共 256 KiB，RT-Thread Nano + 线程栈 + 中间激活大约要占 60~100 KiB，
留给权重的只有 ~150 KiB —— **比最小的 NanoDet-m 还小 6 倍**。

**这是硬墙**：不扩内存，任何真实 YOLO 都跑不起来，跟算力优化无关。

## 4. 算力：跑得动，但慢

按 64 MAC/命令换算：

| 每命令周期 | 等效 MAC/cycle | YOLOv5n (2.25 GMAC) @300 MHz | @50 MHz |
| ---: | ---: | ---: | ---: |
| 24.5（实测加速器侧） | 2.6 | ~2.9 s | ~17 s |
| 100（含 MMIO 往返） | 0.64 | ~12 s | ~70 s |

**命令数才是真正的量级问题**：2.25 GMAC ÷ 64 MAC/命令 = **3500 万条命令**。
即使每条只要 10 拍，也是 3.5 亿拍。所以 YOLO 在这个加速器上属于
"能跑通、可验证、但以秒计"的量级，不是实时推理。

### 卷积的额外代价

miniTensor 的原生 tile 是 4×4×4。对一个 3×3、C_in=32 的卷积，
K = 32×9 = 288，需要 **72 次 GEMM 累加**才能算完一个 4 输出通道 × 4 空间位置的 tile。
YOLOv5n 第一层（640×640）单独就要约 **2950 万条命令**。
这说明当前 tile 形状对 CNN 的映射效率很低 —— 这是架构层面的限制，
只能靠"接受慢"或"改架构"来解决，不是驱动能优化的。

## 5. 可行路径

### 路径 A（推荐，先做）：仿真内存扩容 + 真实 YOLO

Verilator 下 DRAM **不是 BRAM，而是 C++ 字节数组**：

```
npc/vsrc/testbench/IP/BRAM.v:11-12   import "DPI-C" ... vaddr_read / vaddr_write
npc/csrc/wave/mem.cpp:17             static uint8_t dram[0x40000];
```

所以扩容只是几行改动：
1. `dram[]` 尺寸从 `0x40000` 改到例如 `0x1000000`（16 MiB）；
2. `perip_bridge.sv` 的 `dram_read_hit/dram_write_hit` 判据从 `addr[31:18]==0x204` 放宽到覆盖更大窗口；
3. `BRAM.v` 的窗口内偏移位宽相应加宽；
4. `mem.h` 的 `in_dram()` 与 `program_ROM()` 的加载区间同步。

代价：**只影响仿真，不涉及任何综合资源**。这让"在 RT-Thread 上部署运行真实 INT8 YOLO"
在 Verilator 里完全可行，并给出真实的性能/正确性数据。

### 路径 B：ysyxSoC + SDRAM（32 MiB）

`npc/configs/SoC/Kconfig` 里 `CONFIG_SDRAM_SIZE=0x2000000`（32 MiB），
容量上完全够 YOLOv5n。但需要：
- 初始化 `ysyxSoC` 子模块并 `make dev-init`；
- **为 Mundus 写一个 AXI 包装层**（当前 CPU 顶层是 `irom/perip`，不是 AXI）；
- `PLATFORM=soc` 的整条流程。

工作量明显大于路径 A，但那是"能上真实 SoC"的路径。

### 路径 C：FPGA 上板

当前 `top.sv` **没有任何外部存储器引脚**，全部存储都是片上 BRAM。
256 KiB 是物理上限。要走这条路必须先改板级设计（加 DDR 控制器 + 引脚约束），
超出当前仓库范围。

## 6. 建议的推进顺序

| 阶段 | 目标 | 验收 |
| --- | --- | --- |
| **Y0** | 打通 JYD 上的加速器 + 驱动 + RT-Thread（用小的 K=12 GEMM） | `mt_gemm` 打印 PASS |
| **Y1** | 仿真 DRAM 扩容到 16 MiB | 能读写超出 256 KiB 的地址 |
| **Y2** | 卷积的 tile 布局与打包（im2col + 权重行） | ✅ host 侧 `integration/tools/conv_layout_check.py` PASS |
| **Y3** | 在 RT-Thread 下跑通**一层真实 3×3 卷积** | ✅ `mt_conv` PASS（144/144 输出字节与 CPU 参考一致） |
| **Y3b** | 逐层调度到**完整 YOLO 形状检测网络** | ✅ `mt_net` PASS：4 层逐层与 CPU 参考一致，16823 命令 / 2.51M cycles / 0.30 MAC/cycle |

> 详见 [`y3b_detection_network.md`](y3b_detection_network.md)。
> 实测 745472 MACs / 2505519 cycles = **0.30 MAC/cycle**，@300 MHz 约 8.4 ms/次；
> 按此外推 YOLOv5n（2.25 GMAC）约 **25 s @300 MHz**。
| **Y4** | 性能数据 + 优化（命令 FIFO、减少 MMIO 往返） | 给出 cycles/帧 |

**关键判断**：Y0 是必须的（证明链路正确），但 YOLO 的真正门槛在 **Y1 的存储扩容**。
如果最终必须上真实硬件而不是仿真，那么 **路径 B（ysyxSoC + SDRAM）是唯一的选项**，
需要提前把它排进计划。
