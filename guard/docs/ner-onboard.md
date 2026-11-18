# NER 上板：数据结构与流水线设计（v1 计划）

目标：把 `models/ner`（字符级 INT8 CNN，33,827 参数）跑在 PG2L200H 上，
替代现在的规则版 `l2_entity`，补齐"没有线索词的人名"（刘德华、孙悦那种）。

## 1. 已完成

| 项 | 状态 |
|---|---|
| `tools/gen_ner_rom.py` | ✅ 从 `weights_int8.npz` 导出 7 个 `.hex` + `l2_ner_rom.sv` + `ner_config.svh`（纯 Python，不依赖 numpy，Windows 能跑） |
| ROM 回读 | ✅ Verilator 逐值对比 `emb/conv1/conv2/head/bias` 全一致 |
| 构建流程 | ✅ `build_guard.ps1` 生成 ROM，`flow_guard.tcl` 已列入 `build/gen/l2_ner_rom.sv`，PDS 编译通过 |

## 2. 存储

| 表 | 大小 | 实现 |
|---|---|---|
| `emb_w` | 27,520 B（860×32） | BRAM（`$readmemh`） |
| `conv1_w` / `conv2_w` | 3,072 B 各（32×3×32） | BRAM |
| `head_w` | 96 B（3×32） | BRAM |
| bias | 32+32+3 × int32 | BRAM |
| 词表 | 858 项 × (3 B 字符 + 2 B id) | ROM，按 UTF-8 升序，二分查找 10 拍 |
| 激活 | `x/h1/h2` 各 64×32 B = 2 KB | BRAM（双口，一个写一个读） |

总计 ~40 KB → 1~2 个 DRM（板上有 415 个）。

## 3. 计算与节拍（25 MHz）

| 阶段 | 运算 | 拍数（1 MAC/拍） |
|---|---|---|
| 分词 | 64 字符 × 二分 10 拍 | ~700 |
| Embedding | 64 × 32 B 读 ROM | ~2,100 |
| conv1 | 64 × 32 × 96 | 196,608 |
| conv2 | 64 × 32 × 96 | 196,608 |
| head | 64 × 3 × 32 | 6,144 |
| argmax + span | 64 × 3 | ~300 |
| **合计** | 399,360 MAC | **~402k 拍 ≈ 16 ms/窗口** |

> 1 MAC/拍 是最省事、最容易逐位对拍的版本。并行化（32 路 = 0.5 ms）留到 v2：
> conv 的三层循环完全可并行，改成 32 个 MAC 只是把内层展开，控制不变。

## 4. 模块接口（与 `l2_entity` 完全一致，便于替换）

```systemverilog
module l2_ner (
    input  logic        clk, rst_n,
    input  logic        in_valid, in_char, in_last,
    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len,
    output logic [3:0]  out_type      // 9=name 10=addr
);
```

内部把帧切成 64 字节（字符对齐）的窗口，逐窗推理，span 在窗口内合并后输出。

## 5. 关键细节（必须照做，否则对不上金标）

1. **窗口切法**：从窗口起点贪心塞字符，直到再塞一个就超过 64 字节；窗口之间不重叠（与 `ner.py` 的 `decode_chars` 一致）；
2. **padding**：不足 64 token 补 `<pad>=0`；**卷积要算完整 64 个位置**（pad 位置也有 bias 输出），只在输出时忽略真实长度之后的位置；
3. **requant**：`y = round(acc * mul) + zp`，`mul` 见 `ner_config.svh`（`NER_CONV1_MUL` / `NER_CONV2_MUL`），zp 目前都是 0；
   板上用 16 位定点近似 `mul`：`mul ≈ m * 2^-s`，`m` 取 16 bit，误差 ≤ 1 LSB；
4. **ReLU**：`clamp(y, 0, 127)`；
5. **head 不重量化**：`logit = Σ head_w·h2 + head_b`（int32），argmax 并列取小 id；
6. **span 解码**：连续相同标签（≠0）且**字符数 ≥ 2** 才输出，长度按字节累加；
7. 标签 1→type 9、2→type 10。

## 6. 验证计划

1. `tools/gen_ner_vectors.py` 已有的 200 例（`build/ner_vectors/`）；
2. 新写 `sim/tb_l2_ner.sv`：逐例喂字节流，比对 `(start, len, type)` 与 `.exp`；
3. 与 `l2_entity` 并行跑一段（同一帧两个模块的 span 相加）做冒烟；
4. 上板后 `sample.txt --check` 期望字节数会变（NER 会多遮一些），先跑再说。

## 7. 接入方式（两步）

1. `l1_engine` 里把 `l2_entity` 换成 `l2_ner`（接口一样，span 类型一样）；
2. 保留 `l2_entity` 作为"规则兜底"：两者 span 取并集（规则优先），再进 `l1_merge`。

## 8. 还没做的

- [ ] `rtl/l2/l2_ner.sv`（主体 FSM）；
- [ ] `sim/tb_l2_ner.sv` + `make ner-sim`；
- [ ] 上板位流与吞吐测试（预估 16 ms/窗口 + 串口时间）。
