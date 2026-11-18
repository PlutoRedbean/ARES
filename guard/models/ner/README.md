# guard/models/ner — 字符级 人名/地址 v1

纯整数、可上板的小模型：64 字节窗口 → 每个字符 0=none / 1=name / 2=addr，
连续同类标签合成 span。训练脚本、数据、量化参数、金标推理都在这个提交里。

## 1. 产物

| 文件 | 说明 |
|---|---|
| config.json | 窗口/词表/结构/尺寸 |
| vocab.json | 703 项：0=<pad>、1=<unk>，其余按训练集字频排序 |
| weights_int8.npz | 7 个数组，键名/形状见下 |
| quant.json | 每张量的 scale/zp、两层 requant 的 mul |
| eval.json | 留出集 / 难集 span P/R/F1、尺寸、weights sha256 |
| README.md | 本文件（推理配方 + RTL 对接注意） |

weights_int8.npz（严格按 docs/ubuntu-ner.md 4.1）：

    emb_w    int8  [703, 32]
    conv1_w  int8  [32, 3, 32]   # [out, kernel, in]
    conv1_b  int32 [32]
    conv2_w  int8  [32, 3, 32]
    conv2_b  int32 [32]
    head_w   int8  [3, 32]
    head_b   int32 [3]

尺寸：params 28,803（含 bias）；INT8 数据 29,004 B（npz 26,253 B，门槛 120 KB）；
MAC/窗口 399,360（64 × (32·3·32 + 32·3·32 + 3·32)，门槛 4M）。
weights sha256：3297a12910fa6636e549a9d6e8eb1c35385935cf3c2d6533942378f8cd36f0d3。

## 2. 窗口 / 分词 / span

* 窗口是 64 UTF-8 字节，按字符边界切（CJK 一个字符占 3 字节，不劈开）；
  ids[64] 是 token 上限，ASCII 最坏情况刚好 64 项，CJK 约 21 项，其余补 <pad>=0。
* 一个字符 = 一个 token；ASCII 一个字节 = 一个 token。词表 703 项（远小于 4096）。
* 推理时喂满 64 个 token（pad 行 embedding 是 0，但 conv 的 bias 仍会让 pad 位置产生
  非零 h1/h2）。上板时不要提前截断卷积，否则句尾 1~2 个字符的标签会和金标不一致；
  照常算完 64 个位置，只要忽略真实长度之后的输出即可。
* 解码：每个位置 argmax（并列取小 id）得到 0/1/2，连续同类且非 0 的 run 合成 span，
  长度按字节累加。
* host/golden/ner.py 的 decode(bytes) 返回 (label, start_byte, len_byte) 三元组
  （tools/check_ner.py 的约定；.exp 文件里是 start len label）。

## 3. 量化与逐行推理

* 权重：per-tensor INT8 对称，zp=0，范围取 [-127,127]；bias 折进 INT32：
  b_int = round(b_float / (w_scale * a_in))。
* 激活：INT8 非对称。h1/h2 是 ReLU 之后标定的，min=0，所以 zp1=zp2=0；
  公式本身仍是 requant(acc,mul,zp)=round(acc*mul)+zp，mul=(w_scale*a_in)/a_out。
* 累加全程 INT32；round 必须 round-half-even（和 numpy rint / ONNX Round 一致）。
* head 的 1×1 卷积只做 INT32 累加，不重量化；head_b 已按 s_head_w * s_h2 折好。
* 具体乘子（quant.json）：
  mul1=0.0013078760916131159、mul2=0.0014623754965743569；
  s_h1=0.02695917517617668、s_h2=0.15297656791685957。
* 配方（与 docs 4.2 逐行一致）：

    x        = emb_w[ids]
    h1[i][o] = clamp(requant(sum conv1_w[o][k][ci]*x[i+k-1][ci] + conv1_b[o], mul1, zp1), 0, 127)
    h2[i][o] = clamp(requant(sum conv2_w[o][k][ci]*h1[i+k-1][ci] + conv2_b[o], mul2, zp2), 0, 127)
    logit[c][i] = sum head_w[c][o]*h2[i][o] + head_b[c]
    label[i]    = argmax_c logit[c][i]

越界补 0（padding=1）。

## 4. 数据

data/ner/（随分支提交，seed=20261118）：

| 文件 | 句数 | 说明 |
|---|---|---|
| train.jsonl | 15,000 | 负样本 40.67%；难样本（裸名字/口语地址/中英/难负）26.67% |
| heldout.jsonl | 2,000 | 同分布留出，负样本 40% |
| hard.jsonl | 1,000 | 只评估：裸名字 550 / 口语地址 250 / 中英混排 100 / 难负 100 |
| manifest.json | — | 规模、比例、字符覆盖、OOV=0 |

所有句子按 UTF-8 字节 <= 64 生成（最长 34 个字符），正好一个窗口。
难集与训练集无一模一样的句子；名字实体只有 3.8% 在训练集出现过，地址实体 0.6%。
口语地址的构件池有限，hard 里的短语组合和 train 有重叠，但都是无线索裸出现的上下文，
衡量的是 no-cue 边界识别，不是未见短语泛化。

## 5. 训练 / 评估 / 复现

    cd guard
    python3 tools/gen_ner_data.py --out data/ner --seed 20261118
    python3 tools/train_ner.py --data data/ner --out models/ner --seed 20261118
    python3 tools/gen_ner_vectors.py --data data/ner --out build/ner_vectors --n 200
    make ner-check

训练 18 epoch，CPU 约 36 s；同 seed 重训 weights sha256 完全一致
（make ner-check 的 5b 会真的重训一次来比对）。
tools/ner_onnx.py 把同一组整数权重导出成只用 ConvInteger/Round/ArgMax 的 ONNX 图，
make ner-check 会在 500 例上逐 token 比对 numpy 与 ONNXRuntime。

## 6. 本轮指标（eval.json）

| 集合 | P | R | F1 | TP/FP/FN |
|---|---|---|---|---|
| heldout 2,000 | 0.990769 | 0.996133 | 0.993444 | 1288 / 12 / 5 |
| hard 1,000 | 0.990099 | 0.990099 | 0.990099 | 1100 / 11 / 11 |

名字 F1 0.9967（heldout）/ 0.9875（hard）；地址 F1 0.9889 / 0.9957。
六条门槛全部 PASS：F1>=0.92、P>=0.95、R>=0.88、hard R>=0.75/F1>=0.80、
numpy==ONNX 500/500、params/INT8/MAC 达标、同 seed 复现、200 例向量 0 错。

## 7. 已知限制 / 给 RTL 的注意事项

1. 窗口语义：本实现按“64 字节 = 一个窗口，ids 最多 64 token”做。如果 RTL 想按
   64 个字符切（192 字节），模型输出会变；请以本 README 和 ner.py 为准。
2. round-half-even：mul 是浮点乘子。RTL 若用定点乘法近似，必须保证舍入方向和
   half-even 一致，否则逐 token 对齐会挂。建议先用 ner.py 的 200 例向量逐位对拍。
3. 只在名字/地址两类上训练；其它 PII 一律是 0（L1 规则层负责）。
4. 训练数据是合成的，省市/区/街道是随机组合，地理上不一定自洽；字符级模型不依赖这一点。
5. OOV 字符映射到 <unk>；当前 heldout/hard 的 OOV 都是 0。
6. >64 字节的输入会被切成多个不重叠窗口，跨窗口的 span 可能被切断；当前数据都在 64B 内。
