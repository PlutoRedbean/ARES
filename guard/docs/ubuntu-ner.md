# 任务：字符级 人名/地址 模型（在 Ubuntu 上完成）

> 这是一份**可直接执行**的任务书。从上往下照着做，最后跑 `make ner-check` 六条全绿即可交付。
> 仓库里除了这份文件，不需要再看别的文档。

## 0. 环境（复制粘贴，一次搞定）

```bash
sudo apt update
sudo apt install -y build-essential git python3-venv python3-pip \
                    verilator gtkwave cmake ninja-build

python3 -m venv ~/ner-venv && . ~/ner-venv/bin/activate
pip install --upgrade pip
pip install numpy torch --index-url https://download.pytorch.org/whl/cpu
pip install onnx onnxruntime pytest pyserial

git clone https://github.com/ccycyc6/QS.git ~/QS
cd ~/QS/guard && make test        # 基线必须全绿（98 单测 + 11 组仿真）
```

有 GPU：`pip install torch`（cu121 索引），其余不变。

## 1. 目标

做一个**纯整数推理**的字符级 3 分类模型：64 字节窗口 → 每个字符 `0=none / 1=name / 2=addr`，
再把连续同类标签合成 span。要求 RTL 将来能逐位复现，所以**不许用 RNN/attention/BPE/float 推理**。

## 2. 产物（路径固定，缺一不可）

```
guard/models/ner/config.json
guard/models/ner/vocab.json
guard/models/ner/weights_int8.npz
guard/models/ner/quant.json
guard/models/ner/eval.json
guard/host/golden/ner.py         # 纯 numpy 整数推理（禁止 import torch / onnxruntime）
guard/tools/train_ner.py         # 训练，--data --out --seed，可复现
guard/tools/gen_ner_data.py      # 造标注数据
guard/tools/gen_ner_vectors.py   # 留出集 200 例 -> build/ner_vectors/{case_XXXX.in,.exp}
guard/tests/test_ner_golden.py   # 4 个断言：指标/一致性/向量/尺寸
```

## 3. 数据（先做这个，比模型重要）

`gen_ner_data.py` 输出 JSONL，**字节偏移**：

```json
{"text": "联系人张三，手机 13800138000", "spans": [[9, 6, 1], [24, 11, 0]]}
```

`spans` 每项 `[start_byte, len_bytes, label]`，label：`1=name`、`2=addr`、`0=其它 PII`（只当负样本）。

要求：

- 姓氏表直接复用：`from host.golden.entities import SURNAMES`（64 个）；
- 名字 = 姓 + 1~2 个常见名字用字；地址 = 省/市/区 + 街道 + 门牌 + 号/栋/室（用真实地名表，含 2~3 字省市名）；
- **负样本 ≥ 40%**：订单号、金额、日期、页码、纯数字、含姓氏但不是人名的词（金额/王家村/方向）；
- **难样本 ≥ 20%**：无线索词的裸名字（`张三丰来了`）、口语地址（`那条街第三个路口东边`）、名字紧邻数字、中英混排；
- 规模：训练 ≥ 15000 句、留出 ≥ 2000 句、**难集 ≥ 1000 句（单独文件，只用于评估）**。

## 4. 模型（硬约束，为了能上板）

| 项 | 约束 |
|---|---|
| 输入 | `ids[64]` int16，UTF-8 三字节对齐切窗 |
| 词表 | ≤ 4096 项（CJK 3 字节算 1 项，ASCII 每字节 1 项），`<pad>=0`、`<unk>=1` |
| 结构 | `Embedding(→32)` + 2 层 `Conv1d(k=3, 32→32, pad=1, ReLU)` + `Conv1d(1×1, 32→3)` |
| 量化 | 权重 **INT8**（per-tensor，zp=0）；激活 INT8 非对称；累加 INT32 |
| 规模 | 参数 ≤ 60k；INT8 ≤ 120 KB；**≤ 4M MAC / 64 字节窗口** |
| 输出 | `logits[64][3]` → argmax（并列取小 id）→ 连续同类合成 span |

### 4.1 `weights_int8.npz` 键名（严格照做）

```
emb_w    int8  [vocab, 32]
conv1_w  int8  [32, 3, 32]   # [out, kernel, in]
conv1_b  int32 [32]
conv2_w  int8  [32, 3, 32]
conv2_b  int32 [32]
head_w   int8  [3, 32]
head_b   int32 [3]
```

### 4.2 推理配方（`ner.py` 必须逐行照这个写）

```
x        = emb_w[ids]                                   # int8
h1[i][o] = requant(sum_{k,ci} conv1_w[o][k][ci]*x[i+k-1][ci], mul1, zp1)
h1       = clamp(h1, 0, 127)                            # ReLU
h2[i][o] = requant(sum_{k,ci} conv2_w[o][k][ci]*h1[i+k-1][ci], mul2, zp2)
h2       = clamp(h2, 0, 127)
logit[c][i] = sum_o head_w[c][o]*h2[i][o] + head_b[c]   # int32，不重量化
label[i]    = argmax_c logit[c][i]                      # 并列取小 c
requant(acc, mul, zp) = round(acc*mul) + zp             # mul=(w_scale*a_in)/a_out
越界补 0（padding=1）；span 长度按**字节**累加
```

## 5. `eval.json` 格式（我会解析，字段名别改）

```json
{
  "seed": 20261118,
  "data": {"train": 15000, "heldout": 2000, "hard": 1000},
  "heldout": {"span_precision": 0.0, "span_recall": 0.0, "span_f1": 0.0},
  "hard":    {"span_precision": 0.0, "span_recall": 0.0, "span_f1": 0.0},
  "size": {"params": 0, "int8_bytes": 0, "macs_per_window": 0},
  "checksums": {"weights_sha256": "..."}
}
```

## 6. 验收：`make ner-check` 六条全绿

| # | 门槛 | 判据 |
|---|---|---|
| 1 | 留出集 span | F1 **≥0.92**、P ≥0.95、R ≥0.88 |
| 2 | 难集 | R **≥0.75**、F1 ≥0.80 |
| 3 | numpy == ONNX argmax | 500 例完全相同 |
| 4 | 尺寸 | params ≤60k、int8 ≤120 KB、MAC ≤4M |
| 5 | 可复现 | 同 seed 两次训练 `weights_sha256` 相同 |
| 6 | 向量 | `build/ner_vectors` 200 例，`ner.py` 全对 |

```bash
cd ~/QS/guard && make ner-check
```

## 7. 交付

```bash
cd ~/QS && git checkout -b ner-v1 && git add -A \
  && git commit -m 'ner v1: char-level name/address model' && git push origin ner-v1
```

回 Windows 贴两样：`make ner-check` 整屏输出 + `guard/models/ner/eval.json`。

## 8. 禁止项

- ❌ 改 `guard/rtl/`（RTL 我按 `quant.json` 生成，你改了必不一致）
- ❌ 做语义改写/隐晦表述（v1 只做名字和地址；改写要等 DDR3 + 更大 MXU）
- ❌ 难集并进训练集（难集只用于评估）
- ❌ `ner.py` 里调用 onnxruntime / torch（必须纯 numpy 整数推理）
- ❌ 改本文档第 5 节的 JSON 字段名

## 9. 兜底

6 天搞不定：**先交过门槛 3/4/6 的最小版**（F1 0.85 也行），我先把 RTL 通路接通，精度后迭代。
## 10. v1 实测结论（我这边复核过）

v1 已合入 `main`（`models/ner`，28,803 参数 / 29,004 B / 399,360 MAC）。六条门槛在
`make ner-check` 下全绿（含 numpy == ONNX 500/500）。但**在真实感文本上还不能直接当遮罩用**：

| 场景 | 结果 |
|---|---|
| 无线索词的人名（`刘德华的演唱会` / `请发给杨帆` / `存的是孙悦`） | ✅ 全部认出（规则层做不到） |
| 句中人名边界 | ❌ `王小明`→`王`、`王经理`→`王`、`陈静打了个电话`→`陈静打`、`韩梅梅是同学`→`韩梅梅是` |
| 复姓 | ❌ `欧阳娜娜`→`阳娜娜`（训练数据里没有复姓） |
| 普通文本误报 | ❌ 语料 300 句多报 **659** 个 span（`信息`/`谢。`/`g；`/`科技有`/`；`） |
| 地址 | ⚠️ 大体正确，结尾会被截（`…27号院3号` 少了 `楼502`） |
| 置信度门 | 把 `|top1-top2|` 的 int32 阈值提到 **6000**：多报 659→189，但纯靠模型仍不够 |

根因是**数据**，不是结构：

1. 负样本是"订单号/金额/日期"这类模板负样本，**缺少普通散文**（不含 PII 的中文句子）；
2. 训练集里名字几乎总是"姓+常见名"，没有**动词/副词紧跟**的例子（`陈静打了`）；
3. 没有复姓（欧阳/司马/诸葛/上官…）；
4. 地址缺"楼/室/单元"结尾的样本。

## 11. v2 要补什么（只改数据，模型结构不变）

| 项 | 要求 |
|---|---|
| 散文负样本 | 训练集 **≥ 35%**：新闻/说明书/对话体，不含任何 PII；这些句子里要**故意**出现姓氏字（`金额``方向``王家村``张数``刘量`） |
| 边界样本 | 名字后紧跟动词/副词/助词（`陈静打了电话``李雷和韩梅梅``王小明说`），标注只覆盖姓名 |
| 复姓 | 至少 12 个复姓（欧阳/司马/诸葛/上官/东方/皇甫/尉迟/公孙/慕容/长孙/宇文/司徒）各 ≥ 200 例 |
| 地址尾巴 | `X号楼X单元X室`、`X栋X号`、`X层` |
| 线索词多样化 | 除了 联系人/姓名，加 `叫``叫作``名叫``署名``签字``发件人``收件人``户主` |
| 规模 | 训练 ≥ 25k 句（负样本 ≥ 9k，难集 ≥ 1.5k） |

**验收门槛（v2 加两条）**：

| # | 门槛 |
|---|---|
| 7 | 散文负样本集（≥1000 句无 PII）上 **多报 ≤ 0.05 span/句** |
| 8 | 证据集（我给的 11 句手写样本，见 `tools/eval_ner.py`）上 **span 完全正确 ≥ 8/11** |

`tools/eval_ner.py` 就是这两条的评测脚本，交付前自己先跑一遍。
