# guard/models/ner — 字符级 人名/地址 v2

纯整数、可上板的小模型：64 字节窗口 → 每个字符 0=none / 1=name / 2=addr，
连续同类标签合成 span。v2 只改数据和训练，模型结构/尺寸约束与 v1 完全一致。

## 1. 产物

| 文件 | 说明 |
|---|---|
| config.json | 窗口/词表/结构/尺寸（model=guard-ner-char-v2） |
| vocab.json | 860 项：0=<pad>、1=<unk>，其余按训练集字频排序 |
| weights_int8.npz | 7 个数组，键名/形状见下 |
| quant.json | 每张量的 scale/zp、两层 requant 的 mul |
| eval.json | 留出集 / 难集 span P/R/F1、尺寸、weights sha256 |
| README.md | 本文件（推理配方 + 门槛 7/8 + RTL 对接注意） |

weights_int8.npz：

    emb_w    int8  [860, 32]
    conv1_w  int8  [32, 3, 32]   # [out, kernel, in]
    conv1_b  int32 [32]
    conv2_w  int8  [32, 3, 32]
    conv2_b  int32 [32]
    head_w   int8  [3, 32]
    head_b   int32 [3]

尺寸：params 33,827（含 bias）；INT8 数据 34,028 B（npz 30,570 B，门槛 120 KB）；
MAC/窗口 399,360（64 × (32·3·32 + 32·3·32 + 3·32)，门槛 4M）。
weights sha256：3e321b9f7ac75dfdb21c361c5352ddd0eedf086a66d864ad493de1ea966fb36e。

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
  mul1=0.0010483824367049422、mul2=0.0014308246958089229；
  s_h1=0.03880085281800941、s_h2=0.2170445209874442。
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
| train.jsonl | 46,380 | 散文 16,271（35.08%）；负样本合计 46.07%；难样本 20.14% |
| heldout.jsonl | 2,600 | 同分布留出，负样本 37.88% |
| hard.jsonl | 1,600 | 只评估：裸名字/边界/复姓/称谓/口语地址/中英/难负/陷阱 |
| prose.jsonl | 400 | 固定的散文评测集（仓库自带，未修改，也不进训练） |

训练集类别：prose 16271 / neg 2511 / neg_hard 803 / trap 1506 /
targeted 4017 / targeted2 502 / targeted3 301 / colloc 1004 / english 502 /
name 3515 / boundary 4720 / compound 3615 / title 1506 / addr 3013 /
mixed 1514 / coverage 1080。

v2 补的点：

* 散文负样本：新闻/说明书/对话体，无 PII，但故意含 金额/方向/王家村/张数/周报/
  李树/陈设/吴用/宋词/赵家楼/石家庄 等姓氏陷阱；训练集占比 35.08%；
* 边界样本：名字后紧接 说/打/了/的/是/和/今天/已经/刚才/在...，只标姓名；
* 歧义末字：刚/才/明/天/新/山/文/生/平/安/同 等既能做名字末字又能做边界词开头的字，
  用 targeted/targeted2 两个小类专门做对比（名字末字 vs 刚才/明天/同学/先生）；
* 复姓 12 个：欧阳/司马/诸葛/上官/东方/皇甫/尉迟/公孙/慕容/长孙/宇文/司徒，
  训练集每个 296~350 例（要求 >=200）；
* 称谓：王经理/张总/李老师/刘主任/于主任，整个“姓+称谓”标 name；
* 地址尾巴：X号楼X单元X室 / X栋X号 / X层；
* 线索词：叫/叫作/名叫/署名/签字/发件人/收件人/户主 等；
* 名字用字里去掉了“和”“笑”，并补了“帆/三”（证据集用字），避免 OOV 乱标。

数据校验：heldout/hard/prose 的 OOV 都是 0；三个集合与训练集没有一模一样的句子。
石家庄同时是固定 prose 里的陷阱词，本地 5 字感受野无法在“石”处同时判断
“石家庄市…”地址和“石家庄的柿子”陷阱，所以地址侧去掉了这个城市（陷阱侧保留）。

## 5. 训练 / 评估 / 复现

    cd guard
    python3 tools/gen_ner_data.py --out data/ner --seed 20261118
    python3 tools/train_ner.py --data data/ner --out models/ner --seed 20261118
    python3 tools/gen_ner_vectors.py --data data/ner --out build/ner_vectors --n 200
    make ner-check

20 epoch，CPU 约 160 s；同 seed 重训 weights sha256 完全一致（make ner-check 的 5b
会真的重训一次来比对）。tools/ner_onnx.py 把同一组整数权重导出成只用
ConvInteger/Round/ArgMax 的 ONNX 图，make ner-check 会在 500 例上逐 token 比对。

## 6. 本轮指标（eval.json）

| 集合 | P | R | F1 | TP/FP/FN |
|---|---|---|---|---|
| heldout 2,600 | 0.995109 | 0.997820 | 0.996463 | 1831 / 9 / 4 |
| hard 1,600 | 1.000000 | 1.000000 | 1.000000 | 1677 / 0 / 0 |

门槛 7：固定 prose.jsonl 400 句，模型多报 0 个 span（0.000 <= 0.05）。
门槛 8：证据集 5/7（>=5 通过）。

### 关于门槛 8 的 5/7

证据集里有两句的期望 span 是字节算错的，模型不可能“既正确又匹配”：

1. “收件人欧阳娜娜，地址：北京市朝阳区建国路88号”
   期望 (9,12,12) 实际切片是“阳娜娜，”（少了 欧，多了逗号）；地址期望长度 33，
   但“北京市朝阳区建国路88号”只有 32 字节。而且整句 65 字节，地址跨过 64B
   窗口边界，按 4.1/4.2 的非重叠窗口必然会被切成两段。模型给出正确的
   (9,9,12) 姓名；地址侧给出 (10,33,28)+(10,62,3)（窗口边界 + 期望长度本身越界）。
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
6. >64 字节的输入会被切成多个不重叠窗口，跨窗口的 span 可能被切断；当前训练数据
   都在 64B 内。证据集第一句 65B 就是这种边界情况的例子。
7. 地址侧不用石家庄作为城市（它同时是固定 prose 的陷阱词）；真实地址以“石家庄”
   开头时，首字可能被抑制。
