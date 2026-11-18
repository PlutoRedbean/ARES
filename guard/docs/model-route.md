# 模型路线（在 Ubuntu 上做）

目标：从"关键词 + 位数 + 距离"的线性分类器，走到能认**没有人名的线索也认得出名字**、
能处理**口语化/改写**的语义层。

板子路径：Pangu 200Pro+（PG2L200H）→ miniTensor（4×4 INT8 MXU + UB/DMA）→ DDR3
（M3 才接 AXI）。所以模型必须小到能塞进 BRAM/DDR3，并且以 INT8 为主。

## 为什么在 Ubuntu 上做

| 环节 | Windows 现状 | Ubuntu 好处 |
|---|---|---|
| 训练 | 纯 Python 也能跑（现在的 `train_l2.py`） | PyTorch + GPU，随便试 |
| 量化 | 手写 INT8/INT4 模拟 | `torch.ao.quantization` / ONNX Runtime / `nncf` |
| RTL 协同仿真 | Verilator 在 WSL 里（能用） | 原生 Verilator + GTKWave，脚本更快 |
| 大文件/长训练 | 文件系统慢 | 原生 ext4 |
| 板级下载 | PDS 只有 Windows 版 | ❌ 仍然要回 Windows 烧 |

**结论**：训练/量化/仿真在 Ubuntu，**烧板子回 Windows**（PDS + cdt 只有 Windows）。

## 三阶段

### 阶段 A：字符级名字识别（1~2 周，能上板）

- 输入：UTF-8 → 中文字符 id（常用 3.5k 字 → 12 bit），非中文按字节；
- 模型：Embedding(12bit → 32) → 1 层 BiLSTM(32→32) 或 2 层 DWConv → CRF/线性头（BIO 标注）；
- 规模：参数 ~40k，INT8 → ~40 KB，塞得进 DDR3/BRAM；
- 数据：`host/corpus` 的合成器 + 公开人名/地址语料（自己造带标注的句子最快；
  姓名用姓氏表 + 常用名，地址用省市区街道表组合，再混入负样本）；
- 指标：span 级 P/R（字符级会虚高）；目标 **P ≥ 0.95 / R ≥ 0.90**；
- 上板：miniTensor 的 GEMM 做 embedding/FFN，LSTM 用 `l2` 的时序控制（或先只做 CNN）。

### 阶段 B：地址与"改写"（1~2 月）

- 地址：字符级 + 词典特征（省市区词典命中位）；
- 改写：现在别做。真正的改写理解需要 ≥100M 参数，板子塞不下；
  替代方案是"规则 + 小模型召回 + 人工复核"，或者把模型放在**上游主机**，板上只做闸门。

### 阶段 C（可选）：M4，DDR3 + 更大 MXU

- 接 `vendor/minitensor` 的 UB/DMA + AXI，把权重放 DDR3；
- 目标：可以做 4~8 层的小 transformer（~1M 参数）。

## Ubuntu 环境（一次装好）

```bash
sudo apt update
sudo apt install -y build-essential git python3-venv python3-pip \
                    verilator gtkwave clang cmake ninja-build

python3 -m venv ~/guard-venv && . ~/guard-venv/bin/activate
pip install torch --index-url https://download.pytorch.org/whl/cpu   # 有卡就换 cu121
pip install numpy onnx onnxruntime pyserial pytest

git clone https://github.com/ccycyc6/QS.git ~/QS
cd ~/QS/guard && make test          # 先确认基线全绿（98 单测 + 11 组仿真）
```

## 落地顺序（建议）

1. `tools/train_l2.py` 已经在跑（线性、8 特征）；先把**特征扩到 16 维**（加"前一字符类别"
   "是否紧跟冒号""是否在句首"），仍用 INT4，验证精度提升 → 这一步不换模型就能吃到收益；
2. 再上字符级 CNN/LSTM，用 `host/golden/entities.py` 的规则做弱标注（规则召回高的样本
   直接当正样本，人工抽检 10%）；
3. 导出 ONNX → 量化 INT8 → 用 `l2_int4_gemm` 的同一套 TB 模式（金标 ⇔ RTL 逐字节）验证；
4. 最后接 `l2_entity` 的位置（现在它输出 type 9/10 的 span，模型版只需替换判定部分）。

## 交接清单

- [x] 金标规则层（`host/golden/entities.py`）+ 测试 + 合成评估脚本
- [x] RTL 规则模块（`rtl/l2/l2_entity.sv`）+ 16 例位级 TB
- [x] 表生成器（`tools/gen_entity_tables_sv.py`，Python → SV 同源）
- [ ] 板级接线（`l1_merge` 6 路 + redactor type≥9 + `name=`/`addr=`）——见 l2-int4.md §7.3
- [ ] 阶段 A 的字符级模型与数据集
- [ ] ONNX → INT8 → RTL 的量化流程脚本（Ubuntu 侧）

## 别踩的坑

- **不要**在板子上做"语义改写"：LSTM/attention 的中间态放不进 BRAM，DDR3 带宽也不够；
- 字符级模型的**标注**比模型重要，先花两天把合成 + 抽检流程搭好；
- 量化误差用"逐层 cos 相似度 + 端到端 span P/R"两条线看，别只看 KL；
- RTL 侧的判定口径必须和 Python 完全一致（本项目一直靠"同一张表 + 逐字节向量"保证）。
