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
| RTL 内的 hold-and-forward 替换器 | — | ⬜ 下一刀 |

## 2. 证据

```
Ran 44 tests in 0.029s                       # 金标单测（含 merge/策略/审计/关键词）
PASS: L1 engine matches golden vectors       # 1000 例 / 2670 span
PASS: L1 engine matches golden vectors       # 43 例手工边界 / 27 span
PASS: L1 keyword matcher matches golden      # 108 例关键词（含手工 8 例）
PASS: RTL detection + golden redaction agree end to end   # 200 例
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

## 6. 下一刀（M2 收尾）

1. RTL `l1_redactor`：96 字节回退窗口 + 96 字节延迟，命中到达时回填替换，
   输出脱敏字节流 + 二进制审计记录（type/start/len/action）；
2. 合并逻辑搬进 RTL（窗口内按左端点+优先级裁决）；
3. 关键词扩表 + AC 化（可选）；
4. demo 改成全 RTL：`Vredact file in out`，host 只负责把审计记录格式化成 JSON。
