# RV32IM 后端微架构设计文档

> **状态**：Draft v0.45
> **目标架构**：2-wide Decode / Centralized Issue Queue Instruction Queue / Strict In-order Up-to-4 Issue / Out-of-order Completion / In-order Commit

---

## 1. 设计目标

本后端面向 RV32IM 处理器，目标是在保持控制逻辑、精确异常和验证复杂度可控的前提下，提高多功能单元并行度，并允许不同延迟执行单元独立运行。

当前后端定义为：

$$
\boxed{
2\text{-wide Decode}
\rightarrow
CIQ
\rightarrow
\text{In-order 4 Issue}
\rightarrow
\text{OoO Completion}
\rightarrow
2\text{-wide In-order Commit}
}
$$

核心设计如下：

1. 每周期最多接收 2 条 Decode 指令。
2. 所有进入后端的指令顺序分配到 Centralized Issue Queue (CIQ与Completion Queue合并)。
3. Issue 每周期最多发射 4 条，但严格保持程序顺序。
4. 不设置 FU 输出到消费者的同周期结果转发；消费者在 Issue 时读取已登记的 CIQ result，或 Architectural RF。
5. 不同 FU 独立执行，乱序完成。
6. 所有架构状态严格按程序顺序提交。
7. GPR、CSR 等架构状态只允许在 Commit 阶段更新；Store 仅在 Commit 授权后允许异步写入 DCache/Memory。
8. GPR 8 read ports / 2 write ports
9. Producer Map 记录最新的未提交写者。
10. 采用非数据捕捉设计，操作数在 Issue 时从 Architectural RF 或 CIQ result 动态解析。
11. RT-Thread 首版仅支持 M-mode、Zicsr、ECALL/MRET、机器定时器中断与有序 MMIO；具体范围见第 16–17 节。
12. CV-X-IF（custom-0 加速器）接口与全部自定义指令，见 [CV-X-IF 接口规范](xif.md)。

---

## 2. 总体后端结构

将传统意义上的 CIQ 与 Completion Queue 合并为一个统一的 **Centralized Issue Queue**。

一条指令在 Decode/Dispatch 时分配一个 Queue Entry，并一直占用该 Entry，直到最终 Commit 后释放。

```text
                     Frontend
                        │
                 Decode ≤ 2/cycle
                Dependency Tagging
               Producer Map Lookup
                        │
                 Allocate ≤ 2
                        │
                        ▼
        ┌──────────────────────────────┐
        │    Centralized Issue Queue   │
        │          CIQ / Scoreboard    │
        │                              │
        │   WAIT / EXEC / DONE         │
        │   rs / dep_tag               │
        │   rd / result / exception    │
        └──────────────┬───────────────┘
                       │
              oldest candidates
                  count ≤ 4
                       │
                       ▼
        ┌──────────────────────────────┐
        │      Operand Resolve         │
        │                              │
        │   8R GPR  /  Queue Result    │
        │ dep check + source_ready     │
        └──────────────┬───────────────┘
                       │
               ┌───────┴────────┐
               │ IssueScheduler │
               └───────┬────────┘
                       │
      ┌─────────┬──────┼───────┬─────────┐
      ▼         ▼      ▼       ▼         ▼
    ALU0      ALU1    BRU    SMUL/MUL/DIV   LSU
      │         │      │       │         │
      └─────────┴──────┴───────┴─────────┘
                       │
                tag + completion
                       │
                       ▼
              OoO Completion Update
                       │
                       ▼
        ┌──────────────────────────────┐
        │ same Centralized Issue Queue │
        │      entry[tag] = DONE       │
        └──────────────┬───────────────┘
                       │
                 oldest DONE prefix
                  commit ≤ 2
                       │
                       ▼
                In-order Commit
                  │            │
                  ▼            ▼
                 GPR         CSR / SB
```

物理上不再额外创建一个复制指令元数据的 Completion Queue。

这样可以：

* 避免 CIQ 与 Completion Queue 重复保存 PC、rd、控制信息；
* 在发射之前就保证每条指令有固定的结果存储位置；
* Producer Map 在 Dispatch 时将 architectural register dependency 固定为 instruction tag dependency；
* Issue 阶段只针对最多 4 条最老 candidate、最多 8 个 source 动态解析 RF / Queue result；
* 让 flush、commit、exception 的顺序管理统一落到一个有序结构中.

---

## 3. 16-entry Centralized Issue Queue

### 3.1 Entry 生命周期

每个 Queue Entry 使用以下基本状态：

```text
FREE
  │ allocate
  ▼
WAIT
  │ issue
  ▼
EXEC
  │ completion
  ▼
DONE
  │ commit
  ▼
FREE
```

含义：

* `FREE`：Entry 未被占用；
* `WAIT`：已经进入后端，但尚未发射；
* `EXEC`：已经发射到 FU，等待结果；
* `DONE`：执行已经完成，等待顺序提交。

Branch Flush 可以使误预测分支之后的任意未提交 Entry 直接转为 `FREE`，具体见第 15 节。

### 3.2 三个核心指针与占用计数

CIQ 采用循环队列，维护三个核心逻辑位置：

```text
commit_ptr
issue_ptr
alloc_ptr
```

定义如下：

* `commit_ptr`：最老的尚未提交指令；
* `issue_ptr`：最老的尚未发射指令；
* `alloc_ptr`：下一条 Decode 指令的分配位置。

同时维护一个 5-bit `occupancy_count`，表示当前 CIQ 中尚未 Commit 的有效 Entry 数量：

```text
0  <= occupancy_count <= 16
0  : CIQ empty
16 : CIQ full
```

`occupancy_count` 专门用于判断 CIQ 剩余容量，从而避免循环队列中指针相等时的 full / empty 歧义。Issue candidate 是否存在直接由 `entry[issue_ptr + i].state == WAIT` 判断。

逻辑布局：

```text
commit_ptr                     issue_ptr                    alloc_ptr
    ↓                              ↓                           ↓
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ DONE │ EXEC │ DONE │ EXEC │ DONE │ WAIT │ WAIT │ FREE │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
        issued region                    unissued region
```

由于 Completion 可以乱序，因此 `commit_ptr` 到 `issue_ptr` 之间允许同时存在 `EXEC` 与 `DONE`。

由于 Issue 严格有序，因此 `issue_ptr` 始终指向最老的 `WAIT` Entry。

---

## 4. Queue Entry 数据结构与 Tag

后端采用 **valid-only** 生命周期协议，不使用硬件 `allocation_generation`。`tag_t` 仅表示 16-entry CIQ 的物理 slot：

```systemverilog
typedef struct packed {
  logic [3:0] slot_index;
} tag_t;
```

Entry 的有效生命周期由 `entry.valid/state` 管理；指令发射后，各 FU 必须同时保存对应的 operation `valid/alive` 与 `tag`。Flush 清除 CIQ Entry 时必须同步取消相关 FU operation；被取消 operation 此后不得再产生有效 `completion_valid` 或 `recovery_valid`。因此 slot 可在释放后直接复用，不依赖 generation 防止 stale response。

逻辑字段如下：

```systemverilog
typedef struct packed {
  logic              valid;
  entry_state_t      state;

  logic [31:0]       pc;
  logic [31:0]       pred_npc; // BRU：Frontend 修正后生效的预测下一 PC
  npc_pkg::pred_meta_t pred_meta; // CFI：原始 BPU 预测/训练元数据及 ghr_before
  logic              need_redirect; // CFI：未预测目标（JALR）强制恢复
  npc_pkg::cfi_type_t actual_cfi_type; // CFI：Decode 确认的真实类别
  logic [31:0]       actual_npc; // BRU Completion 登记，供精确中断下一 PC 使用
  logic              actual_taken; // BRU Completion 登记，供 BPU 更新/历史恢复
  logic [31:0]       actual_target; // BRU Completion 登记，用于 BTB 训练

  fu_type_t          fu_type;
  op_t               op;

  logic [4:0]        rd;
  logic              rd_wen;

  logic [4:0]        rs1;
  logic              src1_used;
  logic              src1_dep_valid;
  tag_t              src1_dep_tag;

  logic [4:0]        rs2;
  logic              src2_used;
  logic              src2_dep_valid;
  tag_t              src2_dep_tag;

  logic [31:0]       imm; // BRU / immediate operation 要用

  logic [31:0]       result;

  logic [11:0]       csr_addr;       // CSR 指令
  logic              csr_write_en;   // 译码时确定，见 16.2
  logic [31:0]       csr_write_data; // CSR Completion 登记，Commit 时生效
  logic              is_serializing; // CSR/ECALL/MRET

  logic              exception;
  exception_cause_t  exception_cause;
  logic [31:0]       exception_tval;

  logic              is_branch;
  logic              is_load;
  logic              is_store;
  logic              is_csr;
  logic              is_fence;
} queue_entry_t;
```

验证环境可额外维护非综合的 `debug_allocation_generation[16]`，每次对应 slot 重新分配时递增，并通过 shadow sideband 跟踪 Dependency / FU / Completion / Checkpoint 身份，用断言检查 stale Completion、stale Recovery 或错误 slot 复用。该字段不属于正式 `tag_t`，不进入综合后的后端数据通路。

---

## 5. Decode / Dispatch

### 5.1 带宽

```text
DISPATCH_WIDTH = 2
```

每周期最多向 CIQ 分配两条指令。

译码前 Instruction Buffer（IB）与 Decode/Dispatch 使用“接受数量”握手。当前边界不另设译码结果缓冲，IB 只在指令成功分配到 CIQ 时消费对应指令：

```text
IB → Decode/Dispatch:
  head0 / head1       // 按程序顺序排列，head0 较老
  available_count     // 队首有效指令数：0 / 1 / 2

Decode/Dispatch → IB:
  accept_count        // 本周期成功分配到 CIQ 的指令数：0 / 1 / 2
```

实际连线统一使用 `iq_valid[1:0] / iq_inst[2] / iq_accept_count[1:0]`；`available_count` 由 `iq_valid` 求和，`iq_accept_count` 为唯一 pop 条件，不再使用独立的 `rready`。具体字段、Redirect 同周期仲裁见 `frontend_backend_contract.md` 第 2、5 节。

分配必须是连续前缀：只允许不接收、仅接收 head0、同时接收 head0/head1。不能只接收 head1。

Dispatch 根据 `occupancy_count` 判断 CIQ 剩余容量：

```text
free_count = 16 - occupancy_count
```

当 `free_count >= 2` 时最多接收两条；当 `free_count == 1` 时只允许接收 head0；当 `free_count == 0` 时停止分配。最终 `accept_count` 同时受 `available_count` 和 `free_count` 限制。

在时钟沿，IB 消费 `accept_count` 条指令，CIQ 分配相同数量的 Entry，`alloc_ptr` 同步前进；仅实际接受的指令可以更新 Producer Map。正常情况下：

```text
occupancy_count_next = occupancy_count + accept_count - commit_count
```

`accept_count = 0` 时，除 Flush 外，IB 保留尚未消费的指令。

RAW 依赖和 FU 忙不阻塞 Dispatch；依赖在此绑定为 tag，操作数就绪和执行资源检查由 Issue 阶段完成。

**Serializing Dispatch Gate**：CIQ 中存在尚未退休的 Serializing 指令时 `accept_count=0`；若本周期 `head0` 是 Serializing，只接受 `head0`；若 `head1` 是 Serializing，可同时接受 `head0/head1`，此后暂停新 Dispatch。Flush 清除被取消的 Serializing 状态；IRQ Drain 也强制 `accept_count=0`（第 17 节）。

### 5.2 Dependency Binding

```text
Producer Map Lookup
  │
  ▼
Dependency Tag Binding
  │
  ▼
Centralized Issue Queue
```

每个 source 保存：

```text
rs
src_used
src_dep_valid
src_dep_tag
```

源依赖使用第 7 节的 `dispatch_base_map`（已应用本周期正常 Commit clear）绑定。

如果源寄存器没有未提交 producer：

```text
src_dep_valid = 0
rs            = decoded_rs
```

含义是：该 source 到 Issue 时直接读取 Architectural RF。

如果存在未提交 producer：

```text
src_dep_valid = 1
src_dep_tag   = dispatch_base_map[rs].tag
rs            = decoded_rs
```

含义是：该 source 的数据语义已经绑定到指定的老指令，不能简单使用当前 `producer_map[rs]` 或直接相信 RF。

Dispatch 阶段只做 dependency binding，不要求 producer 已经完成，也不在这里从 Queue 捕获 result。

---

## 6. Producer Map 与数据依赖

### 6.1 Producer Map

维护：

```text
producer_map[32]
```

每个寄存器保存：

```text
valid
tag
```

其含义为：

> 当前尚未提交的、程序顺序上最新的该寄存器写者。

Producer Map 不保存 operand value，也不直接表示某 source 是否已经 ready。它只在 Decode/Dispatch 时把 architectural register dependency 转换为固定的 producer tag dependency。

`x0` 永远：

```text
producer_map[x0].valid = 0
```

### 6.2 Commit 时 Producer Map 清除

仅在写寄存器指令正常 Commit 成功（`commit_fire && rd_wen && rd != x0`）时，若：

```text
producer_map[rd].valid
&& producer_map[rd].tag == committing_tag
```

时清除。

未命中时保留原映射；若 Map 已指向更年轻 writer，不能清除它。正常 Commit 同时退休匹配的消费者依赖，见第 14.5 节。

---

## 7. 2-wide Dispatch 的同周期依赖

同一个 Decode cycle：

```asm
D0: add x5, x1, x2
D1: mul x6, x5, x3
```

采用同周期 **tag bypass**，允许存在 RAW 的 D0/D1 同时分配；仅转发 producer tag，不转发操作数值或 FU 结果。

先从当前 `producer_map` 出发，依次应用本周期 `commit0_fire / commit1_fire` 的条件清除（第 6.2 节），得到组合逻辑 `dispatch_base_map`。Dispatch 查询此 Map，防止新 Entry 绑定本周期已退休的 producer。

当 `accept_count = 2` 时，D0/D1 分别获得按序分配的 `tag0` / `tag1`。源依赖绑定规则如下：

1. D0 的源查询 `dispatch_base_map`，不能匹配自身或 D1 的写者更新。
2. D1 的每个有效、非 x0 源优先匹配 D0 的有效目的寄存器；命中时绑定 `tag0`，否则查询同一份 `dispatch_base_map`。
3. 未使用的源和 x0 不建立 producer 依赖。

对 D1 的每个源，逻辑为：

```text
if !src_used || rs == x0:
  src_dep_valid = 0
else if D0.rd_wen && D0.rd != x0 && D0.rd == rs:
  src_dep_valid = 1
  src_dep_tag   = tag0
else:
  src_dep_valid = dispatch_base_map[rs].valid
  src_dep_tag   = dispatch_base_map[rs].tag  // 仅 valid 时有意义
```

在上述例子中，D1 的 x5 源绑定 `tag0`，等待 D0 的结果在 Issue 时可用，不需要阻止两条指令同时进入 CIQ。

Producer Map 从 `dispatch_base_map` 开始，按逻辑程序顺序先应用 D0、再应用 D1 的目的寄存器更新，仅对实际接受且满足 `rd_wen && rd != x0` 的指令生效。若 D0/D1 写同一寄存器，最终 Map 指向较年轻的 `tag1`；D1 的源仍按上述规则绑定，不能绑定自身。

同周期逻辑顺序固定为：`Commit clear → D0 源绑定 → D0 写者更新 → D1 源绑定 → D1 写者更新`。无 Dispatch 时，普通周期的 Map next-state 为 `dispatch_base_map`；Flush 恢复优先级见第 15.3 节。

---

## 8. Strict In-order 4-Issue 发射模块设计

### 8.1 基本定义

```text
ISSUE_WIDTH_MAX = 4
```

IssueScheduler 每周期只考虑：

```text
issue_ptr + 0
issue_ptr + 1
issue_ptr + 2
issue_ptr + 3
```

对每个位置 `issue_ptr + i`，仅当对应 Entry 为 `WAIT` 时，该位置才是有效 Issue candidate：

```text
candidate_valid[i] = (entry[issue_ptr + i].state == WAIT)
```

### 8.2 连续前缀规则

Issue grant 必须是程序顺序上的连续前缀。

只允许：

```text
1111
1110
1100
1000
0000
```

例如：

```text
I0 ready
I1 ready
I2 blocked
I3 ready
```

本周期只能发：

```text
I0
I1
```

### 8.3 单条候选指令的发射条件

指令 `Ii` 可发射，当且仅当：

```text
candidate_valid
&& all_sources_ready
&& target_fu_available
&& memory_ordering_ok
&& control_ordering_ok
&& serializing_constraint_ok
&& all_older_candidates_fired
```

其中 `target_fu_available` 表示存在一个兼容且尚未被本周期更老指令占用的执行端口，并且该 FU 的 `can_accept = 1`。`can_accept` 由各 FU 自身产生，只表示本周期物理接收能力；最终端口选择和发射决定仍由 IssueScheduler 统一完成。

对当前普通、自然对齐、可缓存的 Load/Store，`memory_ordering_ok` 在后端视为成立：内存依赖与访问顺序由 LSU 内部保证。后端仅检查第 9.6 节规定的端口和 credit。MMIO 在 AGU 后由 LSU 识别与延迟执行，额外权限见第 9.6、16 节。

**Serializing Issue Gate**：CSR/ECALL/MRET 仅当其 `tag == commit_ptr`（所有更老指令已提交）、`lsu_mmio_order_idle=1` 且源操作数就绪时可单独 Issue；该周期不发射任何其他候选，直到该指令正常 Commit 或 Trap 前都不得 Issue 更年轻指令。普通指令仍沿用连续前缀发射。

### 8.4 源就绪查询与操作数读取

Issue 只查询四条候选的最多八个 source，不对整个 CIQ 做广播数据捕捉，不重新查询 Producer Map 改变已绑定的依赖。

| Source 状态 | Ready | 数据来源 |
|---|---|---|
| 未使用或 x0 | 1 | 忽略或常量 0 |
| `src_dep_valid == 0`（无依赖或已正常退休） | 1 | Architectural RF |
| `src_dep_tag` 指向有效 producer，且 `DONE && !exception` | 1 | 已登记的 CIQ result |
| `src_dep_tag` 指向有效 producer，但尚未完成 | 0 | 等待 |
| producer 异常，或对应 slot 无效（协议错误） | 0 | 等待异常处理／恢复，不能使用普通结果 |

正常 Commit 在时钟沿清除匹配的 `src_dep_valid`，见第 14.5 节；Issue 不查询退休历史。由于 producer Entry 直到 Commit 才释放，而 Commit 同周期会退休所有匹配的 WAIT 依赖，正常情况下 `src_dep_valid == 1` 必须仍指向有效 producer；若对应 slot 无效，应视为协议错误并由断言捕获，不能回退读 RF。同组 RAW 的消费者指向仍为 WAIT 的 producer，因此不能同周期发射；不同 Entry 保存独立结果版本，WAW 本身不要求禁止同时发射。

Ready 查询与 RF／CIQ result 读取在同一 Issue 级并行进行，仲裁只依赖控制状态。CIQ result 逻辑上需要最多八路独立读取，可将窄的状态／依赖元数据与 32 位结果数组物理分开。FU 接收时锁存操作数，不延后重新读取 Architectural RF。

### 8.5 连续前缀资源仲裁

不设置全窗口 oldest-ready 选择或年龄矩阵。每个物理 FU 独立提供 `can_accept`；IssueScheduler 以这些信号初始化本周期可用端口集合，并按 I0 到 I3 顺序完成连续前缀仲裁和端口预约：

```text
remaining[port] = fu_can_accept[port]
prefix_ok = 1
for i = 0..3:
    port = 从 remaining 中选择 Ii 支持的端口
    grant[i] = prefix_ok && candidate_ok[i] && port_exists
    if grant[i]:
        remaining[port] = 0
    prefix_ok = grant[i]
```

这里 `candidate_ok` 包括第 8.3 节的候选、操作数和顺序条件。端口一旦被更老指令预约，本周期不得再次分配；遇到第一条无法发射的指令即停止所有更年轻指令。

第一版 ALU0/ALU1 为两个独立等价端口，分别提供 `alu0_can_accept / alu1_can_accept`；其他 FU 按各自物理端口提供 `can_accept`。`MUL` 指令在 Issue 取得真实 operand 后判断是否满足 Short-MUL 条件：满足时兼容 `SMUL | MUL`，并优先预约 `SMUL`；否则仅兼容完整 `MUL`。Scheduler 对已 grant 的端口直接产生 `issue_valid`，不存在第二次 `ready` 仲裁，具体接口见第 10 节。

### 8.6 Issue 流水线与完成可见性

采用单个 Issue／Operand Read 级，各 FU 在入口寄存器锁存已获准请求：

```text
Decode/Dispatch：分配 Entry 并绑定 tag
 → Issue：读取候选，并行查询 ready／取数，前缀仲裁和端口预约，周期末写入 FU input register
 → Execute：各 FU 独立执行，可有不同级数和延迟。执行完成后将结果写入 CIQ
 → Commit：检查已登记的完成状态，最多两条顺序提交
```

FU input register 用于切分 Issue 与 Execute 组合路径，不承担 `ready/valid` 弹性缓冲功能。第一版 ALU0/ALU1 定义为 `latency = 1, II = 1`：周期 N 接收请求，周期 N+1 完成，并可每周期继续接收一条新请求。

---
 
## 9. Functional Unit 组织与定义

第一版物理执行资源：

```text
ALU0
ALU1
BRU
SMUL
MUL
DIV
CSR        // 单实例，CSR/ECALL/MRET，序列化
LSU        // 单 Load/Store Issue Port，见第 9.6 节
```

Issue 每周期最多选择 4 个物理端口。FU 在 guaranteed-accept 协议下接收 `issue_req`，不额外设置 skid buffer；具体 LSU 入口实现由 `memory.md` 规定。IssueScheduler 检查端口兼容关系与 `can_accept`，LSU 另检查 Load/Store credit（第 9.6.2 节），不依赖 FU latency。

| FU | 数量 | Latency | II | `can_accept` |
|---|---:|---:|---:|---|
| ALU | 2 | 1 | 1 | `1` |
| BRU | 1 | 1 | 1 | `1` |
| SMUL | 1 | 1 | 1 | `1` |
| MUL | 1 | 参数化 2/3 | 1 | `1` |
| DIV | 1 | variable | variable | `!busy || completing_this_cycle` |
| CSR | 1 | 1 | 1 | `1`（仅允许序列化 Issue） |
| LSU | 1 | variable | 最快 1 | `lsu_can_accept`；另检查 Load/Store credit（9.6.2） |

### 9.1 ALU0 / ALU1

两个 ALU 为完全对称的独立端口，支持 RV32I 普通整数运算（ADD/SUB、逻辑、移位、比较、LUI/AUIPC 及其 immediate 形式）。定义为 `latency = 1, II = 1`：周期 N 接收，周期 N+1 Completion；正常运行时 `can_accept = 1`。

### 9.2 BRU

BRU 独立支持 `BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR`，定义为 `latency = 1, II = 1`，正常运行时 `can_accept = 1`。BRU 根据 `pc/src/imm` 计算 `actual_npc`，并使用：

```text
mispredict = need_redirect || (actual_npc != pred_npc)
```

`JAL/JALR` 的普通结果为 `pc + 4`。BRU Completion 同沿另登记 `actual_npc / actual_taken / actual_target` 到 CIQ，供精确中断与 BPU Commit 训练使用。`need_redirect=1`（未预测目标的 JALR）即使 `actual_npc == pred_npc` 也必须恢复前端取指。第一版 BRU 不处理 instruction-address-misaligned；恢复通过第 15 节的 `recovery_valid / recovery_branch_tag / redirect_pc` sideband 直接触发，不等待 Commit。跨模块 Redirect 见 `frontend_backend_contract.md`。

### 9.3 Short MUL（SMUL）

SMUL 为 1-cycle 组合短乘法端口，仅优化 `MUL`，定义为 `latency = 1, II = 1, can_accept = 1`。第一版采用 **Independent Fit + 17×17 signed multiply**：两个源操作数分别独立判断能否无损表示为 16-bit unsigned 或 signed，只要二者各自均满足其一，即允许进入 SMUL。

```text
src1_fit_u16 = (src1[31:16] == 16'h0000)
src1_fit_s16 = (src1[31:16] == {16{src1[15]}})
src1_fit16   = src1_fit_u16 || src1_fit_s16

src2_fit_u16 = (src2[31:16] == 16'h0000)
src2_fit_s16 = (src2[31:16] == {16{src2[15]}})
src2_fit16   = src2_fit_u16 || src2_fit_s16

smul_eligible = (op == MUL) && src1_fit16 && src2_fit16
```

每个 eligible operand 在进入乘法器前统一规范化为 17-bit signed：unsigned-fit 时使用 `{1'b0, src[15:0]}`，否则使用 `{src[15], src[15:0]}`。随后执行 signed `17×17 -> 34-bit` 乘法并取低 32 bit 作为 `MUL` 结果。该方案可统一覆盖 unsigned×unsigned、signed×signed 及 mixed signed/unsigned 的短操作数组合，并保持与完整 RV32 `MUL` 的低 32-bit 结果严格等价。

满足条件的 `MUL` 同时兼容 `SMUL | MUL`，Scheduler 优先选择 SMUL，以保留完整 MUL 给不能走短乘法路径的指令；`MULH/MULHSU/MULHU` 始终进入完整 MUL。

**未来可选优化：Asymmetric 17×33 Short MUL。** 若综合时序、面积和 workload profile 表明值得，可将 eligibility 放宽为只要求至少一个 operand 满足 `fit16`，将短 operand 规范化为 17-bit signed，另一完整 32-bit operand 扩展为 33-bit signed，并使用 `17×33` 组合乘法器。该方案可覆盖 `small × full-width` 场景、提高 fast-path 命中率，但面积和组合路径明显高于 17×17，因此不作为第一版默认实现。

### 9.4 Full MUL

完整 MUL 支持 `MUL/MULH/MULHSU/MULHU`，采用 fully-pipelined 固定延迟结构：

```text
MUL_LATENCY = 2 or 3   // 参数化，按实现时序选择
II          = 1
can_accept  = 1
```

每一级保存 `pipe_valid + tag`；Flush 只需清除命中 `kill_mask` 的有效位，无效数据可继续穿过流水线但不得产生有效 Completion。

### 9.5 DIV

DIV 为单实例自研 radix-4 iterative divider，支持 `DIV/DIVU/REM/REMU`。内部保存 `busy/alive + tag + operands + partial state + iteration_count`，并定义：

```text
div_can_accept = !busy || completing_this_cycle
```

允许旧 DIV Completion 与新 DIV request 在同一时钟沿交接。被 Flush kill 时立即 abort，清除 `busy/alive`。除零与 signed overflow 按 RV32M 结果语义处理，不产生 arithmetic exception；可对除零、0、±1 等简单情况加入不早于下一周期的 fast path。

### 9.6 LSU：后端可见接口契约

本节**仅规定 Backend ↔ LSU 接口、提交语义及取消保证**。LSU 内部的 AGU、LQ/SQ、Store forwarding、DCache/MSHR、请求仲裁、Completion 缓冲和后续扩展统一由 `memory.md` 定义，不在后端文档重复规定。

当前接口支持普通、自然对齐的 cacheable Load/Store 及第 9.6.5 节约束的 uncached MMIO。misaligned、FENCE/FENCE.I 和通用访存异常尚未支持。

#### 9.6.1 端口与信号

当前配置为 **1 个 Load/Store Issue Port**（每周期最多接收 1 条）和 **1 个 LSU Completion Port**（每周期最多完成 1 条）。Store Commit 独立支持最多 2 条/cycle，见第 14.6 节。

| 方向 | 信号 | 后端可见语义 |
|---|---|---|
| LSU → IssueScheduler | `lsu_can_accept` | LSU 本周期可保证接收一条请求 |
| LSU → IssueScheduler | `load_credit / store_credit` | 可预留的 Load/Store 容量；相应 credit 非零才允许发射 |
| IssueScheduler → LSU | `issue_valid / fu_req_t` | 已获端口及对应 credit 的请求，格式见第 10 节 |
| LSU → Completion Network | `completion_valid / fu_completion_t` | 无 backpressure 的单周期完成事件，见第 11 节 |
| Commit ↔ LSU | `store_commit_valid/tag、store_commit_ok、commit0_fire/commit1_fire`（2 lanes） | Store 提交确认，见第 14.6 节 |
| Backend → LSU | `kill_mask[15:0]` | 取消命中 CIQ slot 的未提交 operation，见第 15 节 |
| Commit → LSU | `load_head_valid/tag` | 指示 CIQ Commit Head 为 `EXEC` Load；LSU 自行判断是否 MMIO |
| LSU → CSR/Commit | `lsu_mmio_order_idle` | 更老已提交 MMIO 写入均已完成、没有未决设备副作用 |

#### 9.6.2 Issue 接收与内存顺序责任

Scheduler 对 Load/Store 必须同时检查 `lsu_can_accept` 与相应 `credit > 0`，按第 8 节连续前缀规则预约端口。`lsu_can_accept` 不组合依赖 `issue_valid`；credit 仅反映已登记的可用容量，不借用本周期预计释放的容量。

对已获 grant 的请求，`issue_fire = issue_valid`，LSU 必须在该时钟沿接收并保有对应 operation；不再提供 `ready`、重试或重复 Issue。`fu_req_t` 中 `op` 区分 Load/Store 及访问类型，`src1` 为地址基址，`imm` 为偏移，Store 的 `src2` 为待写数据；具体地址、字节选择和访存执行由 LSU 负责。

**当前普通可缓存访存的 Store/Load 先后关系、转发与等待由 LSU 内部保证**；后端不检查 LSU 内部 Store 地址、队列状态或 DCache/MSHR 状态，也不要求较老 Store 已完成执行才允许年轻 Load Issue。后端只根据端口、credit 和其他全局发射条件决策。

#### 9.6.3 Completion 的外部语义

- Load Completion：`result` 是按指令语义完成字节选择、符号/零扩展后的 32-bit 结果；结果仅进入 CIQ，最终 GPR 写入仍由 Commit 执行。
- Store execution Completion：仅表示该 Store 的执行和提交前检查已完成，**不代表已写入 DCache/Memory，也不代表 Store 已 Commit**。
- 每个未被 kill 的已接收 operation 最终恰好产生一次 Completion，最早为 Issue 的下一周期；LSU 对外最多 1 个/cycle，不提供 `completion_ready`。结果积压由 LSU 自行保留、仲裁，不得丢失或重复发送。
- Store Commit 后的实际内存更新不再产生第二次 execution Completion。

#### 9.6.4 Store Commit 与 Flush 边界

Store 只有在第 14.6 节对应的 Store `commit_fire` 成功后，才能产生不可撤销的架构访存副作用；此前的推测 Store 不得修改架构可见内存。已获 Commit 授权的 Store 后续由 LSU 独立完成，不阻塞对应 CIQ entry 的释放。

Flush 时 LSU 必须取消 `kill_mask` 命中的未提交 Load/Store 及其尚未发出的 Completion；kill 与 Completion 同周期冲突时 kill 优先。**已获 Commit 授权的 Store 不得因原 CIQ slot 释放、复用或后续 kill 而被取消。** LSU 必须内部隔离被取消事务的旧响应，禁止向复用后的 CIQ slot 发送 stale Completion；该责任不要求后端 `tag_t` 携带 generation。

LSU 内部缓冲、访存顺序、已提交 Store 的后续写入、旧响应隔离和未来多 Memory Port / banked DCache 方案见 `memory.md`。

#### 9.6.5 MMIO 的后端可见规则

AGU 在 LSU 内按 SoC 地址窗口区分 cacheable/MMIO；不增加 Memory Issue Port。**MMIO Load** 可按原 Issue/Credit 进入 LQ，但必须等 `entry[tag]` 成为 `commit_ptr` 所指的 `EXEC` Load，Backend 才输出 `load_head_valid/tag`（不需要知道地址是否 MMIO）；LSU 还须满足较老 Store 可见性顺序，才能发送一次不可撤销的设备 Read，收到响应后按普通 Load Completion/Commit。**MMIO Store** 按 SQ 正常执行并产生一次 Store Completion，只有 `commit_fire` 授权后才可发送设备 Write，设备确认写入生效后才释放 SQ；不得进入 DCache/MSHR/Fabric Write Queue。

`lsu_mmio_order_idle` 仅按已登记的 MMIO 完成状态，在所有已提交 MMIO 设备写入完成且无未决设备副作用时为 1；不得组合依赖本周期设备响应；CSR/ECALL/MRET 及 IRQ Trap Entry 必须检查此信号。MMIO 具体请求/完成/排序契约由 `memory.md` 第 3.1 节定义，不在此复制状态机。

---

## 10. FU Request 与取消协议

所有普通 FU 使用统一请求格式：

```systemverilog
typedef struct packed {
  tag_t        tag;
  op_t         op;

  logic [31:0] src1;
  logic [31:0] src2;
  logic [31:0] imm;
  logic [31:0] pc;
  logic [31:0] pred_npc; // BRU only
  logic        need_redirect; // BRU only：要求强制恢复的未预测 JALR
  logic [11:0] csr_addr;  // CSR only
  logic        csr_write_en; // CSR only；由编码中的 rs1/uimm 是否为零确定
} fu_req_t;
```

每个物理 FU 使用 guaranteed-accept 请求协议：

```text
FU -> IssueScheduler:
  can_accept

IssueScheduler -> FU:
  issue_valid
  issue_req

Backend -> FU:
  kill_mask[15:0]
```

`can_accept = 1` 表示 FU 保证能够在本周期末锁存一条新请求；该信号不得组合依赖本周期 `issue_valid`。IssueScheduler 只会向已经预约且 `can_accept = 1` 的端口产生请求，因此：

```text
issue_valid -> can_accept
issue_fire = issue_valid
```

不存在第二次 `ready`、retry 或跨周期端口预约。每个在途 operation 必须保存 `valid/alive + tag`；若：

```text
operation_valid && kill_mask[operation_tag.slot_index]
```

则清除该 operation 的有效位，此后不得产生有效 Completion；BRU operation 还不得产生有效 Recovery。

---

## 11. FU Completion 接口与协议不变量

所有普通 FU 使用统一 Completion：

```systemverilog
typedef struct packed {
  tag_t              tag;
  logic [31:0]       result;

  logic              exception;
  exception_cause_t  cause;
  logic [31:0]       tval;
} fu_completion_t;
```

接口为：

```text
FU -> Completion Network:
  completion_valid
  completion
```

Completion 无 backpressure，不设置 `completion_ready`。核心协议如下：

1. 每个 `issue_fire` 且未被 kill 的 operation 最终必须恰好产生一次 `completion_valid`。
2. 被 kill 的 operation 此后不得产生 `completion_valid`；BRU 同样不得产生 `recovery_valid`。
3. Completion 最早只能出现在 `issue_fire` 的下一周期。
4. `completion_valid` 为单周期事件，不等待接收端 ready。
5. kill 与 Completion 同周期命中同一 operation 时，kill 优先。
6. FU 的推测执行不直接修改 architectural state；所有执行结果先写入 CIQ。LSU 仅可对已获 Commit 授权的 Store 产生不可撤销的访存副作用（第 9.6 节）。
7. BRU Recovery 是普通 Completion 之外唯一的低延迟控制 sideband；CSR 的架构写入由 Commit 独立处理。
8. CSR Unit 使用普通 Completion 回传旧 CSR 值（或 ECALL 异常），另同步回传本地 `csr_write_data` 以登记 CIQ；BRU 同步回传 `actual_npc`。这些伴随字段仅在对应 FU 的有效 Completion 时登记，不修改其他 FU 的通用 Completion 格式。

---

## 12. OoO Completion

所有已经发射的 FU 独立运行。

Completion 仅更新内部 Entry：

```text
state     = DONE
result    = completion.result
exception = completion.exception
...
```

不会直接修改 GPR、CSR 或 Memory。

---

## 13. Completion Network

Completion Network 负责：

1. 仅接受 `completion_valid && entry[completion.tag.slot_index].valid && entry[completion.tag.slot_index].state == EXEC && !kill[completion.tag.slot_index]` 的 Completion；
2. 在时钟沿登记 result 和 DONE，下一周期由候选查询 producer 状态判断就绪；
3. 保存 exception/cause/tval，异常完成不能作为普通源就绪；
4. 接收各 FU 的独立结果。

执行结果直接保存在预先分配的 CIQ Entry 中。CIQ 使用寄存器数组及 per-entry write-enable，支持所有 FU 同周期完成并更新不同 Entry，不设置共享 Completion 写入带宽仲裁。有效 Completion 在周期末直接登记，消费者从下一周期查询并读取结果。Completion Network 不使用 generation 区分 slot lifetime；其安全性依赖 FU 的 operation-valid 协议：被 Flush 取消的 operation 后续不得再次产生 `completion_valid = 1`。

由于不同 FU 一周期可能完成多条指令，CIQ 应允许多个不同 Entry 同周期被写。

实现上适合使用寄存器数组加 per-entry write-enable，而不是强行映射成单写口 RAM。**理论上两个 completion 不应命中同一个有效 tag；若出现，或被 kill operation 后续仍产生有效 Completion，均视为协议/控制错误，并由 `debug_allocation_generation` 等验证断言捕获。**

---

## 14. In-order Commit

### 14.1 Commit Width

```text
COMMIT_WIDTH = 2
```

### 14.2 Commit 规则

只检查：

```text
commit_ptr
commit_ptr + 1
```

并形成连续 DONE 前缀。

例如：

```text
I0 DONE
I1 DONE
```

可提交 2 条。

```text
I0 DONE
I1 EXEC
```

只提交 I0。

```text
I0 EXEC
I1 DONE
```

提交 0 条。

### 14.3 架构状态唯一写入口

以下状态只能在 Commit 阶段修改：

* GPR；
* CSR；
* architectural Store 的不可撤销授权（实际访存更新由 LSU 在授权后异步完成）；
* exception/trap architectural state；
* 其它 architecturally visible state。

因此：

```text
execution complete != architectural writeback
```

这是保持 Precise Exception 的基础。CSR、Trap Entry、MRET 的唯一架构状态更新点和独占提交规则见第 16–17 节。

### 14.4 2-wide GPR Commit Write

Architectural GPR 提供最多 2 个 Commit write ports。

对于：

```text
commit0 = older
commit1 = younger
```

若两条均满足 `rd_wen && rd != x0`，则允许同周期写回两个寄存器。

如果：

```text
commit0.rd == commit1.rd
```

则必须保证程序顺序上更年轻的 `commit1` 最终获胜，相当于按顺序先应用 commit0，再应用 commit1。

Issue 侧 source 若仍带有指向正在 Commit producer 的有效 dependency tag，本周期仍按周期初状态从该 producer 的 CIQ `result` 取值，FU 接收时锁存操作数。时钟沿之后依赖退休生效，后续 Issue 从 Architectural RF 读取，不依赖 RF primitive 的 read-during-write 行为。

### 14.5 Commit-time Dependency Retirement

`commit0_fire / commit1_fire` 仅表示对应指令成功正常提交（非异常、非 squash，所需架构写入／副作用已被接受），不表示仅选中 Commit candidate。`commit1_fire` 必须以 `commit0_fire` 为前提；广播 tag 使用 4-bit CIQ slot `tag_t`。正常退休的 CFI 还需按 `frontend_backend_contract.md` 第 4 节预留 BPU Update credit，并在 `commit_fire` 同沿向 Frontend 发送训练事件；credit 不足只阻塞相应 CFI 及年轻 Commit，不影响较老可提交指令。

对周期初所有有效 `WAIT` Entry 的两个 source，分别计算：

```text
retire_src = src_dep_valid
             && ((commit0_fire && src_dep_tag == commit0_tag)
                 || (commit1_fire && src_dep_tag == commit1_tag))

if entry.valid && entry.state == WAIT && !kill[entry]:
    if retire_src:
        src_dep_valid_next = 0
```

正常 Commit 的时钟沿完成架构写入、释放 producer Entry，并清除匹配消费者的 `src_dep_valid`。`rs` 和 `src_dep_tag` 不变，后者在 valid 清零后无意义；从下一周期起，该 source 按第 8.4 节直接读 RF。消费者同周期 Issue 时仍读旧状态中的 CIQ result，退休清位不参与本周期 ready／取数路径。

新 Dispatch Entry 按第 7 节从 `dispatch_base_map` 绑定依赖，不使用旧 Entry 的清位结果；由此覆盖 Commit 与 Dispatch 同周期的情况。依赖清位只作用于周期初的 WAIT 消费者，不能覆盖新分配 Entry 的初始化字段。

Flush／异常取消不能触发 dependency retirement。Flush 同周期，kill 优先释放被 squash 的 Entry，surviving WAIT Entry 仍应用正常 Commit 清位；冻结 Checkpoint 不修改，恢复时继续按第 15.3 节校验。

严格顺序发射及顺序提交保证消费者取数前，更年轻 writer 不会提交覆盖所需 RF 值。本机制只广播 Commit tag 并清依赖有效位，不捕捉结果，不新增退休表或退休状态字段。

### 14.6 2-wide Store Commit 确认

Store Commit 的两个通道**与全局 `commit0/commit1` lane 一一对应**，不将两个 Store 压缩到独立编号的 lane。对每个 lane `i ∈ {0,1}`：

- 仅当该 lane 的 Commit candidate 是有效 Store 时，向 LSU 提供 `store_commit_valid[i] = 1` 及其 `store_commit_tag[i]`；非 Store 不使用对应 `store_commit_ok[i]`。
- LSU 返回 `store_commit_ok[i]`，表示该候选 Store 已满足提交前检查，能够在本时钟沿接受 Commit 授权；它只依赖已登记状态，不能组合依赖 `commit_fire[i]`。
- 对 Store，正常 `commit_fire[i]` 必须同时满足 CIQ `DONE && !exception && !kill` 和 `store_commit_ok[i]`；`commit1_fire` 仍须以 `commit0_fire` 为前提。
- 仅在 `store_commit_valid[i] && commit_fire[i]` 时，LSU 接受该 Store 的不可撤销授权；后端在同一沿释放对应 CIQ entry，不要求 DCache 当周期接收写请求。

最多允许两个 Store 同周期获得 Commit 授权。Store execution Completion、Commit 确认与授权后的内存更新相互独立，因此单 LSU Completion port 不限制 2-wide Store Commit。MMIO Store 同样在 Commit 授权后才可能发生设备副作用，其写完成仍由 LSU 独立跟踪。内部 Store 状态转移、缓存写入及 drain 时序由 `memory.md` 定义。
---

## 15. Branch Flush 与 Producer Map 恢复

本设计采用 **Branch Map Checkpoint**。Checkpoint 建立后保持冻结，误预测恢复时通过 surviving CIQ Entry 校验其中的 tag，不在 Flush 时扫描整个 CIQ 重建 Producer Map。

### 15.1 Flush 触发与恢复边界

BRU 发现分支误预测时产生：

```text
recovery_valid
recovery_branch_tag
redirect_pc
```

`recovery_valid` 必须由仍有效的 BRU operation 产生；被 Flush 取消的 BRU operation 此后不得产生有效 Recovery。该规则与 FU Completion 的 valid-only 生命周期协议一致。

分支自身保留并正常完成，只清除所有比该分支年轻的指令。Backend 统一 Redirect 接口携带目标 PC、Branch 类型、CIQ 保存的 `pred_meta.ghr_before` 与 BRU `actual_taken`；Frontend 同周期重定向并清空错误路径 IQ/FTQ，旧 ICache 响应不得再入队。该周期 `accept_count = 0`；更老的 DONE 指令仍可正常 Commit（见 `frontend_backend_contract.md` 第 3 节）。

CIQ 中相对 `commit_ptr` 的循环距离定义为：

```text
age(i) = (i - commit_ptr) mod 16
```

对仍有效的 Entry：

```text
kill[i] = entry[i].valid
          && age(i) > age(recovery_branch_tag.slot_index)
```

`kill[i]` 与 Entry 原状态无关，年轻的 `WAIT / EXEC / DONE` 均直接转为 `FREE`；误预测分支自身不在 kill mask 中。

### 15.2 Branch Map Checkpoint

每个在途控制转移指令按其 CIQ slot 保存一份 Producer Map 快照：

```text
checkpoint_valid[16]
branch_checkpoint[16][32] = {valid, producer_tag}
```

Checkpoint 表示：

> 执行到该控制转移指令自身为止、尚未包含任何年轻指令时的 Producer Map。

Checkpoint 只在该指令成功 Dispatch 时写入，之后保持冻结，Commit 不回写或修补 Checkpoint。`x0` 的 checkpoint 项始终无效。

2-wide Dispatch 从第 7 节的 `dispatch_base_map` 开始，按 D0 → D1 的程序顺序建立快照：

* D0 为控制转移时，先应用 D0 自身的目的寄存器更新并保存 D0 Checkpoint，再处理 D1；
* D1 为控制转移时，先依次应用 D0、D1 的目的寄存器更新，再保存 D1 Checkpoint。

因此，若 `JAL/JALR` 写 `rd`，其 Checkpoint 必须包含指向自身 tag 的映射；普通条件分支不写 `rd`。

分支正确解析后释放自身 Checkpoint。误预测时，在完成恢复后释放该分支的 Checkpoint，同时清除所有被 squash 的年轻分支 Checkpoint。

### 15.3 Frozen Checkpoint 恢复校验

由于 Checkpoint 不随 Commit 更新，其中的 producer 可能已经提交并释放，甚至原 slot 已被复用。因此不能直接将整个 Checkpoint写回 Producer Map。

恢复请求首先必须满足：

```text
checkpoint_valid[branch_slot]
&& entry[branch_slot].valid
&& entry[branch_slot].is_branch
```

`recovery_branch_tag` 来自仍有效的 BRU operation，因此正常情况下不会出现旧分支 Recovery 命中新 slot 的情况；若上述条件不成立属于控制协议错误，应由断言捕获，不能使用该 Checkpoint 恢复。验证环境使用 `debug_allocation_generation` 额外检查 Recovery 所属 allocation lifetime。

对每个寄存器 `r`，取：

```text
cp = branch_checkpoint[branch_slot][r]
id = cp.producer_tag.slot_index
```

仅在以下条件全部成立时恢复该映射：

```text
cp.valid
&& entry[id].valid
&& !kill[id]
&& !commit_free[id]
&& entry[id].rd_wen
&& entry[id].rd == r
```

否则恢复为 `producer_map[r].valid = 0`。其中 `commit_free` 包含本周期正常 Commit 的更老 Entry，因此同周期 Commit 不会留下 stale mapping。若 Checkpoint 中的旧 producer slot 已被复用，则新 occupant 必然年轻于该分支并被 `kill[id]` 排除，因此无需 backend-wide generation。

恢复逻辑只需为每个寄存器按 Checkpoint 中的 tag 索引并校验一个 CIQ Entry，不需要在 16 个 Entry 中搜索 youngest surviving writer：

```text
validated_checkpoint[r] =
    checkpoint producer slot still survives
        ? checkpoint[r]
        : invalid

producer_map <= validated_checkpoint
```

恢复 Producer Map 的写入优先于普通 Commit clear；Flush 周期不允许 Dispatch，因此不存在同周期新 writer 更新。

### 15.4 CIQ 指针与计数恢复

严格顺序 Issue 保证误预测分支能够进入 BRU 时，它及所有更老指令均已发射。因此恢复后：

```text
issue_ptr = branch_slot + 1
alloc_ptr = branch_slot + 1
commit_ptr = commit_ptr + commit_count

occupancy_count_next = occupancy_count
                       - commit_count
                       - squash_count
```

其中 `squash_count` 为 kill mask 中有效 Entry 的数量。`commit_ptr` 不因分支恢复回退，只按同周期实际提交数量前进。

### 15.5 FU 取消与 Completion 处理

对 `EXEC` 状态的年轻指令，CIQ 清除与 FU 取消必须同时发生。FU 内部 operation 保存 `tag` 与 `alive / pipe_valid`，并根据 kill mask 清除对应有效位：

* 流水 FU 可以继续进行无效数据计算，但被取消 operation 不得产生有效 Completion；
* 自研迭代 DIV 在被 kill 时应支持 abort，清除 `alive/busy` 并尽快恢复 `can_accept`；
* BRU 被取消后不得产生有效 `recovery_valid`；
* LSU 按第 9.6.4 节取消命中 kill 的未提交 Load/Store 及待发送 Completion；已获 Commit 授权的 Store 必须保留。旧响应隔离由 LSU 内部实现，不扩展 backend `tag_t`。

valid-only 协议的核心不变量是：**任何被 kill 的 FU operation，此后不得再产生 `completion_valid = 1` 或 `recovery_valid = 1`。** Completion Network 的 Entry `valid/EXEC/kill` 检查用于正常接收与同周期冲突处理，不作为 stale response 的 generation 替代机制。

若 Completion 与 Flush 同周期命中被 kill 的 Entry，Flush 优先，该 Entry 保持 `FREE`。误预测分支自身不被 kill，因此其 Completion 可正常将该 Entry 更新为 `DONE`。

### 15.6 Surviving 依赖与状态优先级

Surviving 指令不可能依赖被清除的年轻 producer，因此无需重新绑定其 `src_dep_tag`。同周期正常 Commit 命中的 surviving WAIT source，仍按第 14.5 节清除 `src_dep_valid`；下一周期从 RF 读取。未命中的依赖保持不变。

`recovery_valid` 有效的周期禁止产生新的 FU `issue_valid`。由于严格顺序 Issue 保证误预测分支及其所有更老指令已经发射，此时尚未发射的 WAIT 指令均属于分支之后的年轻路径，直接由 Flush 清除。

Flush 周期的关键规则为：

```text
Reset
  > Flush kill（仅作用于年轻 Entry）
  > Completion
  > Issue（recovery_valid 时禁止新 Issue）
  > Dispatch（本周期禁止）
```

更老 Entry 的 Commit 与年轻 Entry 的 squash 可同周期发生；Producer Map 使用第 15.3 节定义的 validated checkpoint 作为该周期最终状态。ECALL/中断/MRET 的全队列恢复由第 17 节统一 Trap/Redirect Controller 处理，不使用 Branch Checkpoint 恢复。

---

## 16. M-mode CSR / Serializing（RT-Thread 首版）

### 16.1 指令及 CSR 范围

仅实现 **M-mode、Zicsr 六指令 `CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI`、`ECALL`、`MRET`**。`EBREAK` 只由仿真 Testbench 在**非推测的 CIQ Commit Head 边界**识别为退出事件（可使用仿真专用指令 Shadow），**不进入综合 CPU 的异常/执行协议**；`WFI`、FENCE/FENCE.I、S/U-mode 及其他同步异常均不属于本版支持范围。BSP 必须仅使用本版已实现指令、CSR 和自然对齐的访存；不支持的编码/CSR 访问必须在验证中报错，不得默认为 NOP 或读写成功。本版因此不宣称完整特权架构异常兼容性。

| CSR | 地址 | 首版读写语义 |
|---|---|---|
| `mstatus` | `0x300` | `MIE[3]`、`MPIE[7]` 可读写；`MPP[12:11]=2'b11` 固定 M；其余未实现位读 0/写忽略 |
| `mie` | `0x304` | 仅 `MTIE[7]` 可读写；MSIE/MEIE 首版读 0 |
| `mtvec` | `0x305` | 可读写，**仅 Direct**；`BASE[31:2]` 4B 对齐，`MODE[1:0]` 固定 `00` |
| `mscratch` | `0x340` | 32-bit R/W |
| `mepc` | `0x341` | 32-bit R/W，RV32IM 无 C，读写时 `[1:0]=00` |
| `mcause` | `0x342` | 32-bit R/W，Trap 时由硬件覆盖 |
| `mip` | `0x344` | 仅 `MTIP[7]` 反映 SoC Timer Pending；软件写忽略，其余位 0 |
| `mhartid` | `0xF14` | 只读 0（单 Hart） |
| 可选 `misa` | `0x301` | 参数 `HAS_MISA`；启用时固定 `0x40001100`（RV32 I/M），写入忽略，关闭时访问不支持 |
| 可选 `mtval` | `0x343` | 参数 `HAS_MTVAL`；启用时 32-bit R/W，ECALL Trap 写 0 |
| 可选 `mcycle/mcycleh` | `0xB00/0xB80` | 参数 `HAS_MCYCLE`；启用时同一 64-bit Cycle Counter 的低/高 32 位，可读写；写入的半字覆盖该周期对应半字的自增 |

复位：`mstatus.MIE=0`、`MPIE=0`、`MPP=M`，`mie=0`，`mepc/mcause/mscratch=0`，`mtvec=RESET_MTVEC`（4B 对齐、Direct），可选计数器清零；`mip.MTIP` 随定时器硬件状态，不伪造为软件可写。默认仅实现 **Machine Timer Interrupt（cause=7）**，需要 64-bit MMIO `mtime/mtimecmp`（由 SoC 提供，地址由 BSP/SoC 定义）；软件/外部中断源留待扩展。

### 16.2 独立 CSR Unit 与精确提交

`CSR` 为单独的 guaranteed-accept FU（`latency=1, II=1`，Serializing Gate 保证无并发 CSR）。Zicsr 操作的 `csr_addr`/`csr_write_en` 在 Decode 确定：`CSRRW[I]` 必写；`CSRRS/CSRRC` 当编码 `rs1!=x0` 才写；`CSRRSI/CSRRCI` 当编码 `uimm!=0` 才写。Immediate 操作数为零扩展 `uimm[4:0]`，不读取 GPR；普通形式按原 Producer Map 绑定 `rs1`。`rd=x0` 的 `CSRRW[I]` 不需读 CSR，但仍须写 CSR；CSRRS/CSRRC[I] 均读 CSR。`mhartid` 不可写；固定实现的 `misa` 写入无效（WARL），不作为只读地址访问错误。

CSR Unit 在 Issue 后一周期读取旧 CSR 并形成 `new = src / (old | src) / (old & ~src)`，将旧值作为普通 Completion `result` 写入 CIQ，并同时登记局部伴随字段 `csr_write_data`。**CSR 真正写入仅发生于该指令独占的正常 Commit 沿**；同沿若 `rd_wen` 则提交旧值到 GPR。固定/WARL 字段在实际写 CSR File 时屏蔽。CSR Unit 不执行早期架构写入，也不需要 CSR Rename/Forwarding。

### 16.3 全序列化协议

所有 Zicsr、ECALL、MRET 均置 `is_serializing`。Dispatch 规则见第 5 节；该指令必须等成为 **Commit Head** 且 `lsu_mmio_order_idle=1` 后才能单独 Issue；自身完成/Trap 之前不得发射年轻指令。正常 CSR/MRET 指令 **独占 Commit 周期**：在 lane0 提交，不允许同周期 `commit1_fire`；若位于 lane1，则先只 Commit 较老的 lane0，下周期再处理。ECALL 不 `commit_fire`，而按第 17 节触发 Trap。原有普通指令 4-Issue / 2-Commit 不变。

## 17. 精确 ECALL / MRET / Machine Timer Interrupt

### 17.1 同步 ECALL 与 MRET

`ECALL`（M-mode）在 CSR Unit 完成时登记 `DONE + exception(cause=11, tval=0)`；当其为 `commit_ptr` 时，产生 `trap_fire`，**不作为正常 Commit 退休**，并在同一沿写入 `mepc=ecall.pc`、`mcause=11`、可选 `mtval=0`，以及 `MPIE←MIE、MIE←0、MPP←M`；Redirect 到 `mtvec.BASE`。`ECALL` 自身及其年轻 CIQ Entry 全部取消，Producer Map/Checkpoint 清空；已 Commit Store 永不取消。

`MRET` 在 CSR Unit 正常 Completion 后独占 lane0 Commit：同沿执行 `MIE←MPIE、MPIE←1、MPP←M`，取已提交 `mepc` 为 Redirect PC（RV32IM 4B 对齐）。`MRET` 正常计入退休，清空错误的顺序取指路径；Serializing Gate 保证其后尚无年轻 CIQ Entry。

### 17.2 精确机器定时器中断：Drain-to-Boundary

`irq_eligible = mstatus.MIE && mie.MTIE && mip.MTIP`。检测到条件满足后进入 `IRQ_DRAIN`：立即停止新 Dispatch，但继续允许现有 WAIT Issue、OoO Completion 和正常 In-order Commit；Branch Recovery 仍照常处理，防止错误路径进入最终退休状态。排空期间不允许新的 IB 指令进入 CIQ。**仅在 CIQ 已空、`lsu_mmio_order_idle=1` 且重新检查 `irq_eligible=1` 时接受中断**；如果条件已清除，Redirect 到 `architectural_next_pc` 并恢复执行，不进入 Trap。不能等待全部 cacheable Dirty Line 写回，但已 Commit MMIO 必须确认完成。

增加 32-bit `architectural_next_pc`，Reset 为 `RESET_PC`；每次正常 Commit 按程序顺序更新为最年轻退休指令的真实后继 PC：普通指令为 `pc+4`，控制转移为 BRU 登记的 `actual_npc`，MRET 为 `mepc`。当周期 Commit 完成并经下周期确认 CIQ 为空之后，在中断边界将其写入 `mepc`；`mcause=32'h8000_0007`，可选 `mtval=0`；`MPIE←MIE、MIE←0、MPP←M`，Redirect 到 `mtvec.BASE`。中断本身不退休指令。IB 在重定向时丢弃旧预取内容；即使中断取消也从准确的 `architectural_next_pc` 恢复。`mstatus/mie` 在 Commit 更新引起的中断条件变化于随后周期重新评估。

### 17.3 统一 Redirect / Kill 优先级

```text
Coordinated Cold Reset
  > ECALL Trap（Commit Head，同步异常）
  > MRET Redirect（Serializing Commit）
  > BRU Mispredict Recovery（第 15 节，保留分支与更老指令）
  > IRQ Boundary Redirect（CIQ 已空）
```

ECALL/IRQ Trap 及 MRET 通过统一 Frontend Redirect 清除错误路径 IB；ECALL 的全队列 kill（含自身）/MRET 的路径重定向不进行 Branch Checkpoint 校验，`producer_map` 和未使用的 checkpoint 清空。正常 Branch 误预测仍使用第 15 节年龄选择性 squash 与 Frozen Checkpoint 恢复；优先级低者在同周期不得覆盖高优先级的 CSR/PC/CIQ next-state。所有 Flush 仍优先于被 kill operation 的 Completion，且已提交 Store 的 LSU 所有权不回退。

**验证最低集**：六种 Zicsr 写使能与 `rd=x0`、`mstatus/mie` 字段掩码、ECALL→M-mode Handler→MRET、计时器 MTIP 保持/清除、IRQ Drain 遇到未完成 DIV/Load/Branch、Branch 后 `architectural_next_pc`、MMIO Write Ack 之前的 CSR/IRQ Barrier、Flush 后 stale Completion/旧 MMIO Response。未实现的 Illegal Instruction/Bus Error/EBREAK/WFI 不作为硬件 Trap 测试目标。

---

---

## 18. Frontend ↔ Backend 跨模块接口

本章的**唯一规范性定义**见 [`frontend_backend_contract.md`](frontend_backend_contract.md)。

- **Instruction**：`iq_valid[1:0] / iq_inst[2] / iq_accept_count[1:0]`；连续前缀消费，`iq_accept_count` 是唯一消费依据。
- **Redirect**：Backend 在 Reset/Trap/MRET/BRU/IRQ 优先级仲裁后输出唯一 `backend_redirect_valid/pc/kind`；Branch 同时传 `ghr_before/actual_taken`；Redirect 同周期停止 Dispatch，Frontend 丢弃旧路径 IQ/FTQ/在途请求。
- **BPU Update**：Commit 按 lane0→lane1 顺序对已正常退休 CFI 输出最多两个事件；先以 BPU 已登记 `bpu_update_credit` 约束 Commit，Frontend 更新 `ghr_commit` 并将训练信息排队处理；BRU Completion 不直接推进已提交预测历史。

Frontend 内部 Predecode 修正仅修正尚未进入后端的取指路径，不触发 CIQ Flush。`pred_npc` 为修正后生效的预测值，`pred_meta` 保留原始预测信息；`need_redirect` 要求未预测 JALR 在 BRU Resolution 无条件发起一次恢复，防止 Frontend 等待死锁。
