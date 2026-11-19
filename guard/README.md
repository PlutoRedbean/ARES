# guard —— 隐私守门人（PII 脱敏网关）

![ARES GUARD](docs/ares-guard-logo.png)

```
    _    ____  _____ ____     ____ _   _    _    ____  ____
   / \  |  _ \| ____/ ___|   / ___| | | |  / \  |  _ \|  _ \
  / _ \ | |_) |  _| \___ \  | |  _| | | | / _ \ | |_) | | | |
 / ___ \|  _ <| |___ ___) | | |_| | |_| |/ ___ \|  _ <| |_| |
/_/   \_\_| \_\_____|____/   \____|\___//_/   \_\_| \_\____/
```

*PII redaction, on the wire —— 串口进，脱敏文本 + 审计行出。*

部署在数据源头、在文本离开设备前完成脱敏的分层网关原型。目标平台 **盘古 200Pro+**
（PG2L200H-6IFBB676，25 MHz），控制面复用 ARES 单发射流水核，数据面在 miniTensor 上扩展。

## 当前状态（2026-11-19）

| 层 / 能力 | 状态 |
|---|---|
| L1 规则：身份证 18/15、手机、银行卡、邮箱、IPv4、USCC、车牌 | ✅ 1000 例 / 2670 span 与金标逐字节一致 |
| 合并 + 替换器（`l1_redact_top`，1 字节/拍） | ✅ 1000 例字节 + 审计全一致 |
| L2 语义（miniTensor 4×4 INT8 上的 INT4 分类器） | ✅ 进板级位流，摘要行 `l2=`/`l2m=` |
| L2b 实体（人名/地址）：规则版 `l2_entity` + NER v4 | ✅ 板级默认 NER，16 条门槛全过 |
| 上板：串口进 → 脱敏 → 串口出 | ✅ 25 MHz 收敛（WNS +4.40 ns），见 [docs/board-uart.md](docs/board-uart.md) |
| 长文本 | ⚠️ 板子 >64 字节会提前收帧；上位机按标点分帧规避（[TODO.md](TODO.md) 第 1 条） |
| 浏览器演示台（串口实时 / 实测回放 / 本地预览） | ✅ [web/README.md](web/README.md) |

**资源与时序**（当前位流，PDS 2025.2-SP3）：

| 项 | 值 |
|---|---|
| LUT / FF | **20,879 / 159,800（13.07%）** · 3,815 / 319,600（1.19%） |
| DRM / APM / PLL | 6.0 / 415（1.45%，96 KB NER embedding）· 17 / 740 · 1 |
| 时序 | WNS **+4.40 ns**、TNS 0 → Fmax ≈ 28.2 MHz @25 MHz |
| 位流 | `generate_bitstream/guard_board_top.sbit`（9,188,552 B） |

## 演示样例（`examples/`，五条都在板上逐条验过）

```powershell
python tools\serial_host.py -p COM9 --file examples\demo1_offer.txt
```

| # | 文件 | 场景 | 关键输出 |
|---|---|---|---|
| 1 | `demo1_offer.txt` | 求职信（姓名+地址+手机+邮箱） | `李＊`、`*******4589`、`…com`、地址整段遮；`明远科技有限公司`、`2026年` 原样 |
| 2 | `demo2_hr.txt` | 入职通知（姓名+手机+身份证+地址） | `赵＊`、`*******5678`、`…002X`、地址整段遮 |
| 3 | `demo3_ticket.txt` | 客服工单（姓名+地址+手机+邮箱） | `孙＊＊`、地址整段遮、`*******4567` |
| 4 | `demo4_finance.txt` | 财务寄件（姓名+地址+手机+卡号） | `林＊＊`、地址整段遮、`…0001` |
| 5 | `demo5_mail.txt` | 工作邮件（姓名+邮箱+手机+身份证） | `王＊＊`、`…com`、`…4589`、`…002X` |

五条的非 PII 部分（公司名、职务、`本周五下午三点`、`学历证书原件`）与括号标点全部原样。

## 快速开始

**PC 本机**（金标 + Verilator，无需板子）

```bash
cd guard
make test                 # 11 组：金标单测 / 向量 / 一致性仿真 / 板级 / 摘要格式
make ner-check            # NER 16 条门槛
./run.sh demo             # 全 RTL 端到端：检测 + 合并 + mask
./run.sh serve            # 本机工作台 http://127.0.0.1:8766
```

**浏览器演示台**（接线面板，能连板子）

```powershell
cd guard
make web                  # http://127.0.0.1:8777（Chrome/Edge）
```

**上板**

```powershell
cd guard
powershell -ExecutionPolicy Bypass -File tools\build_guard.ps1     # 出位流
powershell -ExecutionPolicy Bypass -File tools\program_guard.ps1   # 烧板（断电即丢）
python tools\serial_host.py -p COM9 --repl                         # 交互
python tools\board_smoke.py                                        # 12 句自检
```

细节：[docs/board-bringup.md](docs/board-bringup.md)（手册）· [docs/board-uart.md](docs/board-uart.md)（设计）。

## make 目标（常用）

| 目标 | 作用 |
|---|---|
| `make test` | 全套 PC 回归（11 组） |
| `make golden` / `vectors` / `sim` | 金标单测 / 生成向量 / 回放向量 |
| `make demo` / `demo-check` | 端到端 / 200 例对账 |
| `make board-sim` | 位级 UART 端到端（18 例，真实位定时） |
| `make ner-check` / `ner-vectors` | NER 门槛 / 200 例向量 |
| `make web` / `web-demos` | 起演示台 / 重新生成 `web/demos.js` |

## 文档

| 文档 | 内容 |
|---|---|
| [docs/board-bringup.md](docs/board-bringup.md) | 上板手册：出位流 → 烧写 → 第一测 → 验收 → 故障表 |
| [docs/board-uart.md](docs/board-uart.md) | 板级设计：数据通路、帧边界、掩码策略、摘要行、资源、踩坑记录 |
| [docs/l2-int4.md](docs/l2-int4.md) | L2 语义层 + NER 数据通路（窗口重叠、后处理过滤、模型文件） |
| [docs/ubuntu-ner.md](docs/ubuntu-ner.md) | NER 训练交接书（规格、数据、16 条门槛、v5 请求） |
| [web/README.md](web/README.md) | 浏览器演示台（三条数据来源、协议、文件职责） |
| [TODO.md](TODO.md) | 下一步与已知限制 |

## 目录

```
guard/
├── rtl/l1/     规则层 + 合并 + 替换器
├── rtl/l2/     语义层（miniTensor）+ 实体层（规则 / NER）
├── rtl/board/  串口、摘要、顶层、PLL
├── host/       金标（纯 Python/numpy）+ 板级协议
├── tools/      构建、烧写、训练、评测、串口上位机、网页数据生成
├── sim/        Verilator testbench
├── tests/      单测
├── data/ models/  NER 语料与 INT8 模型
├── web/        浏览器演示台（无构建）
└── vendor/     第三方（ARES 核等），来源见 PROVENANCE.md
```

## 四条硬约定

1. **数字可复现**：`make test` / `make ner-check` / `tools/board_smoke.py` 三条命令给出全部结论；
2. **RTL 只用可综合子集**：`logic` / `always_ff` / `always_comb` / 函数，不用 interface/struct/动态数组；
3. **金标与 RTL 逐字节一致**，不一致优先信金标并补测试；
4. **脱敏 1:1**：输出字节数必须等于输入，掩码按字符给星也靠这个（一个汉字 3 个 `*`）。

## L1 当前判定的边界（都已写进测试）

| 规则 | 认什么 | 不认什么 |
|---|---|---|
| 身份证 18/15 | 校验位正确、出生日期合法 | 校验位错的号码（**故意不遮**） |
| 手机 | 1[3-9] 开头的 11 位，允许空格/横线分段 | 座机（`0571…`，暂未覆盖） |
| 银行卡 | 13~19 位 + **Luhn** 校验 | Luhn 不过的数字串 |
| 邮箱 | 常规 RFC 子集 | 无 @ 的 "a.b.c" |
| IPv4 / USCC / 车牌 | 严格格式 + 校验位 | 近似写法 |