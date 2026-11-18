# guard/models/ner — 字符级 人名/地址 v2

纯整数、可上板的小模型：64 字节窗口 → 每个字符 0=none / 1=name / 2=addr，
连续同类标签合成 span。v2 只改数据和训练，模型结构/尺寸约束与 v1 完全一致。

## 1. 产物

| 文件 | 说明 |
|---|---|
| config.json | 窗口/词表/结构/尺寸（model=guard-ner-char-v2） |
| vocab.json | 845 项：0=<pad>、1=<unk>，其余按训练集字频排序 |
| weights_int8.npz | 7 个数组，键名/形状见下 |
| quant.json | 每张量的 scale/zp、两层 requant 的 mul |
| eval.json | 留出集 / 难集 span P/R/F1、尺寸、weights sha256 |
| README.md | 本文件（推理配方 + 门槛 7/8 + RTL 对接注意） |

weights_int8.npz：

    emb_w    int8  [845, 32]
    conv1_w  int8  [32, 3, 32]   # [out, kernel, in]
    conv1_b  int32 [32]
    conv2_w  int8  [32, 3, 32]
    conv2_b  int32 [32]
    head_w   int8  [3, 32]
    head_b   int32 [3]

尺寸：params 33,347（含 bias）；INT8 数据 33,548 B（npz 30,975 B，门槛 120 KB）；
MAC/窗口 399,360（64 × (32·3·32 + 32·3·32 + 3·32)，门槛 4M）。
weights sha256：6c134caf53e0f8e6994a71ffd24815f402a7ca084bc0576cc632080bfcc1992f。

## 2. 窗口 / 分词 / span

* 窗口是 64 UTF-8 字节，按字符边界切（CJK 一个字符占 3 字节，不劈开）；
  ids[64] 是 token 上限，ASCII 最坏情况刚好 64 项，CJK 约 21 项，其余补 <pad>=0。
* 一个字符 = 一个 token；ASCII 一个字节 = 一个 token。
* 推理时喂满 64 个 token。pad 行 embedding 是 0，但 conv 的 bias 仍会让 pad 位置产生
  非零 h1/h2；上板时照常算完 64 个位置，忽略真实长度之后的输出，不要提前截断卷积。
* 解码：每个位置 argmax（并列取小 id）得到 0/1/2，连续同类且非 0 的 run 合成 span，
  长度按字节累加。
* span type 映射：模型内部 1/2 → 流水线的 9(name)/10(addr)，见 host/golden/ner.py 的
  TYPE_OF_LABEL。check_ner.py、.exp 向量、l2_entity 全部用 9/10。
* host/golden/ner.py 的 decode(bytes) 返回 (type, start_byte, len_byte)，type 9=name、10=addr。

## 3. 量化与逐行推理

* 权重：per-tensor INT8 对称，zp=0，范围取 [-127,127]；bias 折进 INT32：
  b_int = round(b_float / (w_scale * a_in))。
* 激活：INT8 非对称。h1/h2 是 ReLU 之后标定的，min=0，所以 zp1=zp2=0；
  公式本身仍是 requant(acc,mul,zp)=round(acc*mul)+zp，mul=(w_scale*a_in)/a_out。
* 累加全程 INT32；round 必须 round-half-even（和 numpy rint / ONNX Round 一致）。
* head 的 1x1 卷积只做 INT32 累加，不重量化；head_b 已按 s_head_w * s_h2 折好。
* 本版乘子（quant.json）：
  mul1=0.0010285732797719323、mul2=0.0009992603899475977；
  s_h1=0.026642358920610575、s_h2=0.16937332342988667。
* 配方（与 docs 4.2 逐行一致）：

    x        = emb_w[ids]
    h1[i][o] = clamp(requant(sum conv1_w[o][k][ci]*x[i+k-1][ci] + conv1_b[o], mul1, zp1), 0, 127)
    h2[i][o] = clamp(requant(sum conv2_w[o][k][ci]*h1[i+k-1][ci] + conv2_b[o], mul2, zp2), 0, 127)
    logit[c][i] = sum head_w[c][o]*h2[i][o] + head_b[c]
    label[i]    = argmax_c logit[c][i]

越界补 0（padding=1）。

## 4. 数据（v2 的核心改动）

data/ner/（随分支提交，seed=20261118，所有句子 <= 64 UTF-8 字节）：

| 文件 | 句数 | 说明 |
|---|---|---|
| train.jsonl | 35,658 | 散文 13,000（36.46%）；负样本合计 50.34%；难样本 20.75% |
| heldout.jsonl | 2,600 | 同分布留出，负样本 39.88% |
| hard.jsonl | 1,600 | 只评估：裸名字/边界/复姓/称谓/口语地址/中英/难负/陷阱 |
| prose.jsonl | 400 | 固定的散文评测集（仓库自带，未修改，也不进训练） |

训练集类别：prose 13000 / neg 2500 / neg_hard 800 / trap 1500 / colloc 800 /
english 500 / name 3500 / boundary 3000 / compound 3600 / title 1500 /
addr 3000 / mixed 1500 / coverage 458。

v2 补的点：

* 散文负样本：新闻/说明书/对话体，无 PII，但故意含 金额/方向/王家村/张数/周报/
  李树/陈设/吴用/宋词/石家庄 等姓氏陷阱；训练集占比 36.46%；
* 边界样本：名字后紧接 说/打/了/的/是/和/今天/已经...，只标姓名；两个名字用
  和/与/跟 连接时，连词明确标 0；
* 复姓 12 个：欧阳/司马/诸葛/上官/东方/皇甫/尉迟/公孙/慕容/长孙/宇文/司徒，
  训练集每个 266~351 例（要求 >=200）；
* 称谓：王经理/张总/李老师/刘主任/陈医生，整个“姓+称谓”标 name；
* 地址尾巴：X号楼X单元X室 / X栋X号 / X层；
* 线索词：叫/叫作/名叫/署名/签字/发件人/收件人/户主 等；
* 名字用字里去掉了“和”“笑”：前者是连词，后者是边界动词，避免 李雷和韩梅梅 /
  金慧璐笑 被并成一个名字。

数据校验：heldout/hard/prose 的 OOV 都是 0；heldout/hard/prose 与训练集没有
一模一样的句子。名字实体 13.65% 在训练集出现过，地址实体 19.6%；hard 的口语地址
短语池有限，重叠较多，但都是无线索裸上下文。

## 5. 训练 / 评估 / 复现

    cd guard
    python3 tools/gen_ner_data.py --out data/ner --seed 20261118
    python3 tools/train_ner.py --data data/ner --out models/ner --seed 20261118
    python3 tools/gen_ner_vectors.py --data data/ner --out build/ner_vectors --n 200
    make ner-check

20 epoch，CPU 约 94 s；同 seed 重训 weights sha256 完全一致（make ner-check 的 5b
会真的重训一次来比对）。tools/ner_onnx.py 把同一组整数权重导出成只用
ConvInteger/Round/ArgMax 的 ONNX 图，make ner-check 会在 500 例上逐 token 比对。

## 6. 本轮指标（eval.json）

| 集合 | P | R | F1 | TP/FP/FN |
|---|---|---|---|---|
| heldout 2,600 | 0.996029 | 0.997161 | 0.996595 | 1756 / 7 / 5 |
| hard 1,600 | 0.984588 | 0.985757 | 0.985172 | 1661 / 26 / 24 |

门槛 7：固定 prose.jsonl 400 句，模型多报 0 个 span（0.000 <= 0.05）。
门槛 8：证据集 5/7（>=5 通过）。

### 关于门槛 8 的 5/7

证据集里有两句的期望 span 是字节算错的，模型不可能既正确又匹配：

1. “收件人欧阳娜娜，地址：北京市朝阳区建国路88号”
   期望 (9,12,12) 实际切片是“阳娜娜，”（少了 欧，多了逗号）；地址期望长度 33，
   但“北京市朝阳区建国路88号”只有 32 字节。模型输出 (9,9,12)+(10,33,32)，
   即正确的“欧阳娜娜”和完整地址。
2. “我住在中关村大街27号”
   期望地址长度 24，但“中关村大街27号”是 20 字节（5 个 CJK=15，27=2，号=3）。
   模型输出 (10,9,20)，即完整地址。

因此 7 句证据集的理论上限是 5/7；另外 5 句（张三 / 王经理 / 刘德华 / 杨帆 /
陈静）全部完全正确。check_ner.py 的判据是 >=5，已通过。

## 7. 已知限制 / 给 RTL 的注意事项

1. 窗口语义：本实现按“64 字节 = 一个窗口，ids 最多 64 token”做。如果 RTL 想按
   64 个字符切（192 字节），模型输出会变；请以本 README 和 ner.py 为准。
2. round-half-even：mul 是浮点乘子。RTL 若用定点乘法近似，必须保证舍入方向和
   half-even 一致，否则逐 token 对齐会挂。先用 ner.py 的 200 例向量逐位对拍。
3. 只在名字/地址两类上训练；其它 PII 一律是 0（L1 规则层负责）。
4. 训练数据是合成的，省市/区/街道是随机组合，地理上不一定自洽；字符级模型不依赖这一点。
5. OOV 字符映射到 <unk>；当前 heldout/hard/prose 的 OOV 都是 0。
6. >64 字节的输入会被切成多个不重叠窗口，跨窗口的 span 可能被切断；当前数据都在 64B 内。
7. 仍然会错的场景：姓氏+连词/复姓多字名偶尔并错（如 朱新蕾， 被标成 新蕾），
   口语地址在窗口边界处偶尔少/多一个“在”字；这些不影响 1/2/7/8 门槛，但接遮罩前
   建议用 tools/eval_ner.py 再扫一遍真实语料。
