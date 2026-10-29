# Dual-core CoreMark status (AMP bring-up)

> 更新：2026-10-27。旧“共享 L2 数据破坏”诊断已撤销。远端 `l2-cache` 的 LSU 修复与验证设施已移植到本地 `base_core` 工作区，保留原生 C5。

## 当前集成

- `ares_frontend_hart`：真实 FE＋原生 C5＋ICache AXI bridge＋Core，未重新接入 legacy adapter。
- `ares_2core_frontend_l2_top`：两 hart、私有 L1D、共享 32KiB L2；新增运行时 `hart1_en`，与 `HART1_ENABLE` 相与。
- `tb_2core_coremark`：hart1 数据／栈偏移 `+0x100000`；四个 L2 读端口和 dirty writeback 的独立 shadow checker；`+H1EN=0` 同二进制参考模式。
- 单／双核 TB：修正双退休计数、按 lane 顺序判定 a0／EBREAK、完成后统计冻结；失败／超时返回非零。
- L2 单测增加 c1 驱逐 c0 dirty line 后读回；短镜像 harness 检查见 `make test-coremark-harness`。

当前本地测试、镜像哈希、指标及边界见 [集成执行记录](l2_integration_results.md)。复现方式见 [交接说明](multicore_l2_handoff.md)，根因见 [旧故障分析](coremark_dual_bug_report.md)。

## 本地原生 C5 结果（2026-10-27）

完整 100 iterations：单核 `31,349,223 retires / 48,856,291 cycles / IPC=0.641662 / 2.0468 CoreMark/MHz`；双核各 `31,349,223 retires`，周期 `48,857,613 / 48,857,616`，聚合 `IPC=1.283289 / 4.0935 CoreMark/MHz`。两 hart 均 a0=0，9 checks 通过，17,202 个 L2 响应及 writeback 检查零错误。

本地与下表远端使用的软件／runtime 构建不完全相同，不把分差归因于某项硬件改动。

## 远端历史结果（不是本地原生 C5 分数）

`003586e`／`1fbe654` 的 legacy adapter 路径、软件 CRC、100 iterations：

| 配置 | retires | cycles | IPC | CoreMark/MHz |
| --- | ---: | ---: | ---: | ---: |
| 单核 | 31,348,582 | 49,944,724 | 0.627666 | 2.0022 |
| 双核 hart0 | 31,348,582 | 50,028,073 | 0.626620 | 1.9989 |
| 双核 hart1 | 31,348,582 | 50,028,076 | 0.626620 | 1.9989 |
| 双核聚合 | 62,697,164 | 50,028,076 | 1.253240 | 3.9978 |

历史 shadow：21,981 响应，i0/i1/c0/c1/writeback 零错误。旧 `21,229,636 / IPC=0.425063` 是 TB 少计双退休；修正统计不改变单核 cycles 和 2.0022。

双核指两份独立 AMP 实例，非 SMP／官方 MULTITHREAD=2。一次程序通过不关闭 L2-M1 的全部随机反压／复位／压力门禁；正式 SoC 的 MMIO／IRQ／启动／DMA／软件及 PPA 另行验收。

## MULTITHREAD=2 单份报告（2026-10-29）

上表的“聚合”是 testbench 把两份独立实例相加得到的诊断值，不是 CoreMark 程序的输出。若需要程序自己打印一份标准 MT 报告，用 `make coremark-mt-image` + `make unit-2core-coremark-mt`：staged overlay（`scripts/coremark_mt/`）把 `MEM_STACK`/`MULTITHREAD=2` 和共享 MMIO 邮箱接进 port，EEMBC 源码零修改。实测 `200 iterations / 45,456,305 ticks = 4.3998 CoreMark/MHz`，`[0]`/`[1]` CRC 相同、`CoreMark PASS`。详见 [CoreMark MULTITHREAD=2](coremark_multithread.md)。
