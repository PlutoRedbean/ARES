# TODO —— 按 docs/plan-pii-gateway.md 的路线

> 勾选以仓库实际状态为准；每完成一项，同时在 `docs/` 里补一句结论（数字要能复现）。

## P0 本机平台（已完成）

- [x] `guard/` 目录骨架 + Makefile + 三条硬约定写进 README
- [x] vendor ARES 流水核（`origin/pipeline-single-issue` @ `98d2427`）到 `vendor/ares-core/`
- [x] vendor miniTensor RTL + 裸机驱动参考到 `vendor/minitensor/`
- [x] 来源与重拷方式记录在 `vendor/PROVENANCE.md`
- [x] Verilator 仿真链（`--binary --timing`，TB 回放 `.in` 并比对 `.exp`）
- [x] Python 金标规则引擎（身份证 18/15、手机、银行卡）+ CLI + 16 个单测
- [x] 合成 PII 语料生成器（含错误校验位、错误日期、超长串、分隔符、干扰项）
- [x] 金标 → 向量 → RTL 一致性测试（200 例 / 289 span，全一致）

## M1 规则层（进行中）

- [x] 数字游程 + 分隔符透明（` `、`-`）
- [x] Luhn（银行卡）
- [x] ISO 7064 MOD 11-2 + 出生日期（身份证 18 位）
- [x] 15 位身份证（YYMMDD 日期校验）
- [x] 手机号 `1[3-9]` 前缀
- [x] 分类 + span 输出 + 顶层 `l1_digit_engine`
- [ ] 邮箱 / IPv4 / 车牌 / 统一社会信用代码
- [ ] `l1_engine` 顶层：字符流 + 命中队列 + 吞吐/延迟 cycle 计数基准
- [ ] 覆盖率：1000 例随机语料 + 手工边界集（空串、全数字、超长、纯分隔符）

## M2 脱敏与审计

- [ ] hold-and-forward 替换器（32 字符回退窗口，`[ID_1]` / 掩码尾 4 位两种策略）
- [ ] 审计 JSON（type/start/len/rule_id/action/档位）
- [ ] 关键词 AC 自动机（给 L2 提供上下文提示，BRAM 表）
- [ ] 端到端 demo：文本文件进 → 脱敏文本 + 审计出（先走 PC 侧字节环回，后接 UART）
- [ ] 降级档位 T0/T1 的 RTL 开关与输出头

## M3 INT4 语义引擎

- [ ] 从 vendor 拷 UB/VPU/接口到 `rtl/l2/`（保持 vendor 只读）
- [ ] 16×16 W4A8 GEMM + 反量化（先仿真对齐 Python 参考）
- [ ] 双缓冲 DMA（描述符化 burst，替代单 outstanding）
- [ ] Transformer 算子：RMSNorm / RoPE / SiLU / softmax / mask
- [ ] 20M 微型 Transformer 逐层对齐（INT8 路径，误差 < 1 LSB）

## M4 0.5B 集成

- [ ] BPE tokenizer（表放 DDR3，RV32 二分查找）
- [ ] 权重 blob 格式 + 加载器（PC 灌入 / SD 预载）
- [ ] 512-token 窗口 + 层间调度 + DDR3 带宽实测
- [ ] 精度评估（CLUENER / MSRA / 微博 NER + 合成 PII，W4A8 vs W8A8）

## M5 网关集成

- [ ] 三层策略与队列（L1 → L2a → L2b）
- [ ] 降级触发（队列深度 / p99 / 带宽 / 温度）与审计事件
- [ ] 输出头 `X-Privacy-Mode` + 审计摘要

## M6 评估

- [ ] P/R/F1（按类型）、p50/p99 延迟、整板功耗、消融
- [ ] 与 plan 里的预算表对账（LUT/DRAM/APM/DDR3 实测 vs 估算）
- [ ] 成文（技术报告 / 论文草案）
