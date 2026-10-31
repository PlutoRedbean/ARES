# 支持RV32IM Mundus 前端架构设计文档

> **Version**: Draft 1.4 / C5 2026-10-18
> **目标架构**：
> Overview: 采用一个Composer+多个子预测器的三级流水线结构
>
> 1. Buffer Queue: Instruction Queue (IQ，当前默认 HEAD 2 + BODY 8) / 16-entries Fetch Target Queue (FTQ)
> 2. Target: uBTB / mBTB
> 3. Direction: Bimodal / TAGE / SC
> 4. Special control-flow: RAS / Loop
> 5. 使用4-way icache作指令缓存，BPU向IFU发出取指请求，IFU从icache中取指，预译码并送入IQ。
> 6. 一次执行流fetch 4条指令，以满足2-width Decode
> 7. latency = 3 cycles，throughput = 1 prediction/cycle

|Parameter|Value|
| --- | --- |
|FTQ_NumEntries |16|
|IQ_DEPTH |8|
|FETCH_WIDTH |4|

## 1. 设计目标

核心设计如下：

1. 每周期BPU预测器输出一个预测结果，Composer负责组合metadata，若发现预测结果不一致，则覆盖前一级的target_pc，并发起重定向请求。
一般认为流水线层级越深的结果置信度越高，覆盖优先级越高。
2. 第一周期uBTB+Bimodal先行快速预测，若uBTB miss则由mBTB经2-3拍延迟读出精确target预测。
3. IFU接收来自FTQ的取指请求，并转发给icache，接收到icache的指令块后，IFU进行预译码，并进行PredecodeCheck，根据检查结果决定是否写入IQ。

## 2. 总体前端架构

```text
                         BPU
                          │
          ┌───────────────┼────────────────┐
          │               │                │
          ▼               ▼                ▼
    Direction          Target           Special
    Predictor         Predictor         Predictor
          │               │                │
   ┌──────┴──────┐   ┌────┴────┐      ┌───┴────┐
   │             │   │         │      │        │
 Bimodal       Gshare uBTB    mBTB    RAS     Loop
   │             │   │         │      │        │
   └──────┬──────┘   │         │      │        │
          ▼          │         │      │        │
      Tournament     │         │      │        │
      Selector       │         │      │        │
          │          │         │      │        │
          └──────────┴─────────┴──────┴────────┘
                          │
                          ▼
                 Prediction Result
                          │
                          ▼
                         IFU
```

其中多个子预测器的置信度排列如下：

```text
从上到下置信度排序（高 → 低）：
             Direction Override Priority

        ┌─────────────────────────────┐
        │       Loop Predictor        │
        │                             │
        │  High confidence → Override │
        │  Low confidence  → Ignore   │
        └──────────────┬──────────────┘
                       │
                       ▼
        ┌─────────────────────────────┐
        │    Bimodal + Gshare         │
        │       Tournament            │
        │                             │
        │   Selected base predictor   │
        └──────────────┬──────────────┘
                       │
                       ▼
        ┌─────────────────────────────┐
        │        Fallback             │
        │     Always Not Taken        │
        └─────────────────────────────┘
```

## 3. BPU 架构设计

### 3.0 总体架构

BPU 是"快速一周期预测 + 两周期精确修正"的两级结构（`rtl/frontend/bpu/bpu.sv`）：

| 阶段 | 内容 | 延迟 |
| --- | --- | --- |
| **S0（issue）** | `fetch_pc` 同时送：uBTB 读（目标）、loop predictor 读、RAS 栈顶、bimodal/tournament PHT；TAGE 只算表索引/标签的 hash | 组合 |
| **S1（快路径，`w_fire`）** | 组合 uBTB 目标 + RAS 覆盖 + loop 覆盖 + 快速方向 → 每 slot 的 `pred_cfi/pred_taken/pred_target`；写 FTQ；推进推测 GHR | 1 周期出结果 |
| **S2（精确修正）** | TAGE（条件方向）与 mBTB（目标）的响应合并：目标优先级 `RAS > mBTB > uBTB`，方向 `TAGE（loop 覆盖优先）> S1 fast`。若与 S1 已发 fetch 的结果不同，`corr_fire` 从 `merged_npc` 重启取指；否则回填 TAGE metadata | 距 issue 2 周期 |

```text
        fetch_pc (S0)
           │  ├─ uBTB / loop / RAS / fast-dir   （异步读，S1 可用）
           │  └─ TAGE hash / mBTB set          （打拍）
           ▼
        S1 fast path ──► FTQ write (w_fire)
           │
           ▼
        S2: TAGE(BRAM 1R1W) + mBTB(BRAM 1R1W) 响应
           │
           ├─ 与 S1 相同 ──► 回填 TAGE meta（shadow1 backfill）
           └─ 不同 ────────► corr_fire，重启取指（redirect 到 merged_npc）
```

S1 的快路径保证每周期都能产生一个 fetch block（不空泡）；S2 的修正只在两者不一致时打断，代价是一次重定向。`shadow0/shadow1` 保存 S0/S1 的预测快照，用来把 S2 的 TAGE/mBTB 响应和它描述的 block 对齐（`mbtb_pred_pc == shadow1_start_pc`、`tage_resp_pc == shadow1_start_pc`）。

### 3.1 设计思路

uBTB为处理器作出无空泡的基础预测以连续生成下一个推测 PC 值，并推入Fetch Target Queue (FTQ)；TAGE/SC/mBTB为处理器提供精确预测以纠正 uBTB 的预测结果。RAS/Loop Predictor为处理器提供特殊控制流的预测。

### 3.2 子预测器单元

| 子预测器 | 类别 | 访问延迟 | 输入 | 输出 | 说明 |
| --- | --- | --- | --- | --- | --- |
| **uBTB** | 目标（快） | F1 | PC | target / cfi_type_t type / cfi_offset | 小容量，负责快速预测提供next_pc |
| **mBTB** | 目标（中） | F2/F3 | PC | 同上 | 大容量精确预测target，2~3 latency |
| **Bimodal** | 方向（快） | F1 | PC | taken | 2-bit 饱和计数器，作为 base 方向器 |
| **Gshare** | 方向（精） | F1 | PC + GHR | taken | 全局历史异或的 2-bit 饱和计数器，作为主方向器 |
| **Tournament** | 方向（选择） | F1 | PC | taken | 2-bit chooser，在 Gshare 与 Bimodal 间选择 |
| **TAGE** | 方向（精） | F2 | PC + GHR | taken + meta | 多表长历史，provider/alternate，作为主方向器 |
| **SC** | 方向（修正） | F3 | PC + GHR | taken | 统计校正器，修正 TAGE 的置信度 |
| **Loop** | 特殊 | F3 | PC | 覆盖方向 | 循环次数精确匹配时翻转方向 |
| **RAS** | 特殊 | F3 | call/ret | 返回地址 | 覆盖 JALR 返回目标 |

置信度排序（高 → 低）：`Loop / RAS -> TAGE → SC → uBTB → Always-Not-Taken`；mBTB 与 TAGE/SC 在目标/方向两个维度上分别生效。

其中cfi_type_t定义为：

```systemverilog
typedef enum logic [2:0] {
    CFI_NONE,
    CFI_COND_BRANCH,
    CFI_DIRECT_JUMP,
    CFI_CALL,
    CFI_RETURN,
    CFI_INDIRECT_JUMP
} cfi_type_t;
```

#### 子分支预测器接口

```systemverilog
interface base_predictor_if #(
    parameter int unsigned PC_WIDTH = 32,
    parameter int unsigned RESET_VEC = 32'h8000_0000
);
    // input
    logic [PC_WIDTH - 1:0] pc;
    logic                valid;

    // output
    logic                pred_valid;
    logic [PC_WIDTH - 1:0] pred_pc;
    cfi_type_t           pred_type;
endinterface
```

#### uBTB / mBTB

uBTB / mBTB 负责预测分支指令的目标地址：uBTB 是 S0 一周期可用的快速目标预测器，mBTB 是两周期可用的精确目标预测器（S2 修正）。

| 参数 | 当前值 | 说明 |
| --- | --- | --- |
| `UBTB_BANKS × UBTB_WAYS` | 16 × 8（`CONFIG_FE_UBTB_WIDTH=7`） | S0 异步读，**LUTRAM**（一周期必须） |
| `MBTB_SET_NUM × MBTB_WAYS` | 512 × 4（`CONFIG_FE_MBTB_WIDTH=9`）× 4 way | S2 响应，**BRAM** |
| `MBTB_REGION_BYTES` | 16 | 每个 mBTB 项覆盖 16 B 区域，读 lo/hi 两个区域 |

存储实现（这是 Pango/LUT 面积的关键）：

- **mBTB** 每个读端口一份整字副本，共三份：`mbtb_lo_mem` / `mbtb_hi_mem`（预测 lo/hi 区）、`mbtb_up_mem`（更新读）。每份是 `[SET]` 的整字（`MBTB_WAYS × $bits(mbtb_entry_t)`），**1R1W**，写时按 RMW 后广播到三份。
  单模块实测：**LUT 26,005 → 1,505，FF 1,564 → 1,062，DRM 0 → 9**。
- 之前版本把 `mbtb_mem[set][way]` 直接异步读（3 读 1 写），ADS 只能铺成 LUTRAM，是前端 205k LUT 的主要来源之一。
- mBTB 的表项不再做逐项复位（那会给每个表项一个写端口），改用 `initial` 零初始化。

##### btb entry设计说明

其中uBTB采用fully associative，通过寄存器实现，mBTB采用set-associative，通过SRAM实现。
BTB的每项entry的设计如下：

```systemverilog
    typedef struct packed {
        logic [ADDR_WIDTH-1:0]    start_pc;
        logic [ADDR_WIDTH-1:0]    target_pc;
        // CFI Information
        cfi_type_t                cfi_type;
        logic [FETCH_WIDTH - 1:0] cfi_offset;  // CFI 在 fetch block 中的 slot 位置
    } btb_target_info_t;

    // One CFI slot of a Fetch Block (multi-target BTB record)
    typedef struct packed {
        logic [FETCH_WIDTH - 1:0] cfi_offset;  // CFI 在 block 内的 slot 位置
        cfi_type_t                cfi_type;
        logic [ADDR_WIDTH-1:0]    target_pc;
    } btb_cfi_t;

    typedef struct packed {
        logic [1:0] useful_cnt;  // 借鉴XiangShan kunminghu-v3 中的useful counter
        logic [ADDR_WIDTH - 1:$clog2(FETCH_WIDTH * INST_BYTES)] tag;

        // Information for fetch block (up to FETCH_WIDTH CFIs, block-relative)
        logic [$clog2(FETCH_WIDTH + 1) - 1:0] cfi_count;
        btb_cfi_t [FETCH_WIDTH - 1:0]         cfi;
    } btb_entry_t;
```

##### btb 的替换策略

> ubtb 采用 useful 计数器和替换算法结合的替换策略。每个表项有一个 useful 计数器，
> 表示该表项的“有用”程度，计数器值越大表示越有用。替换时，首先选择 useful 计数器值为 0 的表项，
> 如果没有，则按替换算法（默认 plru）选择一个表项进行替换。(注：目前只实现useful替换算法)
>
> 在训练时，useful 计数器的更新策略如下：
>
> - 未命中（分配新项）时，初始化为最大值
> - 预测错误（分支属性错、位置错、目标错、实际不跳转）时
> - 若已经减至 0，视为未命中，分配新项并初始化为最大值
> - 否则，减 1
> - 预测正确且跳转时，增 1

#### Bimodal

Bimodal 是快速方向预测器，PHT 由 2-bit 饱和计数器组成，作为 tournament 的 base 方向器。

|Parameter|Value|
|---|---|
|PHT_WIDTH|10|
|Entries|1 << PHT_WIDTH = 1024|
|Counter|2-bit 饱和|

- 每条指令对应一个 PHT 项，索引为 `pc[PHT_WIDTH+1:2]`；
- 一次请求读出连续 `FETCH_WIDTH` 个 PHT 项，分别对应窗口的四个 slot，输出 `pred_taken_slots`；
- 预测值取计数器高位：`taken = counter[1]`。

计数器状态与复位：

```text
SNTK = 2'b00    WTK = 2'b10
WNTK = 2'b01    STK = 2'b11
```

复位为 `WNTK`。仅在条件分支**正常 Commit** 后由 BPU Update 训练，按实际方向对对应项做 2-bit 饱和加减。

预测为 1 级流水，`resp_valid` 与 BTB 响应对齐。

#### Gshare

Gshare 用全局历史 GHR 与 PC 异或索引 PHT：

```text
index = pc[PHT_WIDTH+1:2] ^ GHR
```

|Parameter|Value|
|---|---|
|PHT_WIDTH|10|
|GHR_WIDTH|12|
|Entries|1 << PHT_WIDTH = 1024|

同样每指令一项、一次读出四个 slot 的方向，2-bit 饱和计数，1 级流水。

由于前端是解耦的（预测远早于分支解析），GHR 需要维护两份：

```text
ghr_spec   // 推测历史，供预测使用
ghr_commit // 已提交历史，用于 redirect 时修复 ghr_spec
```

- 一个 Fetch Block 预测完成并压入 FTQ 时，按预测路径推进推测历史：

```text
for each effective predicted CFI in program order:
    ghr_spec = {ghr_spec[GHR_WIDTH-2:0], effective_pred_taken}
```

每次推进一条 CFI 的生效预测方向；当前 IFU 保留多个预测不跳转 CFI，在首个预测跳转 CFI 后截断；每条 CFI 的完整 `ghr_before` 在写入 FTQ 前生成。

- 发生 **BRU Recovery** 时，使用该 CFI 在预测时保存的 `pred_meta.ghr_before`（包含更老但未提交的正确历史）并追加 `actual_taken`，而非简单使用 `ghr_commit`：

```text
ghr_spec = {pred_meta.ghr_before 的低 GHR_WIDTH-1 位, actual_taken}
```

- `ghr_commit` 只在 CFI **正常 Commit** 的 BPU Update 事件被接受时按 lane0→lane1 顺序推进；BRU Completion 不推进。ECALL/MRET/IRQ 类架构重定向使用同周期 Commit 更新后的 `ghr_commit` 恢复 `ghr_spec`。详见 `frontend_backend_contract.md` 第 3–4 节。

PHT 只对**正常 Commit** 的条件分支训练（`bpu_update_valid && actual_cfi_type == CFI_COND_BRANCH`），索引取预测时捕获的 GHR，保证训练与预测使用同一索引。

#### TOURNAMENT

Tournament 在 Bimodal 与 Gshare 之间选择，维护每个 PC 的 2-bit chooser。

|Parameter|Value|
|---|---|
|CHOOSER_WIDTH|10|
|Entries|1 << CHOOSER_WIDTH = 1024|

```text
SBM = 2'b00  // 强偏好 Bimodal
WBM = 2'b01  // 弱偏好 Bimodal
WG  = 2'b10  // 弱偏好 Gshare
SG  = 2'b11  // 强偏好 Gshare
```

- 按 `pc[CHOOSER_WIDTH+1:2]` 读出四个 slot 的 chooser；`SBM/WBM` 选 Bimodal，`WG/SG` 选 Gshare；
- 两个分量方向器均为 1 级流水，与 chooser 对齐；
- 复位为 `WBM`。

更新规则（仅条件分支，读-改-写）：按两个分量各自是否正确，把 chooser 向正确的一方移动。

```text
两者都对 / 都错 : 保持
Gshare 对、Bimodal 错 : 向 Gshare 移动
Bimodal 对、Gshare 错 : 向 Bimodal 移动
```

预测时把两个分量的结果与 Gshare 使用的 GHR 一并写入 metadata（`chooser_meta`），训练时据此更新 chooser 和分量。

#### RAS

TODO:

#### Loop

TODO:

### 3.4 训练方法

BPU 收集原始预测的 metadata，经 FTQ/IQ 随 CFI 进入 Backend CIQ；BRU Completion 登记真实结果，最终在正常 Commit 时按 `bpu_update_t` 训练预测器。

```systemverilog
typedef struct packed {
    logic [ADDR_WIDTH-1:0] pred_target; // 原始预测目标（未必为实际生效 pred_npc）
    logic                  pred_taken;  // 原始预测方向
    cfi_type_t             pred_type;   // 原始预测 CFI 类型
    logic [GHR_WIDTH-1:0]  ghr_before;  // 逐 CFI 的预测前 GHR 快照

    chooser_meta_t chooser_meta; // 保留实际预测表索引历史，固定布局
    logic loop_override; // 停用时置零
    
} pred_meta_t;
```

后端 BRU 在 Completion 时向 CIQ 登记 `actual_npc/actual_taken/actual_target`，不直接修改 `ghr_commit` 或训练已提交预测器。后端在 **CFI 正常 Commit** 时，通过 `bpu_update_valid[1:0] / bpu_update[2]` 反馈 `bpu_update_t`（CFI PC、实际方向/目标/类型、原始 `pred_meta`），并按 `bpu_update_credit` 保证事件不丢失、顺序不变。完整接口定义见 `frontend_backend_contract.md` 第 4 节。

## 4. IFU-IDU接口设计(Instruction Queue)

IF-ID 使用参数化 IQ；当前 Kconfig 默认 HEAD=2、BODY=8，总深度 10。

```systemverilog
module iq #(
    parameter int unsigned DECODE_W = 2,  // IDU 每拍最多读出
    parameter int unsigned IQ_DEPTH = 10
) (
    input logic                              clk,
    input logic                              rst,

    // ---------- IFU Write Port ----------
    input logic                              wvalid,
    input fe_pkg::iq_entry_t                wdata[fe_pkg::FETCH_WIDTH],
    input logic [fe_pkg::FETCH_WIDTH - 1:0] wmask,  // Fetch Block中Branch后的指令置为无效
    output logic wready,

    // ---------- IDU Read Port ----------
    output logic [DECODE_W - 1:0]            rvalid,  // HEAD中有效的指令槽
    input logic [$clog2(DECODE_W+1) - 1:0]   raccept_cnt,  // 唯一消费条件：0/1/2
    output fe_pkg::iq_entry_t               rbits[DECODE_W],

    input logic                              flush  // 仅 Backend Redirect/Reset 全队列清空；Local Redirect 保留正确 prefix
);
```

内部使用 BODY+HEAD FIFO；HEAD 为 2 个寄存器，BODY 为参数化循环队列（当前默认 8），提供 IFU 写入。

```text
                 一个逻辑 IB，总容量 8 条
┌─────────────────────────────────────────────┐
│                                             │
│  Body：最多 6 条后续指令                     │
│  ┌────┬────┬────┬────┬────┬────┐            │
│  │ C  │ D  │ E  │ F  │    │    │            │
│  └────┴────┴────┴────┴────┴────┘            │
│                 │ 按顺序补充                │
│                 ▼                           │
│          ┌────────┬────────┐                │
│  Head：  │ H0 = A │ H1 = B │                │
│          └────┬───┴───┬────┘                │
└───────────────┼───────┼─────────────────────┘
                ▼       ▼
             Decoder0 Decoder1
                └───┬───┘
                    ▼
              CIQ Allocate
```

Head 保存的是指令编码、PC、预测信息等，**不是译码完成后的结果**。两套组合 decoder 持续读取 H0/H1。

Body 可以做成循环队列，维护读指针、写指针和占用量。Head 是两个位置固定的寄存器，不需要通过读指针选出。

传统的队列中，读出指令时IQ selection -> Decoder -> CIQ Allocate，减少从IQ到CIQ的组合路径长度

```text
// 传统队列：HEAD+BODY组成一条完整的队列
Body 存储寄存器
    ↓
由 read_ptr 控制的两条队首选择
    ↓
Decoder
    ↓
Producer Map 查询 / 同组 tag bypass
    ↓
CIQ 寄存器
```

加入 Head 后：

```text
路径一：
Body → 队首选择 → Head 寄存器

路径二：
Head 寄存器 → Decoder → Dependency Binding → CIQ 寄存器
```

> 当HEAD和BODY均空时，IFU可以直接将新指令旁路写入HEAD，减少latency

### 4.1 使用方法

> IQ -> IDU

1. IQ为IDU提供 2bits 的rvalid，表示HEAD中有效的指令槽。如rvalid == 2'b11，则表示HEAD中slot0 slot1均有效；
如rvalid == 2'b01，则表示HEAD中slot0有效，slot1无效；
2. IDU 根据 `rvalid` 选择连续有效前缀，计算 `raccept_cnt=0/1/2`；在同一时钟沿将对应指令写入 CIQ、IQ 消费相同数量。`raccept_cnt` 是唯一消费条件，不再使用 `rready`。BE Redirect 当周期 `raccept_cnt=0`。

> IFU -> IQ

1. IFU从icache中取指+预译码后，拉高wvalid，并根据predecode的结果设置wmask，将Fetch Block中Branch / Jal / Jalr 后的指令置为无效；

### 4.2 IQ BODY的FIFO设计

|指针|宽度|含义|
| --- | --- | --- |
|head|`numEntries` bits| 下一个要读的行|
|tail |`numEntries` bits |下一个可写的指令槽|
|maybe_full| 1 bit| 提供tail==head时的empty/full状态|

head和tail使用独热码+左旋的方式实现。

### 4.3 IQ的entry设计说明

```systemverilog
    typedef struct packed {

        // Instruction PC (needed by the multi-cycle NPC back-end)
        logic [ADDR_WIDTH - 1:0] pc;

        // 经过前端 Predecode 修正后，该条指令生效的预测下一 PC
        logic [ADDR_WIDTH-1:0] pred_npc;
        // BPU 原始预测/历史快照（Commit 训练和 BRU Recovery 用）
        pred_meta_t pred_meta;

        // Instruction
        logic [31:0] inst;
        logic        valid;  // 指令是否有效

        cfi_type_t cfi_type;  // is_jal is_jalr is_branch is_call is_ret
        logic is_cfi;  // control flow instruction
    } iq_entry_t;
```

## 5. BPU-IFU接口设计(Fetch Target Queue)

BPU-IFU通过一个16-entry的FTQ来缓存预测结果。大致执行流程如下：

```text
                    BPU
                     │
          ┌──────────┴──────────┐
          │                     │
       Fast Pred             Deep Pred
          │                     │
          │                     ▼
          │              update FTQ entry
          │                     │
          ▼                     │
       FTQ Allocate ────────────┘
          │
          ▼
       IFU / ICache
          │
          ▼
       Predecode
          │
          ├──── prediction mismatch ──┐
          │                           │
          ▼                           │
         IQ                           │
                                      │
Backend BRU ── redirect ──────────────┤
                                      ▼
                                  FTQ Flush
```

### 5.1 FTQ 总体设计

BPU-IFU通过一个16-entry的FTQ缓存BPU最终产生的Fetch Block预测结果。
BPU经过完整预测流水线后，仅在最后一级输出最终预测结果，并通过FTQ写端口写入队列。
IFU按照FIFO顺序读取FTQ中的预测结果，并据此进行取指。

FIFO设计与IQ的BODY部分一致

当 IFU 在 Predecode 阶段发现可立即修正的预测错误，或 Backend 发出 Redirect 时，
FTQ 丢弃对应错误路径的未消费预测结果并从目标 PC 重新开始取指。**只有 Backend Redirect 才对 IQ 中尚未 Dispatch 的旧路径进行整体清空**；Frontend 本地修正应保留 IQ 中的正确较老指令和修正块有效前缀，详见 `frontend_backend_contract.md` 第 3.1 节。

接口设计说明：

```systemverilog
module ftq #(
    parameter int unsigned FTQ_NUM_ENTRIES = 16
) (
    input clk,
    input rst,
    // FTQ Write Port
    input logic wvalid,
    output logic wready,
    input fe_pkg::ftq_entry_t wdata,

    // FTQ Read Port
    output logic rvalid,
    input logic rready,
    output fe_pkg::ftq_entry_t rdata,

    // flush port
    /*
    * where flush signal comes from:
    * 1. IFU Predecode mismatch
    * 2. Backend redirect
    */
    input logic flush
);
```

### 5.2 FTQ的entry设计说明

```systemverilog
typedef struct packed {
    // Fetch Block
    logic [ADDR_WIDTH-1:0] start_pc;

    // Per-slot prediction (one entry per instruction slot of the block)
    logic [FETCH_WIDTH-1:0]       pred_cfi_valid;  // BTB knows a CFI here
    cfi_type_t [FETCH_WIDTH-1:0]  pred_cfi_type;
    pred_meta_t [FETCH_WIDTH-1:0] pred_meta;       // 每个 slot 一份完整预测元数据
} ftq_entry_t;
```

**面积实测**：

| 版本 | LUT | FF | DRAM |
| --- | --- | --- | --- |
| FTQ=24、未压缩 meta | 44,517 | 27,819 | 0 |
| **FTQ=16、pred_meta 压缩后** | **13,432** | **8,179** | 0 |

压缩实现（已合入）：`tage_meta_t` 把每张表的 `idx[8]/tag[8]/hit/alt/useful_bits/base_idx/pred_taken` 移到按 fetch block 的旁路环表 `tage_block_meta_t block_meta_mem[128]`（单调 `wptr` + 8-bit 代际），slot 里只留 `block_ptr(7b)+block_seq(8b)`，每 slot **204 → ~42 bit**。提交训练时按 `block_ptr` 读旁表、`block_seq` 校验（环回绕才失配）。

准确率回归：100 iterations 下 **96.13% → 95.76%**（差异全部来自 FTQ 24→16，pred_meta 压缩本身与压缩前逐项一致：48,644,476 cycle / 95.76% / branch 95.44% / jump 98.70%）。

### 5.3 冲刷机制

FTQ中的预测结果均是比当前IFU取指pc更年轻的Fetch Block，因此发生redirect时，FTQ中所有未消费的预测结果均失效。

FTQ存在两种冲刷来源：

1. **Frontend Local Redirect**：Predecode 仅对能确定下一 PC 的错误预测在前端局部修正，保留已入 IQ 的正确较老指令；未知目标 JALR 转交 BRU 强制恢复，条件分支的实际方向不由 Predecode 猜测。
2. **Backend Redirect**：Backend 对 Branch/ECALL/MRET/IRQ 完成仲裁，Frontend 整体清除旧路径 IQ/FTQ/在途响应，从统一的 `backend_redirect_pc` 重新取指，且优先于同周期的 Local Redirect。

```text
flush
  ↓
清空所有未消费FTQ Entry
  ↓
停止使用旧预测结果
  ↓
IFU PC ← redirect_pc
  ↓
重新开始BPU预测
```

## 6. IFU 架构设计

本栏目主要介绍IFU的完整设计，包括Fetch Block、Predecode，PredecodeCheck的具体检查规则等。

### 6.1 Fetch Block设计

前端设计为 4-way fetch，IFU收到FTQ的预测结果后，向icache发出取指请求，icache返回4条指令。
由IFU对4条inst进行组织，填充iq_entry，生成Fetch Block，并进行PredecodeCheck。

Fetch Block中的CFI信息由FTQ提供，以供后续PredecodeCheck使用。

```systemverilog
typedef struct packed {

    // Fetch information
    logic [31:0] start_pc;
    logic [31:0] predicted_pc;

    // Instructions
    logic [31:0] inst [4];
    logic [3:0]  valid; // 跨cache line的、CFI指令后的指令置为无效

    // BPU 预测使用的 metadata
    pred_meta_t pred_meta;

    // FTQ association
    logic [FTQ_IDX_W-1:0] ftq_idx;

} fetch_block_t;
```

### 6.2 PredecodeCheck设计

PredecodeCheck主要检查Fetch Block中是否存在CFI指令，如果有，并进行PredecodeCheck，
主要检查：

1. CFI指令 type 是否与预测结果一致
2. Target 是否与预测结果一致(针对jal/branch指令)

若 PredecodeCheck 发现预测错误，只有在能确定正确后继 PC（例如 JAL 立即数目标）时才在前端执行 Local Redirect；这不是 Backend CIQ Flush。不能从指令编码判断条件分支的实际 taken，也不能在 Predecode 求出 JALR 的寄存器目标。未预测到的条件分支按生效预测不跳转处理，并修复对应的推测 GHR。具体保留/取消范围见 `frontend_backend_contract.md` 第 3.1 节。

> 若存在 JALR，则 Predecode 不核验其动态 Target（依赖 RF[rs1]），也不猜测其目标；该 JALR 正常进入 IQ 执行，由 BRU 在 `actual_npc != pred_npc` 时发起恢复。

```text
                 PreDecode
                     │
                     ▼
             if(find JALR in fetch block)
                     │
             BPU 是否预测？
                /          \
              yes           no
               │             │
               ▼             ▼
          正常继续       current block:
         由BRU检验       [0 ... k] valid
        Target的正确性   [k+1 ...] invalid
                              │
                              ├──────────► IQ
                              │
                               └──► JALR 正常入 IQ（不暂停后续取指）
                                       │
                                       ▼
                                  BRU 发出 redirect 请求
                                       │
                                       ▼
                                  actual target
                                       │
                         ┌─────────────┴────────────┐
                         ▼                          ▼
                    flush FTQ                 PC = target
                         │                          │
                         └────────────┬─────────────┘
                                      ▼
                                  restart BPU

```

完成Predecode后，将Fetch Block中CFI指令后的指令置为无效(通过设置wmask)，并将Fetch Block送入IQ。

下面是 PredChecker 模块对分支预测检查的错误类型：

- jal 类型错误：预测块的范围内有 jal 指令，但是预测器没有对这条指令预测跳转；
- ret 类型错误：预测块的范围内有 ret 指令，但是预测器没有对这条指令预测跳转；
- 无效指令预测错误：预测器对一条无效的指令（不在预测块范围/是一条 32 位指令中间）进行了预测；
- 非 CFI 指令预测错误：预测器对一条有效但是不是 CFI 的指令进行了预测；
- 转移目标地址错误：预测器给出的转移目标地址不正确。

若发现可由 Predecode 确定下一 PC 的错误，**保留修正点及之前的正确指令作为有效前缀写入 IQ**，并对更年轻的前端路径执行 Local Redirect；条件分支与 JALR 的动态结果仍由 BRU 确认，不能把未确定的目标当作实际 Target。

例如

```asm
add  x1, x2, x3     # slot 0  correct path
sub  x4, x5, x6     # slot 1  correct path
jal  ra, target     # slot 2  correct path, but is predicted not taken(actually taken)
xor  x7, x8, x9     # slot 3  wrong path
```

对于jal指令：

- 正确路径上——必须执行；
- 有副作用——要把返回地址写入 ra（x1）；
因此需要送入iq，同时向前端发出重定向请求以及正确的target_pc。

## 7. ICache 设计

### 7.1 ICache 总体设计

基本参数如下：

```systemverilog
parameter int unsigned FETCH_WIDTH = 4;
parameter int unsigned INST_BYTES  = 4;
parameter int unsigned LINE_BYTES  = 32;
parameter int unsigned SETS        = 64;
parameter int unsigned WAYS        = 4;

assign line offset = pc[$clog2(LINE_BYTES) - 1:0]
PC[10:5]  = set index
PC[31:11] = tag
```

采用 4-way Set Associative Cache：

```text
                 PC
                  │
          ┌───────┼───────┐
          │       │       │
        TAG      INDEX   OFFSET
          │       │       │
          ▼       ▼       ▼
       ┌─────────────────────┐
       │     4-way ICache    │
       │                     │
       │  Way0 Way1 Way2 Way3│
       └──────────┬──────────┘
                  │
             hit / miss
                  │
                  ▼
             32B line data
                  │
                  ▼
            Fetch Extractor
```

---

### 7.3 Fetch Request

IFU 每次向 ICache 提供一个起始 PC：

```systemverilog
typedef struct packed {
  logic        valid;
  logic [31:0] pc;
} icache_req_t;
```

大致读取逻辑如下：

```text
word_offset = req_pc[4:2]

for (int i = 0; i < FETCH_WIDTH; i++) {
    if (word_offset + i < LINE_BYTES / INST_BYTES)
        inst[i] = line_data[(word_offset + i) * INST_BYTES * 8 +: INST_BYTES * 8];
    else
        inst[i] = '0;
}
```

### 7.4 Fetch Window 与 Cache Line 边界

一次 Fetch 需要最多 16B，因此当：

```text
line_offset <= 16
```

时，可以完整从当前 Cache Line 提供 4 条指令。

当：

```text
line_offset > 16
```

时，4 条指令会跨越 Cache Line。

例如：

```text
fetch_pc offset = 0x18

Current Line:
0x18 → inst0
0x1C → inst1

Next Line:
0x20 → inst2
0x24 → inst3
```

目前先设计为 **不支持单次 Fetch 跨两个 Cache Line**。

```text
if line_offset > 16; then
    只返回当前 Cache Line 中剩余的有效指令，并将后续位置标记为无效。
```

例如：

```text
fetch_pc = ...18

inst[0] valid = 1
inst[1] valid = 1
inst[2] valid = 0
inst[3] valid = 0
```

下一次 Fetch 从：

```text
fetch_pc = ...20
```

重新发起请求。

因此 ICache 不需要在一次请求中同时访问两个 Cache Line，也不需要额外的跨 Line 拼接逻辑。

### 7.5 Fetch Response

ICache 返回一个 Fetch Window：

```systemverilog
typedef struct packed {
  logic        valid [FETCH_WIDTH];
  logic [31:0] pc    [FETCH_WIDTH];
  logic [31:0] inst  [FETCH_WIDTH];
} icache_resp_t;
```

其中：

```text
valid[i] = 1
```

由ifu根据接收到的icache_resp.valid选择有效指令，并推入IQ中。

以及各 `inst[i].valid` 共同确定。

### 7.6 时序设计

推荐将 Tag Lookup 与 Data Select 组织为一个 ICache pipeline stage。

基本时序：

```text
Cycle N:
    IFU → req_pc

Cycle N+1:
    Tag Lookup
    Data Select
    Hit / Miss

Cycle N+2:
    Hit:
        → 4 × instruction
        → PreDecode

    Miss:
        → Refill
```

---

## 8. Frontend ↔ Backend 跨模块接口

本章的**唯一规范性定义**见 [`frontend_backend_contract.md`](frontend_backend_contract.md)。

- **Instruction**：`rvalid/rbits/raccept_cnt` 与 Backend 的 `iq_valid/iq_inst/iq_accept_count` 对应；`rvalid` 只允许 `00/01/11`，接受连续前缀，`raccept_cnt` 是唯一 IQ pop 条件。
- **Prediction Metadata**：每条 CFI 的 `pred_npc` 为生效预测后继 PC；`pred_meta` 保留原始 BPU 预测和 `ghr_before`，随指令进入 CIQ。未预测目标的 JALR 由 BRU 在目标不符时正常恢复。
- **Redirect**：统一接收 Backend 最终仲裁的 `backend_redirect_valid/pc/kind`；Branch Recovery 使用逐 CFI `ghr_before/actual_taken` 恢复推测历史，Trap/MRET/IRQ 使用 Commit 历史。FE 本地修正不清空正确的 IQ 旧 prefix。
- **BPU Update**：接收正常 CFI Commit 的最多两个 `bpu_update` 事件，通过登记的 `bpu_update_credit` 预留事件缓冲；在接受沿更新 `ghr_commit`，预测表可按顺序延迟训练。

Backend Redirect 与同周期 Local Redirect 冲突时，Backend 获胜；旧路径 ICache 响应不得重新进入 IQ。首版不支持深级预测器在某块指令入 IQ 后对该更老块进行无定位回滚。

## 9. C5 implementation boundary (2026-10-18)

真实 FE/BE/IROM 功能集成已验收；入口与证据见 `../fe_contract_migration.md`。
GHR 的提交沿更新、独立恢复和预测表 FIFO 训练是三条分离路径；RAS/Loop 用于
恢复的提交状态也在接受沿按 lane 顺序推进。原始预测 metadata 经 Predecode/BE
保持不变；只有独立 `pred_npc` 可被本地修正。本文开头的三级深预测器、TAGE/SC/mBTB
及 1 prediction/cycle 属目标架构；本轮没有实现这些性能项目，也没有板级 PPA 签核。

## 10. 当前实现现状与实测（2026-10-28）

### 10.1 配置（已写入 Kconfig 默认值）

`configs/frontend/Kconfig` 的默认值已与当前实测配置对齐，`rm configs/build/.config && make config-gen`
即可复现：

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `FE_FETCH_WIDTH` | 4 | |
| `FE_DECODE_WIDTH` | 2 | |
| `FE_FTQ_NUM_ENTRIES` | **16** | 24→16 的 PPA 取舍（准确率 −0.37pp） |
| `FE_BASE_PREDICTOR` | `FE_BIMODAL` | S1 基础方向（TAGE 开启时不参与快路径） |
| `FE_TAGE` / `FE_TAGE_NUM_TABLES` | y / 8 | 方向主力，减到 4 表要掉 1.2pp |
| `FE_MBTB` | y | **不可关**（关掉准确率 −17.7pp） |
| `FE_RAS` / `FE_RAS_ENTRIES` | y / **8** | 32→8 零损失 |
| `FE_LOOP_PRED` | **n** | CoreMark 上关掉准确率 +0.02pp，直接删除 |
| `FE_LOOP_ENTRIES` / `FE_LOOP_ITER_WIDTH` | 16 / 8 | 模块已不例化，仅保留选项 |

消融依据（1-iteration，base 526,361 cycle / 93.52%）：

| 配置 | cycles | Overall acc |
| --- | --- | --- |
| base | 526,361 | 93.52% |
| loop off | 526,276 | **93.54%** |
| loop off + RAS 8 | 526,364 | **93.52%** |
| + TAGE 4 表 | 541,472 | 92.32% |
| MBTB off | 535,738 | 75.87% |
| TAGE off | 567,648 | 89.14% |
| RAS off | 528,386 | 93.20% |

### 10.2 单模块面积（PDS `synthesize -ads`，PG2L200H）

| 模块 | LUT | FF | DRM | 备注 |
| --- | --- | --- | --- | --- |
| `ftq` | **13,432** | **8,179** | 0 | FTQ=16 + pred_meta 压缩后 |
| `mbtb` | **1,505** | 1,062 | **9** | 三副本整字 BRAM（改造后） |
| `loop_predictor` | **5,322** | **1,457** | 0 | 配置缩减后（16 项 / 8-bit iter） |
| `iq` | 12,365 | 3,782 | 0 | |
| `ras` | **4,889** | **2,066** | 0 | 配置缩减后（32 项 / SNAP=2） |
| `icache` | 9,569 | 1,104 | 24 | |
| `tage` | 7,290 | 2,893 | 16 | 2 副本整字 BRAM |
| `frontend` 整体 | 205,349（128.5%） | 90,581 | 40 | **当前器件装不下** |

### 10.3 准确率基线（branch difftest）

`make unit-coremark BRDIFF=1`（详细见 `docs/bpu_branch_difftest.md`）：

```
Direction Tournament-Loop-Tage / Target ubtb-ras-mbtb
Branch 5,787,723 events, 95.89%    Jump 616,853 events, 98.42%
Overall 6,404,576 events, 247,623 misses, 96.13%
CoreMark: 48,639,576 cycles, IPC 0.6455, CoreMark/MHz 2.0559
```

### 10.4 待办

1. ~~mBTB BRAM 改造后的功能回归~~ —— 已完成：修复"整字 RMW 基准字未随流水打拍"的 bug 后，
   CoreMark 与 baseline **逐指标一致**（48,639,576 cycle / IPC 0.645481 / 96.13%）。
2. `pred_meta` 压缩（block_ptr/block_seq 旁表）+ FTQ 项数下调。
3. `loop_predictor` / `ras` / `ftq` 的逻辑优化，目标把 `frontend` 压回 159.8k LUT 以内。

### 10.5 mBTB BRAM 改造记录

- 结构：`mbtb_lo_mem` / `mbtb_hi_mem` / `mbtb_up_mem` 三份整字存储
  （`SET_W = MBTB_WAYS × $bits(mbtb_entry_t)`，每份 1R1W），写按整字 RMW 后广播。
- 时序不变：读地址本来就是寄存器，输出仍在 S2 与 TAGE/shadow1 对齐，`bpu.sv` 未改。
- 关键 bug（已修）：更新流水 U0 读出的整字必须随 U1→U2 打拍
  （`up_word_u1`/`up_word_u2`），否则 U3 写回时基准字已被下一次更新覆盖，
  会覆盖同 set 其它 way —— 表现为目标误预测翻倍（190k → 464k）、
  CoreMark 从 48.6M 涨到 65.0M cycle。
- 回归：accuracy 96.13%、cycles 48,639,576、IPC 0.645481，与改造前完全一致。
