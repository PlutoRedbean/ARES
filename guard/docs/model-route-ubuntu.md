# Ubuntu 交接单：字符级 人名/地址 模型（v1）

> 你在 Ubuntu 上要做的**全部**内容、文件格式、验收门槛、自检命令都在这一份里。
> 做完切回 Windows，我按第 6 节验收并接进 RTL。

## 0. 一句话目标

交付一个**纯整数推理**的字符级模型：给 64 字节窗口，输出每个字符的 3 分类
（0=none / 1=name / 2=addr）；`host/golden/ner.py`（numpy，无 torch）跑出来的结果
必须和 RTL 将来逐位一致。**不上板的部分不要做。**

## 1. 环境（照抄）

```bash
sudo apt update
sudo apt install -y build-essential git python3-venv python3-pip \
                    verilator gtkwave cmake ninja-build

python3 -m venv ~/ner-venv && . ~/ner-venv/bin/activate
pip install --upgrade pip
pip install numpy torch --index-url https://download.pytorch.org/whl/cpu
pip install onnx onnxruntime pytest pyserial

git clone https://github.com/ccycyc6/QS.git ~/QS
cd ~/QS/guard && make test        # 基线必须全绿（98 单测 + 11 组仿真）再动手
```

有 GPU 的话把 torch 那行换成 `pip install torch`（cu121 索引），其余不变。

## 2. 数据（先做这个，比模型重要）

**交付 `tools/gen_ner_data.py`**：带种子、可复现地生成标注数据，输出 JSONL：

```json
{"text": "联系人张三，手机 13800138000", "spans": [[9, 6, 1], [24, 11, 0]]}
```

`spans` 每项是 `[start_byte, length_bytes, label]`，label 1=name、2=addr、0=其它 PII
（其它 PII 只做"不要误判成名字"的负样本，不用模型学）。要求：

- 姓氏表用 `host/golden/entities.py` 里那 64 个（可以直接 `from host.golden.entities import SURNAMES`）；
- 名字：`姓+1~2 字`，名字用常见字表随机拼；
- 地址：省/市/区/县 + 街道 + 门牌 + 号/栋/室，用真实地名表（含 2~3 字省市名）；
- **负样本占比 ≥ 40%**：订单号、金额、日期、页码、纯数字、含姓氏但不是人名的词（"金额""王家村""方向"）；
- **难样本**（至少 20%）：没有线索词的裸名字（`张三丰来了`）、口语地址（`那条街第三个路口东边`）、名字和数字紧邻、UTF-8 与 ASCII 混排；
- 规模：训练 ≥ 15000 句，留出 ≥ 2000 句，**难集 ≥ 1000 句**（单独文件）。

## 3. 模型（v1 的硬约束，为了将来能上板）

| 项 | 约束 |
|---|---|
| 输入 | `ids[64]` int16（字节级窗口，按 UTF-8 三字节对齐切） |
| 词表 | ≤ 4096 个"字符"（3 字节 CJK 当一个字符；ASCII 每字节一个），`<pad>=0`、`<unk>=1` |
| 结构 | Embedding(→32) + 2 层 1D 卷积（k=3，32→32，ReLU）+ 1×1 卷积（32→3）；**不要 RNN/attention** |
| 权重量化 | **INT8 per-tensor**（per-channel 也行，但要写进 `quant.json`），零点 0 |
| 激活量化 | INT8 非对称，逐层写 `scale`/`zero_point` |
| 累加 | INT32 |
| 规模 | 参数 ≤ 60k；INT8 权重 ≤ 120 KB；**每 64 字节窗口 ≤ 4M MAC** |
| 输出 | `logits[64][3]` → argmax；连续同类标签合成 span（RTL 就这么解码） |

## 4. 要交付的文件（路径固定）

```
guard/models/ner/
    config.json          # window/vocab_size/pad_id/unk_id/labels/arch
    vocab.json           # {"chars":["<pad>","<unk>","联",...]}  下标即 id
    weights_int8.npz     # 每层 int8 权重 + int32 bias（键名见下）
    quant.json           # 每层 {"w_scale":..,"a_scale_in":..,"a_scale_out":..}                            
    eval.json            # 第 5 节格式
guard/host/golden/ner.py       # 纯 numpy 整数推理（禁止 import torch/onnx）
guard/tools/train_ner.py       # 训练（--data --out --seed，可复现）
guard/tools/gen_ner_data.py    # 数据生成（第 2 节）
guard/tools/gen_ner_vectors.py # 留出集 200 例 -> build/ner_vectors/{case_XXXX.in,.exp}
guard/tests/test_ner_golden.py # 指标 / onnx==numpy / 向量可复现 / 尺寸
```

`weights_int8.npz` 的键名（RTL 生成器按名读，严格照做）：

```
emb_w     int8  [vocab, 32]
conv1_w   int8  [32, 3, 32]     # [out, kernel, in]，padding=1
conv1_b   int32 [32]
conv2_w   int8  [32, 3, 32]
conv2_b   int32 [32]
head_w    int8  [3, 32]
head_b    int32 [3]
```
## 5. `eval.json` 的格式（我会解析，字段名别改）

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

## 6. 验收门槛（我跑 `make ner-check`，全过才接 RTL）

| # | 门槛 | 判据 |
|---|---|---|
| 1 | 留出集 span F1 | **≥ 0.92**，且 P ≥ 0.95、R ≥ 0.88 |
| 2 | 难集（无线索词） | span R **≥ 0.75**，F1 ≥ 0.80 |
| 3 | numpy 整数推理与 ONNX 一致 | 500 例 argmax **完全相同**（并列取小 id） |
| 4 | 尺寸 | params ≤ 60k、int8 ≤ 120 KB、MAC/窗口 ≤ 4M |
| 5 | 可复现 | 同 seed 二次训练，`weights_sha256` 相同 |
| 6 | 向量 | `gen_ner_vectors.py` 的 200 例，`ner.py` 全对 |

**门槛 3 是重点**：`ner.py` 必须是整数推理（int8 权 + int32 累加 + 每层 `scale/zp`
重量化），不许偷偷用 float —— RTL 要的就是这条路径。

## 7. 自检（交付前必跑）

```bash
cd ~/QS/guard
make test          # 基线仍然全绿
make ner-check     # 仓库里的校验器：六条门槛逐条 PASS/FAIL
```

## 8. 交付方式

1. `git checkout -b ner-v1`，把第 4 节的文件全部提交（模型文件几 MB，直接进 git）；
2. push 分支（或 `git format-patch`）；
3. 回 Windows 时贴给我：`make ner-check` 的输出 + `guard/models/ner/eval.json`。

## 9. 明确不要做的

- ❌ 不要碰 `rtl/`（RTL 侧我按 `quant.json` 生成 ROM，两边各做一半必不一致）；
- ❌ 不要做"语义改写/隐晦表述"——v1 只做名字和地址，改写要等 M4（DDR3 + 更大 MXU）；
- ❌ 不要用 BPE/子词：板子侧是定长 64 字节窗口 + 字节级词表；
- ❌ 不要把难集并进训练集——难集只用于评估；
- ❌ 不要把 `ner.py` 写成"调用 onnxruntime"，它必须是纯 numpy 的独立实现；
- ❌ 不要改本文件和第 5 节的字段名。

## 10. 时间与优先级

| 步骤 | 预估 | 说明 |
|---|---|---|
| 数据生成器 + 抽检 | 2 天 | 先把数据做对，模型是次要的 |
| 训练 + 量化 + 整数推理 | 3 天 | 门槛 1/2/3 都在这里 |
| 向量 + 测试 | 0.5 天 | 机械活 |
| 调参补门槛 | 1~2 天 | 难集 R 最容易卡 |

如果 6 天内搞不定：**先交付能过门槛 3/4/6 的最小可用版**（哪怕 F1 只有 0.85），
我这边就能先把 RTL 通路接通，精度后面迭代。

## 11. 回到 Windows 之后我做什么

1. `make ner-check` 复跑，看六条门槛；
2. 读 `quant.json` → 生成 `build/gen/l2_ner_rom.sv`（权重 ROM）；
3. 写 `rtl/l2/l2_ner.sv`：窗口缓冲 → 卷积（走 miniTensor 的 4×4 阵列）→ argmax → span；
4. 用 `build/ner_vectors` 跑位级 TB，与 `ner.py` 逐字节对齐；
5. 接进 `l2_entity` 的位置（同一个 span 接口，type 9/10 不变），再走一遍板级回归。
