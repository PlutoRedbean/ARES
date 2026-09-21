# RV32IM 后端微架构设计文档

> **状态**：Draft v0.27
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
7. GPR、CSR、Store 等架构可见状态只允许在 Commit 阶段更新。
8. GPR 8 read ports / 2 write ports
9. Producer Map 记录最新的未提交写者。
10. 采用非数据捕捉设计，操作数在 Issue 时从 Architectural RF 或 CIQ result 动态解析。

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
    ALU0      ALU1    BRU     MUL/DIV    LSU
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
* 让 flush、commit、exception 的顺序管理统一落到一个有序结构中。**(暂未设计)**

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

Flush 可以使任意尚未提交的 Entry 直接转为 `FREE`。

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

## 4. Queue Entry 数据结构（等待深入探讨设计）

依赖与 Completion 使用同一 `tag_t = {slot_index, allocation_generation}`；Entry 保存对应分配代次（可存于独立元数据数组）。查询与完成写入必须校验完整身份，不能只比较 4 位槽号。代次位宽和复用协议必须保证旧请求仍可能返回时不会重用同一 tag，具体位宽随 Flush/取消协议确定。

逻辑字段如下：

```systemverilog
typedef struct packed {
  logic              valid;
  entry_state_t      state;

  logic [31:0]       pc;

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

/*--可能暂时用不到--*/
  logic              exception;
  exception_cause_t  exception_cause;
  logic [31:0]       exception_tval;
/*--可能暂时用不到--*/

  logic              is_branch;
  logic              is_load;
  logic              is_store;
  logic              is_csr;
  logic              is_fence;
} queue_entry_t;
```

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

如果源寄存器当前没有未提交 producer：

```text
src_dep_valid = 0
rs            = decoded_rs
```

含义是：该 source 到 Issue 时直接读取 Architectural RF。

如果存在未提交 producer：

```text
src_dep_valid = 1
src_dep_tag   = producer_map[rs].tag
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

Commit 一条写寄存器指令时：

```text
producer_map[rd].valid
&& producer_map[rd].tag == committing_tag
```

时清除。

否则说明已经存在一个更年轻的 writer，Producer Map 必须继续指向年轻 writer。

---

## 7. 2-wide Dispatch 的同周期依赖

同一个 Decode cycle：

```asm
D0: add x5, x1, x2
D1: mul x6, x5, x3
```

采用同周期 **tag bypass**，允许存在 RAW 的 D0/D1 同时分配；仅转发 producer tag，不转发操作数值或 FU 结果。

当 `accept_count = 2` 时，D0/D1 分别获得按序分配的 `tag0` / `tag1`。源依赖绑定规则如下：

1. D0 的源查询本周期 Dispatch 更新前的 Producer Map，不能匹配自身或 D1 的写者更新。
2. D1 的每个有效、非 x0 源优先匹配 D0 的有效目的寄存器；命中时绑定 `tag0`，否则查询同一份 Producer Map。
3. 未使用的源和 x0 不建立 producer 依赖。

对 D1 的每个源，逻辑为：

```text
if !src_used || rs == x0:
  src_dep_valid = 0
else if D0.rd_wen && D0.rd != x0 && D0.rd == rs:
  src_dep_valid = 1
  src_dep_tag   = tag0
else:
  src_dep_valid = producer_map[rs].valid
  src_dep_tag   = producer_map[rs].tag  // 仅 valid 时有意义
```

在上述例子中，D1 的 x5 源绑定 `tag0`，等待 D0 的结果在 Issue 时可用，不需要阻止两条指令同时进入 CIQ。

Producer Map 的 Dispatch 更新按逻辑程序顺序先应用 D0、再应用 D1，仅对实际接受且满足 `rd_wen && rd != x0` 的指令生效。若 D0/D1 写同一寄存器，最终 Map 指向较年轻的 `tag1`；但 D1 的源仍按更新前的规则绑定，不能绑定自身。与 Commit 清除同周期发生时，对同一寄存器的新 Dispatch 写者更新优先于旧写者清除。

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

### 8.4 源就绪查询与操作数读取

Issue 只查询四条候选的最多八个 source，不对整个 CIQ 做广播数据捕捉，不重新查询 Producer Map 改变已绑定的依赖。

| Source 状态 | Ready | 数据来源 |
|---|---|---|
| 未使用或 x0 | 1 | 忽略或常量 0 |
| 无 producer 依赖 | 1 | Architectural RF |
| 完整 tag 匹配有效 producer，且 `DONE && !exception` | 1 | 已登记的 CIQ result |
| 完整 tag 匹配有效 producer，但尚未完成 | 0 | 等待 |
| 已确认 producer 正常提交 | 1 | Architectural RF fallback |
| producer 异常，或依赖身份无法确认 | 0 | 等待异常处理／恢复，不能使用普通结果 |

“查不到 producer”不能直接视为“已经提交”；RF fallback 的退休确认及 Flush 协议见第 14.4 节。同组 RAW 的消费者指向仍为 WAIT 的 producer，因此不能同周期发射；不同 Entry 保存独立结果版本，WAW 本身不要求禁止同时发射。

Ready 查询与 RF／CIQ result 读取在同一 Issue 级并行进行，仲裁只依赖控制状态。CIQ result 逻辑上需要最多八路独立读取，可将窄的状态／依赖元数据与 32 位结果数组物理分开。FU 接收时锁存操作数，不延后重新读取 Architectural RF。

### 8.5 连续前缀资源仲裁

不设置全窗口 oldest-ready 选择或年龄矩阵。按 I0 到 I3 顺序检查，为实际获准的指令扣减本周期执行端口接收额度，遇到第一条阻塞指令即停止：

```text
remaining = 本周期可接收的执行端口额度
prefix_ok = 1
for i = 0..3:
    port = 从 remaining 选择 Ii 支持的端口
    grant[i] = prefix_ok && candidate_ok[i] && port_exists
    if grant[i]:
        扣减 port 接收额度
    prefix_ok = grant[i]
```

这里 `candidate_ok` 包括第 8.3 节的候选、操作数和顺序条件；端口额度必须保证本周期可以接收。实际握手约束见第 10 节。

第一版 ALU0/ALU1 按等价端口分配，其他 FU 按专用端口分配。FU available 表示可接收新请求。

### 8.6 Issue 流水线与完成可见性

采用单个 Issue／Operand Read 级：

```text
Decode/Dispatch：分配 Entry 并绑定 tag
 → Issue：读取候选，并行查询 ready／取数，前缀仲裁，周期末 FU 接收
 → Execute：各 FU 独立执行，可有不同级数和延迟。执行周期末将结果写入 CIQ
 → Commit：检查已登记的完成状态，最多两条顺序提交
```

---
 
## 9. Functional Unit 组织

逻辑资源：

```text
ALU0
ALU1
BRU
MUL
DIV
LSU
```

Issue 最多从这些目标中选择 4 个。

---

## 10. FU Request 接口（待设计）

所有 FU 尽量统一请求格式：

```systemverilog
typedef struct packed {
  logic        valid;
  tag_t        tag;

  op_t         op;

  logic [31:0] src1;
  logic [31:0] src2;
  logic [31:0] imm;
  logic [31:0] pc;
} fu_req_t;
```

握手：

```text
req_valid
req_ready
```

只有：

```text
req_valid && req_ready
```

时，CIQ Entry 才从 `WAIT` 转为 `EXEC`，FU 同时锁存 tag、操作数和控制信息。“非数据捕捉”指等待 Entry 不捕获广播结果，不排除 FU 入口锁存请求。

实际接收必须形成连续前缀：

```text
fire[i] = 对应请求的 req_valid && req_ready
fire[i] → 所有 j < i 的 fire[j]
issue_ptr += 本周期 fire 数量
```

直接连接 FU 时，年轻请求的 valid 必须受更老请求成功接收约束，不能向多个 FU 独立发 valid 后仅修正 grant。`req_valid` 不等待自身 `req_ready` 才产生，FU 的接收能力不得通过年轻请求反馈形成组合环；未接收的有效请求保持端口选择及载荷稳定，直到接收或被 Flush 取消。

---

## 11. FU Completion 接口（待设计）

统一 Completion 格式：

```systemverilog
typedef struct packed {
  logic              valid;
  tag_t              tag;

  logic [31:0]       result;

  logic              exception;
  exception_cause_t  cause;
  logic [31:0]       tval;
} completion_t;
```

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

1. 校验完整 tag，只有匹配有效 EXEC Entry 且未被 Flush 取消的 Completion 才可更新；
2. 在时钟沿登记 result 和 DONE，下一周期由候选查询 producer 状态判断就绪；
3. 保存 exception/cause/tval，异常完成不能作为普通源就绪；
4. 接收各 FU 的独立结果。

执行结果直接保存在预先分配的 CIQ Entry 中。CIQ 使用寄存器数组及 per-entry write-enable，支持所有 FU 同周期完成并更新不同 Entry，不设置共享 Completion 写入带宽仲裁。有效 Completion 在周期末直接登记，消费者从下一周期查询并读取结果。

由于不同 FU 一周期可能完成多条指令，CIQ 应允许多个不同 Entry 同周期被写。

实现上适合使用寄存器数组加 per-entry write-enable，而不是强行映射成单写口 RAM。**理论上两个 completion 不应命中同一个有效 tag；如果出现，应视为协议/控制错误并在验证中检查。**

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
* architectural Store；
* exception/trap architectural state；
* 其它 architecturally visible state。

因此：

```text
execution complete != architectural writeback
```

这是保持 Precise Exception 的基础。

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

Issue 侧 source 若仍带有指向正在 Commit producer 的有效 dependency tag，本周期从该 producer 的 CIQ `result` 取得值；下一周期确认该 producer 已正常提交后，通过 RF fallback 取数。只有确认正常提交才能回退，不能将 Entry 无效或代次不匹配直接当作退休证明。

退休确认机制需与 Flush/回收协议一起落实（例如退休序号，或 Commit 时清除匹配消费者的依赖有效位）；必须覆盖同周期 Commit 与新 Dispatch 绑定旧 producer 的情况。仍有效的消费者不能保留指向已取消 producer 的依赖。严格顺序发射和提交保证消费者取数前，更年轻的写者不会提交覆盖其所需 RF 值。这样避免依赖 RF primitive 的 read-during-write 行为；具体退休确认实现仍待恢复协议确定。

---

## 15. Serializing Instructions

以下类型第一版建议按序列化指令处理：

```text
CSR with side effects
FENCE
FENCE.I
ECALL
EBREAK
MRET/SRET（若实现）
特殊 Cache/TLB 管理操作
```

最简单规则是：

```text
该指令只有在所有更老指令完成必要提交条件后才能执行；
该指令未完成前，不允许年轻指令越过。
```

具体限制可按未来 privilege/CSR 实现继续细化。

---
