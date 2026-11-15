# M2 第一刀：红action、审计、关键词、端到端 demo

> 2026-11-15，PC 本地（Verilator 5.040 + Python 3.12），未上板。
> 复现：`cd guard && make clean && make test`（含 44 个单测、5 组仿真、1 组端到端）

## 1. 做了什么

| 项 | 位置 | 状态 |
|---|---|---|
| 重叠合并（左端点优先 + 类型优先级） | `host/golden/redact.py:merge` | ✅ 金标 |
| 替换策略 token（`[MOBILE_1]`）/ mask（尾 4 位） | `host/golden/redact.py:redact` | ✅ 金标 |
| 审计记录 + JSON（type/rule/start/len/action/replacement） | `host/golden/redact.py`、`tools/demo.py` | ✅ |
| 关键词提示（8 个，RTL 并行匹配） | `host/golden/keywords.py` + `rtl/l1/l1_keyword_match.sv` | ✅ 金标 ↔ RTL 108 例一致 |
| 关键词表单一来源（Python → 生成 SV package） | `tools/gen_keywords.py` | ✅ |
| Verilator C++ 驱动（文件进、检测结果出） | `sim/main_detect.cpp`、`make harness` | ✅ |
| 端到端 demo（文本进 → 脱敏文本 + 审计 JSON） | `tools/demo.py` | ✅ golden / `--rtl` 两种模式 |
| RTL 内合并 + mask 替换器（`l1_merge` / `l1_redactor` / `l1_redact_top`） | `rtl/l1/l1_redact.sv` | ✅ 1000 例字节+审计全一致 |
| 全 RTL 驱动 `Vredact` + `demo --rtl-full` | `sim/main_redact.cpp`、`tools/demo.py` | ✅ |

## 2. 证据

```
Ran 44 tests in 0.029s                       # 金标单测（含 merge/策略/审计/关键词）
PASS: L1 engine matches golden vectors       # 1000 例 / 2670 span
PASS: L1 engine matches golden vectors       # 43 例手工边界 / 27 span
PASS: L1 keyword matcher matches golden      # 108 例关键词（含手工 8 例）
redact cases=1000 errors=0                   # RTL 合并+mask：字节流 + 审计记录
PASS: RTL detection + golden redaction agree end to end   # 200 例（含全 RTL 脱敏）
```

`make demo`（走 RTL 检测 + 金标红action）在 `examples/sample.txt` 上的输出：

```
订单联系人：李娜，手机 [MOBILE_1]，备用邮箱 [EMAIL_1]。
身份证号 [ID18_1]，银行卡 [BANK_1]，开户行在北京市朝阳区建国路 88 号。
公司统一社会信用代码 [USCC_1]，服务器 [IPV4_1]，车牌 [PLATE_1]。

请勿把密码和账号通过微信发给客户，谢谢。
```

demo 的 stderr 摘要：

```
[demo:rtl] in=...B out=...B spans=7 types=bank,email,id18,ipv4,mobile,plate,uscc keywords=邮箱,密码,账号
```

`examples/sample.txt` 里的 `88 号` 没有被误伤（不是 PII），关键词 `密码/账号` 只作为提示、不参与替换。

## 3. 合并规则（金标与 RTL 后续要一致实现）

1. 按 `(start 升序, 类型优先级升序, 长度降序)` 排序；
2. 从左到右贪心保留，与已保留区间重叠的丢弃。

类型优先级（数字小 = 优先）：邮箱 1 > 车牌 2 > USCC 3 > IPv4 4 > ID18 5 > ID15 6 > 手机 7 > 银行卡 8。
这样 `1.2.3.4@x.com` 保留邮箱、丢掉内部的 IPv4；`13800138000` 与 `4111...` 相邻时两个都保留。

## 4. 这一刀暴露的两个问题

1. **空格透明带来的漏报**：`13800138000 13800138001`（只隔一个空格）会被当成一个 22 位游程，
   超过 19 位整段作废 → 两个手机号都不报。真实文本里两个号码通常用 `，`/`；`/换行分隔，
   所以 demo 和测试改用标点。修法（下一刀）：有界分隔符 + 超长时在分隔符处重启。
2. **关键词表字节序**：生成器一开始把首字节放进了高字节，导致 RTL 全不命中；
   已改为 `val |= b << (8*i)`，并由 108 例向量兜住。

## 5. 已知限制

- **RTL 还没有做替换**：合并/替换/审计在 host 侧（Python），RTL 只负责检测；`demo --rtl` 已经
  把 RTL 的检测结果接进同一条流水线，所以"RTL 检测 → 金标替换"的路径是真实跑通的。
- 关键词是 8 个固定词的**并行比较器**（窗口 12 字节），不是完整的 AC 自动机；
  扩到几十个词时再换 AC + BRAM 转移表（接口不变）。
- mask 是**字节级**的：数字类型效果正确（尾 4 位保留），中文类型可能切出半个 UTF-8 字符。
- 重叠合并只在金标里实现；RTL 侧待 hold-and-forward 替换器一起做。

## 6. M2 第二刀：合并与替换已经进 RTL

`rtl/l1/l1_redact.sv`：

- **`l1_merge`**：8 个 pending slot；命中到达先查重（`start < last_end` 直接丢），
  按 `(start, 优先级, 长度)` 选最早可提交者；当 `pos - start >= 64` 时提交，
  并清掉与它重叠的 slot；`in_last` 后进入 flush，逐个提交到空。
- **`l1_redactor`**：128 字节循环缓冲，输出滞后 `64+2` 字节（`+2` 是为了让提交比出队早一拍到）；
  span 起点匹配后按 mask 策略输出（长度 >4 时保留最后 4 字节，其余 `*`）；1 字节/拍无停顿。
  span 队列 8 深，字节缓冲 128 深，`ovf` 会置位（当前 1000 例从未触发）。
- **审计**：提交时即输出 `(start, len, type)` 脉冲；host 侧格式化成 JSON。

全 RTL 驱动：`make redact-harness` → `build/obj_redtop/Vredact <in> <out>`，
脱敏文件写 `out`，审计打到 stdout。`tools/demo.py --rtl-full` 就是用它：

```
[demo:rtl-full] in=375B out=375B spans=7 types=bank,email,id18,ipv4,mobile,plate,uscc
```

`examples/sample.txt` 上的输出与金标 `redact(policy="mask")` **逐字节相同**。

## 7. 本机可跑入口（`./run.sh`）

```bash
./run.sh demo                                   # examples/sample.txt，全 RTL
./run.sh text "手机 13800138000 邮箱 a@b.co"     # 一段文本
./run.sh file 某个.txt --policy token --json audit.json
./run.sh repl                                   # 交互（:policy token|mask 切换，:q 退出）
./run.sh report examples/sample.txt              # 只统计
```

`mask` 走全 RTL（`Vredact`）；`token` 走金标渲染（RTL 的变长输出还没做）。
`make test` 里加了 `cli-smoke`：demo 输出必须含 `*`、无 PII 文件必须原样透传。

在 `examples/sample.txt` 上的实际输出：

```
── 审计 (7) ────────────────────────────────────────────
 #  type   span        rule              action  replacement
 1  mobile 54+13       prefix.mobile     mask    *********8000
 2  email  83+16       syntax.email      mask    ************.com
 3  id18   116+18      iso7064.mod11_2   mask    **************002X
 4  bank   147+19      luhn.bank         mask    ***************1111
 5  uscc   250+18      gb32100.mod31     mask    **************0Y43
 6  ipv4   281+9       syntax.ipv4       mask    *****0.21
 7  plate  300+9       syntax.plate      mask    *****2345

── 关键词提示 ──────────────────────────────────────────
邮箱、身份证、银行卡、密码、账号

── 统计 ────────────────────────────────────────────────
mode=rtl-mask  in=375B  out=375B  spans=7  bank=1 email=1 id18=1 ipv4=1 mobile=1 plate=1 uscc=1
```

## 8. 还差什么

1. **token 策略（`[MOBILE_1]`）仍在 host**：RTL 目前只做 1:1 的 mask；token 是变长输出，
   需要反压/令牌表，放下一刀；
2. 关键词仍不参与替换（只是提示），扩表后换 AC；
3. 空格分隔的双号码漏报（见 §4.1）待修；
4. 上板（PDS/时序/引脚）按计划留到最后，PC 侧流程先用仿真闭环。
