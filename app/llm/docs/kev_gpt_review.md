# kev-gpt 移植可行性评审

> 目标板：紫光同创 盘古 200Pro+（MES2L676-200HP，PG2L200H-6IFBB676，Logos-2，28 nm）
> 评审对象：https://github.com/MichaelAyles/kev-gpt
> 结论先行：**思路成立，代码不能直接搬；直接移植的投入产出比很差。**

---

## 1. 一句话结论

kev-gpt 是一个为 Xilinx Kria KV260 **深度定制**的 3.16M 参数、INT4、全片上、16 路并发的
char-level GPT。它成立的前提是 KV260 的 **约 7.7 MB 片上存储（144×288Kb URAM + 576×36Kb BRAM，
项目按 ~3 MB 预算使用）、1,248 个 DSP、200 MHz 时序、Vivado 工具链**。200Pro+ 的对应预算是 **1.82 MiB DRM、
740 个 25×18 APM、27 MHz 板载时钟（可 PLL 到 100–150 MHz）、Pango ADS**。

直接把 RTL 搬过来，会同时撞上**容量、带宽、主频、工具链**四堵墙；而且串口 115200 的
上限只有约 **2.9k token/s（BPE）**，kev-gpt 的 60k token/s 在这块板子上没有可见收益。
**建议借它的方法，做一块英文缩小版（1–2M 参数、INT4、100 MHz、串口 100–300 token/s）。**

---

## 2. 它到底是什么（先看清事实）

| 项目 | kev-gpt 的事实 |
|---|---|
| 模型 | 3.16M 参数，4 层，d=256，ctx=256，char-level，vocab≈57 |
| 权重 | INT4，约 1.5 MB，全部驻留片上 URAM/BRAM，token 循环不碰 DDR |
| 板卡 | Xilinx Kria KV260，XCK26（16 nm），200 MHz |
| 片上存储 | 约 7.7 MB（144×URAM 288Kb + 576×BRAM 36Kb；项目按 ~3 MB 预算使用） |
| 算力 | 16 路并发（split-brain），PE 可扩到 1152；GEMV 核 0 DSP（INT4×INT8 用 LUT）或 DSP 打包 |
| 实测 | 16 路合计 59,965 token/s @200 MHz；单路约 19,242 token/s；公网聊天约 1,658 token/s |
| 代码 | 约 336 KB 的 PL-ARCHITECTURE.md、87 KB 的 WIDE-WORD-DATAPATH-LOG.md；stage3 sequencer 文档仍标 ⏳ |
| 许可 | **仓库没有 LICENSE 文件**（默认版权保留），代码/权重不能直接复用、分发或商用 |

关键点：**60k token/s 是 16 路并发的吞吐记录，不是单用户串口聊天的体验**；单路 19k 也是
PL 内部计数，真正到用户还有 serving 的往返。它最值得学的是“权重留在片上、INT4、整数
golden、逐位对齐”的方法，而不是那套为 KV260 调出来的 RTL。

---

## 3. 为什么它在 KV260 上成立

1. **带宽墙**：单流 decode 是 memory-bandwidth bound。KV260 的 A53 和 PL 共享约 20 GB/s
   DDR，DDR 驻留模型在 PL 上不会更快。唯一出路是把 1–2 MB 模型放进片上，URAM/BRAM
   能提供数百 GB/s 到 TB/s。
2. **URAM 的宽度**：kev-gpt 的 banked GEMV 把“同一列 k 的多个输出行”打包进一个 64-bit
   URAM 字，一次读喂 16 个 lane，PE=256 时并排 16 个 URAM。URAM 36Kb、深、宽、双口，
   正好适合这种“权重固定、激活广播”的布局。
3. **INT4 + 融合**：3.16M 参数压到 1.5 MB；电报体输出减少 token 数，KV 小，片上放得下。
4. **16 路并发**：一次权重读取服务 16 条流，摊薄权重带宽；代价是 16 份 KV 和 16 份激活。
5. **200 MHz + 7.7 MB**：28 nm 的 Pango 器件在同样逻辑上很难同时做到 200 MHz 和 7.7 MB 片上。

---

## 4. 放到 200Pro+ 的八个不匹配

| # | 维度 | kev-gpt / KV260 | 200Pro+ / PG2L200H | 影响 |
|---|---|---|---|---|
| 1 | 片上存储容量 | 约 7.7 MB | **415 × 36Kb = 1.82 MiB** | 3.16M INT4 权重约 344 块 + 512 KB KV 约 114 块 + SoC 36.5 块 ≈ **494 块 > 415**，放不下 |
| 2 | 存储类型 | URAM 36Kb，深、64-bit 字、级联 | DRM36K，**最大 72-bit、512 深** | banked GEMV 的“64-bit 字 + 深级联”要重写；同样容量需要更多块、更多布线 |
| 3 | 主频 | 200 MHz（16 nm） | 板载 **27 MHz**，PLL 后 100–150 MHz 较稳 | 同逻辑先慢 1.3–2×；200 MHz 在 28 nm -6 上风险高 |
| 4 | 算力/ lane 数 | PE 256–1152，16 路 | miniTensor **4×4 = 16 MAC/cycle**；M=1 时只有 4 个输出列在工作，且 GEMM 核一次要 **10 周期** | 单流有效约 **1.6 MAC/cycle 上限**，实测 3×3 卷积仅 0.7 |
| 5 | DSP/乘法器 | DSP48E2，3 MAC/DSP 的打包证明 | APM **25×18**、48-bit 累加、SIMD 12×9 | 打包证明不可直接复用；但 740 个 APM 对 64–128 lane 足够 |
| 6 | 工具链 | Vivado + URAM/DSP 原语 + AXI | Pango ADS，SV 子集受限（枚举、sized cast、结构体 part-select 都要预处理） | RTL 要过 pango_prep.py，时序/原语/约束全部重做 |
| 7 | 服务链路 | A53 + /dev/mem + WebSocket | RV32 + UART | 串口上限 2.9k token/s，60k 的吞吐优势被抹平 |
| 8 | 成熟度/许可 | stage3 README 仍标 sequencer ⏳（与主 README 的 60k 记录存在版本差异）；无 LICENSE | — | 直接当产品基线风险高；代码不能直接复用 |

### 4.1 先算容量：3.16M 到底能不能放下

- 权重 INT4：3.16M / 2 ≈ **1.58 MB** → **约 344 块** DRM36K（每块 4,608 B）。
- KV（4 层、ctx=256、d=256、INT8）：4×2×256×256 = **512 KB** → **约 114 块**。
- 当前 b5 SoC 已用 **36.5 块**。
- 合计 **约 494 块 > 415 块**（估算取整有 ±3 块误差）。即使 KV 压到 INT4（256 KB），仍是 **约 437 块**，仍然超。
- 只有把 ctx 降到 64（KV 128 KB）才勉强到 **约 401 块（97%）**，没有任何布线/双缓冲余量。

**结论：kev-gpt 的 3.16M/ctx256 模型在 200Pro+ 上放不下；1.7M 左右才是舒适区。**

### 4.2 再算算力：4×4 的真实上限不是 16 MAC/cycle

tensor_gemm_core.sv 里 RUN_CYCLES = 10：一个 4×4×4 GEMM 要 10 个周期才出结果，
控制器还要串行地读 A、读 B、启动、等 10 周期、写 4 行 C，合计约 20–26 周期。
所以：

- M=4（4 个 token 一起算）：64 MAC / 20–26 周期 ≈ **2.5–3.2 MAC/cycle**，不是 16。
- M=1（单流 decode）：只有 1 行 A 有效，16 MAC / 20–26 周期 ≈ **0.6–0.8 MAC/cycle**。
- 实测 3×3 卷积 745K MAC / 1.1M 周期 = **0.7 MAC/cycle**，与上面的账一致。

这带来一个很重要的判断：**当前 miniTensor 是“延迟/控制瓶颈”，不是“阵列太小”**。
先把 10 周期核和串行控制器做成流水线，比换一个更大的阵列更划算。

### 4.3 如果硬移植，性能会是多少

假设移植成功、主频 100 MHz、只做单流（不做 16 路）：

- 3.16M 模型，3.69M MAC/token；按 1.6 MAC/cycle 上限 ≈ **43 token/s**；按实测 0.7 ≈ **19 token/s**。
- 即使做到 4 MAC/cycle，也只有 **108 token/s**。
- 要做到 1,000 token/s，需要约 **37 MAC/cycle**；这已经超出 4×4 阵列，必须上 64 lane 或更大阵列。

而串口 115200 在 4 B/token 下是 **2,880 token/s**。也就是说：**100–300 token/s 已经足够把
串口喂满到“人眼看起来实时”**；为了 60k 去移植 kev-gpt，收益几乎为零。

---

## 5. 工作量与风险（直接移植）

| 工作包 | 估算 | 风险 |
|---|---|---|
| 把 stage3 RTL 过 Pango ADS（SV 子集、原语、约束） | 2–4 人月 | 高：URAM/DSP 原语没有一一对应 |
| 重做权重存储（DRM bank、72-bit 字、打包） | 1–2 人月 | 高：容量/布线/时序 |
| 重做 GEMV 数据通路（LUT/DSP 打包、retiming） | 2–4 人月 | 高：28 nm 200 MHz 难 |
| 重做 sequencer/控制（仓库里仍是 ⏳） | 2–3 人月 | 高：依赖原作者的未完成工作 |
| 板级/串口/固件/serving | 1 人月 | 中 |
| **合计** | **8–14 人月** | **很高** |

而且移植后的合理预期是 **单流 20–100 token/s、16 路 1–5k token/s**，仍然被串口卡在 2.9k。
投入 8–14 人月，换来一个“串口看不出差别”的结果，不划算。

---

## 6. 哪些东西值得借（这才是重点）

| 可借用 | 怎么用 |
|---|---|
| model/、keviniser/ 的训练/数据管线 | 直接用来训练我们自己的 1–2M 小模型（PyTorch，可移植） |
| INT4 QAT + per-channel scale | 权重 INT4、激活 INT8、INT32 累加；导出 $readmemh/C 数组 |
| 整数 golden（goformer、seq_ref） | Python 整数前向，逐层对齐 RTL； cosine > 0.999 的 gate |
| banked 权重布局 | “同一 k 列、多个输出行打包进一个宽字”的思想，改成 72-bit DRM 字 |
| Gumbel-max 片上采样 | argmax(logit/T + g)，省掉把词表 logits 读回 CPU |
| 逐位对齐的验证纪律 | 每个 RTL 块先过 iverilog/Verilator 的 bit-exact，再上板 |
| 串口/聊天 serving 的思路 | 但把 A53/WebSocket 换成 RV32/UART |

**不要借**：URAM 原语、DSP48 打包、16 路 split-brain、Vivado/AXI 工程、未完成的 sequencer。

---

## 7. 许可与合规

仓库根目录没有 LICENSE 文件。按默认版权规则，**代码和模型权重不能直接复制、修改后分发或商用**。
如果要在项目/产品里复用，先联系作者取得书面许可；更稳妥的做法是**只参考方法，自己重写**。
训练数据（TinyStories 等）也要单独确认其许可。

---

## 8. 最终判断

| 问题 | 回答 |
|---|---|
| kev-gpt 本身是真的吗？ | 是，有 RTL、有上板记录、有逐位对齐的工程日志；但它是研究/展示项目，不是可移植的产品基线 |
| 能直接放到 200Pro+ 吗？ | **不能**。容量、主频、原语、工具链都不匹配；3.16M/ctx256 甚至放不下 |
| 硬移植值得吗？ | **不值得**。8–14 人月，单流 20–100 token/s，串口上限 2.9k，收益被抹平 |
| 该怎么做？ | 借方法，做 **英文 1–2M 参数、INT4、100 MHz、4×4 流水线 + BRAM/DDR** 的缩小版；先跑 100–300 token/s 的串口对话，再决定是否上 0.5B/DDR3 |

> 下一步见 fpga_llm_plan.md：按“MVP → 1.7M → 可选 0.5B”的三阶段方案，
> 以及 ../tools/llm_budget.py 的算力/内存计算器。

---

## 附：主要依据

- kev-gpt README、fabric/stage3/README.md、fabric/stage3/PL-ARCHITECTURE.md（本地 shallow clone 阅读）
- 盘古 200Pro+ 产品页：http://www.meyesemi.com/ProDetail.aspx?ProId=69
- Pango Logos2 DRM 用户指南（36Kb，最大 72-bit）：http://pangomicro.com/en/uploads/49630285_1729131726.pdf
- Pango Logos2 APM 用户指南（25×18，48-bit 累加，SIMD 12×9）：http://pangomicro.com/en/uploads/62175380_1729131758.pdf
- 本仓库 lm_soc 的 Pango 综合/布局报告（LUT 24,237、DRM 36.5、APM 62）
