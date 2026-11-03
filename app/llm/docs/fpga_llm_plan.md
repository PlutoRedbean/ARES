# 200Pro+ 上的英文语言模型部署方案

> 目标板：紫光同创 盘古 200Pro+（MES2L676-200HP，PG2L200H-6IFBB676，Logos-2，28 nm）
> 现有资产：RV32IM 五级流水 CPU + miniTensor（4×4 INT8 脉动阵列）+ 64 KB L2 scratch + UART
> 目标：在 FPGA 内跑一个语言模型，通过串口交互
> 配套：kev-gpt 评审见 kev_gpt_review.md；算力/内存计算器见 ../tools/llm_budget.py
> **语言范围：只做英文。** 中文 tokenizer/语料/评测不在本方案范围内；Route C 也只使用英文 prompt。

---

## 0. 结论（给忙人）

1. **kev-gpt 不能直接移植**：它是为 KV260 的约 7.7 MB 片上存储（项目按 ~3 MB 预算）、
   1,248 DSP、200 MHz、Vivado 定制的；200Pro+ 只有 1.82 MiB DRM、740 个 25×18 APM、
   27 MHz 板载时钟、Pango ADS。
   直接搬 RTL 的工作量约 8–14 人月，单流合理预期只有 20–100 token/s，而串口 115200 的
   上限约 2.9k token/s，吞吐优势被抹平。详见 kev_gpt_review.md。
2. **现有 4×4 miniTensor 的真实瓶颈是“10 周期 GEMM + 串行控制器”，不是阵列太小**。
   M=1 时有效上限约 1.6 MAC/cycle，实测 3×3 卷积 0.7 MAC/cycle。先把核和控制器做成
   流水线（目标 2.5 MAC/cycle），再超频到 100 MHz，1.7M 参数模型就能到 100–200 token/s，
   已经足够串口对话。
3. **推荐三步走**：
   - **A（2–4 周）**：56K–279K 参数英文 char 模型，27 MHz，现有 b5，60–1000 token/s，先跑通
     “串口输入一句话、模型逐字回一句”的闭环；
   - **B（2–3 个月）**：1.77M 参数、4 层、d=192、ctx=128、INT4，100 MHz，4×4 流水线，
     100–200 token/s；这是这块板子上“真正像语言模型”的甜点；
   - **C（可选，6–12 个月）**：0.5B 英文模型放 1 GB DDR3，64–128 lane INT4 GEMV，
     8–12 token/s；这是“真聊天机器人”，但是另一个量级的工程。
4. **不建议**：为了 60k token/s 去移植 kev-gpt；为了“通用英文对话”硬上 4×4；在没有
   DDR3 控制器和 64 lane 引擎的情况下直接塞 0.5B。

### 0.1 路线速查

| 路线 | 模型 | 关键改动 | 预期 token/s | 周期 | 质量定位 | 风险 |
|---|---|---|---|---|---|---|
| A0 | 56K char GRU | 无（现有 b5） | 300–1000 | 1–2 周 | 玩具/莎士比亚/模板 | 低 |
| A1 | 279K char Transformer | 权重放 BRAM | 60–200 | 2–4 周 | 领域小模型 | 低 |
| B1 | 1.77M Transformer | PLL 100 MHz + 4×4 流水线 | 100–200 | 2–3 月 | TinyStories/英文领域语料 | 中 |
| B2 | 1.77M + 64 lane | 新 GEMV 引擎 | 1–3k（UART 封顶 2.9k） | 3–4 月 | 同上，更快 | 高 |
| C | 0.5B 英文 | DDR3 + 64/128 lane | 8–12 | 6–12 月 | 英文真聊天 | 很高 |

---

## 1. 硬件基线（先把账算清）

### 1.1 器件与板卡

| 资源 | 数值 | 说明 |
|---|---|---|
| FPGA | PG2L200H-6IFBB676 | Logos-2，28 nm，676 脚，-6 速度等级 |
| LUT6 | 159,800 | 等效 LUT4 约 239,700 |
| 触发器 | 319,600 | |
| DRM36K | 415 块 | 每块 36 Kb = 4,608 B；**合计 1.82 MiB**；最大 72-bit 宽 |
| APM | 740 个 | 25×18 乘法器，48-bit 累加，SIMD 12×9 |
| DDR3 | 1 GB，32-bit，1066 Mbps | 理论 4.26 GB/s；板载 2 片 DDR3 |
| 时钟 | 27 MHz 晶振 | 当前 SoC 直接用它；可用 PLL 到 100–150 MHz |
| 串口 | USB-UART，115200 8N1 | 11,520 B/s；可试 921600 |
| 其他 | 2×QSPI、SD、GbE、HDMI、8×HSST | 后续可做权重加载/网络 |

### 1.2 当前 b5 SoC 实测占用

| 资源 | 已用 | 总量 | 占比 |
|---|---|---|---|
| LUT | 24,237 | 159,800 | 15.2% |
| FF | 27,287 | 319,600 | 8.5% |
| DRM36K | 36.5 | 415 | 8.8% |
| APM | 62 | 740 | 8.4% |

剩余约 **135K LUT、378 块 DRM、678 个 APM**。逻辑和乘法器都很宽裕；
**真正的约束是 DRM 容量、主频和 DDR3 控制器**。

### 1.3 miniTensor 现状

| 项 | 现状 | 对 LLM 的影响 |
|---|---|---|
| 阵列 | 4×4 INT8，输出固定 | M=1 decode 只用 1 行 A，3/4 阵列闲置 |
| GEMM 核 | 一次 4×4×4 要 10 周期（RUN_CYCLES=10） | M=1 上限 1.6 MAC/cycle；实测 0.7 |
| 控制器 | 读 A、读 B、启动、等 10 周期、写 4 行 C，全串行 | 每 tile 约 20–26 周期，延迟主导 |
| UB | 128-bit × 256 = 4 KB | 放激活/权重 tile；权重必须分块 |
| L2 scratch | 64 KB @0x1000_0000 | 目前映射成 LUTRAM（约 8K LUT），不适合大权重 |
| DMA | 支持 LOAD/STORE，64 条命令队列 | 可做权重/激活搬运 |
| 向量单元 | 128-bit add/max/relu | 可做部分逐元素算子，但 LN/softmax/GELU 还不够 |
| Epilogue | INT32 + bias + 单组 mult/shift/zp/relu | **per-tensor**，LLM 需要 per-channel |
| 主频 | 27 MHz | 先 PLL 到 100 MHz，是最便宜的一次提速 |

### 1.4 当前缺什么

1. **PLL/时钟树**：board_cpu.v 直接接 clk_27m；需要 100 MHz 并重算 UART 分频。
2. **DDR3 控制器**：主仓库 video 工程已有验证过的 Pango DDR3 IP（ddr3_test），但 lm_soc
   的 b5 没有接；这是 0.5B 路线的硬门槛。
3. **GEMV/GEMM 流水线**：现有 10 周期核 + 串行控制器，吞吐只有峰值的 5–17%（M=4/M=1）。
4. **非线性硬件**：GELU、LayerNorm、softmax 目前没有；可先 CPU，后加 LUT。
5. **per-channel requant**：epilogue 只有一组 mult/shift，量化精度不够。
6. **权重大小/加载**：64 KB scratch 只能放 56K INT8；上 1.7M 必须用 DRM 或 DDR3。

---

## 2. 算力、内存、带宽账本

### 2.1 公式

- 每 token MAC ≈ 非 embedding 参数 + 输出 head + 注意力（QK^T + AV）。
  FLOPs ≈ 2×MAC；**不要再用“MAC = 2×参数量”**，那是 FLOPs。
- token/s = 主频 × MAC/cycle ÷ 每 token MAC。
- 权重字节：INT8 = 参数量；INT4 = 参数量/2。
- KV 字节 = 层数 × 2 × ctx × kv_dim × 每元素字节。
- DRM 块数 = (权重字节 + KV 字节) ÷ 4,608；再加 SoC 的 36.5 块。
- 带宽上限 = 4.26 GB/s ÷ (权重字节 + KV 字节)。
- 串口上限 = 11,520 B/s ÷ 每 token 字节；BPE 约 4 B/token → 2,880 token/s；
  本方案只做英文：ASCII char-level 约 1 B/token → 11,520 token/s；英文 BPE 约 4 B/token → 2,880 token/s。

### 2.2 候选模型账本（估算，非实测）

| 模型 | 参数 | MAC/token | 权重 | KV | 27M/0.7 | 27M/2.5 | 100M/2.5 | 100M/4 | 64L/100M | DDR上限 | UART上限 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| GRU-56K char h96 | 0.057M | 0.052M | 55K I8 | 0 | 362 | 1,293 | 4,787 | 7,659 | 122,549 | 75,254 | 11,520 |
| Tx-279K char 2L d128 ctx64 | 0.279M | 0.311M | 273K I8 | 32K | 61 | 217 | 803 | 1,285 | 20,559 | 13,651 | 11,520 |
| Tx-1.77M BPE2K 4L d192 ctx128 | 1.771M | 1.966M | 865K I4 | 192K | 9.6 | 34 | 127 | 204 | 3,255 | 3,936 | 2,880 |
| Kev-3.16M char57 4L d256 ctx256 | 3.163M | 3.685M | 1.54M I4 | 512K | 5.1 | 18 | 68 | 109 | 1,737 | 2,023 | 2,880 |
| Qwen2.5-0.5B (English) 24L d896 ctx512 | 494M | 516M | 241M I4 | 3M | 0.0 | 0.1 | 0.5 | 0.8 | 12.4 | 17 | 2,880 |

说明：

- 27M/0.7 是 **实测**（3×3 卷积 745K MAC / 1.1M 周期）；其余是估算。
- 27M/2.5、100M/2.5 是“4×4 流水线 + 100 MHz”的目标；100M/4 是 4 周期核的 M=1 上限。
- 64L/100M 是新增 64 lane GEMV 的估算；Qwen 的 64L 是 12.4，128L/150M 是 37.2，
  但 DDR3 只有 17，所以 0.5B 最终还是带宽封顶。
- DRM 容量校验：1.77M 用 235 块 + SoC 36.5 = 271.5 块（65%），舒适；
  3.16M 约 494 块（119%），**放不下**；Qwen 在 DDR3，不在 DRM。

### 2.3 三个硬约束

**约束一：M=1 浪费阵列。**
4×4 阵列本来一次算 4 个输出行 × 4 个输出列；单流 decode 只有 1 个 token（1 行 A），
4 个行里有 3 个是空的。加上 10 周期核，单流上限只有 1.6 MAC/cycle。
要填满阵列，要么 **batch/多流**（4 条流/4 个候选 token），要么 **换 GEMV 引擎**
（按输出列并行，而不是按行）。

**约束二：415 块 DRM 决定模型上限。**
1.82 MiB 听起来不少，但要减去 SoC、KV、双缓冲、布线余量。
INT4 权重 + INT8 KV 的舒适区约 **1.5–1.7M 参数**；3.16M 需要 1.54 MB 权重 + 0.5 MB KV，
超过 415 块。**想在片上跑 3.16M，必须降 ctx 或砍 KV 精度，且只剩个位数余量，不建议。**

**约束三：串口 115200 封顶 2.9k token/s。**
100–300 token/s 已经能让 20–50 token 的回复在 0.2–0.5 s 内出现，人眼感觉“实时”。
只有当你要做多用户、预填充长 prompt、或 0.5B 时，才需要 921600 或 GbE。
**因此“更大的阵列/更高的 60k”在单用户串口场景里边际收益很低。**

---

## 3. 三条路线

### 3.1 路线 A：先跑通（2–4 周）

目标：证明“串口输入 → 模型生成 → 串口输出”的完整闭环，建立训练/量化/导出/上板流水线。

- A0：56K char GRU，权重 55 KB，直接放 64 KB L2 scratch；27 MHz；预计 300–1000 token/s。
- A1：279K char Transformer（2 层 d128 ctx64），权重 273 KB INT8 或 136 KB INT4，
  放 DRM（约 68 块）；27 MHz；预计 60–200 token/s。
- 质量：领域 toy（TinyStories 英文短句、莎士比亚对话、指令模板）；不是通用聊天。
- 交付：位流、固件、PyTorch 训练脚本、导出脚本、串口 demo、测试记录。

### 3.2 路线 B：甜点（2–3 个月）

目标：1.77M 参数、4 层、d=192、ctx=128、INT4，100 MHz，4×4 流水线，100–200 token/s。
这是“这块板子上真正像语言模型”的配置，也是性价比最高的一档。

- 权重 865 KB INT4 + KV 192 KB → 235 块 DRM + SoC 36.5 = 271.5 块（65%）。
- 先做 B1（不换阵列，只做 PLL + 流水线 + 驱动优化）；如果还不够，再做 B2（64 lane）。
- 质量：TinyStories/莎士比亚英文小故事；英文领域语料（FAQ/客服/风格文本），不是通用问答。

### 3.3 路线 C：0.5B（可选，6–12 个月）

目标：Qwen2.5-0.5B 级英文模型（英文 prompt），INT4，放 1 GB DDR3，64–128 lane，8–12 token/s。
这是“真聊天机器人”，但需要 DDR3 控制器、64/128 lane 引擎、151K tokenizer、KV 管理，
是另一个量级的工程；没有明确产品需求不建议先做。

---

## 4. 路线 A 详细：先跑通（2–4 周）

### 4.1 A0：56K char GRU（1–2 周）

| 项 | 配置 |
|---|---|
| 模型 | 1 层 GRU，vocab 64，embed 64，hidden 96 |
| 参数 | 约 56.6K；INT8 权重约 55 KB |
| 存放 | 64 KB L2 scratch（0x1000_0000）；代码在 128 KB DDR_BRAM |
| 计算 | 3 个门 = 3×(64+96)×96 ≈ 46K MAC；加 head 6K MAC |
| 主频 | 27 MHz（先不动） |
| 预期 | 0.7 MAC/cycle → 约 360 token/s；2.5 → 约 1,300；串口 11,520（char） |
| 质量 | 莎士比亚/模板/固定风格短句；不是通用聊天 |

**为什么先做 GRU**：它没有注意力/KV/位置编码，一层 GEMV 就能跑；权重 55 KB 正好塞进
现有 64 KB scratch，不用改 RTL、不用 DDR3、不用 PLL。它是验证“训练→量化→打包→固件→
串口”整条流水线的最低风险载体。

**落地要点**：

1. 训练：PyTorch 单层 GRU，char-level，语料 1–5 MB；PC 上 10–30 分钟；
2. 量化：对称 per-tensor INT8（先用现有 epilogue 的 mult/shift），或 per-channel（改 RTL）；
3. 打包：复用 tools/model/pack_weights.py 的思路，导出 C 头文件 + 整数 golden；
4. 固件：新增 firmware/app/llm.c：
   - llm_load_weights()：把权重从 .rodata 拷到 scratch；
   - llm_gemv()：用 MT_GEMM2D / MT_CONVGROUP 做 1×1 GEMV；
   - llm_gru_step()：3 个门 + sigmoid/tanh（CPU 查表）；
   - llm_sample()：temperature/top-k，或先 greedy；
   - uart_line()：行缓冲、回显、退格、回车触发；
5. 串口协议（先文本）：
   - 上电打印 LLM ready. Type a prompt and press Enter.
   - 收到一行 → 生成 20–50 token → 以 CRLF 结束；
   - 支持 !reset 清 KV/状态，!temp=0.8 调温度（可选）。

**验收**：输入一句 5–10 个词的英文，2 s 内开始逐字输出，20 token 回复 < 3 s；
连续 1,000 token 无乱码/无死机；断句/退格正常。

### 4.2 A1：279K char Transformer（2–4 周）

| 项 | 配置 |
|---|---|
| 模型 | 2 层，d=128，ctx=64，FFN=256，vocab 128（char） |
| 参数 | 约 279K；INT8 273 KB / INT4 136 KB |
| KV | 2×2×64×128 = 32 KB（INT8） |
| 存放 | DRM（INT8 约 68 块，含 KV；INT4 约 37 块） |
| 计算 | 约 311K MAC/token；27 MHz 0.7 → 61；2.5 → 217 |
| 预期 | 60–200 token/s；串口 11,520（char） |
| 质量 | 领域小模型：莎士比亚/短故事/FAQ 模板 |

**落地要点**：

1. 线性层全部映射成 1×1 卷积（c_in=d，c_out=3d/ffn），复用 net_conv 的 2D burst；
2. LayerNorm/softmax/GELU 先在 CPU 上做（每层几百到几千周期，相对 GEMV 可忽略）；
3. KV 放 DRM 或 L2；ctx=64 时 KV 只有 32 KB，L2 也能放下；
4. 权重 273 KB 超过 64 KB scratch，必须放 DRM；在 ares_l2 里加一个 weight BRAM 窗口，
   或把 scratch 改成 DRM（registered read），不要再用 LUTRAM 堆大数组；
5. 量化建议 per-channel（至少 per-output-channel），否则 2 层 Transformer 的精度会明显掉；
   这需要把 epilogue 的单个 mult 改成 4 个/组（见 5.3 的 (5)）。

**验收**：固定 prompt 的 token 流与 Python 整数 golden 逐位一致（greedy）；
20–50 token 回复 < 2 s；模型在 5 个留出 prompt 上不崩；串口 1,000 token 无错。

---

## 5. 路线 B 详细：1.77M 甜点（2–3 个月）

### 5.1 模型配置

| 项 | 配置 |
|---|---|
| 结构 | 4 层 decoder-only Transformer，pre-LN，RoPE 可选（先学绝对位置） |
| d / heads / ctx | 192 / 6 / 128 |
| FFN | 512（2×d 或 2.67×d） |
| vocab | 2,048 BPE（英文）；只做英文，先 BPE 2K |
| 参数 | 约 1.77M（含 embedding，tied） |
| 权重 | INT4 约 865 KB；INT8 约 1.73 MB（太大，见下） |
| KV | 4×2×128×192 = 192 KB（INT8） |
| DRM | 235 块 + SoC 36.5 = 271.5 / 415（65%） |
| 每 token MAC | 约 1.97M |
| 目标 | 100 MHz，2.5 MAC/cycle → 127 token/s；4 → 204；150 MHz → 190–300 |

**为什么不是 3.16M**：3.16M INT4 权重约 344 块 + KV 512 KB 约 114 块 + SoC 36.5 块
≈ 494 块，超过 415；即使 KV 压到 INT4 也约 437 块。**1.77M 是容量、速度、质量三者的平衡点。**

### 5.2 总体架构

    PC 串口终端
        │ 115200/921600 8N1
        ▼
    RV32IM CPU @100 MHz
        │  MMIO / 命令队列
        ▼
    miniTensor（4×4 流水线） ──► 权重 BRAM 1 MB（DRM，banked）
        │                         KV BRAM 256 KB
        │                         激活 UB 4 KB + L2 64 KB
        ▼
    UART TX → PC

- CPU：tokenizer、prompt 模板、采样、UART 协议、层调度、LN/softmax/GELU（先软后硬）。
- miniTensor：QKV/Proj/FFN/Head 的 GEMV；epilogue 做 bias+requant。
- 权重 BRAM：INT4 打包，按输出 lane 分 bank；一次读 72-bit 喂多个 lane。
- KV BRAM：每层 K/V，INT8；decode 时只追加 1 个位置。
- 所有大块数据走 DRM；L2 只做激活/临时区；代码在 DDR_BRAM。

### 5.3 B1：不换阵列，只做“PLL + 流水线”（推荐先做）

这是投入产出比最高的一步：**阵列不变、指令集不变、golden 不变**，只改时序和控制。

**(1) PLL 27 → 100 MHz**

- 用 Pango PLL IP（可参考 rtl/video/video_ip_pll.v 的 27 MHz 输入配置），生成 clk_100m + locked；
- board_cpu.v 里加复位同步（locked + por），SoC/CPU/miniTensor 全部用 clk_100m；
- UART 分频从 234 改成 868（100 MHz / 115200 ≈ 868.05）；先验证 115200 收发；
- 注意 DDR3 IP 的 core_clk 与 SoC 时钟的 CDC（B 阶段不用 DDR3，先不管）。

**(2) tensor_gemm_core：10 周期 → 4–6 周期**

- 现状：S_IDLE → S_RUN 10 拍 → S_RESULT，结果组合输出，控制器再写 4 行；
- 改法：双缓冲累加器（A 组计算时 B 组清零/装载），结果打一拍寄存；
  RUN_CYCLES 先试 6，再试 4；每 4–6 拍允许一个新 cmd；
- 保持整数结果 bit-exact：只是时序变，数据路径不变；用现有 iverilog/Verilator 测试逐位对齐。

**(3) tensor_controller：串行 → 流水**

- 现状：READ_A → WAIT_A → READ_B → WAIT_B → CORE_START → CORE_WAIT(10) → WRITE(4) → DONE，
  约 20–26 拍/tile；
- 改法：
  - A/B 双缓冲：core 算 tile i 时，预取 tile i+1 的 A/B；
  - C 写回与下一 tile 的 core 并行；
  - cmd_ready 在输入缓冲有空位时就拉高（深度 2 的 cmd FIFO），不要等 S_IDLE；
  - UB 是 128-bit 单读口：每 tile 2 次读 + 4 拍写回，6 拍/tile 足够；
- 目标：6 拍/tile → M=1 16 MAC/6 拍 = 2.67 MAC/cycle；4 拍/tile → 4 MAC/cycle。

**(4) mini_tensor_top / shim：减少每命令开销**

- 现有 64 条命令队列 + CONVGROUP/GEMM2D 已经把“一个 push 展开成一整块 GEMM”；
- 把 tensor 的 cmd_ready 从“仅 S_IDLE”改成“输入缓冲有空”，让队列真正连续流动；
- epilogue/vector 与 GEMM 可以按层交错，但先保证 GEMM 不停。

**(5) Epilogue：per-channel requant**

- 现状：一个 tile 16 个输出共用一个 mult/shift/zp；LLM 每个输出通道的 scale 不同；
- 改法：把 config 行扩展成 4 组（每个输出列一组）mult/shift/zp，或每 4 个输出通道
  读一行 64-bit 的 per-channel 表；面积很小（4×16-bit 乘法器或分时复用）；
- 先做 per-channel，再做 GELU/LN/softmax 硬件；否则 4 层模型的精度会掉。

**(6) 权重存储：从 LUTRAM 迁到 DRM**

- 现状：ares_l2 的 sp_mem 是 128-bit×4096，综合成约 8K LUTRAM；
- 1.77M INT4 权重 865 KB 必须用 DRM；建议新增一个只读 weight BRAM 窗口：
  - 地址 0x2000_0000 起，1 MB 窗口；
  - 72-bit 宽、按输出 lane 分 bank；CPU 只读，DMA/GEMM 直接读；
  - 上电由固件从 QSPI/SD/UART 加载，或位流内初始化（若流程支持，先做后者更简单）；
- KV 放 0x3000_0000 起的 256 KB DRM 窗口，双口/简单读写；
- L2 scratch 保留 64 KB 做激活；如果 LUTRAM 紧张，把 scratch 也改成 DRM registered read。

### 5.4 B1 的预期与验收

| 指标 | 目标 |
|---|---|
| 主频 | 100 MHz，WNS ≥ 0（先 100，再试 125/150） |
| GEMM 吞吐 | ≥ 2.5 MAC/cycle（M=1，1×1 GEMV） |
| 1.77M 模型 | ≥ 100 token/s（greedy，ctx=128） |
| 首 token | ≤ 1 s（20 token prompt） |
| 串口 | 115200 稳定；可选 921600 |
| 正确性 | 固定 prompt 的 token 流与 Python 整数 golden 一致 |
| 资源 | LUT ≤ 60%，DRM ≤ 75%，APM ≤ 30%，WNS ≥ 0 |

**Gate**：如果 100 MHz 下只有 1.2 MAC/cycle，先别上 64 lane；把控制器/UB 带宽/命令开销
逐项 profiling，通常能到 2–2.5。只有稳定到 2.5 仍不够，才考虑 B2。

### 5.5 B2（可选）：64 lane GEMV

如果 B1 到 200 token/s 你还想要更快（预填充、多用户、或为 C 铺路），再做 64 lane：

- 64 个 lane，每个 lane 一个输出通道；权重 INT4，激活 INT8，INT32 累加；
- 每 lane 每周期 1 MAC；64 MAC/cycle @100 MHz = 6.4 GMAC/s；
- 权重带宽：64 lane × 0.5 B × 100 MHz = 3.2 GB/s；8 个 72-bit DRM bank 可提供
  8×9 B×100 MHz = 7.2 GB/s，够；
- 乘法器：用 32 个 APM 的 SIMD 12×9（2 MAC/APM）或 64 个 APM（1 MAC/APM）；
  740 个 APM 绰绰有余；
- 1.77M 模型：1.97M / 6.4G = 0.31 ms → 3.2k token/s；串口 2.9k 封顶；
- 只有做 0.5B（C）时，64 lane 才是“必需”，否则是“锦上添花”。

### 5.6 里程碑（B1，12 周）

| 周 | 交付 |
|---|---|
| W1 | PLL 100 MHz 上板；UART 115200 回环；b5 原 demo 跑通 |
| W2 | 1×1 GEMV 微基准：测 MAC/cycle、每 tile 周期、瓶颈（A/B/C/命令） |
| W3–W4 | tensor_gemm_core 流水线（RUN_CYCLES 6/4），bit-exact 回归 |
| W5–W6 | tensor_controller 双缓冲/预取/写回重叠；cmd FIFO；2.5 MAC/cycle |
| W7 | epilogue per-channel；Python 整数 golden 对齐 |
| W8 | 1.77M 模型训练/量化/打包；权重 BRAM 加载；单层上板 |
| W9–W10 | 4 层 forward + KV + attention + sampling；串口闭环 |
| W11 | 性能调优（tiling、命令批、UB 冲突）；测 100/125/150 MHz |
| W12 | 验收、文档、demo、回退位流 |

---

## 6. 路线 C 详细：0.5B 英文聊天（可选，6–12 个月）

### 6.1 账本

以 Qwen2.5-0.5B-Instruct 为例（24 层，d=896，GQA 2 KV heads，vocab 151,936；只跑英文 prompt）：

| 项 | 数值 |
|---|---|
| 参数 | 494M |
| INT4 权重 | 约 241 MB（1 GB DDR3 放得下） |
| KV（ctx=512，INT8） | 约 3 MB（必须放 DDR3） |
| 每 token MAC | 约 516M |
| DDR3 带宽上限 | 4.26 GB/s ÷ 244 MB ≈ **17 token/s** |
| 64 lane @100 MHz | 6.4 GMAC/s ÷ 516M ≈ **12.4 token/s** |
| 128 lane @150 MHz | 19.2 GMAC/s ÷ 516M ≈ **37 token/s**，但 DDR 仍 17 |
| 实际预期 | **8–12 token/s**（带宽 + 调度开销） |

### 6.2 需要做的东西

1. **DDR3 控制器接入**：复用主仓库 video 工程的 Pango DDR3 IP（ddr3_test）和
   official_ddr3.fdc；先做独立读写测试，再做 AXI/beat 适配；这是最大风险。
2. **64–128 lane INT4 GEMV**：64 lane × 100 MHz 就够匹配 DDR；128 lane 只在
   预填充/多用户时有意义。
3. **KV 管理**：0.5B 的 KV 3 MB 在 DDR3，attention 每 token 要读 KV；需要
   连续布局、预取、与权重流共享带宽。
4. **Tokenizer**：151,936 BPE（Qwen 多语种词表，英文可用）；词表/合并表几 MB，放 DDR3；RV32 上做 BPE
   可能每 prompt 几毫秒到几十毫秒，可接受；或先在 PC 端 tokenize，串口传 token id。
5. **采样**：151K logits 不能读回 CPU；用片上 argmax/Gumbel-max，或分块读回。
6. **权重加载**：241 MB 从 QSPI/SD 加载，QSPI 约几十 MB/s → 几秒到十几秒；可接受。
7. **散热/电源**：28 nm 200K LUT + DDR3 全速，注意板卡供电和温度。

### 6.3 更现实的中间档：300M 自训模型

如果目标是“英文领域聊天”，不一定要 0.5B：

- 300M 参数、32K vocab、INT4 ≈ 150 MB；DDR3 带宽上限 28 token/s；
- 64 lane @100 MHz 算力 6.4G / 300M ≈ 21 token/s；实际 15–20；
- 质量低于 0.5B，但比 1.7M 强很多；需要自己训练/微调，成本高；
- 适合“有领域数据、要可控成本”的场景。

### 6.4 建议

- 没有明确产品需求，**不要先做 C**；用 Jetson Orin Nano / RK3588 / PC 跑 0.5B
  更便宜、更快、质量更好。
- 如果一定要在 200Pro+ 上做“真聊天”，先做 C 的 **DDR3 + 64 lane 最小闭环**
  （跑一个 1.77M 模型从 DDR3 流式加载），验证带宽/调度，再上 0.5B。

---

## 7. 关键设计细节

### 7.1 量化

- 权重：INT4/INT8，**per-output-channel 对称**；激活：INT8 per-tensor；累加 INT32。
- Requant：y = clamp((acc + bias) × mult >> shift + zp)；mult 每通道一个。
- QAT：用 Brevitas 或手动 fake-quant；先 PTQ 看 cosine，掉太多再 QAT。
- Gate：每层输出与 FP 的 cosine > 0.999；最终 token 流与整数 golden 一致。
- Embedding/head：1.77M 模型里 embedding 2K×192=384K 参数，占 22%；如果太大，
  用 1K vocab 或 4-bit embedding；head 与 embedding tied。

### 7.2 非线性

| 算子 | 建议 | 精度/成本 |
|---|---|---|
| GELU | 256/512 项 LUT + 线性插值，Q4.12 | 1–2 KB BRAM；cosine > 0.999 |
| LayerNorm | rsqrt：8-bit 种子 LUT + 2 次 Newton；γ-only 或 γ/β | 几百 LUT；逐元素 |
| Softmax | exp LUT（Q1.20），减 max，倒数用 restoring/Newton | 1–2 KB LUT；ctx 次 |
| Sigmoid/Tanh（GRU） | 256 项 LUT | 小 |

先全部在 CPU 上做：1.77M 模型每层 LN 192 元素、softmax 128×6，CPU 100 MHz 下
几千周期，相对 1.97M MAC 可忽略；等 GEMM 快了再搬到硬件。

### 7.3 注意力与 KV

- KV 布局：[layer][head][ctx][d]，INT8；每层 2×128×192 = 48 KB；4 层 192 KB。
- Prefill：prompt 的 T 个 token 一次性算 QKV，KV 写满前 T 个位置；T≤128。
- Decode：只算新 token 的 Q，K/V 追加；QK^T 是 1×ctx×d，AV 是 1×ctx×ctx。
- Attention 的 GEMV 很小（ctx=128，d=192，每层约 2×128×192=49K MAC），
  可以 CPU/向量单元做，也可以复用 4×4；不要让它成为串行瓶颈。
- KV 用 INT8 需要 per-head scale；softmax 前 dequant 到 Q16 或 INT32。

### 7.4 权重布局与带宽

- 1.77M @2.5 MAC/cycle：每 cycle 消耗 2.5×0.5 B = 1.25 B；100 MHz = 125 MB/s，
  随便一块 DRM 都够；**容量才是问题，不是带宽**。
- 64 lane @100 MHz：64×0.5 B×100M = 3.2 GB/s；需要 8 个 72-bit bank 并行；
  8×9 B×100M = 7.2 GB/s，够。
- Banking：把“同一 k 列、不同输出通道”的 INT4 打包进一个 72-bit 字；
  一次读喂 16–18 个 lane；bank 数 = lane 数 / 16。
- 双缓冲：当前 tile 计算时预取下一 tile；权重是只读的，适合大块 burst。
- 如果权重在 DDR3：用 256-bit burst，行缓冲友好；每 token 读一遍 241 MB 是 0.5B 的瓶颈。

### 7.5 串口协议

- 物理：115200 8N1，USB-UART；可选 921600（先确认 CP2102/CH340 支持）。
- 文本模式（先做）：
  - 上电：打印 LLM ready、模型名、上下文长度；
  - 输入：一行 ASCII（英文），回车触发；回显、退格、Ctrl-C 取消；
  - 输出：逐 token 输出，空格/换行按模型；结束后打印统计（token/s、耗时）。
- 二进制模式（后做）：0xAA 0x55 + 长度 + token id；用于 151K vocab/高速。
- 流控：TX 阻塞会拖慢生成；如果 tok/s 接近 UART 上限，加 256 B FIFO 或 XON/XOFF。
- 错误：超时、非法字符、prompt 过长（>ctx）要给出明确提示。

### 7.6 权重加载

| 方式 | 容量 | 时间（115200 / 921600） | 适用 |
|---|---|---|---|
| C 数组（.rodata） | ≤128 KB（DDR_BRAM） | 随固件 | A0 55 KB |
| 位流内 BRAM 初始化 | ≤1 MB | 上电即用 | A1/B1 865 KB |
| QSPI Flash | 16–64 MB | 几秒 | B/C |
| SD 卡 | GB | 几秒 | C |
| UART 上传 | 任意 | 865 KB ≈ 75 s / 9 s | 调试 |

A1/B1 最省事：训练后生成 hex，综合时初始化 weight BRAM（若 Pango 流程支持）；缺点是改模型要重烧位流。
调试阶段用 UART 上传到 DRAM/BRAM 更快迭代。

### 7.7 时钟、复位、CDC

- PLL：27 MHz → 100 MHz；locked 后释放复位；por 计数器至少 256 拍。
- UART：100 MHz / 115200 = 868；如果 PLL 改成 125 MHz，分频 1085。
- DDR3：IP 的 core_clk 可能 200 MHz；SoC 100 MHz 与它之间用异步 FIFO/握手；
  B 阶段不用，C 阶段必须做。
- 调试：把 mcycle、GEMM busy、UART FIFO 深度引到 GPIO/LED，或通过串口打点。

---

## 8. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| DDR3 控制器集成失败/带宽不够 | 高 | C 路线阻塞 | 先复用 video 工程 IP 做独立读写测试；B 路线不依赖 DDR3 |
| 100 MHz 时序不收敛 | 中 | 性能减半 | 先 100 MHz；流水线/重定时；floorplan；WNS 为准 |
| DRM 容量不够/布线拥塞 | 中 | 模型缩小 | 1.77M/INT4；监控 65% 占用；权重 bank 靠近 GEMM |
| 4×4 流水线达不到 2.5 MAC/cycle | 中 | 100 token/s 变 50 | 先做微基准；逐项 profile；必要时上 16×16 或 64 lane |
| Pango ADS 对 SV 支持有限 | 中 | 编译失败 | 坚持 Verilog-2001 子集；每次改 RTL 先跑 pango_prep.py |
| 串口吞吐/流控 | 低 | 输出卡顿 | 115200 先够；加 FIFO；必要时 921600 |
| 模型质量不及预期 | 高 | 演示效果差 | 明确“领域小模型”定位；选好语料；做 5–10 个固定 prompt 的 eval |
| 许可/合规 | 中 | 无法复用 | kev-gpt 无 LICENSE；只参考方法，不拷贝代码/权重 |
| 电源/散热 | 低 | 降频/不稳定 | 28 nm 200K LUT 功耗可控；加散热片；测核心温度 |

---

## 9. 两周行动清单（从今天开始）

| 天 | 任务 | 产出 |
|---|---|---|
| D1 | 跑通 b5：make fw、build_soc.ps1、program_board、upload；抓串口日志 | 基线位流/固件/日志 |
| D2 | 在 mt_detect 里加 mcycle profiling；记录每层周期 | 现有 0.7 MAC/cycle 的分解 |
| D3 | 构造 1×1 GEMV 微基准（c_in=128/256，c_out=128/256，H=W=4） | 每 tile 周期、MAC/cycle、瓶颈 |
| D4 | 加 PLL 100 MHz；UART 分频 868；重跑 b5 | 100 MHz 位流 + WNS |
| D5 | 测 100 MHz 下 GEMV；对比 27 MHz | 频率/吞吐曲线 |
| D6 | 训练 56K char GRU；导出 INT8 + 整数 golden | 模型/权重/golden |
| D7 | 写 llm.c 的 GEMV/GRU/采样；PC 仿真对齐 | 仿真通过 |
| D8 | 上板：串口输入→生成；测 tok/s | A0 demo |
| D9 | 调 tiling/命令批；试 2.5 MAC/cycle 的控制器改法 | 性能提升 |
| D10 | 训练 279K Transformer；导出/对齐 | A1 模型 |
| D11 | A1 上板；测 60–200 tok/s | A1 demo |
| D12 | 写 1.77M 模型配置/训练脚本；评估语料 | B1 计划 |
| D13 | 评审：A 是否达标？B1 是否值得？ | go/no-go |
| D14 | 文档、回退位流、下一步排期 | 评审材料 |

---

## 10. 验收标准（Gate）

### Phase 0（基线）

- b5 位流能上板，串口 115200 打印正常；
- 1×1 GEMV 微基准：100 MHz 下 ≥ 2.0 MAC/cycle，且能说清瓶颈；
- WNS ≥ 0，资源占用在预算内。

### 路线 A

- 56K/279K 模型：固定 prompt 的输出与 Python 整数 golden 一致（greedy）；
- 20–50 token 回复 < 3 s；≥ 50 token/s；
- 连续 1,000 token 无乱码/死机；退格/取消正常。

### 路线 B1

- 1.77M 模型：≥ 100 token/s（ctx=128，greedy）；
- 固定 prompt 的 token 流与 golden 一致；5 个留出 prompt 不崩；
- 100 MHz WNS ≥ 0；DRM ≤ 75%；LUT ≤ 60%；APM ≤ 30%；
- 首 token ≤ 1 s；串口 115200 稳定。

### 路线 B2/C

- B2：≥ 1,000 token/s（UART 2.9k 封顶）；bit-exact；
- C：0.5B 英文模型 8–12 token/s；英文 20 轮对话不崩；DDR3 带宽利用率 > 70%。

---

## 11. 附录

### 11.1 文件地图

| 文件 | 作用 |
|---|---|
| rtl/board/board_cpu.v | 顶层；加 PLL/复位 |
| rtl/soc/ares_soc.sv | SoC 地址映射 |
| rtl/soc/ares_l2.sv | scratch/DDR/MMIO；权重 BRAM 可在这里加 |
| rtl/soc/ares_uart.sv | UART；分频/流控 |
| rtl/minitensor/tensor/MXU/INT8_GEMM/tensor_gemm_core.sv | 4×4 GEMM 核；10 周期 |
| rtl/minitensor/tensor/MXU/Systolic_Array/tensor_systolic_array.sv | 脉动阵列 |
| rtl/minitensor/tensor/tensor_controller.sv | 串行控制；流水线改造重点 |
| rtl/minitensor/tensor/Epilogue/tensor_epilogue_core.sv | requant；per-channel 改造 |
| rtl/minitensor/memory/unified_buffer.sv | 4 KB UB |
| rtl/minitensor/memory/vpu_dma.sv | DMA |
| rtl/minitensor/top/mini_tensor_top.sv | 命令/状态机 |
| firmware/app/mt.c / mt.h | 驱动/命令队列 |
| firmware/app/mt_net.c | 1×1/3×3 卷积映射；可复用为 GEMV |
| firmware/app/main.c | demo 入口 |
| tools/pango_prep.py | SV→Verilog 预处理 |
| tools/model/pack_weights.py | 量化/打包/golden 的模板 |
| docs/kev_gpt_review.md | kev-gpt 评审 |
| tools/llm_budget.py | 算力/内存计算器 |

### 11.2 常用命令

    make fw
    powershell -ExecutionPolicy Bypass -File tools/build_soc.ps1 -Stage b5
    powershell -ExecutionPolicy Bypass -File tools/program_board.ps1 -Bitstream build/pango/soc/prj_tasks/pnr_1/generate_bitstream/board_cpu.sbit
    powershell -ExecutionPolicy Bypass -File tools/upload.ps1 -Port COM9 -File build/fw/lm.bin
    python tools/llm_budget.py

### 11.3 参考

- kev-gpt: https://github.com/MichaelAyles/kev-gpt
- 盘古 200Pro+: http://www.meyesemi.com/ProDetail.aspx?ProId=69
- Pango Logos2 DRM: http://pangomicro.com/en/uploads/49630285_1729131726.pdf
- Pango Logos2 APM: http://pangomicro.com/en/uploads/62175380_1729131758.pdf
- 本仓库 docs/archive/plan_fx.md 的 P8 极简语言模型一节（早期估算）
- 本仓库 lm_soc 的 Pango 综合/布局报告（LUT 24,237、DRM 36.5、APM 62）

> 版本：2026-11-01。所有 token/s、容量、周期均为第一性估算；上板后以实测为准。

---
