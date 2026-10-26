# Dual-core CoreMark status (AMP bring-up)

> **Superseded.** 双核 AMP CoreMark 已通过；本文件只保留为索引，结论与证据见
> [coremark_dual_bug_report.md](coremark_dual_bug_report.md)，集成说明与指标见
> [multicore_l2_handoff.md](multicore_l2_handoff.md)。

## Implemented

- `ares_frontend_hart`: real frontend + adapter + ICache AXI bridge + core,
  with a D-side AMP address offset.
- `ares_2core_frontend_l2_top`: two harts, shared `l2_top`, two I ports
  (i0/i1) and two D ports (c0/c1), plus a runtime `hart1_en`.
- `l2_top`: second instruction read port, I0/I1 alternating arbitration.
- `tb_2core_coremark`: two CoreMark images, hart1 data/stack at `+0x100000`,
  both harts start together; L2 response shadow checker; `+H1EN=0` reference
  mode.

## Result

~~~text
make unit-2core-coremark DMEM=<coremark_dmem.hex>
ALL TESTS PASSED: 8 checks - 2 harts + shared L2, two CoreMark instances
L2 shadow check: rsp=21981 err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0
hart0: retires=31348582 cycles=50028073 IPC=0.626620 CM/MHz=1.9989
hart1: retires=31348582 cycles=50028076 IPC=0.626620 CM/MHz=1.9989
aggregate: retires=62697164 max_cycles=50028076 IPC=1.253240 CM/MHz=3.9978
L2: hits=21771 misses=210
~~~

Single-hart baseline (real frontend, same L2):

~~~text
make unit-coremark DMEM=<coremark_dmem.hex>
retires=31348582 cycles=49944724 IPC=0.627666 CoreMark/MHz=2.0022
hits=10133 misses=165
~~~

> 旧版本这里写的是 `retires=21,229,636 / IPC=0.425063`：测试平台把每拍 2 条
> 退休记成 1 条，退休数和 IPC 被低估约 1.5 倍；CoreMark/MHz 只依赖 cycles，
> 所以 2.0022 不变。计数器已修正。

## The 44.7 ms "misalign"

之前的判断（"共享 L2 数据破坏"）是错的。实际是 `lsu_agu` 在**投机发射级**
断言自然对齐，预测失败路径上的垃圾 `LH` 命中该断言。L2 数据通路经影子内存
逐拍比对 21981 个响应零错，hart0 的退休流与单 hart 参考运行逐条一致。

修复：契约检查移到架构可见点（`lsu_top.a_load_natural_align` 与既有的
`a_drain_mask_legal`）。详见 [coremark_dual_bug_report.md](coremark_dual_bug_report.md)。
