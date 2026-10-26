# ARES 2-core shared-L2 / CoreMark handoff

## TL;DR

**双核 AMP CoreMark 已通过。** 两个 hart 各跑一份独立 CoreMark（100 iter），各自使用真实前端 + 私有 L1D，共享同一个 L2；per-hart 与聚合指标都正常输出。

~~~text
ALL TESTS PASSED: 8 checks - 2 harts + shared L2, two CoreMark instances
L2 shadow check: rsp=21981 err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0
hart0: retires=31348582 cycles=50028073 IPC=0.626620 CM/MHz=1.9989
hart1: retires=31348582 cycles=50028076 IPC=0.626620 CM/MHz=1.9989
aggregate: retires=62697164 max_cycles=50028076 IPC=1.253240 CM/MHz=3.9978
L2: hits=21771 misses=210
~~~

之前记录的 "44.7 ms 被共享 L2 数据破坏卡住" **不是数据通路 bug**，而是仿真断言在**投机路径**上误报。根因与修复见 docs/coremark_dual_bug_report.md。

## 1. 目标

短期目标（已完成）：

- 两个 hart 各跑一份普通单线程 CoreMark（AMP，两份独立实例）
- 代码共享，hart1 数据/栈使用独立地址区
- 共享同一个 L2
- 输出 per-hart retires/cycles/IPC 和聚合 CoreMark/MHz
- 不要求官方 MULTITHREAD=2 分数

长期目标（不属于当前阶段）：

- 2-core SoC：CLINT/PLIC/Mailbox/MMIO xbar/Boot ROM/SPM
- 最终 L2：128 KiB、8 bank x 128-bit、MSHR/writeback queue/QoS/video port
- SMP：A 扩展、L2 directory/snoop、IPI、SMP OS，另行立项

## 2. 仓库状态

分支：l2-cache

链路：

~~~text
rtl/frontend (BPU/FTQ/IFU/ICache/IQ)
  -> fe_legacy_adapter
  -> ares_core_top
  -> l2_top (I/D)
~~~

## 3. 已完成并验证

### 3.1 单核真实前端 CoreMark：通过

~~~bash
make unit-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

~~~text
ALL TESTS PASSED: 2 checks - ARES real FE + shared L2 CoreMark
CoreMark metrics: retires=31348582 cycles=49944724 IPC=0.627666
                  CoreMark/MHz=2.0022 time_ns=499447286 hits=10133 misses=165
~~~

> 注意：旧文档里的 `retires=21,229,636 / IPC=0.425063` 是测试平台把
> 每拍 2 条退休记成 1 条造成的低估；CoreMark/MHz 只依赖 cycles，所以
> 2.0022 不变。计数器已在 `tb_ares_coremark` / `tb_2core_coremark` 修正。

### 3.2 双核 AMP CoreMark：通过

~~~bash
make unit-2core-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

两个 hart 同镜像、同代码地址（0x8000_0000），hart1 数据/栈偏移
`C1_DATA_OFFSET = 0x0010_0000`（0x8020_0000 起）。结果见 TL;DR。
约 500k 周期、Verilator 墙上时间 10-20 分钟。

`+H1EN=0` 可用**同一个二进制**得到单 hart 参考运行（hart1 保持复位），
用于 lockstep 对比。

### 3.3 前端适配器

rtl/frontend/fe_legacy_adapter.sv

- 旧 iq_rvalid/iq_rbits/iq_raccept_cnt -> 新 iq_valid/iq_inst/iq_accept_count
- IQ/redirect 组合直连，零额外取指周期
- BPU update 4-entry FIFO，2 push / 1 pop，不丢训练事件
- 前端 RTL 本体未改

### 3.4 AXI -> L2 I 桥

rtl/frontend/interface/axi_l2_bridge.sv

- ICache AXI4-Lite 32-bit read -> L2 128-bit I beat
- 16 B beat buffer，连续 4 个 word 命中同一 beat
- 只读；AXI 写通道 tie off

### 3.5 共享 L2

rtl/l2/l2_top.sv（32 KiB bring-up 版，顶层可参数化到 128 KiB）

- 4-way、64 B line、write-back + write-allocate
- 两个 D 端口：c0/c1
- 两个 I 端口：i0/i1
- 一个 128-bit memory port
- round-robin replacement
- 一次只服务一个 L2 transaction（无 per-port MSHR）
- L2 单元测试 17 checks：hit/miss、clean refill、dirty writeback、byte enable、
  双端口并发、c1 驱逐 c0 dirty 行

双核 CoreMark 现在额外带一个 **L2 shadow 检查器**（`tb_2core_coremark`）：
以镜像初始内容 + 所有被 L2 接受的 store 建立影子内存，逐拍比对 i0/i1/c0/c1
的每个读响应和每个 dirty writeback beat。任何共享 L2 数据破坏都会被直接
抓到，而不是等到下游崩掉再反推。

### 3.6 双核硬件拓扑

rtl/top/ares_frontend_hart.sv
rtl/top/ares_2core_frontend_l2_top.sv

- 两个 hart，每个包含 real frontend + adapter + AXI bridge + core
- hart0：D -> L2 c0，I -> L2 i0，DATA_OFFSET=0
- hart1：D -> L2 c1，I -> L2 i1，DATA_OFFSET=0x0010_0000
- `hart1_en`（运行时输入，与 `HART1_ENABLE` 相与）用于单 hart 参考运行
- MMIO 仍是 stub，CoreMark 不使用

### 3.7 性能现状（属正常区间；**不要拿 Mundus/NPC 核的 IPC 当基线**）

| 指标 | 值 |
|---|---|
| IPC（单核 / 每 hart） | 0.628 |
| CPI | 1.593 |
| 每周期退休 0 条的周期 | 28,715,088 / 49,944,724 = 57.5% |
| 每周期退休 1 条 | 11,110,690 = 22.2% |
| 每周期退休 2 条 | 10,118,946 = 20.3% |
| CoreMark/MHz | 2.0022 |

分布是精确值：旧计数器记的是"有退休的周期数" 21,229,636，新计数器记退休总数
31,348,582，两者相减即"每周期 2 条"的周期数。

**为什么 57.5% 空转是这套配置的正常表现**：这台机器的深度指标很浅——

| 结构 | 值 |
|---|---|
| 发射/提交 | 2-wide in-order |
| IQ / FTQ | 10 / 24 条 |
| LQ / SQ | **4 / 8** |
| MSHR / WB buffer | 2 / 2，且整条 L2 读通路单 outstanding |
| L1D | 8 KiB、2-way、32 B line |
| ICache | 8 KiB、32 B line、64 set、4-way |
| L2 | 32 KiB、4-way，一次只服务一笔事务 |

4 条 LQ + 单 outstanding 读 + 每次 lookup 一个事务，决定了 load 密集代码基本无法
重叠访存延迟；CoreMark 又分支/访存密集，因此 0.6 左右 IPC、2.0 CoreMark/MHz
落在"2-wide 浅队列 in-order"这类机器的常见区间（约 0.6-1.0 IPC / 1.5-3.0 CM/MHz）。

**已排除共享 L2 带宽**：整次单核运行 L2 只有 10,133 hit + 165 miss，约 0.2 次/千周期。

> 关于 0.9 IPC：该数字不是 ARES 的。它来自 `main` 分支的 **NPC/Mundus 核**
> （`npc/configs/Mundus/Kconfig`：Branch Predict → 4 个 tagged table / 历史
> 4-12-32-64 / FTQ 8 / 独立后端）。ARES 的 `rtl/frontend` 虽是同门前端，但参数与
> 后端都是另一套（TAGE 8 表、几何历史 4..233、GHV 160、IQ 10、LQ 4），两者不可
> 作为同机基线互相比较。要判断 ARES 的 IPC 好坏，只能在同一份 RTL 上做 A/B。

若要提 IPC，按预期收益排序：**LQ 4 → 8/16**、IQ 10 → 16+、FTQ 24 → 32+、
ICache 8 KiB → 16/32 KiB、fetch width 4 → 8、L1D 2-way → 4-way、L2 多 outstanding。
分支预测器（8 表 + 几何历史）已经不是短板。

## 4. 已解决的"双核失败"（简短版）

原报告：44.7 ms 时 hart0 触发 `lsu_agu.sv:188 a_natural_align`，被判断为
共享 L2 数据破坏。实际：

1. L2 shadow 检查器 21981 个响应 **零错**（i0/i1/c0/c1 + writeback）。
2. hart0 的完整退休流（PC/rd_wen/rd/wdata）与 hart1、与单 hart 参考运行
   **逐条完全一致**（到出错点的 2,768,013 条），参考运行在该点之后正常继续。
3. 52 次断言全部是同一条投机指令：`addr=0xa3, LH, load`，发生时后端
   架构下一 PC 是 `0x8000_03d8` —— 即落在预测失败的路径上，随后被 squash。

`lsu_agu` 的 `out_valid` 是投机发射级，垃圾代码可以用任意寄存器值当地址，
所以"地址不对齐"在那里不是设计属性。

### 修复

把 `SPEC-A1 / D-C0-01`（仅自然对齐）的检查移到**架构可见**的位置：

| 检查 | 位置 | 时机 |
|---|---|---|
| `a_load_natural_align` | `rtl/memory/lsu_top.sv` | 活跃 LQ 条目向 cache 发起 lookup（`lq_lookup_valid`） |
| `a_drain_mask_legal` | `rtl/memory/lsu_top.sv` | COMMITTED store drain（原有，本来就 sound） |

`lsu_agu` 里的投机断言已删除；`lq` 增加 `lookup_size` 输出让检查写在 LSU 边界。
实测：双核运行中旧 AGU 断言触发 52 次，新 load 检查触发 **0** 次。

store 侧本来安全：SQ 条目只有 COMMITTED 之后才由 `sq_drain_valid` 驱动
dcache 写通路，错误路径的 store 随条目一起被丢弃。

细节与证据见 docs/coremark_dual_bug_report.md。

## 5. 复现

生成软件 CRC、100 iter CoreMark 的 128-bit memory image：

~~~bash
export MUNDUS_HOME=/home/ccy/Documents/qs/Mundus

rm -rf /tmp/coremark_sw
cp -a $MUNDUS_HOME/am-kernels/benchmarks/coremark /tmp/coremark_sw
rm -rf /tmp/coremark_sw/build
sed -i 's/^#define ITERATIONS .*/#define ITERATIONS 100/' \
    /tmp/coremark_sw/include/core_portme.h

python3 - <<'PY'
from pathlib import Path
p = Path('/tmp/coremark_sw/src/core_main.c')
s = p.read_text()
s = s.replace('\ttotal_time=get_time();\n',
              '\ttotal_time=get_time();\n\t(void)total_time;\n', 1)
p.write_text(s)
PY

cd /tmp/coremark_sw
AM_HOME=$MUNDUS_HOME/abstract-machine \
NPC_HOME=$MUNDUS_HOME/npc NEMU_HOME=$MUNDUS_HOME/nemu \
MUNDUS_HOME=$MUNDUS_HOME \
make ARCH=riscv32-jyd CROSS_COMPILE=riscv64-unknown-elf- image

python3 - <<'PY'
from pathlib import Path
b = Path('/tmp/coremark_sw/build/coremark-riscv32-jyd.bin').read_bytes()
if len(b) % 16:
    b += b'\0' * (16 - len(b) % 16)
with open('/tmp/coremark_sw_dmem.hex', 'w') as f:
    for i in range(0, len(b), 16):
        f.write(f'{int.from_bytes(b[i:i+16], "little"):032x}\n')
PY
~~~

单核参考：

~~~bash
cd /home/ccy/Documents/qs/ARES
make unit-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

双核：

~~~bash
make unit-2core-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

两者都依赖外部软件镜像，所以不在 `make all` 里。

## 6. 下一步

已完成的部分不再重复。后续按长期目标推进：

1. 2-core SoC 化：CLINT/PLIC 已在单核 SoC 里验证过，下一步把 mailbox、
   MMIO xbar、Boot ROM、SPM 接到双核拓扑上。
2. L2 性能版：128 KiB、8 bank x 128-bit、per-port MSHR、writeback queue、
   QoS、video port。当前 bring-up L2 一次只服务一个 transaction，双核
   load 延迟会被取指抢占。
3. L1D/L2 一致性：当前是 AMP 且数据区不重叠，**没有**一致性需求；一旦要做
   SMP，需要 A 扩展 + L2 directory/snoop + IPI，另行立项。
4. 若要对外报分，先把软件镜像、编译选项、L2 配置固定下来，并明确是
   per-hart 还是聚合口径。

## 7. 关键文件

- rtl/l2/l2_top.sv
- rtl/l2/test/tb_l2.sv
- rtl/frontend/fe_legacy_adapter.sv
- rtl/frontend/interface/axi_l2_bridge.sv
- rtl/top/ares_frontend_hart.sv
- rtl/top/ares_frontend_l2_top.sv
- rtl/top/ares_2core_frontend_l2_top.sv
- rtl/top/test/tb_ares_coremark.sv
- rtl/top/test/tb_2core_coremark.sv
- rtl/memory/lsu_top.sv（a_load_natural_align / a_drain_mask_legal）
- docs/coremark_dual_bug_report.md

## 8. 约束

- 单核 CoreMark 是正确性基线，改动 L2 后先保证它仍然通过
- 双核是 AMP，不是 SMP；不要用 MULTITHREAD=2 解释任何现象
- 遇到双核"数据破坏"类症状，先确认失败访问是否**架构可见**：
  用 `+H1EN=0` 跑单 hart 参考，比较退休流，再怀疑数据通路
- 双核跑一次约 10-20 分钟 Verilator 墙上时间，不要放进快速回归
