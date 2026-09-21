# 支持RV32IM Mundus 前端架构设计文档

> **Version**: Draft 1.1
> **目标架构**：
> Overview: 采用一个Composer+多个子预测器的三级流水线结构
>
> 1. Buffer Queue: 8-entries Instruction Queue (IQ) / 16-entries Fetch Target Queue (FTQ)
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
       ┌───────────┼───────────┐
       ▼           ▼           ▼
 Direction       Target      Special
 Predictor      Predictor     Predictor
       │           │           │
      TAGE      uBTB/mBTB    RAS/Loop
       │
       ▼
      SC
       │
       └──────────────┐
                      ▼
               Prediction Result
                      │
                      ▼
                    IFU
```

其中多个子预测器的置信度排列如下：

```text
从上到下置信度依次降低
        Direction Override Priority

        ┌──────────────────────┐
        │    Loop / RAS        │
        │   特殊 CFI override  │
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │      TAGE + SC       │
        │  主方向预测 + 修正   │
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │       Bimodal        │
        │     基础方向预测     │
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │      uBTB hint       │
        │    快速预测 fallback │
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │   Always Not Taken   │
        └──────────────────────┘

    -------- Target Prediction --------

        ┌──────────────────────┐
        │       RAS / Loop     │
        │    特殊 CFI target   │
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │        mBTB          │
        │   高精度 target      │
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │        uBTB          │
        │   低延迟 target      │
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │     PC + 4 / target  │
        └──────────────────────┘
```

## 3. BPU 架构设计

### 3.0 总体架构

BPU采用一个Composer+多个子预测器的流水线结构。由于每一级的预测器的延迟是固定的，因此Composer可以在每个周期内收集所有预测器的结果，并覆盖前一级的预测结果。
借助快速预测器+精准预测器的组合，实现更高的预测吞吐量和更高的预测准确率。

```text
                    ┌──────────────────────┐
                    │        pc_gen        │
                    └──────────┬───────────┘
                               │
                           fetch_pc
                               │
                               ▼
                     ┌─────────────────┐
                     │ BPU F1          │
                     │ uBTB + Bimodal  │
                     └───────┬─────────┘
                             │
                             │ fast_pred_pc
                             ▼
                          pc_gen
                             │
                             │
                             │ 同时向后流水
                             ▼
                     ┌─────────────────┐
                     │ BPU F2          │
                     │ TAGE + SC+mBTB  │
                     └───────┬─────────┘
                             │
                             ▼
                     ┌─────────────────┐
                     │ BPU F3          │
                     │ RAS + Loop      │
                     └───────┬─────────┘
                             │
                             │ final prediction
                             ▼
                           FTQ
                             │
                             ▼
                            IFU


       后续发现预测错误
                │
                ▼
          redirect_pc
                │
                └──────────────────────► pc_gen
```

### 3.1 设计思路

uBTB为处理器作出无空泡的基础预测以连续生成下一个推测 PC 值，并推入Fetch Target Queue (FTQ)；TAGE/SC/mBTB为处理器提供精确预测以纠正 uBTB 的预测结果。RAS/Loop Predictor为处理器提供特殊控制流的预测。

### 3.2 子预测器单元

| 子预测器 | 类别 | 访问延迟 | 输入 | 输出 | 说明 |
| --- | --- | --- | --- | --- | --- |
| **uBTB** | 目标（快） | F1 | PC | target / cfi_type_t type / cfi_offset | 小容量，负责快速预测提供next_pc |
| **mBTB** | 目标（中） | F2/F3 | PC | 同上 | 大容量精确预测target，2~3 latency |
| **Bimodal** | 方向（快） | F1 | PC | taken | 2-bit 饱和计数器，作为 base 方向器 |
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

uBTB和mBTB的接口是一样的，区别在于容量和访问延迟不同。基本参数如下：

```systemverilog
parameter int unsigned FETCH_WIDTH     = 4;
parameter int unsigned INST_BYTES      = 4;
parameter int unsigned PC_WIDTH        = 32;
parameter int unsigned uBTB_NumEntries = 32;
parameter int unsigned mBTB_NumEntries = 4096;
parameter int unsigned mBTB_NumWays    = 4;
```

其中uBTB采用fully associative，通过寄存器实现，mBTB采用set-associative，通过SRAM实现。
BTB的每项entry包含：

```systemverilog
typedef struct packed {
    logic [1:0] useful_cnt; // 借鉴XiangShan kunminghu-v3 中的useful counter
    logic [PC_WIDTH - 1:$clog2(FETCH_WIDTH * INST_BYTES)] tag;

    // Information for fetch block
    btb_targetInfo_t btb_targetInfo;
} btb_entry_t;
```

其中，每项的targetInfo定义如下：

```systemverilog
typedef struct packed {
    logic valid;
    logic [PC_WIDTH-1:0] start_pc;
    logic [PC_WIDTH-1:0] target_pc;
    // CFI Information
    cfi_type_t           cfi_type;
    logic [2:0]          cfi_offset; // 指示CFI在Fetch Block中的位置
} btb_targetInfo_t;
```

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

TODO:

#### TAGE+SC

TODO:

#### RAS

TODO:

#### Loop

TODO:

### 3.3 预测流水线级行为

#### pipeline携带的metadata说明

```systemverilog
typedef struct packed {
    // decoupled valid/ready handshake
    logic valid;
    logic ready;

    // Fetch information
    logic [PC_WIDTH-1:0] fetch_pc;

    // Update information
    logic [$clog2(FTQ_NumEntries) - 1:0] ftq_idx;
    logic [SEQ_W-1:0] ftq_seq; // TODO: It may be not necessary

    // redirect signal
    logic has_redirect; // 只有F2 F3阶段会发出redirect
    // TODO: maybe need to add more metadata
} bpu_pipeline_meta_t;
```

> ftq_seq可能并不需要：
>
> - BPU 只有最后一级才输出最终 prediction
> - 任何输入 FTQ 的 redirect 都直接 flush 整个 FTQ

### 3.4 训练方法

BPU会在各个流水线内收集预测的metadata，最终组装为一个pred_meta，经FTQ最终送入IQ，以用于后端BRU的训练。

```systemverilog
typedef struct packed {
    // Prediction sources
    logic                    ubtb_hit;
    logic                    mbtb_hit;
    logic                    tage_hit;
    logic                    sc_hit;
    logic                    ras_hit;
    logic                    loop_hit;

    // Final provider
    pred_source_e            pred_source;

    // TAGE
    logic [TAGE_IDX_W-1:0]   tage_idx;
    logic [TAGE_IDX_W-1:0]   tage_alt_idx;

    // SC
    logic [SC_IDX_W-1:0]     sc_idx;

    // mBTB
    logic [MBTB_IDX_W-1:0]   mbtb_idx;
    logic [MBTB_WAY_W-1:0]   mbtb_way;

    // Loop
    logic                    loop_used;
    logic [LOOP_IDX_W-1:0]   loop_idx;

    // RAS
    logic                    ras_used;

    // TODO: These are generated by AI. It may need to be verified later
} pred_meta_t;
```

后端BRU需要提供这些信息

```systemverilog
typedef struct packed {
    logic      bpu_update_valid
    logic      bpu_update_pc       // CFI's source PC
    logic      bpu_update_target
    cfi_type_t bpu_update_type
    logic      bpu_actual_taken
} bpu_updateinfo_t;
```

## 4. IFU-IDU接口设计(Instruction Queue)

IF-ID通过一个8-entry的IQ来缓存指令块。

```systemverilog
module if_id_iq #(
  parameter int FETCH_W  = 4,     // IFU 每拍最多写入
  parameter int DECODE_W = 2,     // IDU 每拍最多读出
  parameter int IQ_DEPTH = 8
)(
  input  logic clk, rst_n,

  // ---------- IFU Write Port ----------
  input  logic                         wvalid,
  input  iq_entry_t                    wdata [0:FETCH_W-1],
  input  logic  [FETCH_W - 1:0]        wmask,      // Fetch Block中Branch后的指令置为无效
  output logic                         wready,

  // ---------- IDU Read Port ----------
  output logic  [DECODE_W - 1:0]      rvalid,     // HEAD中有效的指令槽
  input  logic                        rready,
  input  logic  [$clog2(DECODE_W+1) - 1:0]      raccept_cnt, // IDU实际消费的指令数
  output iq_entry_t [DECODE_W - 1:0]  rbits,

  input  logic                        flush
);
```

内部使用BODY+HEAD的FIFO结构，HEAD为2-entry，BODY为6-entry。其中HEAD仅为2个寄存器，提供给IDU。BODY则由一个6-entry的循环队列组成，提供给IFU写入。

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
2. IDU根据rvalid选择HEAD中有效的指令槽，读取对应的rbits；写入CIQ后，拉高rready，并设置raccept_cnt，表示IDU实际消费的指令数；

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
    
    // BPU metadata
    pred_meta_t pred_meta;

    // Instruction
    logic [31:0] inst;
    logic        valid;      // 指令是否有效

    logic need_redirect;     // 主要用于处理PredecodeCheck发现未被预测到的jalr指令后，
                             //   需要交给BRU进行redirect(TODO:或许会有更好的设计？)
    cfi_type_t   cfi_type;   // is_jal is_jalr is_branch is_call is_ret
    logic        is_cfi;     // control flow instruction
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

当IFU在Predecode阶段发现当前Fetch Block的预测错误，或者后端发送redirect信号时，
前端需要清空当前FTQ中的所有未消费预测结果，并从新的PC重新开始取指。

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
    input npc_pkg::ftq_entry_t wdata,

    // FTQ Read Port
    output logic rvalid,
    input logic rready,
    output npc_pkg::ftq_entry_t rdata,

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
    // Entry identity
    logic [SEQ_W-1:0]        seq; // TODO: It may be not necessary

    // Fetch Block
    logic [PC_WIDTH-1:0]     start_pc;

    // Prediction result
    logic                         pred_taken;
    logic [PC_WIDTH - 1:0]        pred_target;
    cfi_type_t                    pred_type;
    logic [$clog2(FETCH_WIDTH):0] pred_pos;

    // BPU metadata
    pred_meta_t              pred_meta;

} ftq_entry_t;
```

### 5.3 冲刷机制

FTQ中的预测结果均是比当前IFU取指pc更年轻的Fetch Block，因此发生redirect时，FTQ中所有未消费的预测结果均失效。

FTQ存在两种冲刷来源：

1. Predecode冲刷：IFU在Predecode阶段发现当前Fetch Block的BPU预测与实际CFI信息不一致时，向FTQ发送flush信号，并从实际目标PC重新开始取指。
1. Backend冲刷：后端BRU产生redirect信号时，FTQ同样被整体冲刷，IFU从redirect_pc重新开始取指。

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

若predecodeCheck发现预测错误，则向BPU和FTQ发出redirect信号，FTQ flush，并将actual target写入PC。

> 若存在jalr指令，则根据BPU是否预测了该jalr指令走不同的通路，同时不对Target进行检查(jalr依赖于rf\[rs1\])

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
                              └──► stall BPU/FTQ
                                       │
                                       ▼
                                等待 BRU redirect
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
