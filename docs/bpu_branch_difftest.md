# BPU 预测准确率基线（branch difftest）

> 2026-10-28。从 `$MUNDUS_HOME/npc/csrc/wave/branch_difftest.cpp` 移植，
> 用 CoreMark 定量看 BPU 改动对准确率的影响。

## 怎么跑

```bash
make unit-coremark BRDIFF=1
```

- RTL 侧：`rtl/top/ares_core_top.sv` 在 `CONFIG_BRANCH_DIFFTEST` 下把每个
  已解决的 CFI（`bpu_update_valid/bpu_update`：update_pc、pred_taken、
  pred_target、actual_taken、actual_target）通过 DPI 送给参考模型；
- C++ 侧：`sim/csrc/branch_difftest.cpp`（含参考模型 + 统计），
  `rtl/top/test/tb_ares_coremark.sv` 在结束时调 `branch_difftest_dump_report()`；
- 报告：`build/branch_difftest_report.txt`；
- 指令分类：模型需要读 PC 处的指令判断 CFI 类型。ARES 的 CoreMark TB 用的是
  纯 SV 内存模型，所以 C++ 侧自己加载同一份 `$readmemh` 镜像
  （路径由环境变量 `ARES_BRDIFF_DMEM` 给出，Makefile 已设置）。

## Baseline（CoreMark，单 hart，真实 FE + 共享 L2）

```
Direction : Tournament-Loop-Tage
Target    : ubtb-ras-mbtb

Branch events / dir miss / tgt miss : 5,787,723 / 47,354 / 190,553
Branch accuracy                     : 95.89%

Jump events   / dir miss / tgt miss :   616,853 /  7,123 /   2,593
Jump accuracy                       : 98.42%

Overall events / misses / accuracy  : 6,404,576 / 247,623 / 96.13%
```

同时 CoreMark 本体指标不变（DPI 观测不影响时序）：

```
retires=31,395,905  cycles=48,639,576  IPC=0.645481  CoreMark/MHz=2.0559
L2 hits=11,318  misses=183
```

## 移植说明与已知限制

- `sim_state`、`inst_cnt`、`panic/Log`、`vaddr_read` 这些 NPC 依赖做了本地
  替代；`vaddr_read` 用 `ARES_BRDIFF_DMEM` 指定的镜像文件。
- 报告里的 `IPC / enqueue IPC` 目前恒为 0（没有接 NPC 的退休指令计数）；
  Cycles/IPC 仍以 TB 打印的 `CoreMark metrics` 为准。
- 未启用 `CONFIG_BRANCH_DIFFTEST_TAGE`，因此没有 TAGE 独立模型的
  逐表准确率；`queue_update` 路径的整体/分类/PC 分桶统计可用。
- 双 hart 版本（`unit-2core-coremark`）还没有加 BRDIFF 开关；当前基线是单 hart。
