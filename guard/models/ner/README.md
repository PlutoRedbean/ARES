# models/ner —— 交付格式（`docs/model-route-ubuntu.md` 的补充）

这里放 Ubuntu 侧交付的模型。**不要手改这个目录里的文件**，它们是 `tools/train_ner.py` 的产物。

## 推理配方（`host/golden/ner.py` 必须严格照这个写）

```
ids[64]        int16，<pad>=0 <unk>=1
x              = emb_w[ids]                       # int8，值域 [-128,127]
h1[o][i]       = clamp(requant(sum_{k,ci} conv1_w[o][k][ci] * x[i+k-1][ci],
                        s1_mul, z1), -128, 127)   # padding=1，越界补 0
h1             = relu(h1)                        # 即 clamp(y, 0, 127)
h2[o][i]       = clamp(requant(sum_{k,ci} conv2_w[o][k][ci] * h1[i+k-1][ci],
                        s2_mul, z2), -128, 127)
h2             = relu(h2)
logits[c][i]   = sum_o head_w[c][o] * h2[o][i] + head_b[c]   # int32，不重量化
label[i]       = argmax_c logits[c][i]           # 并列取小的 c
```

`requant(acc, mul, zp) = round(acc * mul) + zp`，`mul`/`zp` 逐层来自 `quant.json`，
`mul = (w_scale * a_scale_in) / a_scale_out`。

**RTL 侧**会把 `mul` 换成一个 16 位定点乘数 + 移位，允许 ±1 LSB 的重量化误差；
验收只比 **span 是否完全一致**（argmax 级），不比中间值。

## span 解码

```
把 label[i] 相同的连续位置合成一个 span：
  label==1 -> type 9  (name)
  label==2 -> type 10 (addr)
  长度 = 该段覆盖的**字节数**（label 是按 UTF-8 字符对齐的，累加字符的字节长度）
```

## 文件

| 文件 | 内容 |
|---|---|
| `config.json` | `window`/`vocab_size`/`pad_id`/`unk_id`/`labels`/`arch` |
| `vocab.json` | `{"chars": [...]}`，下标即 id |
| `weights_int8.npz` | `emb_w` `conv1_w` `conv1_b` `conv2_w` `conv2_b` `head_w` `head_b` |
| `quant.json` | `{"layers":[{"name":"conv1","w_scale":..,"a_scale_in":..,"a_scale_out":..,"zp_out":..}, ...]}` |
| `eval.json` | 指标 + 尺寸 + 权重 sha256（格式见交接单第 5 节） |

## 自检

```bash
cd guard && make ner-check     # 六条门槛逐条 PASS/FAIL
```
