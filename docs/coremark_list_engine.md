# CoreMark 链表引擎（list9_engine）

> 状态：已实现并通过 Verilator 验收（2026-11-01）。
> 单核 100 iterations：**13.381925 CoreMark/MHz**（7,525,556 cycles），
> 4-hart `MULTITHREAD=4` 200 iterations：**57.242704 CoreMark/MHz**
> （3,630,085 cycles），4 份 CRC 全对。

## 1. 为什么做

全加速镜像里，CRC/矩阵/状态机之后剩下的时间几乎都在 `core_bench_list`：
数组化之后每 100 iterations 仍有 5,643,826 条链表指令（占 retire 的 70%），
其中 `find` 2.81M、`core_bench_list` 自身的 move-to-front/排序簿记 2.84M。
这些指令的共同点是**串行指针追逐**：软件无论怎么展开，每节点都要
`next → info->idx` 的依赖 load，move-to-front 还要 O(n) 搬数组。

链表引擎把 **102 次 find + reverse + move-to-front** 整个 hot loop 搬到
硬件，软件只保留排序、remove/undo 和 CRC walk。这样：

- find 在引擎的 32 项阵列里顺序扫描，1 node/cycle；
- reverse 只翻一个方向位；
- move-to-front 是阵列内 1 元素/cycle 的移位；
- 软件不再执行 5.6 万条/iteration 的链表指令。

## 2. 结构

```
CPU (core_bench_list 驱动)                 list9_engine @ 0xA000_3000
  ├─ 写 NODE[0..30] / VAL[0..30]  ───────►  32 x {node, val} 阵列
  ├─ 写 N/FINDER/SEED3/CTRL       ───────►  FSM: FIND → UPD → MTF → NEXT
  ├─ 轮询 STATUS.done             ◄───────  busy/done/dir
  └─ 读 NODE[0..30] + RETVAL      ◄───────  最终逻辑顺序 / found/missed
        │
        └─ 软件继续做 sort / remove / undo / crc walk / materialize
```

- **阵列**：`NODE[i]` 是节点地址，`VAL[i] = {idx[31:16], data16[15:0]}`；
  32 项、异步读、单写口（host 写 / 引擎移位分时复用）。
- **方向位**：`dir` 把逻辑位置映射到物理项（`dir ? n-1-k : k`），
  reverse 只翻 `dir`；host 读回时按 `dir` 反向取。
- **move-to-front**：与 C 数组影子完全一致——保存 `ri+1`（dir=0）或
  `n-2-ri`（dir=1）的项，按 1 元素/cycle 移位，再写回位置 1 / n-2。
- **retval**：miss 取 `(data16>>8)&1`，found 取 `(data16>>9)&1`，
  最后一次加 `found*4 - missed`（u16 回绕）。
- **不做的部分**：排序仍然在软件，因为 `cmp_complex` 会回调
  `calc_func` 再进矩阵/状态机；remove/undo/CRC walk 也很便宜。

## 3. MMIO 映射（4 KiB 窗口，0xA000_3000）

| 偏移 | 名称 | 说明 |
| --- | --- | --- |
| 0x000..0x07C | NODE[0..31] | 节点地址，逻辑顺序；读回是最终顺序 |
| 0x100..0x17C | VAL[0..31] | `{idx[31:16], data16[15:0]}` |
| 0x700 | CTRL | bit0 = start |
| 0x704 | N | 节点数（3..32） |
| 0x708 | FINDER | s16 finder_idx（负数 = data16 模式） |
| 0x70C | SEED3 | s16 find 次数 |
| 0x710 | STATUS | bit0 busy，bit1 done，bit2 最终方向 |
| 0x714 | RETVAL | u16，含 `found*4-missed` |
| 0x718 / 0x71C | FOUND / MISSED | 调试计数 |

Host 侧只做 32-bit word 读写；数据写只允许在 `busy=0` 时进行。

## 4. 软件接口

`scripts/coremark_array_list.c` 的 `core_bench_list()` 在
`ARES_LIST_ENGINE` 下走 `ares_hw_loop()`：

1. 把当前数组影子的 31 项写进 NODE/VAL；
2. 写 N/FINDER/SEED3/CTRL，轮询 STATUS.done；
3. 按 STATUS.dir 读回最终顺序，重建 `ares_nodes/ares_info`；
4. 继续原有 `ares_sort` / `ares_remove_after_head` / `ares_crc_walk` /
   `ares_materialize`。

软件路径（不定义 `ARES_LIST_ENGINE`）保留 P0-0 的索引链表实现作为
fallback 和黄金模型；两者共享同一段尾代码。

## 5. 验证

- `make unit-list9`：232 组 directed/random 向量（n=3..32，1..255 次
  find，两种 key 模式），逐项比较 RETVAL/FOUND/MISSED/dir/最终顺序；
  **ALL 232 LIST9 VECTORS PASSED**。
- `make test-coremark-array`：软件影子 vs 原版 200/200 calls 一致。
- `make pipeline-isa`：ISA 36/36。
- 单核全加速：`CoreMark PASS`，9 checks 全过。
- 4-hart `MULTITHREAD=4`：`CoreMark PASS`，4 份
  `crclist/crcmatrix/crcstate` 全对，`a0=0`。

## 6. 结果（Verilator，100 MHz 计数）

| 配置 | iterations | cycles | CoreMark/MHz | 相对旧全加速 |
| --- | ---: | ---: | ---: | ---: |
| 全加速（旧软件数组） | 100 | 14,263,577 | 7.0109 | 1.000x |
| 全加速 + P0-0（软件） | 100 | 14,179,708 | 7.0824 | 1.010x |
| **全加速 + list9_engine** | **100** | **7,525,556** | **13.3819** | **1.909x** |
| **4-hart MT + list9_engine** | **200** | **3,630,085** | **57.2427** | **1.82x**（相对 31.5 聚合） |

4-hart 聚合接近线性（单核 13.38 × 4 = 53.5，实测 57.24，因为
4×50 iterations 摊薄了启动开销）。

## 7. 限制与后续

- 只支持 `n <= 32`；CoreMark 的链表是 31 节点，其它规模回退软件。
- host 数据口是逐 word MMIO；每次调用约 62 次写 + 62 次读，~500 cycle，
  相对整段 ~70k cycle 可忽略。若以后要支持更大的链表，改成 DMA/描述符。
- 引擎是每 hart 一份（链表是私有的）；4 份面积很小（2×32×32 阵列 +
  ~1k LUT），时序在 MMIO 响应寄存器之后，不进入 load-use 关键路径。
- 该变体是 accelerated variant，不能与官方 EEMBC 分数直接比较。

## 8. 文件

| Path | 内容 |
| --- | --- |
| `rtl/accel/list9_engine.sv` | 引擎 RTL |
| `rtl/accel/test/unit/tb_list9_engine.sv` | 向量 TB |
| `scripts/gen_list9_vectors.py` | directed/random 向量 + Python 黄金模型 |
| `scripts/coremark_array_list.c` | 软件影子 + 引擎驱动 + 共享尾 |
| `rtl/pipeline/soc/jyd/pipeline_accel.sv` | 第三页 0xA000_3000 封装 |
| `rtl/pipeline/soc/jyd/perip_bridge.sv` | ACCEL_LIST_PAGE 译码 |
