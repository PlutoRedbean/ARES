# 双核 CoreMark 旧对齐故障：根因与移植边界

> 更新：2026-10-27。原始分析／修复来源：远端 `l2-cache` 的 `003586e`；文档状态校正至 `1fbe654`。本地已移植相关增量，保持原生 C5，未覆盖远端 legacy frontend 到当前主线。

## 1. 旧症状及被推翻的诊断

旧测试在约 44.7ms 触发 `lsu_agu.a_natural_align`，访问为 `LH addr=0x000000a3`。
当时把下游断言解释为共享 L2 数据／指针破坏，该推断已被后续调查推翻。

远端记录的证据：

1. 四个 L2 端口 i0/i1/c0/c1 的 21,981 个响应及 dirty writeback 与 shadow memory 比较零错误。
2. 到旧故障位置的 2,768,013 条退休流（PC、rd_wen、rd、wdata），hart0／hart1／单 hart 参考逐条一致；参考流可继续运行。
3. 52 次 AGU 对齐触发均是预测失败路径上的相同 LH，随后被 squash，没有进入相应的架构退休流。

这些证据支持“该故障不是观测到的 L2 数据破坏”，不构成任意并发／反压／复位下 L2 的完全正确性证明。

## 2. 移植的修复

- `lsu_agu.sv`：删除投机发射级自然对齐断言，保留地址计算／流水／分类行为。
- `lq.sv`：增加 `lookup_size`，与被选择条目的地址一起输出。
- `lsu_top.sv`：增加 `a_load_natural_align`，在 live LQ lookup 边界检查 size/address；保留 COMMITTED store drain 的 `a_drain_mask_legal`。
- `LSU_INTERFACES.md` 与相关单测同步；AGU 新增历史 `LH 0xa3` 的传输定向回归。

**能力边界**：未增加未对齐访存、split／rounding 或异常支持。LQ lookup 仍可能早于指令提交，不应把“live lookup”称为“已经退休”。全转发、MMIO、仍存活的投机访问和检查点完整性的审查列在下一阶段 A1，不能用本次长程序未触发断言代替该审查。

## 3. 同时移植／修正的验证设施

| 项目 | 当前行为 |
| --- | --- |
| 双退休统计 | 每拍按有效 lane 数累计，在 EBREAK 完成后冻结；lane0 EBREAK 不计后续 lane |
| a0／EBREAK | 按 lane 程序顺序更新 effective a0，允许同拍 lane0 更新、lane1 退出 |
| 单 hart 参考 | 双核二进制 `+H1EN=0` 保持 hart1 复位，聚合指标按启用 hart 数计算 |
| L2 参考模型 | 仅初始化镜像和 L2 接受的 store 更新 shadow；读响应／写回被检查，错误写回不覆盖 golden 状态 |
| Checker 错误累计 | 远端 task 的 `output errs` 改为 `inout`，避免后续调用丢失旧错误 |
| 失败传播 | 非零返回／checker 错误／缺文件／超时用 `$fatal(1)`，不再打印失败后正常退出 |
| 短镜像负向回归 | 直接运行真实 TB 二进制，覆盖双 hart 完成／失败条件及单 hart 参考 |

完整命令与本地实际结果见 [交接说明](multicore_l2_handoff.md) 和 [集成记录](l2_integration_results.md)。
