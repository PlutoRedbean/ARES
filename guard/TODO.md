# TODO —— 按 docs/plan-pii-gateway.md 的路线

> 勾选以仓库实际状态为准；每完成一项，同时在 `docs/` 里补一句结论（数字要能复现）。

## P0 本机平台（已完成）

- [x] `guard/` 目录骨架 + Makefile + 硬约定写进 README（现在是四条）
- [x] vendor ARES 流水核（`origin/pipeline-single-issue` @ `98d2427`）到 `vendor/ares-core/`
- [x] vendor miniTensor RTL + 裸机驱动参考到 `vendor/minitensor/`
- [x] 来源与重拷方式记录在 `vendor/PROVENANCE.md`
- [x] Verilator 仿真链（`--binary --timing`，TB 回放 `.in` 并比对 `.exp`）
- [x] Python 金标规则引擎（身份证 18/15、手机、银行卡）+ CLI + 单测（现共 63 个）
- [x] 合成 PII 语料生成器（含错误校验位、错误日期、超长串、分隔符、干扰项）
- [x] 金标 → 向量 → RTL 一致性测试（200 例 / 289 span，全一致）

## M1 规则层（完成）

- [x] 数字游程 + 分隔符透明（` `、`-`）
- [x] Luhn（银行卡）
- [x] ISO 7064 MOD 11-2 + 出生日期（身份证 18 位）
- [x] 15 位身份证（YYMMDD 日期校验）
- [x] 手机号 `1[3-9]` 前缀
- [x] 分类 + span 输出 + 顶层 `l1_digit_engine`
- [x] 邮箱 / IPv4 / 车牌 / 统一社会信用代码
- [x] `l1_engine` 顶层（5 引擎并行）+ 吞吐/延迟 cycle 基准（1 字节/拍，150 MB/s @150 MHz）
- [x] 覆盖率：1000 例随机语料（2670 span）+ 43 例手工边界集，全部一致
- [x] 结论写入 `docs/m1-results.md`

## M2 脱敏与审计

- [x] RTL 合并 + mask 替换器（`l1_redact_top`，1000 例字节/审计一致）
- [ ] RTL token 策略（变长输出 + 反压/令牌表）——上板后优先级提高：
      板上现在只能 mask，token 要等这一项
- [ ] 分隔符透明导致的超长游程漏报（`138... 138...`）：有界分隔符 + 分隔符处重启
- [x] 审计 JSON（type/start/len/rule_id/action/档位）—— host 侧，见 `docs/m2-results.md`
- [x] 关键词提示（8 词并行匹配器；扩表时换 AC + BRAM，接口不变）
- [x] 端到端 demo（`make demo`：RTL 检测 + 金标红action + 审计 JSON）
- [x] 本机可跑入口 `./run.sh`（serve / demo / text / file / repl / report）+ `cli-smoke`
- [x] 网页工作台 `./run.sh serve`（实时脱敏，含审计表/关键词/高亮）+ 接口测试
- [ ] 降级档位 T0/T1 的 RTL 开关与输出头（板级摘要行预留了 `ovf` 位，档位位待加）
- [ ] 板级软流控（XON/XOFF）或长度前缀成帧，让裸终端也能安全灌大文件
- [ ] 关键词提示上串口（现在只在 RTL 里跑，摘要行没有关键词位）

## 上板（串口进 → 脱敏 → 串口出）✅ 2026-11-15

手册：[docs/board-bringup.md](docs/board-bringup.md)；设计与验证：[docs/board-uart.md](docs/board-uart.md)。

- [x] PDS/ADS 兼容性：`package`/`always_ff`/`for (int ...)`/`automatic` 在
      PDS 2025.2 `-verilog_standard SystemVerilog` 下**一次通过**，规则层 RTL 没改
      （结论写在 docs/board-uart.md §2）
- [x] 板级顶层 `guard_board_top`：27 MHz → PLL → 10 MHz + 复位同步 + LED（led[7]=PLL 锁）
- [x] 串口桥：分数分频波特率（16× 过采样）、RX/TX FIFO、LF/空闲冲刷、帧间软复位、
      LF→CRLF 整形、每帧一行审计摘要
- [x] 引脚：`uart_rx` = **B24**（ARES MSH 顶层用过），TX C24，clk D18，rst C22
- [x] 资源（synthesize -ads + dev_map + pnr）：**6,912 LUT / 2,578 FF / 0.5 DRM / 37 APM / 1 PLL**
- [x] 时序：核心 **10 MHz**（27 MHz → PLL），WNS **+15.1 ns**、TNS 0、WHS +0.038 ns（Fmax ≈ 11.8 MHz）
- [x] 位流：`pnr` + `gen_bit_stream` → `generate_bitstream/guard_board_top.sbit`（9,188,552 B）
- [x] 烧写链路：`tools/program_guard.ps1` 跑通并修掉 cdt_cfg 的四个坑
      （tcl 必须 ASCII-only / 只能一个 `%s` / GUI 子系统 exe 要 `Start-Process -Wait` /
      `-file` 与 `-args` 都要绝对路径）——见 docs/board-uart.md §10.6
- [x] 综合暴露的问题：`l1_merge` 的 `free_list` 被推成 32 个锁存器（改写成扫描空槽）、
      `guard_report` 的 BCD 25 级串行链（改成比较树 + 独热 TB）
- [ ] **规则层校验链流水化**：27 MHz 不收敛（最差路径 ~75 ns），要把 Luhn/加权和/
      邮箱游程检查拆拍，才能把时钟从 10 MHz 抬回 27/50 MHz（见 docs/board-uart.md §2.1）
- [x] 位级端到端仿真 `make board-sim`（18 例 / 10491 B 输入 / 309 span，逐字节一致）
- [x] 上位机 `tools/serial_host.py`（发文本 / 读回 / `--check` / 审计 JSON / pace 流控）
- [ ] 真板子跑一遍 §8 验收清单（回环、sample.txt `--check`、ovf 触发）
- [ ] 3 Mbaud 环回（10 MHz 下 16× 只能到 625 kbaud：把 OV 降到 8，或提 PLL 输出——
      后者得先解决规则层时序）
- [ ] DDR3 AXI 桥 + 带宽实测（M3 需要）

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