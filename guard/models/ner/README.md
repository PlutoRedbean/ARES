# guard/models/ner — 字符级 人名/地址 v3.1

纯整数、可上板的小模型：64 字节窗口 → 每个字符 0=none / 1=name / 2=addr，
连续同类标签合成 span。v3.1 只改数据和训练；模型结构、INT8 推理、64B 窗口不变。

## 1. 产物

| 文件 | 说明 |
|---|---|
| config.json | 窗口/词表/结构/尺寸（model=guard-ner-char-v3） |
| vocab.json | 3,080 项：0=<pad>、1=<unk>，其余按 name_chars + 训练字频 |
| weights_int8.npz | 7 个数组，键名/形状见下 |
| quant.json | 每张量的 scale/zp、两层 requant 的 mul |
| eval.json | 原 10 条 + unseen_names / addr_digits 两个新字段 |
| README.md | 本文件（推理配方 + v3 数据 + 尺寸冲突说明） |

weights_int8.npz：

    emb_w    int8  [3080, 32]
    conv1_w  int8  [32, 3, 32]   # [out, kernel, in]
    conv1_b  int32 [32]
    conv2_w  int8  [32, 3, 32]
    conv2_b  int32 [32]
    head_w   int8  [3, 32]
    head_b   int32 [3]

尺寸：INT8 数据 105,068 B（npz 86,037 B，门槛 120 KB）；MAC/窗口 399,360。
compute params（conv/head）6,307；总 tensor 元素 104,867。
weights sha256：1d97a87bdb3f95e42991a9322cb1ac9c0252f5085141825b5d396b3a88f894f8。

### 尺寸口径（重要）

v3 要求“名字用字表 ≥3000 汉字”。3000 × 32 = 96,000 个 embedding 元素，
加 conv/head 6,307，总元素 104,867。按字面把 embedding 算进 §4 的
“params ≤60k” 只能有 ~1,678 词，和 §12.1 冲突。本交付按硬件口径：

* size.params = 6,307（conv/head 计算权重，gate 4a 通过）；
* embedding ROM 计入 size.int8_bytes = 105,068 B（gate 4b 通过，≤120 KB）；
* config.json 同时记录 params_compute / total_tensor_elements。

如果必须“总元素 ≤60k”，需要把词表压到 1,678；3000 字与 unseen 召回会下降。

## 2. 窗口 / 分词 / span

* 窗口是 64 UTF-8 字节，按字符边界切；ids[64] 最多 64 token，其余补 <pad>=0。
* 一个字符 = 一个 token；ASCII 一个字节 = 一个 token。
* 推理时喂满 64 个 token；pad 行 embedding 是 0，但 conv bias 仍会让 pad 位置
  产生非零 h1/h2；上板时算完 64 个位置，忽略真实长度之后的输出。
* 解码：argmax（并列取小 id）得到 0/1/2，连续同类且非 0 的 run 合成 span，
  长度按字节累加。
* span type 映射：模型内部 1/2 → 流水线 9(name)/10(addr)。
* decode(bytes) 返回 (type, start_byte, len_byte)。

## 3. 量化与逐行推理

* 权重：per-tensor INT8 对称，zp=0，范围 [-127,127]；bias 折进 INT32。
* 激活：INT8 非对称；h1/h2 是 ReLU 后标定，zp1=zp2=0。
* 累加 INT32；round 必须 round-half-even（numpy rint / ONNX Round）。
* head 1x1 只做 INT32 累加；head_b 已按 s_head_w * s_h2 折好。
* 本版乘子：
  mul1=0.0010241935483870969、mul2=0.0017447451573018272；
  s_h1=0.041876753402583115、s_h2=0.18269899486639632。
* 配方：

    x        = emb_w[ids]
    h1[i][o] = clamp(requant(sum conv1_w[o][k][ci]*x[i+k-1][ci] + conv1_b[o], mul1, zp1), 0, 127)
    h2[i][o] = clamp(requant(sum conv2_w[o][k][ci]*h1[i+k-1][ci] + conv2_b[o], mul2, zp2), 0, 127)
    logit[c][i] = sum head_w[c][o]*h2[i][o] + head_b[c]
    label[i]    = argmax_c logit[c][i]

越界补 0（padding=1）。

## 4. v3 数据（v3.1 又加了两类上下文）

data/ner/（随分支提交，seed=20261118）：

| 文件 | 规模 | 说明 |
|---|---|---|
| train.jsonl | 79,998 行 | **139,871 个不同全名**；散文 35.63%；含数字地址 70.92% |
| heldout.jsonl | 2,600 | 同分布留出 |
| hard.jsonl | 1,600 | 只评估 |
| unseen_names.jsonl | 600 | 训练没出现过的全名（0 overlap） |
| addr_digits.jsonl | 600 | 含门牌号的地址 |
| prose.jsonl | 400 | 固定散文集（仓库自带，未修改，也不进训练） |
| name_chars.txt | 3,000 字 | v3 名字用字表 |

v3/v3.1 新增：

* 名字用字表 3,000：2,270 个来自 120 万中文人名语料的用字 + 730 个常用补字
  （tools/name_chars.py）；
* 12 万不同全名：24,000 行 × 每行 5 个名字，三字名占多数；
* 2,000 个真人风格名：常见姓 + 公开统计里的常见名字部分，不与 12 万名字重复；
* v3.1 额外 4,000 行 name_ctx：名字末字故意取 问/在/回/说/去/好/是/时 等
  也像边界词的字，后接 的演唱会/说/问/在楼下/很忙，专门修“名字少最后一个字”；
* v3.1 额外 1,000 行 addr_start：地址从字符串开头出现（X号/栋/单元/室），
  修“地址首字丢掉”；
* 地址：X号 / X栋X号 / X号楼X单元X室 / X层，整段（含数字）连续标 2；
* 保留 v2 的散文负样本、边界、复姓、称谓、陷阱、难集。

## 5. 训练 / 评估 / 复现

    cd guard
    python3 tools/gen_ner_data.py --out data/ner --seed 20261118
    python3 tools/train_ner.py --data data/ner --out models/ner --seed 20261118
    python3 tools/gen_ner_vectors.py --data data/ner --out build/ner_vectors --n 200
    make ner-check

16 epoch，CPU 约 170 s；同 seed 重训 weights sha256 完全一致。
tools/ner_onnx.py 导出 ConvInteger/Round/ArgMax 整数图，500 例逐 token 对拍。

## 6. 本轮指标

| 集合 | P | R | F1 | TP/FP/FN |
|---|---|---|---|---|
| heldout 2,600 | 0.996475 | 0.995473 | 0.995974 | 1979 / 7 / 9 |
| hard 1,600 | 0.997018 | 0.997018 | 0.997018 | 1672 / 5 / 5 |

* gate 3：numpy == ONNX 500/500
* gate 4：params 6,307（compute）、INT8 105,068 B、MAC 399,360
* gate 5：同 seed 重训 sha256 一致
* gate 6：200 例向量 0 错
* gate 7：prose 400 句多报 0（0.000 <= 0.05）
* gate 8：证据集 5/7（>=5；两句固定期望值字节算错，理论上限 5/7）
* gate 9：unseen_names 600 例召回 **1.000**（600/600，>=0.95）
* gate 10：addr_digits 600 例整段命中 **1.000**（600/600，>=0.98）
* gate 11：马嘉祺 / 周杰伦 / 欧阳娜娜 / 司马相如 **4/4**

### gate 8 的 5/7

两句的期望 span 本身字节错误，模型无法正确又匹配：

1. 收件人欧阳娜娜…：期望 name (9,12,12) 实际切片是“阳娜娜，”；地址期望 33 字节，
   实际 32；且整句 65B 跨 64B 窗口，按非重叠窗口必然切段。
2. 我住在中关村大街27号：期望地址长度 24，实际 20 字节。

所以 7 句证据集最多 5/7。gate 9/10/11 是单独的真实评估集。

## 7. 已知限制 / RTL 注意

1. 3000 字 embedding ROM 96,000 B，加 conv/head 共 105,068 B；60k 是 compute
   params 口径，详见 §1。
2. 窗口按 64 字节（字符对齐），ids 最多 64 token；>64B 的地址跨窗口会切断
   （证据集第一句 65B 就是例子）。
3. round-half-even：RTL 定点乘法必须和 numpy rint 一致；先用 200 例向量对拍。
4. 只有 name/addr 两类；其它 PII 仍由 L1 规则层处理。
5. hard 集仍有 5 FP/5 FN：主要是名字末字 去/回/刚 和复姓边界，留给下一轮数据微调。
6. addr_digits 已 600/600；但跨 64B 窗口的超长地址仍会切成两段。
