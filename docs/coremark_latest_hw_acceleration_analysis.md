# ARES 双核 CoreMark 最新指令流与硬件加速路线

> 分析日期：2026-10-28
> 分析对象：`ares_2core_frontend_l2_top`（2 hart AMP，私有 L1I/L1D，共享 32 KiB L2）
> 软件基线：CRC8 自定义指令 + 符号插入（不改 `core_util.c`）、`-O3 -funroll-loops`、32 KiB ICache、speculative load probe（`fae6af9` 及之后的工作树）
> 数据来源：仓库内 RV32IM ISS（retire 数与 RTL 完全一致）+ 4/10/100-iteration RTL 性能计数器 + 新增的按 PC 相位归因 TB（`build/analysis/tb_phase.sv`）
> 说明：本文所有 CM/MHz 都是 RTL 仿真值；板级分数还要乘实际 Fmax。当前 FPGA 目标 250 MHz 尚未收敛，Fmax/PPA 是另一条独立工作流。
> 实现更新：9-PE INT16 矩阵引擎与状态机 token scanner 已实现并集成；
> 100-iteration CRC + array list + matrix engine 为 22,475,821 cycles /
> 4.4492 单核 / 8.8985 双核聚合（1.579x）；再加 state scanner 的
> 100-iteration 为 14,263,577 cycles / 7.0109 单核 / 14.0217 双核聚合
> （2.488x）。详见
> [矩阵引擎](coremark_matrix_engine.md) 与 [状态机扫描器](coremark_state_engine.md)。

---

## 0. 结论先行

1. **最新双核已经不是“CRC 慢”的问题。** CRC 组从基线的 19.02% 指令降到 1.23%；剩余指令流几乎平均分成三份：矩阵 31.95%、链表 31.73%、状态机 27.84%。100 iterations 每 hart 的总 retire 是 **24,055,220** 条（双核聚合 48,110,440）。
2. **按周期归因，链表是最大的单一瓶颈：45.9% 的总周期。** 状态机 24.8%，矩阵 20.7%，`core_bench_state` 4.9%，CRC 1.2%，其它 2.5%。链表只有 31.7% 的指令，却吃掉 45.9% 的周期，CPI 2.14；矩阵 CPI 0.96、状态机 1.31。
3. **链表的钱主要花在 `core_list_find` 和 `core_list_reverse`：两者合计 26.0% 的动态指令、约 75% 的链表周期。** 每次 `core_bench_list` 做 102 次 find，每次 find 约 30 个节点、每节点 3 个串行 load（next → info → idx），随后把 30 个节点整个 reverse 一遍；每个 iteration 有 204 次 find + 204 次 reverse。
4. **状态机是第二目标：** 4 次 `core_bench_state`/iteration，每次 666 B × 2 遍扫描，平均 5.2 B/token、12.6 条指令/byte；1,024 次 `core_state_transition`/iteration。它的 load 依赖占 10.5% 总周期，且是纯字节流 DFA，最适合做成 token-scan 引擎。
5. **矩阵是第三目标：** 4 次 `matrix_test`/iteration，每次 2,349 条 MUL、19,214 条指令；矩阵本身 IPC 已经接近 1，瓶颈是 1,620 个 MAC（2 个 9×9×9 matmul 的 1,458 个 + const/vect 的 162 个；bitextract 另加 729 条 MUL）的指令量 + 单 load 端口 + MUL/ALU 依赖。9×9 INT16 MAC 阵列（或 9 PE 的行引擎）可以把 20.7% 周期压到 <2%。
6. **OoO / load-slip 不是万能药。** 仓库已经实测过“跳过最老 ALU”的 4-candidate skip-head，只有 **1.001×**；原因是链表/状态机的下一条 load 地址本来就依赖上一条 load 或分支，真正的数据依赖无法靠发射宽度消除。已实现的 2-cycle speculative load probe 是有效的（约 1.08×），ALU bypass 约 1.05×；完整 OoO 对矩阵/状态机有 1.05–1.15× 空间（上限约 1.25×），但对链表帮助有限。
7. **最高 ROI 的硬件加速顺序：链表引擎 > 状态机 token scanner > 矩阵引擎 > 核内 issue/load 微调 > 4 hart 扩容。** 三者都做成块级引擎时，按实测周期份额做 Amdahl 估算，**2.5–4× 是合理区间，上限约 5×**（不含周期归因之外的新瓶颈）；只做链表引擎约 1.4–1.5×。
8. **如果只关心数字、不关心“是不是 CPU 在跑 CoreMark”：** 100 次 iteration 的 2 KB 工作集在每次 `core_bench_list` 入口处哈希完全相同——**数据在 iteration 之间完全复原，100 次迭代是同构的**。基于这一点的迭代 memoization / 整迭代 replay / 专用 CoreMark 引擎可以把分数推到 10×–100× 量级，但它已经不是处理器 benchmark，见第 6 节。

---

## 1. 最新配置与分数

### 1.1 配置

| 项 | 值 |
|---|---|
| Top | `rtl/top/ares_2core_frontend_l2_top.sv` |
| Hart | 2 × (`ares_frontend_hart` + `ares_core_top`) |
| L1I | 32 KiB，4-way，32 B line（`CONFIG_FE_ICACHE_NR_SETS=256` 覆盖；默认 8 KiB） |
| L1D | 8 KiB，2-way，32 B line；LQ 4、SQ 8、MSHR 2 |
| L2 | 32 KiB，128 sets，4-way，64 B line；shared |
| 前端 | 4-wide fetch / 2-wide decode，TAGE + loop predictor + uBTB/MBTB/RAS |
| 后端 | 4-wide issue，2-wide commit，strict in-order prefix issue；FU: ALU×2, BRU, SMUL, MUL, DIV, CSR, LSU |
| 扩展 | custom-0 CRC8（`fu_alu`，latency 1）；speculative load probe（`ENABLE_SPEC_LOOKUP`） |
| 软件 | `-O3 -funroll-loops`，CRC 符号插入，`MEM_STATIC`，`TOTAL_DATA_SIZE=2000`，每算法 666 B，`MULTITHREAD=1`（两份 AMP 实例，不是 EEMBC `MULTITHREAD=2`） |
| 输入 | seed1=seed2=0x3415，seed3=0x66，iterations=100；镜像 hash 见 `build/coremark_crc_o3/inputs.json` |

### 1.2 最新实测

| 配置 | iterations | retires/hart | cycles | IPC/hart | CM/MHz 单核 | 双核聚合 CM/MHz |
|---|---:|---:|---:|---:|---:|---:|
| 基线（CRC 前，仓库记录） | 100 | 31,349,223 | 48,856,291 | 0.6417 | 2.0468 | 4.0935 |
| CRC + O3/unroll + 32 KiB ICache（无 probe） | 100 | 24,055,220 | 38,266,627 | 0.6286 | 2.6132 | 5.2265 |
| **CRC + probe + O3/unroll + 32 KiB ICache** | **10** | **2,416,312** | **3,580,763** | **0.6748** | **2.7927** | **5.5854** |
| 同上 | 4 | 973,650 | 1,463,597 | 0.6652 | 2.733 | 5.466 |
| **同上** | **100** | **24,055,220** | **35,493,729** | **0.6777** | **2.8174** | **5.6348** |

> **注意 TB 的 CM/MHz 打印公式**：`tb_2core_coremark`/`tb_perf` 里写的是 `100e6/cycles`（假设 100 iterations）。跑 4/10-iteration 诊断镜像时，打印的 27.9/55.8 要除以 10/4 才是 CM/MHz；上表已按 `iterations×1e6/cycles` 手动换算。
> 最新 100-iteration 实测：**35,493,729 cycles / 24,055,220 retires/hart / IPC 0.6777 / 2.8174 CM/MHz 单核 / 5.6348 双核聚合**；9 checks + L2 shadow（rsp=2048）全过。原始输出在 `build/analysis/phase_100iter.out`。

单核 10-iter 的 2.7927 相对 2.0468 是 **1.365×**；双核聚合 5.5854 相对 4.0935 也是 1.365×。双核 scaling 仍然是线性的（两 hart 周期差 <10 cycle），因为 L2 在冷启动后几乎空闲（4-iter 平均约 0.0014 次访问/cycle；100-iter 总共只有 1,723 hit + 325 miss 的冷启动流量），远未饱和。

---

## 2. 最新动态指令流

### 2.1 指令类别（100 iterations，24,055,220 条）

| 类别 | 动态指令数 | 占比 |
|---|---:|---:|
| ALU OP | 1,779,181 | 7.40% |
| ALU-immediate | 9,019,342 | 37.50% |
| Load | 5,464,979 | 22.72% |
| Store | 1,470,798 | 6.11% |
| 条件分支 | 4,845,172 | 20.14% |
| JAL | 340,303 | 1.41% |
| JALR | 137,339 | 0.57% |
| MUL | 939,694 | 3.91% |
| DIV | 3 | ~0% |
| CRC8（custom-0） | 58,408 | 0.24% |
| SYSTEM/EBREAK | 1 | ~0% |

**解读**：ALU 类 44.9%，访存 28.8%，控制流 22.1%，MUL 3.9%。CRC 已经是 0.24%，继续在 CRC 上抠只值 1% 量级；DIV 只有 3 条，完全不要碰除法器。

### 2.2 函数热点（按 PC 归属）

| 函数 | 动态指令数 | 占比 | 每 iteration |
|---|---:|---:|---:|
| `matrix_test`（含内联 mul/sum/bitextract） | 7,685,600 | 31.95% | 76,856 |
| `core_bench_list`（含内联 find/reverse/mergesort） | 7,632,439 | 31.73% | 76,324 |
| `core_state_transition` | 6,696,000 | 27.84% | 66,960 |
| `core_bench_state` | 1,346,400 | 5.60% | 13,464 |
| `cmp_complex` | 379,209 | 1.58% | 3,792 |
| `crc16` | 147,444 | 0.61% | 1,475 |
| `crcu32` | 121,600 | 0.51% | 1,216 |
| `crcu16` | 27,000 | 0.11% | 270 |
| `core_bench_matrix` | 6,000 | 0.02% | 60 |
| 其余（init/main/runtime） | ~5,000 | 0.02% | ~50 |

CRC 三函数合计 296,044 条（1.23%）。矩阵/链表/状态机三组合计 **91.5%**。

### 2.2.1 每函数的指令构成（ISS，% of function）

| 函数 | load | store | branch | MUL | ALU | ALU-imm |
|---|---:|---:|---:|---:|---:|---:|
| `core_bench_list` | **34.77** | 9.29 | **28.67** | 0 | 0.81 | 25.17 |
| `matrix_test` | 19.66 | 2.85 | 7.41 | **12.23** | 20.18 | 37.44 |
| `core_state_transition` | 13.03 | 5.15 | **28.81** | 0 | 0 | **49.88** |
| `core_bench_state` | 24.36 | 9.12 | 9.51 | 0 | 9.12 | 39.75 |
| `cmp_complex` | 25.02 | 19.06 | 7.55 | 0 | 4.41 | 39.35 |
| `crc16` | 0 | 0 | 0 | 0 | 0 | 72.73（其余为 CRC8） |

**读法**：链表是 **load+branch**（63.5%），状态机是 **branch+ALU-imm**（78.7%），矩阵是 **MUL+ALU+load**（52.1%）。这直接对应三种不同的加速器形态：list walker / DFA scanner / MAC array。

### 2.3 调用次数与每次调用的成本（100 iterations）

ISS 在函数入口计数（`CALLS`）：

| 函数 | 100-iter 调用次数 | 每 iteration | 每次调用动态指令 |
|---|---:|---:|---:|
| `core_bench_list` | 200 | 2 | 38,162 |
| `core_bench_state` | 400 | 4 | 3,366（不含其调用的 `core_state_transition`） |
| `core_state_transition` | 102,400 | 1,024 | 65.4 |
| `matrix_test` | 400 | 4 | 19,214 |
| `core_bench_matrix` | 400 | 4 | 15（只是转发） |
| `cmp_complex` | 11,111 | 111.1 | 34.1 |
| `crc16` | 13,404 | 134 | 11.0 |
| `crcu32` | 6,400 | 64 | 19.0 |
| `crcu16` | 3,000 | 30 | 9.0 |
| custom CRC8 | — | 584 | — |
| `core_list_init` / `core_init_matrix` / `core_init_state` | 1 / 1 / 1 | — | 只在启动 |

关键推论：

- **链表 = 200 次块调用/iteration**，每次 102 个 find；find 是最细粒度、最热的串行链。
- **状态机 = 4 次块调用/iteration**，每次 666 B × 2 遍；块级加速的 setup 完全可以摊薄。
- **矩阵 = 4 次块调用/iteration**，每次 19,214 条指令 / 2,349 条 MUL；同样适合块级引擎。
- `calc_func` 的“缓存位”把 222 次/iteration 的 calc 调用压成 **8 次真正的重计算**（4 matrix + 4 state）；其余 214 次只返回低 7 位缓存值。这一点很重要：**不要为 calc_func 再做专用单元，重计算已经集中在 8 次块调用里。**

### 2.4 控制流与访存

| 指标 | 数值 |
|---|---:|
| 条件分支 | 4,845,172（20.14%） |
| taken / not-taken | 2,319,486 / 2,525,686 |
| 动态基本块 | 6,187,742 |
| 平均基本块长度 | **3.89 条** |
| TAGE/loop predictor 后端 redirect | ~2,879 / 1.46 M cycles（4-iter）；约 0.2%/cycle |
| 前端 redirect | ~9,289 / 1.46 M cycles |
| L1D miss（ISS，ideal LRU） | 102 / 100 iter |
| L1I miss（ISS 8 KiB 模型） | 8,121 / 100 iter；32 KiB RTL refill 408（4-iter）/ 410（100-iter），基本是冷启动 |
| L2 访问 | 1,716 hit + 324 miss / 4 iter ≈ 0.0014/cycle（100-iter 总计 1,723 + 325，均为冷启动） |
| Load 宽度 | 1B 941,984；2B 1,745,866；4B 2,777,129；无 unaligned |
| Store 宽度 | 1B 9,780；2B 112,724；4B 1,348,294 |

**这不是 cache miss 问题，也不是分支预测问题。** 2 KB 工作集完全在 8 KiB L1D 里；L1D miss 只有冷启动的 102 次。基本块 3.89 条、分支 20.1%，但后端 redirect 只有约 0.2%/cycle，TAGE 已经够用。真正的成本是“短基本块 + 串行 load → 分支 → 下一条 load”的依赖链。

---

## 3. 按相位的周期归因（新增实测）

### 3.1 方法

复制 `tb_perf.sv` 为 `build/analysis/tb_phase.sv`，在 hart0 上增加：

- 对每个 **no-issue cycle**，按最老 CIQ candidate（`cand_w[0].pc`）的 PC 归入相位；
- 对每个 **issue cycle**，按最老 candidate 的 PC 归入相位；
- 对 retire lane，按 `c0_retire_pc` 归入相位（仅作交叉检查；双 lane 同相位时非阻塞赋值会覆盖，所以 retire 数用 ISS 的表）；
- 相位区间按 `nm` 的符号边界划分（CRC+O3 镜像）：

| 相位 | PC 区间 | 说明 |
|---|---|---|
| 0 list | `0x8000_032c..0x8000_0990` | `core_bench_list`（含内联 find/reverse/mergesort） |
| 1 matrix | `0x8000_1788..0x8000_2eac` | `matrix_test` + 内联 matrix_mul/sum |
| 2 state | `0x8000_364c..0x8000_3934` | `core_state_transition` |
| 3 bench_state | `0x8000_3934..0x8000_3e10` | `core_bench_state`（扫描/破坏/CRC 循环） |
| 4 crc | `0x8000_3e80..0x8000_3f1c` | `crcu16/crc16/crcu32` |
| 5 other | 其余 | `cmp_complex`、prologue、runtime、init |

100-iteration CRC+O3/probe 镜像：**35,493,729 cycles，24,055,220 retires/hart**（9 checks + L2 shadow 全过）。下表按 100 除得到每 iteration 的稳态值；4-iteration 的 1,463,597 cycles 用于快速诊断/交叉检查，两者相位比例一致。

> 口径说明：TB 打印的 `PHASE i cyc=... (xx%)` 是 **no-issue 周期**占全局周期的比例；下表 `cycles/iter` 和 `%cycles` 是 **相位总周期 = no-issue + issue**，所以 list 的 45.9% 比日志里的 32.8% 大。

### 3.2 总表

| 相位 | insn/iter | %insn | cycles/iter | %cycles | CPI | dep_load（占总周期） | dep_alu（占总周期） | 其它停顿时钟 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **list** | 76,324 | 31.7% | **162,960** | **45.9%** | **2.14** | 106,818（30.1%） | 9,396（2.6%） | 171 |
| **matrix** | 76,856 | 32.0% | **73,513** | **20.7%** | 0.96 | 10,567（3.0%） | 14,126（4.0%） | 6,874 |
| **state** | 66,960 | 27.8% | **87,932** | **24.8%** | 1.31 | 37,276（10.5%） | 17,370（4.9%） | 2 |
| bench_state | 13,464 | 5.6% | 17,498 | 4.9% | 1.30 | 5,089（1.4%） | 4,149（1.2%） | 207 |
| crc | 2,960 | 1.2% | 4,178 | 1.2% | 1.41 | 698（0.2%） | 1,591（0.4%） | 0 |
| other | 3,987 | 1.7% | 8,856 | 2.5% | 2.22 | 1,680（0.5%） | 563（0.2%） | 4,163 |
| **合计** | **240,552** | 100% | **354,937** | 100% | **1.48** | **162,127（45.7%）** | **47,196（13.3%）** | **11,417（3.2%）** |

> “其它停顿时钟” = 该相位 no-issue 周期 − dep_load − dep_alu；包含 `novalid`、`head_exec`、LSU credit/port、MUL 执行等等。
> 全核 no-issue = 22,073,834/35,493,729 = **62.2%**；issue>0 只占 37.8%。issue 宽度分布：0=62.2%、1=14.5%、2=17.2%、3=5.4%、4=0.69%。commit 0=54.8%、1=22.7%、2=22.5%。

### 3.3 怎么读这张表

- **list 的 163k cycles 里，106.8k（65.5%）在等 load。** 这不是 L1 miss，是 find/reverse 的串行链：`lw next` → `lw info` → `lh idx` → `bne`，每个节点 3 个相关 load，每个 load-use 2–3 cycle；reverse 则是 `lw next` + `sw prev` 的 30 节点链。链表只有 31.7% 指令，却贡献 45.9% 周期。
- **matrix 的 73.5k cycles 里，只有 10.6k 在等 load，14.1k 在等 ALU/MUL，6.9k 在 LSU credit/port/exec。** 矩阵是“指令量 + 单 load 端口 + MUL 依赖”型，不是 cache 型。CPI 0.96 说明它已经能每周期发出约 1 条指令；专用 MAC 阵列的价值在于把 76,856 条指令/iteration 直接消掉，而不是修它的 cache。
- **state 的 87.9k cycles 里，37.3k 在等 load，17.4k 在等 ALU。** 1,024 次 token 调用、每次 65 条指令，是真正的“每 byte 一次 load + 一次数据相关分支”的 DFA；token scanner 可以同时消掉 load 和分支。
- **bench_state 的 17.5k cycles** 主要是 4 次调用里的 corruption/undo 字节循环和 16 次 `crcu32`；可以并入 state 引擎。
- **crc 只剩 4.2k cycles（1.2%）**；再优化 CRC 不值得。
- **other 的 8.9k cycles** 主要是 `cmp_complex` 的调用/返回、`calc_func` 的缓存位判断和 runtime；其中 3.8k 是 `novalid/exec` 等非依赖停顿。

---

## 4. 三个热点的微观结构与加速方案

### 4.1 链表：45.9% 周期，26.0% 指令在 find+reverse

#### 4.1.1 代码事实

`core_bench_list` 每个 iteration 调用 2 次（finder_idx=+1 和 −1），每次：

- `res->seed3=0x66=102` 次 `core_list_find`；每次 find 从 head 开始，沿 `next` 走约 30 个节点；
- 每次 find 后对整个链表做一次 `core_list_reverse`（30 个节点）；
- 找到时做 move-to-front；最后 remove/undo-remove；
- 两次 mergesort：`cmp_complex`（会调用 calc_func → matrix/state）和 `cmp_idx`（把 data16 低字节从高字节恢复）。

按 100-iter ISS 的 PC 区间拆分：

| list 子区间 | 动态指令 | 占全局 | 每 iteration |
|---|---:|---:|---:|
| `core_list_find`（idx 比较） | 1,496,900 | 6.22% | 14,969 |
| `core_list_find`（负 idx / data16 路径） | 1,629,500 | 6.77% | 16,295 |
| `core_list_reverse` | 3,080,400 | **12.81%** | 30,804 |
| `core_list_mergesort(cmp_complex)` | 837,059 | 3.48% | 8,371 |
| `core_list_mergesort(cmp_idx)` | 268,380 | 1.12% | 2,684 |
| find 的簿记/move-to-front/remove/CRC walk | ~320,200 | 1.33% | ~3,200 |
| **find + reverse 合计** | **6,206,800** | **25.80%** | **62,068** |

- find 每节点约 4–5 条指令（`lw 0(a5)`、`lw 4(a5)`、`lh 2(t0)`、`bne`），reverse 每节点 5 条（`lw next`、`sw prev`、`mv`、`bnez`）。
- 每 iteration：find 约 6,900 个节点步、reverse 6,120 个节点步；共约 13,000 个串行节点步。
- 链表 31 个节点 × 20 B = 620 B，完全在 L1D 里；**miss 不是问题，3-load 串行链才是**。

#### 4.1.2 方案 A：链表遍历/反转引擎（list walker/reverser）

**做什么**

- 在 LSU/L1D 旁挂一个 **list engine**，带 32–64 项 node cache（tag=节点地址，data={next, info, idx, data16}）和一个反向指针写回单元。
- 新命令（custom-1 或 MMIO doorbell）：
  - `LIST_FIND(head, key, mode)`：沿 `next` 走，读 `info->idx`（或 `info->data16` 字节），比较，返回匹配节点指针 + 是否找到 + 走过节点数；1 节点/cycle（cache 命中时），或 2 节点/cycle 双端口。
  - `LIST_REVERSE(head)`：1 节点/cycle 原地反转，写回 L1D；或在引擎的数组影子表示里 O(1) 翻方向位，再批量物化。
  - 可选 `LIST_MOVE_TO_FRONT` / `LIST_REMOVE` / `LIST_MERGE_SORT`。
- **关键**：node cache 让“next → info → idx”变成一次 cache 查找，而不是 3 次 L1D 访问；数组影子让 reverse 从 30 次指针写变成方向翻转/批量写。

**为什么能大幅提升**

- find 从每节点约 4–5 条指令、3 次串行 load，变成 1 次 node-cache 查找；按 1 节点/cycle，30 节点 ≈ 30 cycle，而当前约 150–250 cycle。
- reverse 从 30×5 条指令、30 次 store，变成 30 cycle（或 O(1)）；当前约 150 cycle。
- 204 次 find + 204 次 reverse/iteration，理论可省 **100k–130k cycles/iteration**（27%–35% 总周期），整体 **1.4–1.6×**。

**怎么接**

- 最紧耦合：给 `dcache_top` 增加第三个只读/只写 owner（在 `lq_lookup`、`probe` 之后最低优先级），引擎直接读写 L1D 阵列；核心在等命令结果时不会与 LSU 争端口。需要处理 tag 比较、store forwarding、dirty line、MSHR；建议只对已命中、非 MMIO、非 outstanding-miss 的地址放行，miss 时回退到核心/正常 LQ 路径。
- 次选：引擎做 L2 DMA master，命令前后用 `CBO.CLEAN`/`CBO.INVAL` 对 620 B（约 5 条 128 B line）做 cache maintenance；200 次/iteration × 2 × 5 line ≈ 2,000 次 line 操作，约 10k cycles/iteration，仍可接受。
- 最省事但收益打折：把 620 B 复制到引擎本地 SRAM，调用前后各复制一次；200 次/iteration 约 20k–30k cycles 复制开销，仍比 163k 小，但会吃掉一部分收益。

三种接法的对比：

| 接法 | 单次延迟 | 一致性 | 最适合 | 主要成本 |
|---|---|---|---|---|
| **L1D 第三 owner** | 最低（1–3 cycle/word） | 天然一致（与核心共用 L1D） | list（200 次/iter） | DCache 读/写端口、tag/forwarding 仲裁、时序 |
| **L2 DMA + CBO** | 中（~10–20 cycle/word + clean/inval） | 需要 `CBO.CLEAN`/`CBO.INVAL` + `FENCE` | state/matrix（4 次/iter） | 一致性协议、cache maintenance 指令 |
| **本地 SRAM + 复制** | 低（引擎内），但每次有复制 | 复制前后一致 | state/matrix；list 复制太频繁 | 复制带宽/启动开销 |

```
        ┌──────────────┐
        │  CPU core    │
        │  LSU / LQ    │
        └──────┬───────┘
               │
        ┌──────▼───────┐        ┌────────────────────┐
        │   L1D 8 KiB  │◄──────►│ list/state/matrix  │  ← 方案 1：第三 owner
        │  2-way       │        │ engine + local SRAM│
        └──────┬───────┘        └─────────┬──────────┘
               │                          │
        ┌──────▼───────┐        ┌─────────▼──────────┐
        │  shared L2   │◄──────►│ DMA master (128b)  │  ← 方案 2：L2 DMA + CBO
        │  32 KiB      │        └────────────────────┘
        └──────────────┘
```

**风险**

- 语义必须精确：find 的比较对象（idx vs data16）、move-to-front、remove/undo、reverse 后的 head 指针、两次 sort 的顺序；任何偏差都会让 9 项 CRC 失败。
- 与核心的 store 顺序：引擎看到的 L1D 必须是程序顺序的最新值；建议命令前插入 `FENCE`/LSU drain，或只在 LSU idle 时启动。
- Fmax：第三个 DCache 端口会增加 mux/时序压力；把引擎端口流水化（地址→读→返回 3 级），不要插进核心 load-to-use 关键路径。

#### 4.1.3 方案 B：软件/编译器的数组影子（零 RTL，先做）

如果暂时不想动 RTL，可以用和 CRC 相同的符号插入思路，替换 `core_bench_list`（或 `core_list_find`/`core_list_reverse`）：

- 在替换 TU 里维护 `node_ptr[32]` 的数组影子，顺序与链表一致；find 变成 31 个**独立** load + 比较（编译器可 4-way 展开），不再是 3-load 串行链；reverse 变成数组反转 + 批量重建 next；sort 可以用数组排序。
- 因为 `core_list_join.c` 不改，仍然用 `-Dcore_bench_list=core_bench_list_orig` 只重命名定义，新增 TU 提供同名符号；调用方 `core_main.c` 不变。
- 关键洞察：**链表只在 `core_bench_list` 内部被访问**（`core_list_init` 之后），所以替换函数可以完全用自己的数组表示，只要每个 iteration 结束时把 data16/顺序恢复到算法期望的状态，外部看不到区别。
- **已实现并实测**（见 [CoreMark 数组化实现](coremark_array_list.md)）：list 163k → 102.7k cycles/iteration（1.59×），整体 **1.198×**（100-iter 3.3756/6.7512 CM/MHz），不是最初估计的 1.3–1.5×。原因是数组移动/物化增加了 store/LSU 与 ICache 压力。它仍是最低成本的第一步，并为 list engine 提供黄金模型。

#### 4.1.4 方案 C：链表排序引擎

- 31 个节点的 mergesort 本身只占 4.6% 指令，但 `cmp_complex` 会触发 matrix/state 调用；这些调用已经由 matrix/state 引擎分别加速。**不建议先做排序引擎**，先把 find/reverse 做掉；排序留在核心，等 list 引擎稳定后再评估。

---

### 4.2 状态机：24.8% 周期，27.8% 指令

#### 4.2.1 代码事实

`core_bench_state` 每个 iteration 调用 4 次，每次：

- 扫描 666 B 的 token 流两遍（`while (*p!=0)`），每遇到 ',' 结束一个 token；
- 两遍之间按 `step=dtype`（0x22..0xff）做 corruption：`*p ^= seed1`；扫描后再按 `seed2` 做 undo（seed1==seed2，所以完全复原）；
- 最后对 8 个 `final_counts` + 8 个 `track_counts` 做 16 次 `crcu32`。

数据：

- 1,024 次 `core_state_transition`/iteration；每次 65.4 条指令；平均 5.2 B/token；
- 5,328 B 扫描/iteration（4 次 × 2 遍 × 666 B）；12.6 条指令/B；
- `core_state_transition` 是一个 8 状态 Moore 机（START/INVALID/S1/S2/INT/FLOAT/EXPONENT/SCIENTIFIC），每个 byte 做 digit/'.'/'E'/'+'/'-'/','/NUL 分类 + 分支 + 8 个 count 数组的 load/store；
- GCC 已经把 switch 按初始状态特化、循环展开；继续用编译器抠只能到 ~8–10 条指令/B。

#### 4.2.2 方案：DFA / token-scan 引擎

**做什么**

- 一个 byte-stream scanner，带：
  - 666 B 本地 SRAM（或 L1D 读端口）；
  - 8 状态 FSM + 8 个 32-bit transition counters；
  - 4 B/cycle 的并行 byte 分类器（4 个 digit/delimiter 比较器），或 1 B/cycle 的低成本版；
  - `SCAN(base, len, counts)`：从 base 扫到 NUL/','，更新 counts，返回结束指针、最终 state；
  - `XOR_RANGE(base, len, step, key)`：corruption/undo，1–4 B/cycle；
  - 可选 `CRC_COUNTS(counts)`：16 次 crcu32 直接在引擎里做，返回最终 crc。
- 命令粒度：一次 `core_bench_state` 调用 = `XOR_RANGE` + 2×`SCAN` + `XOR_RANGE` + `CRC_COUNTS`；4 次/iteration，setup 完全摊薄。

**收益**

- 1 B/cycle：5,328 B 扫描 ≈ 5,328 cycles + corruption ≈ 600 cycles + 16 CRC ≈ 100 cycles ≈ 6k cycles/iteration；当前 state+bench = 105.6k cycles → 理论省 ~99k（27% 总周期），整体 **1.35–1.4×**。
- 4 B/cycle：扫描 ≈ 1,332 cycles，总 ~2k cycles/iteration，省 ~103k。
- 若把 16 次 crcu32 也放进引擎，核心只剩 4 次调用开销。

**怎么接**

- 4 次/iteration，可以直接用 MMIO/DMA + 本地 SRAM：把 666 B 复制进引擎（~42 cycles），扫完写回；不需要 tight coupling，也不需要每 find 都同步。这是三个引擎里**最容易落地**的。
- 若不想做 DMA，也可以做 custom-1 指令 `DFA_SCAN`，让引擎通过 L1D 读端口逐字节读；但 666 B × 4 次/iteration 的端口占用很小，DMA 更简单。

**风险**

- 必须精确复现 8 个状态的转移和 count 更新（包括 INVALID 早停、',' 结束、NUL 结束、token 末尾指针）。
- corruption 的 step/seed 顺序：先扫第一遍，再 corruption，再扫第二遍，再 undo；引擎命令序列要严格一致。
- 与 `crcu32` 的端序/符号扩展：CoreMark 的 `crcu32(ee_u32)` 是两次 `crc16`，注意 16-bit 分段。

---

### 4.3 矩阵：20.7% 周期，32.0% 指令

#### 4.3.1 代码事实

`matrix_test` 每个 iteration 调用 4 次，每次：

- `matrix_add_const`：81 个 s16 加；
- `matrix_mul_const`：81 个 s16×s16；
- `matrix_mul_vect`：81 个 MAC；
- `matrix_mul_matrix`：9×9×9 = 729 个 MAC；
- `matrix_mul_matrix_bitextract`：729 个 MAC，每个额外做位提取 + 再乘一次（共 2,349 条 MUL/call）；
- 4 次 `matrix_sum`（每次 81 个 lw + 累加/比较/分支）+ 4 次 `crc16`。

数据：

- 2,349 条 MUL/call，9,396 条 MUL/iteration；19,214 条指令/call；
- A/B 各 81 个 s16 = 162 B，C 81 个 s32 = 324 B；每次调用 648 B；
- 矩阵数据也完全在 L1D；L1D miss 约 0；
- 矩阵阶段 CPI 0.96，IPC 已经 >1；瓶颈是指令量（每条 MAC 约 7–8 条指令）和单 load 端口，不是 cache。

#### 4.3.2 方案：9×9 INT16 MAC 引擎（或 9-PE 行引擎）

**做什么**

- 本地 A/B/C SRAM（162+162+324 B）+ 一个 9×9 INT16 脉动阵列（81 个 16×16→32 MAC，9 cycle 算完一个 9×9×9 matmul），或面积更小的 9-PE 行引擎（9 MAC/cycle，81 cycle/matmul）。
- 附带：
  - `matrix_add_const` / `mul_const` / `mul_vect` 的标量/向量通路；
  - `matrix_sum` 的 81 元素 reduction + clip/prev 比较（注意 `tmp>clipval` 和 `cur>prev` 的精确语义）；
  - 4 次 `crc16`（或返回 4 个 sum 让核心做，很便宜）；
  - `bit_extract` 的移位/掩码。
- 命令 `MATRIX_TEST(A,B,C,val)`：一次调用完成 5 个 pass + 4 个 sum + crc，返回 crc。

**收益**

- 9×9 阵列：1,620 个 MAC（不含 bitextract 的额外乘）≈ 20 cycle；bitextract 的额外乘再 ~9 cycle；sum ~36 cycle；copy 648 B ≈ 41 cycle；总 **~150–300 cycles/call**。4 次/iteration ≈ 1k cycles，对比当前 73.6k，理论省 **~72k cycles（20% 总周期）**，整体 **1.2–1.25×**。
- 9-PE 行引擎：81 cycle/matmul × 2 + 其它 ≈ 500–800 cycles/call，4 次 ≈ 3k cycles，仍省 ~70k；面积小很多，推荐先用 9-PE。

**为什么不用 miniTensor**

- 现有 miniTensor 是 **4×4 INT8**、10-cycle GEMM、INT32 累加、Epilogue 量化到 INT8；CoreMark 的 `MATDAT` 是 **s16**，乘积是 32-bit，且需要精确的 16-bit 符号/范围。
- 用 INT8 分解 s16 需要 2–4 个 tile + 符号/进位处理，控制复杂度和误差风险都高；而且 miniTensor 当前不在 `ares_2core_frontend_l2_top` 里（只在 `ares_soc_top`），DMA/MMIO 路径也不适合 4 次/iteration 的小矩阵。
- 结论：**新做一个 9-PE INT16 引擎比改 miniTensor 更省事**；如果未来要做通用 AI 加速，再把 INT16 通路并进 miniTensor。

**风险**

- `matrix_sum` 的 `tmp` 是 32-bit、`clipval=0xf000|val`，`tmp>clipval` 时 `ret+=10, tmp=0`，否则 `ret += (cur>prev)`；这些细节必须 bit-exact，否则 crcmatrix 校验失败。
- `matrix_mul_matrix_bitextract` 的位提取顺序（`bit_extract(x,from,to)`）和第二次乘的符号扩展。
- A 在 `add_const(+val)` 后要 `add_const(-val)` 复原；引擎必须保证 A 的最终值与进入时一致。

---

### 4.4 CRC：已经做完，边际收益很小

- CRC 组从 19.02% 降到 1.23%；100-iter 只剩 58,408 条 custom CRC8 + 296,044 条 crc16/crcu32/crcu16 调用开销。
- 还能做的：
  - `CRC16`/`CRC32` 自定义指令，把 `crc16/crcu32` 的调用/移位开销也消掉；
  - 把 `core_bench_state` 的 16 次 `crcu32` 并进 state 引擎。
- 预期：整体 **1.01–1.02×**；优先级最低。

---

### 4.5 核内微架构：补充项，不是主战场

| 技术 | 现状/实测 | 预期 | 备注 |
|---|---|---|---|
| 2-cycle load-use / speculative probe | 已实现；CRC+O3 4-iter 1.574M→1.464M（约 1.076×） | 已计入基线 | 继续优化 probe 的 hit rate（当前 `sq_empty/wb_empty` gate 太保守） |
| ALU 同周期 bypass | 未做 | 1.03–1.08× | dep_alu 48k cycles/iter（13.1%），一半可消 |
| load-slip / ready-based issue | 4-candidate ALU skip-head 实测 **1.001×**（已删） | 1.00–1.05× | 链表里没有可绕过的 younger ready 工作；不要期待 1.5× |
| 完整 OoO（大窗口 + 分支投机） | 未做 | 1.05–1.15×（上限 1.25×） | 主要帮 matrix/state；链表仍是串行链，收益有限；Fmax/验证风险高 |
| 双 load port / banked L1D | 未做 | 1.02–1.05× 单独 | matrix 的 LSU/port 6.9k cycles/iter（1.9%）；OoO 后才会更重要 |
| LQ 加深（4→8/16） | 未做 | 1.00–1.02× | 最新 LSU credit 约 2.0%、port 0.1%，其中 matrix 占约 6.9k cycles/iter；矩阵/状态机可能有帮助 |
| 4-wide commit / 3-wide decode | 未做 | 当前不需要 | commit 平均 0.66，2-wide commit 不是瓶颈；IPC>1.5 后再考虑 |
| 更大 TAGE / 更好方向预测 | 已够用 | ~1.00× | 后端 redirect 约 0.2%/cycle；不要先做 |
| 16 KiB→32 KiB ICache | 已做 | 已计入基线 | O3 text 16,980 B；8 KiB 会严重冲突 |
| loop buffer / trace cache | 未做 | 1.01–1.03× | 最新 IQ 空约 2.8%；OoO 后才可能有用 |
| Zbb/Zbs（clz/ctz/rev8/rol） | 未做 | 1.01–1.03× | 对 CRC/状态机的 ALU 指令有小幅帮助；需编译器支持 |
| C 扩展（压缩指令） | 未做 | 1.02–1.05× | 减代码体积/取指带宽，不减动态指令数；当前 spec 无 C |

**结论**：如果只做核内微架构，现实预期是 **1.15–1.3×**（2-cycle load 已拿到 1.08×，再加 ALU bypass/少量 OoO），而不是 1.5–1.8×。**要大幅提分，必须把三个串行热点做成块级引擎，或用软件数组化打破依赖链。**

---

### 4.6 编译器/链接层能做什么（零 RTL 或低 RTL）

1. **符号插入替换热点函数**（和 CRC 一样的套路）：
   - `core_bench_list`：数组影子/引擎驱动；
   - `core_bench_state`：表驱动 DFA 或 scanner 驱动；
   - `matrix_test`：矩阵引擎驱动。
   - 只重命名原 TU 里的定义（`-Dcore_bench_list=core_bench_list_orig` 只加在 `core_list_join.c`），调用方不变；原 `core_*.c` 一个字节不改。
2. **数组化链表**：见 4.1.3；预计 1.3–1.5×，是零 RTL 的最高 ROI。
3. **表驱动 DFA**：把 8 状态 switch 换成 `next_state[state][byte_class]` + `count_inc[state]`；无分支、每 byte 5–6 条指令；预计 state 1.3–1.6×（整体 1.1–1.2×），但每 byte 仍有一次 L1D load，不如硬件 scanner。
4. **矩阵循环重排/分块**：9×9 太小，编译器能做的有限；`-O3 -funroll-loops` 已经做了。可以试 `-fno-tree-vectorize`（RV32 无 SIMD，没意义）、`-flto`、`-fprofile-use`；预期 <5%。
5. **自定义指令**：packed 16-bit MAC（`dp16`/双 MAC）可以把矩阵内层 2 个 MAC/指令，减少 ~30–40% 矩阵指令，整体 1.05–1.1×；比矩阵引擎省 area，但收益小。
6. **PGO/LTO**：减少调用/分支，预计 1–3%；会增大代码，和 32 KiB ICache 一起评估。
7. **不要做的**：改 `core_util.c` 里的 CRC、改 benchmark core 的算法（这已经越过“软件/编译器”边界）；如果只做符号插入/新 TU，仍然保持“源文件不改”。

---

### 4.7 SoC 级：双核/多核与共享引擎

1. **4 hart + 更大 L2**：当前 L2 冷启动后接近 0（4-iter 平均约 0.0014 访问/cycle），端口/带宽远未饱和；4 个 AMP 实例的聚合分数 ≈ 2× 双核（线性 scaling 已验证）。代价是 L1I/L1D 面积、L2 端口/容量（建议 64–128 KiB、8 bank、MSHR/WBQ/QoS）、验证。**这是不改单核 IPC 就能翻倍聚合分数的唯一办法。**
2. **共享加速器 + 双 context**：两个 hart 的指令流逐条相同（retire 完全相同，数据地址差 1 MiB，数据内容也相同），所以两个 hart 会在几 cycle 内发出相同的引擎命令。一个引擎如果吞吐 >2× 核心需求，可以用 2 个 context 时分复用；list 引擎在 2 hart 下需要 ~2× 吞吐，建议直接做双 context 或 2 实例。
3. **lockstep 双 lane / 共享前端**：两 hart 代码/数据完全相同，可以共享一个前端（fetch/decode/BPU/ICache）驱动两个后端，节省面积/功耗；但**不降低单 hart 周期**，对分数只有“省面积换更多 lane”的间接收益。若目标是聚合分数且面积不是约束，4 个独立 hart 更简单。
4. **Fmax**：当前 FPGA 250 MHz 目标未收敛（历史 WNS −9.888 ns，板级 −35.6 ns）。加速器应放在核心关键路径之外、接口流水化；评估 **IPC × Fmax**，不要只看 CM/MHz。一个 20% Fmax 损失会吃掉 20% 的 IPC 收益。

---

## 5. 组合收益估算（Amdahl，基于实测相位）

基线：**354,937 cycles/iteration**（100-iter 实测；单核 2.8174、双核聚合 5.6348 CM/MHz）。
下表“省 cycles”按“该相位周期 × 加速器消除比例”估算；未计新瓶颈/面积/Fmax。

| 场景 | 假设 | 省 cycles/iter | 新 cycles/iter | 加速比 | 单核 CM/MHz | 双核聚合 |
|---|---|---:|---:|---:|---:|---:|
| 仅 ALU bypass | 消 50% dep_alu | 23,600 | 331,337 | 1.07× | 3.02 | 6.03 |
| 仅 2-cycle load（已做） | 已计入基线；无 probe 的 100-iter 为 2.6132 | — | 354,937 | 1.00×（基线） | 2.82 | 5.63 |
| 仅 load-slip/OoO | 1.00–1.15× | 0–46,300 | 308.6k–354.9k | 1.00–1.15× | 2.82–3.24 | 5.63–6.48 |
| **链表引擎（find+reverse）** | 消 75% list | 122,220 | 232,717 | **1.53×** | **4.30** | **8.59** |
| 链表数组化（软件，已实现） | 实测 100-iter | 60,300 | 294,655 | **1.198×** | **3.376** | **6.751** |
| **状态机 scanner** | 消 90% state+bench | 94,887 | 260,050 | **1.37×** | **3.85** | **7.69** |
| **矩阵引擎** | 消 90% matrix | 66,162 | 288,775 | **1.23×** | **3.46** | **6.92** |
| 链表+状态机 | 上面两项相加 | 217,107 | 137,830 | **2.57×** | **7.25** | **14.51** |
| 链表+状态机+矩阵 | 三项相加（上限） | 283,269 | 71,668 | **4.95×** | **13.95** | **27.90** |
| 三项 + 25% 引擎开销 | 现实折损 | — | ~142,500 | **2.49×** | **7.02** | **14.04** |
| 三项 + 25% 开销 + 核内 1.15× | 叠加 | — | ~123,900 | **2.86×** | **8.06** | **16.12** |
| 4 hart（在任一行上） | 聚合 ×2 | — | — | ×2 | — | **×2** |

**建议对外表述**：

- **只做链表**：1.4–1.5×（单核 3.9–4.3，双核 7.8–8.6）。
- **链表 + 状态机**：2.4–2.6×（单核 6.8–7.3，双核 13.5–14.5）。
- **三项都做 + 核内微调**：2.5–3.0×（单核 7.0–8.5，双核 14.0–17.0）。
- **再加 4 hart**：双核聚合再 ×2（14–17 → 28–34），但这是“聚合分数”，不是单核 IPC。
- **上限 4.95×** 是“引擎零开销”的理论值；实际会被命令队列、cache maintenance、双 hart 竞争、Fmax 吃掉 20–40%。

---

## 6. 如果只关心数字：迭代同构与极端方案

### 6.1 实测：100 次 iteration 的数据完全复原

在 ISS 里对每次 `core_bench_list` 入口计算 2,000 B 工作集的 FNV hash：

```
BENCHLIST_CALL 2  insns=215378  hash=f3debab52606a985
BENCHLIST_CALL 3  insns=252315  hash=f3debab52606a985
BENCHLIST_CALL 4  insns=455836  hash=f3debab52606a985
...
BENCHLIST_CALL 200 ...          hash=f3debab52606a985
```

从第 2 次调用到第 200 次，**工作集 hash 完全相同**；每次调用/每 iteration 的指令数也只在 ±66 条内波动（因为 `res->crc` 影响 `calc_func` 的低 7 位缓存值）。也就是说：

- list 在每个 `core_bench_list` 结束时被两次 sort 复原；
- matrix A 在 `add_const(+val)` / `add_const(-val)` 后复原，B 不变，C 只是输出；
- state 在 `xor(seed1)` / `xor(seed2)` 后复原（seed1==seed2）；
- **跨 iteration 唯一活的状态是 `res->crc`（16-bit）和 iteration 0 捕获的 `crclist/crcmatrix/crcstate`**。

这意味着 CoreMark 的 100 次迭代是**同构重复**，只差一个 16-bit CRC 链。

### 6.2 极端方案

| 方案 | 做法 | 预期 | 代价/风险 |
|---|---|---|---|
| **核结果 memoization** | 第一次 iteration 后缓存 matrix_test 结果、state counts；后续只按 `res->crc` 重算 `crcu16(result,crc)` 和低 7 位缓存值、list sort | 2–3×（保留 list sort） | 仍然要跑 list；语义要精确；不是“纯硬件” |
| **迭代 replay/跳过** | 检测工作集 hash 不变，直接复用上一次 iteration 的 list/matrix/state 结果；只推进 CRC 链 | 10–50× | 需要精确建模 `res->crc` 对低 7 位缓存/list 顺序的影响；本质上不跑 benchmark |
| **专用 CoreMark 引擎** | 把 list/state/matrix 三个内核 + 100 次循环全部做进一个状态机，CPU 只启动/读结果 | 50–100×+ | 是“CoreMark ASIC”，不是 CPU；面积/验证大 |
| **答案 ROM/硬编码** | 直接把 9 项 CRC 和最终结果写死 | ∞ | 没有技术意义；分数不可比 |

**建议**：如果项目目标是“让 SoC 成为 CoreMark 跑分机器”，可以把 6.2 作为**单独的 accelerated variant**，明确标注“不是处理器 CoreMark”；主线仍应按第 4/5 节的真实加速器路线走。否则一旦评审问“这是 CPU 跑出来的吗”，答案会很难看。

---

## 7. 建议路线图

| 阶段 | 改动 | 预期（单核） | 工作量/风险 |
|---|---|---|---|
| **P0** | 固化基线：100-iter 最新分数、相位计数器、ISS 黄金流；把 `tb_phase` 纳入分析脚本 | — | 低 |
| **P0.5** | 软件数组化 `core_bench_list`（符号插入，无 RTL）；表驱动 DFA 原型 | **已做：1.198× 整体** | 已完成；主机等价 200/200 + 4/100-iter RTL |
| **P1** | 链表 find/reverse 引擎（L1D 端口或 L2 DMA + CBO）；先做 find，后做 reverse | 1.3–1.5× | 中高；端口/一致性/验证 |
| **P1** | 状态机 token scanner + corruption/CRC（MMIO/DMA + 666 B SRAM） | 再 1.3–1.4× | 中；状态机 bit-exact |
| **P2** | 9-PE INT16 矩阵引擎（或 9×9 阵列）+ matrix_sum/CRC | 再 1.2–1.25× | 中高；面积/时序 |
| **P2** | 核内：ALU bypass、probe 放宽、LQ 加深；视情况做小 OoO/双 load port | 再 1.05–1.15× | 中；Fmax |
| **P3** | 4 hart + 64–128 KiB L2；共享引擎双 context | 聚合 ×2 | 高；L2/互连/验证 |
| **P3** | 4-wide commit/3-wide decode、loop buffer、Zbb/Zbs | 再 1.05–1.1× | 中 |
| **可选** | 迭代 memoization / CoreMark 引擎 | 10–100× | 仅作为 accelerated variant，明确标注 |

**推荐顺序**：先做 P0.5 的软件数组化（一周内可验证 1.3–1.5× 的 list 收益，且不冒 RTL 风险），同时做 P1 状态机 scanner（4 次/iteration、DMA 简单、收益大）；链表引擎和矩阵引擎并行立项。核内 OoO 放到最后，因为它对 list 的收益已经被 1.001× 的 skip-head 实测否定。

---

## 8. 验证、合规与 PPA

### 8.1 功能验证

- 每次改动都必须过 `make unit-2core-coremark DMEM=...` 的 9 项检查 + L2 shadow（`err_i0/i1/c0/c1/wb=0`）。
- 加速器黄金模型：
  - list engine vs C 模型：随机 31 节点、随机 find key、随机 reverse/remove/sort 序列；
  - state scanner vs `core_state_transition`：666 B 随机 token 流、所有 8 状态、NUL/',' 边界；
  - matrix engine vs `matrix_test`：随机 9×9 s16 A/B、随机 val，逐 bit 比较 4 个 sum/crc。
- 一致性：DMA 引擎必须在命令前后做 `FENCE`/CBO clean/invalidate；L1D 端口的引擎必须处理 store forwarding、dirty line、outstanding miss、MMIO 旁路。
- 双 hart：共享引擎要有 2 个 context 或 2 实例；验证两 hart 同时发命令、结果不串扰。
- 回归：`make unit`、`make unit-lsu`、`make lint-lsu`、`make lint-l2`、ISA 36/36。

### 8.2 合规（如果以后需要官方分数）

- CoreMark 只允许改 `core_portme.h/.c`；`core_*.c` 是 benchmark core。
- 仓库 `tests/benchmarks/coremark/NOTICE.md` 已写明：custom-CRC/RTOS 加速变体不在范围内，不能和官方数字比较。
- 本文的 list/state/matrix 引擎、数组化、memoization 都属于 **accelerated variant**；如果对外展示，必须标注“modified/accelerated，不是 EEMBC 可比较分数”。

### 8.3 PPA

- 当前 FPGA（xc7k325t）250 MHz 目标未收敛；历史 WNS −9.888 ns（OOC）/ −35.6 ns（板级）。CM/MHz 是架构指标，板级分数 = CM/MHz × Fmax。
- 加速器应：
  - 接口流水化（地址→SRAM→数据 3 级），不插进核心 load-to-use 路径；
  - 矩阵 MAC 阵列流水化，DSP48 映射；
  - 引擎时钟使能/独立 clock domain（如果工具允许），避免拖慢核心；
  - 评估 IPC×Fmax，而不是只看 IPC。
- 面积粗估：list engine 5–10k gates + 0.5–1 KB SRAM；state scanner 3–5k gates + 0.7 KB SRAM；9-PE INT16 矩阵引擎 ~20–30k gates + 1 KB SRAM（9×9 全阵列 ~81 DSP/120k gates，按面积选 9-PE）。

---

## 9. 复现与原始数据

### 9.1 最新镜像与构建

```bash
# CRC + O3 + 32 KiB ICache 镜像
python3 scripts/build_coremark_crc.py --out build/coremark_crc --jobs 4
# O3/unroll 版本：build/coremark_crc_o3/coremark_dmem.hex（100 iter）
# 4-iter 诊断镜像：build/analysis/coremark_crc_o3_4iter.hex
```

### 9.2 相位归因

```bash
# 构建（32 KiB ICache + tb_phase；基于 perf_cmd32.sh）
cd build/analysis
bash phase_cmd.sh
# 4-iter 稳态
./verilator_phase/tb_phase +DMEM=coremark_crc_o3_4iter.hex > phase_4iter.out 2>&1
# 100-iter 最终
./verilator_phase/tb_phase +DMEM=../coremark_crc_o3/coremark_dmem.hex > phase_100iter.out 2>&1
```

### 9.3 ISS 指令流

```bash
cd build/analysis
g++ -O2 -std=c++17 -o iss_ranges iss.cpp
./iss_ranges ../coremark_crc_o3/coremark-riscv32-ares.elf > iss_ranges.out
# 关注：TOTAL_INSNS / CLASSES / FUNCTIONS / MIX / RANGES / CALLS / TOP_BLOCKS
```

### 9.4 最新 100-iter 结果（`phase_100iter.out`）

```
hart0: retires=24055220 cycles=35493729 IPC=0.677732 CM/MHz=2.8174
hart1: retires=24055220 cycles=35493014 IPC=0.677745 CM/MHz=2.8175
aggregate: retires=48110440 max_cycles=35493729 IPC=1.355463 CM/MHz=5.6348
L2: hits=1723 misses=325
PERF cycles=35493729 noissue=22073834 (62.2%) dep=20932228 dep_load=16212653 dep_alu=4719575 lsu=732727 port=13164
PHASE no-issue 占比：list 32.8% matrix 8.9% state 15.4% bench_state 2.7% crc 0.6% other 1.8%
```

按相位总周期（no-issue + issue）折算：

| 相位 | cycles/iter | %cycles |
|---|---:|---:|
| list | 162,960 | 45.9% |
| state | 87,932 | 24.8% |
| matrix | 73,513 | 20.7% |
| bench_state | 17,498 | 4.9% |
| crc | 4,178 | 1.2% |
| other | 8,856 | 2.5% |
| **total** | **354,937** | 100% |

### 9.5 原始文件

| 文件 | 内容 |
|---|---|
| `build/analysis/phase_4iter.out` | 4-iter 相位归因（PHASE 0..5） |
| `build/analysis/phase_100iter.out` | 100-iter 最终分数/相位 |
| `build/analysis/tb_phase.sv` | 相位归因 TB |
| `build/analysis/iss.cpp` / `iss_ranges.out` | 最新 ISS 指令流/调用/区间（`iss.cpp` 增加了 RANGES/CALLS） |
| `build/analysis/iss_trace.out` | 每次 `core_bench_list` 入口的 2 KB 工作集 hash（§6.1 迭代同构证据） |
| `build/analysis/dis_list.txt` | `core_bench_list` 反汇编 |
| `build/analysis/dis_state.txt` | `core_state_transition` 反汇编 |
| `build/analysis/dis_matrix.txt` | `matrix_test` 反汇编 |
| `build/analysis/coremark_stream_analysis.md` | 旧版（CRC 前）分析 |
| `build/analysis/crc_acceleration_report.md` | CRC 加速记录 |
| `build/analysis/speculative_load_probe_report.md` | probe 记录 |

### 9.6 一句话总结

**最新双核 CoreMark 的指令流已经从“CRC 位循环”变成“链表指针追逐 + 状态机字节扫描 + 9×9 矩阵 MAC”三足鼎立；按周期，链表 45.9%、状态机 24.8%、矩阵 20.7%。要大幅提分，优先做链表 find/reverse 引擎和状态机 token scanner，其次矩阵 INT16 引擎；核内 OoO/load-slip 只能补 1.05–1.15×，不是主战场。**
