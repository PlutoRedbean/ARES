# 共享 L2 远端修复与验证设施集成记录

日期：2026-10-27。验证时本地分支 `base_core`，HEAD `ed5b2a465d93688ef78ca2b8968e2673051f2904`，结果对应本轮提交前工作区；后续提交记录以 Git log 为准。
远端 tip 已用 `git ls-remote` 核对为 `1fbe654f71cfec7ea734cadd51bac372008394ea`。

## 1. 来源与移植范围

共同基线 `19d0128`；移植 `be114d9` 的 dirty eviction 用例、`612955d` 的双核入口，以及 `003586e` 的 LSU 修复／统计／参考模式／shadow checker；文档结论参考 `55a8e25`、`cb0ecb6`、`1fbe654`，不逐字搬入已过期诊断或无测量支持的性能归因。

原生 C5 FE／双路训练／独立恢复、BRAM IP 与本地板级资产保留；legacy adapter 没有回到 hart 主路径。未修改 L2 数据通路、默认仿真 DUT、Vivado／board profile、架构频率或存储配置。

额外修正有明确依据的验证缺陷：

- Shadow task 的 `output errs` 改为 `inout`，保留累计错误；golden memory 不由 DUT writeback 覆写。
- 按 lane 顺序处理 a0／EBREAK、正确累计双退休，完成时冻结每 hart 统计；聚合分数按启用 hart 数计算。
- 失败、缺文件、无 DMEM、超时用 `$fatal(1)` 返回非零；增加 `+TIMEOUT_NS` 以直接验证超时路径，参数必须为正数。
- 新增 13 项短镜像 harness 检查；AGU 增加历史 `LH 0xa3` 传输回归；双核冒烟接入新增的 `hart1_en`。

## 2. 已执行验证

所有命令在仓库根目录运行；本轮使用 `CCACHE_DISABLE=1`，避免编译缓存写出工作区。日志留在忽略目录 `build/verification/l2-integration/`。

| 命令／范围 | 本轮结果 | 日志 |
| --- | --- | --- |
| `make lint-all lint-backend lint-lsu lint-l2` 及 `make lint-soc lint-mt lint-board` | PASS，无 Verilator warning/error | `lint.log`／`platform-lint.log` |
| `make unit-lsu unit-l2 unit-l2-frontend` | PASS；12 个 LSU TB、L2 17 checks、双 FE model 4 checks、原生 C5 冒烟 25／25+25 retires | `memory-l2.log` |
| `make unit-lsu ARES_LSU_UNIT_TBS=tb_lsu_agu` | PASS；新增 `LH 0xa3` 定向测试，76,228 checks | `agu-regression.log` |
| `make unit unit-frontend unit-frontend-modes unit-soc unit-board unit-mt-irq unit-mt-cpu-irq unit-clint unit-plic test-config test-vivado test-images` | PASS；Backend／FE／4 组预测器配置、SoC／board／IRQ、配置、Vivado 生成器 10/10、镜像测试 3/3 | `system.log` |
| `make tb-ares-pkg tb-fe-stub tb-mem-model unit-fe-adapter` | PASS | `base.log` |
| 单项 `add` → `recursion` → `mersenne` | PASS，按顺序执行后才运行批量 | `isa-add.log` 等 |
| `make isa isa-stub CROSS_COMPILE=riscv64-unknown-elf-` | PASS，真实 FE／桩各 36/36 | `isa.log` |
| `make test-coremark-harness` | PASS，13 checks | `harness.log` |

短镜像同时断言精确退休数（单 hart 3、双 hart 各 3／聚合 6）和关闭 hart1 后的聚合分数口径。检查覆盖：两种 TB 的成功、非零返回、缺参数、缺文件、超时；双核 `+H1EN=0`；hart1 失败；hart0 完成但 hart1 未完成时必须等待并超时。

## 3. 完整 CoreMark（本地原生 C5）

同一份普通软件 CRC 镜像，100 iterations，当前原生 C5；两条 make 命令均返回零：

| 配置 | retires | cycles | IPC | CoreMark/MHz | 状态 |
| --- | ---: | ---: | ---: | ---: | --- |
| 单核 | 31,349,223 | 48,856,291 | 0.641662 | 2.0468 | PASS，a0=0 |
| 双核 hart0 | 31,349,223 | 48,857,613 | 0.641645 | 2.0468 | PASS，a0=0 |
| 双核 hart1 | 31,349,223 | 48,857,616 | 0.641645 | 2.0468 | PASS，a0=0 |
| 双核聚合 | 62,698,446 | 48,857,616 | 1.283289 | 4.0935 | PASS，9 checks |

双核 shadow：`rsp=17202 err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0`。
单核 L2 hits=8,423、misses=178；双核 hits=16,970、misses=232。
日志为 `coremark-single.log`／`coremark-dual.log`。
本轮软件通过本仓库 ARES runtime 重建；不能把它与远端 legacy adapter／旧镜像分数的差值解释成单项硬件优化收益。
`+H1EN=0` 本轮通过短镜像检查；尚未另跑该模式的完整 100-iteration 参考程序。


以上 CoreMark/MHz 为当前回归工作负载的仿真统计，未作为官方发布分数或 FPGA 频率验收。

远端 legacy adapter 路径的历史值只保留在 [状态索引](coremark_dual_status.md)，不代替本地结果。

## 4. 输入与工具

软件来自本机既有 `/home/redbean/ysyx-workbench/am-kernels/benchmarks/coremark`，普通软件 CRC；在忽略目录中复制 src/include，链接本仓库 ARES AbstractMachine，未修改／提交外部源码。`ITERATIONS=100`、`TOTAL_DATA_SIZE=2000`、performance seeds `0/0/0x66`、单实例，两 hart 各跑一份。

- 工具：Verilator 5.046（2026-02-28）；`riscv64-unknown-elf-gcc` 13.2.0；目标 `riscv32-ares`／RV32IM_Zicsr／ilp32。
- 配置：MUL_LATENCY=3；L1D LINE_BYTES=32；默认 FE；L2 128 sets × 4 ways × 64B=32KiB。
- ELF SHA-256：`1c1cb8f04fbad8c99813456e12c572dc175b07eadc9069b9a779391d87a268a1`。
- binary SHA-256：`b77bffd438b20b1d41f9d17177012c3d87c2aeed949e72c232269baba460a5b9`。
- hex SHA-256：`ce3ad6ee15c3bd4ec220e557e52e17056b5f96307eb3681308d075c48a85c02c`。
- `.config` SHA-256：`b6faa4d5a05a2e4bd41de2a944896938826cdf1a9f97283ad4f748af81af0514`。

完整软件输入、RTL／Makefile／脚本哈希及工具版本另存 `build/verification/l2-integration/inputs.json`；命令见 [交接说明](multicore_l2_handoff.md)。这是带外部依赖的已记录输入，尚不满足干净 checkout 自包含镜像构建。

## 5. 失败策略与修改范围

失败／缺镜像／超时用非零退出，不降级为成功。新增文件打开检查和 TIMEOUT_NS 正数检查分别对应已存在的必需输入／超时契约，已由短镜像负向测试验证；未新增推测性判空、重试、兼容分支、异常吞没或静默兜底。保持修改围绕远端修复、验证设施与计划同步；无部署、容器或外部服务写入。

变更文件：`Makefile`；`rtl/memory/{lq,lsu_agu,lsu_top}.sv`、`LSU_INTERFACES.md`、`test/unit/{tb_lq,tb_lsu_agu}.sv`；`rtl/l2/test/tb_l2.sv`；`rtl/top/ares_2core_frontend_l2_top.sv`、`rtl/top/test/{tb_ares_coremark,tb_2core_coremark,tb_frontend_l2}.sv`；`scripts/test_coremark_harness.py`；主实施计划／下一阶段计划、CoreMark 状态／根因／交接／本记录及多核清单。

原有未跟踪 `fpga/vivado/probes/icache_way.json` 和 `scripts/vivado/analyze_routed.tcl` 保留原样。验证时 RTL／构建修改尚未暂存，HEAD 和 index 保持原状；生成镜像、复制的外部软件、编译产物及日志留忽略目录。

## 6. 尚未验收

L2-M1 不整体关闭：默认几何下至少 3 seed × 100 万 accepted transactions、随机反压、复位旧响应隔离、32B/64B 行宽边界、覆盖率、完整检查器故障注入和自包含软件链仍缺。

LQ lookup 是活跃访问边界而不是提交点；本轮不宣告所有投机／全转发／MMIO 对齐路径已穷尽验证，也不增加 misaligned 支持。完整双核 map／MMIO／IRQ／Mailbox／启动、DMA／tensor／RTOS、默认入口、板级 PPA 和实板均继续按 [下一阶段计划](next_steps_implementation_plan.md) 验收。
