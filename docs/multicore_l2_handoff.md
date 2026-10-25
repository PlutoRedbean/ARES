# ARES 2-core shared-L2 / CoreMark handoff

## TL;DR

单核真实前端 + 共享 L2 的 CoreMark 已经通过。双核 AMP 的前端、L2 第二 I 口、hart1 数据偏移和双实例测试都已接好，但双核 CoreMark 在约 44.7 ms 时被共享 L2 的数据破坏卡住，尚未通过。当前问题不是多核编译，而是双核共享 L2 数据通路。详细证据见 docs/coremark_dual_bug_report.md。

## 1. 目标

短期目标：

- 两个 hart 各跑一份普通单线程 CoreMark（AMP，两份独立实例）
- 代码共享，hart1 数据/栈使用独立地址区
- 共享同一个 L2
- 输出 per-hart retires/cycles/IPC 和聚合 CoreMark/MHz
- 不要求官方 MULTITHREAD=2 分数

长期目标（不属于当前 bug）：

- 2-core SoC：CLINT/PLIC/Mailbox/MMIO xbar/Boot ROM/SPM
- 最终 L2：128 KiB、8 bank x 128-bit、MSHR/writeback queue/QoS/video port
- SMP：A 扩展、L2 directory/snoop、IPI、SMP OS，另行立项

## 2. 仓库状态

分支：l2-cache

最近提交：

~~~text
55a8e25 docs: narrow the dual-core issue to I1/L1D-L2 interaction
be114d9 test(l2): cover c1 read evicting a dirty c0 line
177b68e wip(l2): two-frontend AMP topology and dual CoreMark harness
dcbcc27 feat(fe): run CoreMark on real frontend and shared L2
c18639f feat(fe): add legacy frontend to backend contract adapter
392e5bc feat(l2): add shared two-port L2 and two-hart bring-up top
~~~

远程：git@github.com:PlutoRedbean/ARES.git

## 3. 已完成并验证

### 3.1 单核真实前端 CoreMark：通过

~~~text
ALL TESTS PASSED: 2 checks - ARES real FE + shared L2 CoreMark
retires=21,229,636
cycles=49,944,724
IPC=0.425063
CoreMark/MHz=2.0022
time=499,447,286 ns
L2 hits=10,133 misses=165
a0=0
~~~

链路：

~~~text
rtl/frontend (BPU/FTQ/IFU/ICache/IQ)
  -> fe_legacy_adapter
  -> ares_core_top
  -> l2_top (I/D)
~~~

### 3.2 前端适配器

rtl/frontend/fe_legacy_adapter.sv

- 旧 iq_rvalid/iq_rbits/iq_raccept_cnt -> 新 iq_valid/iq_inst/iq_accept_count
- IQ/redirect 组合直连，零额外取指周期
- BPU update 4-entry FIFO，2 push / 1 pop，不丢训练事件
- 前端 RTL 本体未改

### 3.3 AXI -> L2 I 桥

rtl/frontend/interface/axi_l2_bridge.sv

- ICache AXI4-Lite 32-bit read -> L2 128-bit I beat
- 16 B beat buffer，连续 4 个 word 命中同一 beat
- 只读；AXI 写通道 tie off

### 3.4 共享 L2

rtl/l2/l2_top.sv

- 4-way、64 B line、write-back + write-allocate
- 两个 D 端口：c0/c1
- 两个 I 端口：i0/i1
- 一个 128-bit memory port
- round-robin replacement
- 一次只服务一个 L2 transaction（bring-up 版，无 per-port MSHR）
- L2 单元测试 17 checks：hit/miss、clean refill、dirty writeback、byte enable、双端口并发、c1 驱逐 c0 dirty 行

### 3.5 双核硬件拓扑

rtl/top/ares_frontend_hart.sv
rtl/top/ares_2core_frontend_l2_top.sv

- 两个 hart，每个包含 real frontend + adapter + AXI bridge + core
- hart0：D -> L2 c0，I -> L2 i0，DATA_OFFSET=0
- hart1：D -> L2 c1，I -> L2 i1，DATA_OFFSET=0x0010_0000
- hart1 数据/栈在 0x8020_0000 起；代码仍共享 0x8000_0000
- MMIO 仍是 stub，CoreMark 不使用

## 4. 双核当前失败

rtl/top/test/tb_2core_coremark.sv

约 44.7 ms 时：

~~~text
MISALIGN addr=000000a3 size=1 load=1 store=0
[44695475000] %Error: lsu_agu.sv:188: a_natural_align
~~~

两边都大约 retired 1.842M，PC 大约 0x8000_0634，L2 hits/misses 约 3261/203。

已排除：

- hart1 完全 reset：hart0 50 ms 正常
- hart1 D 完全关闭：hart0 50 ms 正常
- hart1 写关闭、读保留：hart0 仍然失败
- hart1 D 地址：都在 0x8020_xxxx，偏移正确
- hart0 写入 hart1 范围：没有观察到
- c1 read response 逐拍对比 backing memory：50 ms 内没有 mismatch
- L2 c1 驱逐 c0 dirty 行：定向测试通过
- 换 hart1 数据偏移（不同 L2 set）：仍然失败
- I0 固定优先级 vs I0/I1 交替：仍然失败

所以不是：

- 缺少 MULTITHREAD=2
- hart1 数据偏移错误
- 简单 c1 response 路由错误
- 简单 dirty victim writeback 错误

当前最可疑：

1. c1 的 I1 取指路径。关闭 c1 D 会同时停掉 c1 前端，I1 流量也停，所以还没把 I1 和 D 读分开。
2. L1D/L2 交互。L2 单元测试不模拟 L1D MSHR 持有 line 时的 victim/writeback 竞态。
3. 共享 L2 单 outstanding 的 I/D 相邻响应。rsp_data_q/rsp_valid_q/req_port 在 i0/i1/c0/c1 之间的时序。

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

单核参考（应通过）：

~~~bash
cd /home/ccy/Documents/qs/ARES
make unit-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

双核复现（预期在 44.7 ms 失败）：

~~~bash
make repro-2core-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

## 6. 下一步建议

1. 把 I1 和 c1 D 分开
   - 给 hart1 一个私有 instruction source，或 reset 后冻结 i1，只让 c1 D 跑
   - 如果 hart0 正常，说明 i1 是问题
   - 反之，把 c1 D 直接接私有 memory，只保留 i1

2. hart0 lockstep trace
   - 单核和双核跑同一镜像，记录 hart0 retired PC/instruction
   - 找第一条分叉的 load/instruction，定位被破坏的寄存器/数据

3. c0 response shadow
   - 当前只检查了 c1 response；需要对 c0 的已知数据/哨兵区做逐拍 shadow 比较

4. 检查 L1D/MSHR
   - dcache_top、mshr、line_adapter 在 c1 读触发 L2 eviction 时的状态
   - 关注 L1D 持有 line 时 L2 victim/writeback 的竞态

5. 不要先改前端或重新编译 CoreMark
   - 前端、adapter、AXI bridge、AMP offset 在单核都正确
   - 当前失败在共享 L2 / 双 hart 数据通路

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
- docs/coremark_dual_bug_report.md

## 8. 约束

- 单核 CoreMark 是当前正确性基线，改动 L2 后先保证它仍然通过
- 双核是 AMP，不是 SMP；不要用 MULTITHREAD=2 解释当前失败
- 在双核 CoreMark 通过前，不要对外报双核分数

