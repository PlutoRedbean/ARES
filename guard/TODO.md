# TODO —— 下一步清单（按里程碑分组）

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
- [x] 结论写入 `docs/board-uart.md`（板级设计与验证）

## M2 脱敏与审计

- [x] RTL 合并 + mask 替换器（`l1_redact_top`，1000 例字节/审计一致）
- [ ] RTL token 策略（变长输出 + 反压/令牌表）——上板后优先级提高：
      板上现在只能 mask，token 要等这一项
- [x] 分隔符透明导致的超长游程漏报（`13800138000 13800138001` 整段 >19 位被丢弃）：
      分隔符处存"分类快照"+ 影子游程，超长时先结算快照再用影子顶替；金标与 RTL 同步改，
      新增 5 例边界（48 例）专测这个语义
- [ ] 连续三个以上号码被空格连在一起时，中间那个仍会丢（快照只保留"最后一个分隔符之前"的
      前缀，中间段的数字已经不在了）——要根治得缓存两段数字

- [x] 审计 JSON（type/start/len/rule_id/action/档位）—— host 侧，见 `guard/README.md`
- [x] 关键词提示（8 词并行匹配器；扩表时换 AC + BRAM，接口不变）
- [x] 端到端 demo（`make demo`：RTL 检测 + 金标红action + 审计 JSON）
- [x] 本机可跑入口 `./run.sh`（serve / demo / text / file / repl / report）+ `cli-smoke`
- [x] 网页工作台 `./run.sh serve`（实时脱敏，含审计表/关键词/高亮）+ 接口测试
- [x] 降级档位**输出头**：摘要行 `mode=N`（1 = T1 规则层生效，0 = T0 直通）
- [ ] 降级档位 **T0 直通开关**的运行时控制（现在只有构建期参数 MODE_T1；
      要真正切换得先有控制通道：XON/XOFF 帧或"长度前缀"帧，见下一条）
- [ ] 板级软流控（XON/XOFF）或长度前缀成帧，让裸终端也能安全灌大文件
- [x] 关键词提示上串口：摘要行 `kw=`（命中次数）+ `kwm=`（8 词位图），
      金标/上位机/TB 三处同源（`board_proto.kw_stats`）

## 上板（串口进 → 脱敏 → 串口出）✅ 2026-11-15

手册：[docs/board-bringup.md](docs/board-bringup.md)；设计与验证：[docs/board-uart.md](docs/board-uart.md)。

- [x] PDS/ADS 兼容性：`package`/`always_ff`/`for (int ...)`/`automatic` 在
      PDS 2025.2 `-verilog_standard SystemVerilog` 下**一次通过**，规则层 RTL 没改
      （结论写在 docs/board-uart.md §2）
- [x] 板级顶层 `guard_board_top`：27 MHz → PLL → **25 MHz** + 复位同步 + LED（led[7]=PLL 锁）
- [x] 串口桥：分数分频波特率（8× 过采样）、RX/TX FIFO、LF/空闲冲刷、帧间软复位、
      LF→CRLF 整形、每帧一行审计摘要
- [x] 引脚：`uart_rx` = **B24**（ARES MSH 顶层用过），TX C24，clk D18，rst C22
- [x] 资源（synthesize -ads + dev_map + pnr，25 MHz 版，含 L2）：**4,785 LUT / 2,947 FF / 0.5 DRM / 10 APM / 1 PLL**
- [x] 时序：核心 **25 MHz**（27 MHz → PLL），WNS **+5.0 ns**、TNS 0、WHS +0.038 ns（Fmax ≈ 28.7 MHz）
- [x] 位流：`pnr` + `gen_bit_stream` → `generate_bitstream/guard_board_top.sbit`（9,188,552 B）
- [x] 烧写链路：`tools/program_guard.ps1` 跑通并修掉 cdt_cfg 的四个坑
      （tcl 必须 ASCII-only / 只能一个 `%s` / GUI 子系统 exe 要 `Start-Process -Wait` /
      `-file` 与 `-args` 都要绝对路径）——见 docs/board-uart.md §10.6
- [x] 综合暴露的问题：`l1_merge` 的 `free_list` 被推成 32 个锁存器（改写成扫描空槽）、
      `guard_report` 的 BCD 25 级串行链（改成比较树 + 独热 TB）
- [x] **规则层时序重构**（2026-11-17）：分块定位到 `l1_text_engines`（−37.9 ns），
      把邮箱/IPv4/USCC 从"游程结束整缓冲组合校验"改成**逐字节增量校验** →
      文本块 +22.4 ns，整板 27 MHz 只剩 merge 的 31.5 ns。核心时钟 10 → **25 MHz**，
      LUT 6,912 → 4,749、FF 2,578 → 2,947、APM 37 → 10，WNS +4.7 ns（含 L2，见 docs/board-uart.md §2.1）
- [ ] `l1_merge` 的 5 路插入流水化（现在是整板最深的 31.5 ns；做完能上 50 MHz）
- [x] 位级端到端仿真 `make board-sim`（18 例 / 10491 B 输入 / 309 span，逐字节一致）
- [x] 上位机 `tools/serial_host.py`（发文本 / 读回 / `--check` / 审计 JSON / pace 流控）
- [x] 真板验收（2026-11-17）：USB-UART 枚举成 CP210x → **COM9**，
      `sample.txt --check` **PASS 1334/1334 B**，5 倍拼接 **PASS 6670/6670 B**
      （35 帧、ovf 全 0）；顺带修掉上位机 pace 死锁（board-uart.md §10.8）。
      **还没测**：`--no-pace` 灌爆触发 `ovf=001`、拔插/复位后的行为
- [x] 上下文兜底真板验证（2026-11-17）：`身份证 330203300422240391`（校验位错）→
      `**************0391`；`身份证 4404022301341`（13 位）→ `*********1341`；
      `号码 330203300422240391`（无关键词）→ 不遮，精度保持不变
- [x] 帧边界回到"只认回车"：Ctrl-D 恢复成普通字节（实测发出 `61 62 63 04`，正文原样带出）
- [x] 3 Mbaud **仿真**通路：OV 从 16 降到 8，`make board-sim-3m`（同一套 18 例，位时间
      9 个 27 MHz 周期）全过
- [ ] 3 Mbaud **板级环回**：要 USB-UART 支持 3 Mbaud（FT232 可以，CH340/CP2102 不行）
- [ ] DDR3 AXI 桥 + 带宽实测（M3 需要）

## M3 INT4 语义引擎

- [x] L2 第一刀：**miniTensor MXU 接入**（`tensor_gemm_core` 的 4×4 阵列），
      INT4 权重的上下文分类器（none/id18/bank/mobile），12 例/14 游程对金标，
      889 LUT / 954 FF / WNS +30 ns（`make l2-sim` / `fpga/pango/flow_l2.tcl`），
      见 [docs/l2-int4.md](docs/l2-int4.md)
- [x] L2 接进板级位流：`l2_semantic_top` 挂到同一字符流，摘要行加 `l2=`/`l2m=`；
      板上 4,749 LUT / 2,947 FF / WNS +4.7 ns，sample.txt **PASS 1334 B**
- [x] **权重训练**：`tools/train_l2.py`（4000 训练 / 2000 留出，INT4 量化 + 整数坐标下降，
      train/holdout 1.000）→ `host/golden/l2_weights.py` → `tools/gen_l2_weights_sv.py`
      生成 RTL 权重包。RTL 未改，只换表；训练后 `sample.txt` 的 `l2` 从 2 降到 1（不再
      把分组卡号的 4 位片段算成 PII）
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