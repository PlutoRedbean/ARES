# miniTensor 存储容量扩展（Y1）

> 目标：突破片上 256 KiB 的硬墙，让固件能持有真实模型的权重与激活。
> 这一步是"在平台上跑 YOLO"的**硬前置**。

---

## 1. 结果

```text
msh >mt_memtest
miniTensor extended-memory test (CPU + DMA, >256 KiB).
miniTensor extended-memory test PASSED (0x8040_0000 and 0x80F0_0000).
msh >quit
HIT GOOD TRAP
```

`mt_memtest` 覆盖了四条路径，全部成功：

1. CPU **uncached 写** 到 `0x8040_0000`（远超旧的 256 KiB 边界）
2. CPU **读回**同一段（顺带验证 perip_bridge 的 store→load forwarding 在加宽后的地址上仍然正确）
3. DMA：`0x8040_0000 → UB → 0x80F0_0000`（约 14 MiB 偏移处）
4. DMA：`0x80F0_0000 → UB → uncached scratch`，CPU 逐字节比对 64 B 全部一致

---

## 2. 新的地址映射

| 窗口 | 大小 | 属性 | 用途 |
| --- | ---: | --- | --- |
| `0x8010_0000 – 0x8013_FFFF` | 256 KiB | **cacheable** | RT-Thread `.rodata/.data/.bss`/栈 |
| `0x8013_0000 – 0x8013_FFFF` | 64 KiB | 物理切片 | miniTensor scratch（只准走别名） |
| `0x8020_0000 – 0x8020_00FF` | 256 B | MMIO | 外设 + miniTensor 控制寄存器 |
| `0x8030_0000 – 0x8033_FFFF` | 4 MiB 窗口 | uncached **别名** | 映射到 `0x8010_0000`（清 bit21） |
| **`0x8040_0000 – 0x80FF_FFFF`** | **12 MiB** | **uncached** | **权重 / 激活（本次新增）** |

D-cache 的 cacheable 判据是**硬编码**的（`scsrc/Mundus.scala:543-544`，只看
`addr[31:18] == 0x204`），所以 `0x8040_0000` 以上**天然不可缓存** ——
CPU 可以直接读写，不存在一致性问题。

`0x8014_0000 – 0x803F_FFFF` 被**故意留空**：这段如果划进 DRAM，就会把
`0x8020_0000` 的外设页一并吞掉（第一版实现正是踩了这个坑，表现为固件在打印
banner 之前就挂死）。

---

## 3. 改了哪些地方

| 文件 | 改动 |
| --- | --- |
| `npc/csrc/include/mem.h` | `DRAM_BASE`/`DRAM_SIZE` 常量；`in_dram()` 覆盖 15 MiB |
| `npc/csrc/wave/mem.cpp` | `dram[]` → 15 MiB；`program_ROM` 读到文件尾（权重 blob 自动被加载） |
| `npc/vsrc/testbench/jyd/perip_bridge.sv` | 三段式 DRAM 译码 + 别名归一化；store queue / BRAM 命令地址 18→24 位 |
| `npc/vsrc/testbench/jyd/bram_driver.sv` | 地址 18→24 位；FPGA 分支用 `ifdef __VERILATOR__` 保留原 16 位 |
| `npc/vsrc/testbench/IP/BRAM.v` | 字地址 16→22 位，重建 `0x8000_0000 \| (word << 2)` |

**FPGA 路径未受影响**：Vivado 的 Block Memory Generator 仍是 65536×32，
`bram_driver` 在非 Verilator 分支下沿用原来的 16 位地址。

---

## 4. 为什么这样可以，而不用加 DDR

Verilator 下 DRAM **不是 BRAM，而是 C++ 字节数组**（`BRAM.v` 通过 DPI 走
`vaddr_read/vaddr_write`）。所以扩容只是把数组改大，**不消耗任何综合资源**，
也不需要新的存储控制器。代价仅在仿真内存占用（15 MiB）与镜像加载时间。

代价：**目前只有仿真能用**。FPGA 上仍是 256 KiB，除非改板级设计加 DDR
（`top.sv` 现在连一个外部存储器引脚都没有）。

---

## 5. 对 YOLO 的意义

| 模型 | INT8 权重 | 12 MiB 窗口是否放得下 |
| --- | ---: | :---: |
| YOLOv5n | 1.9 MB | ✅ |
| YOLOv8n | 3.2 MB | ✅ |
| YOLOv2-tiny | 5.9 MB | ✅ |
| YOLOv3-tiny | 8.7 MB | ✅ |

**容量壁垒已经拆除** —— 接下来（Y2）要解决的是把 PyTorch 权重量化、
按 miniTensor 的 4×4×4 tile 布局打包，以及逐层调度。
