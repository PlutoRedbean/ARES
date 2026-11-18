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

权重（`W4`，-8..7）**不再是手调的**：由 [tools/train_l2.py](../tools/train_l2.py)
在带标签样本上训练、量化到 INT4、再用整数坐标下降微调到 RTL 的精确语义，最后由
[tools/gen_l2_weights_sv.py](../tools/gen_l2_weights_sv.py) 生成
`build/gen/l2_weights_pkg.sv`（金标与 RTL 共用同一张表）。

当前这张表（4000 训练 / 2000 留出，INT4 量化后 **train 1.000 / holdout 1.000**）：

```
         k_id k_bank k_mob k_other dist len colon bias
none   [   0,     0,    0,     1,     2,  -5,   0,   3]
id18   [   4,    -2,   -2,     0,    -1,   2,   0,  -1]
bank   [  -2,     4,   -2,     0,    -1,   2,   0,  -1]
mobile [  -2,    -2,    4,     0,    -1,   2,   0,  -1]
```

模型自己学出来的三条规律：

1. **位数是硬门**：`len` 列 none 给 −5、PII 类给 +2 —— 短数字（<11 位）再靠近关键词也判 none，
   这和 L1 兜底的"11..19 位才认"一致；
2. **关键词定类型**：k_id/k_bank/k_mob 在各自类别上 +4，其它类别 −2；
3. **距离惩罚弱化**：`dist` 只给 −1（手调版是 −2）—— 训练数据里"关键词近但数字远"很少见，
   模型更愿意相信关键词。

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
   整板 5,444 LUT / 3,278 FF / WNS +5.4 ns；板上 `sample.txt --check` **PASS 1460 B**（含 name=/addr= 的 153 B 摘要行），
   实测 `身份证 …卡… 手机号 …` 一帧 → `l2=3 l2m=14`，无关键词 → `l2=0`。
2. **特征只有 8 个、权重是手调的**：还没训练。要真"学"，下一步是
   用 `host/corpus` 标注数据训一个小线性模型，导出 INT4 权重直接替换这张表。
3. **没有 DDR3 / 大模型**：现在的 MXU 用量 889 LUT，离"跑 0.5B"差三个数量级；
   miniTensor 的 UB/DMA/controller 还没用上（那是 M3 后续）。

## 6. 复现

```bash
cd guard
make l2-vectors l2-sim         # 功能
python3 tools/train_l2.py                    # 重新训练（写 host/golden/l2_weights.py）
python3 tools/gen_l2_weights_sv.py build/gen/l2_weights_pkg.sv   # 生成 RTL 权重包
# 面积/时序（Windows + PDS）：
pds_shell -file fpga/pango/flow_l2.tcl -project_name l2_res
```

## 7. L2b 实体层：人名 / 地址

规则式（词典 + 上下文线索），**不是语义理解**——语义改写要走模型路线（见 [ubuntu-ner.md](ubuntu-ner.md)）。

| 类型 | 规则 | 例子 |
|---|---|---|
| `name`（type 9） | 姓氏表（64 个常见姓）+ 1~2 个汉字；要求 12 字节内有名字线索（叫/姓名/联系人/收件人/户名/本人/给/找/致），或"姓+职务"（先生/女士/老师/同学/经理/主任/医生/律师） | `联系人张三`、`姓名：李四`、`王经理` |
| `addr`（type 10） | 线索（地址/住址/住在/位于/收货地址）或锚点字（省/市/区/县/路/街/号）起头，累积汉字+数字，6..48 字节且含锚点 | `地址：北京市朝阳区建国路88号`、`我住在杭州市西湖区文三路100号` |

遮法与结构化 PII 不同：号码保留后 4 位（可核对），**人名/地址整段涂掉**——留 4 位等于把名字泄一半。

### 7.1 RTL 模块（已写、已单独验证）

`rtl/l2/l2_entity.sv`：UTF-8 三字节流式解码 + 4 字符线索窗口 + 姓氏/锚点/职务/线索表。
表由 `tools/gen_entity_tables_sv.py` 从 `host/golden/entities.py` **生成**（两侧同源）：

```bash
make entity-sim        # 16 例 / 14 span，RTL 与金标逐字节一致
```

```
entity cases=16 errors=0
PASS: L2b entity layer matches golden
```

金标侧单独测：`tests/test_entities.py`（9 个用例），合成 500 句带标签：
recall **500/500 = 1.000**、误报 **0/500**。

### 7.2 host 侧已可用

```bash
python3 tools/demo.py --in 某文件.txt --policy mask --entities
```

### 7.3 还没做：接进板级替换通路（踩到的问题已定位）

把实体 span 送进 `l1_merge`（5→6 路源）+ `l1_redactor`（type≥9 整段遮）+ 摘要行
`name=`/`addr=`，本轮的实现**已经跑通到"板上能出报告"**，但还有一处没对齐：
实体在 `in_last` 那一拍才吐"帧尾收尾"的 span，合并器同拍开始 flush，这个 span 会
落到替换器出队指针之后（漏遮 + `done` 卡死）。已定位的两个具体修复点：

1. `l1_redact_top` 里把 `in_last` 延迟 2 拍再给合并器（本轮试过，能解决卡死，
   但帧中段的地址 span 仍偶尔与出队指针错位，需要把"span 入队时校验 start ≥ 出队指针"
   做成显式丢弃并计入 `dropped`）；
2. `guard_report` 的字段计数器必须 5 位（17 个字段，4 位会在 15 回绕——这个已修，
   是"报告永远发不完"的根因）。

结论：**这块要在下一轮专门做**（半天），本轮已把"单独可仿真验证的模块 + 同源表 +
金标"全部落地，没有把半成品烧进板子。