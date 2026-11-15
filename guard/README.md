# guard —— 隐私守门人（PII 脱敏网关）

部署在数据源头、在文本离开设备前完成脱敏的分层降级网关原型。目标平台盘古 200Pro+
（PG2L200H），控制面复用 ARES 单发射流水核，数据面在 miniTensor 上扩展。

规划文档：[docs/plan-pii-gateway.md](docs/plan-pii-gateway.md)（可行性、资源/带宽预算、
里程碑、风险）。本文件只讲**本机平台怎么用**。

## 当前状态（2026-11-15）

| 阶段 | 状态 |
|---|---|
| 本机开发平台（仿真/金标/语料/一致性测试） | ✅ 就绪 |
| L1 规则层：身份证 18/15、手机、银行卡、邮箱、IPv4、USCC、车牌 | ✅ 1000 例 / 2670 span 全一致，另 43 例手工边界 |
| 顶层 `l1_engine`（5 引擎并行）+ 吞吐基准 | ✅ 1 字节/拍，150 MB/s @150 MHz |
| 红action 金标：重叠合并 + token/mask + 审计 JSON | ✅（M2，见 [docs/m2-results.md](docs/m2-results.md)） |
| 关键词提示（8 词，金标 + RTL 并行匹配） | ✅ |
| 端到端 demo（文本进 → 脱敏 + 审计 JSON，RTL 检测在环） | ✅ `make demo` |
| RTL 合并 + mask 替换器（`l1_redact_top`，1 字节/拍） | ✅ 1000 例字节+审计全一致 |
| 全 RTL 脱敏驱动 + `demo --rtl-full` | ✅ |
| 本机入口 `./run.sh`（demo/text/file/repl/report） | ✅ 见下方快速开始 |
| L2（INT4 语义层） | ⬜（M3） |

## 快速开始

最短路径（自动构建 + 跑样例，输出脱敏文本、审计表、关键词提示、统计）：

```bash
cd /home/ccy/Documents/qs/QS/guard
./run.sh demo                                   # 全 RTL：检测 + 合并 + mask 替换
./run.sh text "手机 13800138000 邮箱 a@b.co"     # 一段文本
./run.sh file 某个.txt --policy token --json audit.json
./run.sh repl                                   # 交互模式
./run.sh report examples/sample.txt              # 只统计
```

完整验证：

```bash
make test        # 金标单测 + 生成向量 + Verilator 一致性仿真
make golden      # 只跑 Python 单测
make vectors     # 只生成 build/vectors
make sim         # 只跑仿真（需要先有向量）
make kw          # 关键词匹配器一致性
make harness     # 构建 Verilator C++ 驱动（Vdetect）
make demo        # 端到端 demo：examples/sample.txt → 脱敏 + build/audit.json
make redact-harness  # 全 RTL 脱敏驱动（build/obj_redtop/Vredact）
make demo-check  # RTL 检测 + 金标红action 的端到端比对（200 例）
make bench       # 吞吐基准（1 字节/拍）
make edges       # 手工边界集（邮箱/IPv4/USCC/车牌/超长/空串）
make lint        # Verilator lint
```

当前结论与数字见 [docs/m1-results.md](docs/m1-results.md)。

依赖：`verilator >= 5.0`（本机 5.040）、`python3 >= 3.10`（本机 3.12，只用标准库）、`make`。
当前一切都在 PC 仿真里闭环；**RTL 还没有过 PDS 综合**，上板（Windows + PDS）留到流程在 PC 上验证满意之后，
相关事项记在 TODO 的「上板预留」。
**目前不需要 torch**：L1 是纯规则，L2 上板前的量化评估才会用到（可复用 `gesture-env` 里的 venv）。

金标命令行（在 guard 根目录运行）：

```bash
python3 -m host.golden.cli ../some/text.txt --redact
printf '身份证 11010519491231002X' | python3 -m host.golden.cli
```

## 目录

```
guard/
├── Makefile              # test / golden / vectors / sim / lint / clean
├── TODO.md               # 按路线的任务清单（勾选式）
├── docs/
│   └── plan-pii-gateway.md
├── rtl/l1/               # 本工程新增 RTL
│   ├── l1_digit_engine.sv    # 数字类（身份证/手机/银行卡）
│   ├── l1_text_engines.sv    # 邮箱 / IPv4 / USCC / 车牌
│   └── l1_engine.sv          # 顶层（5 引擎同流并行）
├── sim/                  # Verilator testbench（一致性 + 吞吐）
├── host/
│   ├── golden/           # 金标：规则引擎 + 红action/审计 + 关键词 + CLI
│   └── corpus/           # 合成 PII 语料
├── run.sh                # 本地入口（自动构建 → tools/guard_cli.py）
├── examples/             # sample.txt（含 PII）/ clean.txt（无 PII）
├── tools/gen_vectors.py  # 语料 → .in/.exp/manifest 向量 + bench 语料
├── tools/gen_edges.py    # 手工边界集
├── tests/                # 金标单测（unittest）
└── vendor/               # ARES core / miniTensor 拷贝，见 PROVENANCE.md
```

## 三条硬约定

1. **金标与 RTL 一一对应**：判定写在 `host/golden/pii_rules.py` 和 `rtl/l1/*.sv` 两处，
   任何一侧改规则，另一侧必须同步；`make test` 会用同一批向量把两边拉齐。
2. **坐标按字节**：span 的 `start/len` 是 UTF-8 字节偏移，和 RTL 字符流天然一致。
3. **一致性靠向量**：语料随机合成，期望值由金标生成；RTL 必须在全部用例上逐条对齐。
   新增规则先加金标单测，再加向量。

## L1 当前判定的边界（都已写进测试）

- 数字游程：`' '`、`'-'` 在游程内透明（`138 0013 8000` 是 13 字节的 span）；尾部透明字符不计入；
- `X`/`x` 只在前 17 位之后作为身份证校验位；
- 位数 > 19 的游程整段作废；
- 优先级 ID18 > ID15 > 手机 > 银行卡（18 位走身份证分支，不做银行卡回退）；
- 出生日期按"能被 4 整除即闰年"判断（忽略世纪规则），日上限按月份区分。
