# L2 INT4 语义层（用 miniTensor 的 MXU）

> 目的：给 L1 规则层补"**上下文语义**"——同一个 18 位数字，前面写着"身份证"还是
> 写着"订单号"，含义完全不同。L1 只看校验位/结构，L2 看上下文。
>
> 这一层**真的用到了 vendor/minitensor**：矩阵乘就是它的 4×4 INT8 脉动阵列
> （`tensor_gemm_core` → `tensor_systolic_array` → 16 个 `tensor_pe`），不是另写的。

## 1. 做什么

输入字节流 → 每个数字游程给一个类别：

| class | 含义 | 例子 |
|---|---|---|
| 0 | none | `号码 330203300422240391`（前面没有 PII 关键词） |
| 1 | id18 | `身份证 330203300422240391`（哪怕校验位是错的） |
| 2 | bank | `银行卡 6222020000000000001` |
| 3 | mobile | `手机号 13800138000` |

**分数是学出来的权重**，不是 if-else：8 个特征 × INT4 权重 → 4 个类别的点积。

## 2. 特征（INT8）与权重（INT4）

| # | 特征 | 说明 |
|---|---|---|
| f0..f3 | 窗口内出现过 身份证 / 银行卡 / 手机号 / 其它 PII 关键词 | 0/1 |
| f4 | 关键词结束到游程开始的距离档 | 0(≤2) 1(≤5) 2(≤12) 3(更远) |
| f5 | 游程 11..19 位 | 0/1 |
| f6 | 前一个字节是 `:` 或 `=` | 0/1 |
| f7 | 偏置 | 恒 1 |

权重（`W4`，-8..7，打包进 A 矩阵时符号扩展到 INT8，即 **W4A8**）：

```
         k_id k_bank k_mob k_other dist len colon bias
none   [   0,     0,    0,     0,     0,   0,   0,   2]
id18   [   6,    -6,   -6,    -6,    -2,   1,   0,   0]
bank   [  -6,     6,   -6,    -6,    -2,   1,   0,   0]
mobile [  -6,    -6,    6,    -6,    -2,   1,   0,   0]
```

直觉：关键词给对应类别 +6；距离越远扣得越多（`-2×档`），远到 3 档时只剩 1 分、
低于 none 的 2 分 → 判 none。

## 3. 怎么用 miniTensor

```
l2_semantic_top
├── l1_keyword_match          关键词窗口（L1 复用）
├── l2_features               8 个 INT8 特征
└── l2_int4_gemm
    └── tensor_gemm_core      ← miniTensor 的 MXU（4×4 INT8 阵列 + 自己的 FSM）
```

K=8 超过阵列的 K=4，所以做**两次 GEMM 并串联 acc**：

```
C1 = W[:,0:4] · x[0:4]
C2 = W[:,4:8] · x[4:8] + C1     ← acc_init 就是 C1
y_c = C2[c][0]                  ← 四列相同，取第 0 列
class = argmax(y)，全非正 → none
```

一次推理约 24 个核心时钟（两次 10 拍 GEMM + 握手）。

## 4. 验证与数字

```
make l2-vectors    # 金标生成 12 例 / 14 个游程
make l2-sim        # Verilator 位级仿真，与金标逐个游程比对 class + span
```

- 金标：`host/golden/l2_int4.py`（`scores/classify/features_from_hits/semantic_scan`）
- RTL 与金标**同一套权重、同一套整数运算**；`make test` 里跑（12 例 0 错）
- 单元测试：`tests/test_l2_int4.py`（权重范围、关键词→类别、窗口边界、无命中）

综合（`fpga/pango/flow_l2.tcl`，PG2L200H，25 MHz）：

| 资源 | 用量 |
|---|---|
| LUT | **889**（0.56%） |
| FF | **954**（0.30%） |
| APM / DRM | 0 / 0（8×8 乘法走 LUT） |
| WNS | **+30.3 ns**（路径 ≈9.7 ns，远快于 25 MHz） |

## 5. 还没做

1. ~~没接进板级位流~~（2026-11-17 已接）：`l2_semantic_top` 与 L1 并行挂在同一字符流上，
   摘要行加 `l2=`（判成 PII 的游程数）/`l2m=`（类别位图，bit1=id18 bit2=bank bit3=mobile）。
   整板 4,749 LUT / 2,947 FF / WNS +4.7 ns；板上 `sample.txt --check` **PASS 1334 B**，
   实测 `身份证 …卡… 手机号 …` 一帧 → `l2=3 l2m=14`，无关键词 → `l2=0`。
2. **特征只有 8 个、权重是手调的**：还没训练。要真"学"，下一步是
   用 `host/corpus` 标注数据训一个小线性模型，导出 INT4 权重直接替换这张表。
3. **没有 DDR3 / 大模型**：现在的 MXU 用量 889 LUT，离"跑 0.5B"差三个数量级；
   miniTensor 的 UB/DMA/controller 还没用上（那是 M3 后续）。

## 6. 复现

```bash
cd guard
make l2-vectors l2-sim         # 功能
# 面积/时序（Windows + PDS）：
pds_shell -file fpga/pango/flow_l2.tcl -project_name l2_res
```