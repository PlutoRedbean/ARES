# Frontend ↔ Backend Interface Contract

> **Status**: v1.1 / C5 integration baseline / 2026-10-18
> **Scope**: RV32IM, 4-wide Fetch, 2-wide Decode/Dispatch, 16-entry CIQ, 2-wide Commit  
> **Normative ownership**: 本文仅约束 Frontend/Backend 交界。Frontend 的 BPU/FTQ/IFU/IQ 内部实现见 `frontend.md`；Backend 的 Decode/CIQ/BRU/Commit/Trap 见 `backend.md`。冲突时优先遵守本文的跨模块协议。

## 1. 边界与信号组

| 信号组 | 方向 | 带宽 | 约束 |
|---|---|---:|---|
| Instruction | FE IQ → BE Decode/Dispatch | 最多 2 inst/cycle | 连续前缀；按 `iq_accept_count` 消费 |
| Redirect | BE → FE | 最多 1 event/cycle | 一周期有效，无 ready；BE 内部先完成优先级仲裁 |
| BPU Update | BE Commit → FE BPU | 最多 2 CFI events/cycle | 与正常 Commit 同沿；按 BPU 已登记 credit 预留，不丢训练事件 |

共同的 `RESET_PC`、`RESET_MTVEC` 由顶层配置（Frontend 原 `RESET_VEC` 必须与 Backend `RESET_PC` 同值）；本接口的 PC/指令宽度均为 32 bit，不支持 C 压缩指令。Cold Reset 同步清除 IQ/FTQ/在途请求、训练 FIFO、`ghr_spec/ghr_commit` 与后端在途指令，所有 `valid` 置 0。

## 2. Instruction Interface：IQ → Decode/Dispatch

```systemverilog
// FE -> BE
logic [1:0] iq_valid;       // 仅允许 00 / 01 / 11；低位为最老指令
fe_pkg::iq_entry_t iq_inst[2];
// BE -> FE
logic [1:0] iq_accept_count; // 0 / 1 / 2；表示本周期成功入 CIQ 的数量
```

- `iq_available_count = iq_valid[0] + iq_valid[1]`，仅对 `iq_valid` 有效的 `iq_inst` 解码；`iq_inst[0]` 总是较老的候选。`iq_accept_count <= iq_available_count`，且只可接受连续前缀，禁止跳过 slot0 消费 slot1。
- `iq_accept_count` **是唯一消费依据**。周期末 FE IQ 弹出相应数量，BE 将同样数量的指令分配到 CIQ，并依程序顺序更新 Producer Map。旧版 IQ 的 `rready` 删除；不再与 `raccept_cnt` 并列判定握手。
- `iq_accept_count` 在当前 CIQ 容量、Serializing Dispatch Gate、IRQ Drain 与全局 Redirect/Reset 条件下由 BE 组合产生；不依赖 IQ 的后续 `ready`。正常同周期 Commit 可依据 Backend 的既有 `dispatch_base_map` 更新依赖，但首版 `free_count` **不借用**预计本周期释放的 CIQ 容量。
- 当 `iq_accept_count=0` 时，FE 必须保持队首指令及其 metadata 稳定（发生有效全局 Redirect/Reset 除外）。FE 可以继续预取到自身缓冲满；该行为不改变 BE 的背压协议。
- IQ 内部可沿用 2-entry Head + 参数化 Body（当前默认 8，总 IQ 深度 10） 和 IFU→IQ `wvalid/wready/wmask`。当部分写入不足容纳有效 prefix 时，IFU 保持该块等待；无条件丢弃有效指令是协议错误。

### 2.1 每条指令的控制信息

`fe_pkg::iq_entry_t` 的跨边界字段固定为 `pc, inst, pred_npc, pred_meta, cfi_type, is_cfi, valid`（详细声明见 `frontend.md` 第 4.3 节）。`iq_inst[i].valid` 必须与 `iq_valid[i]` 一致；不得通过重复的 valid 位产生不同的消费判断。其中：

- `pred_npc` 是**经 FE 最终修正、与这条指令绑定的有效预测下一 PC**；条件分支预测不跳转时为 `pc+4`，预测跳转时为生效目标。BE BRU 只用它比较 `actual_npc`；不得将 `pred_meta.pred_target` 无条件当作 `pred_npc`。
- `pred_meta` 保留**原始 BPU 预测**（`pred_taken/pred_target/pred_type`、训练所需索引/chooser metadata、`ghr_before`），允许与经 Predecode 修正后的 `pred_npc` 不同；用于预测器训练与 BRU 恢复历史，而非判断当前路径正确性。Backend 对预测器私有 metadata **原样保存并回传**，不得重新解码、压缩或根据最新预测器状态重建；具体可选 TAGE/SC/Loop/RAS 的 metadata 位宽由 FE 在共享 `fe_pkg::pred_meta_t` 中定义，且必须保持该接口类型编译一致。
- `pred_meta.ghr_before` 是**此条 CFI 被预测前**的推测 GHR 快照，已按程序顺序计入所有更老 CFI 的预测历史；不得把一个 Fetch Block 的不正确共享快照同时当作不同 CFI 的快照。当前保留块内多个预测不跳转的 CFI，在首个预测跳转 CFI 后截断；BPU 在写入 FTQ 前按槽生成完整快照，禁止下游通过块快照与前缀计数重建。预测表实际使用的索引历史单独保留，不被恢复快照替换。
- `cfi_type/is_cfi` 描述 Predecode 识别出的**实际指令类型**，Decode 必须与 `inst` 核对；原始预测类型属于 `pred_meta`。非 CFI 不参与 BPU CFI 更新。

Decode 将 CFI 的 `pred_npc/pred_meta/actual cfi_type` 随指令保存至 CIQ，直至其正常 Commit 或被 Flush。Issue BRU 时传递独立的 `pred_npc`；BRU Completion 另登记 `actual_npc/actual_taken/actual_target`。未被接受的 IQ 内容不进入后端状态。

## 3. Redirect Interface：Backend → Frontend

```systemverilog
typedef enum logic { REDIRECT_BRANCH, REDIRECT_ARCH } fe_redirect_kind_t;
// BE -> FE; valid 仅持续当前事件周期，不提供 ready
logic              backend_redirect_valid;
logic [31:0]       backend_redirect_pc;
fe_redirect_kind_t backend_redirect_kind;
logic [GHR_WIDTH-1:0] backend_redirect_ghr_before; // BRANCH only
logic              backend_redirect_actual_taken;     // BRANCH only
bpu_update_t       backend_redirect_info;             // BRANCH only; independent of training FIFO
```

- Backend 独占最终架构级 Redirect 仲裁：`Reset > ECALL Trap > MRET > BRU Recovery > IRQ Boundary Redirect`；仅向 FE 输出**一个获胜事件**。`REDIRECT_ARCH` 覆盖 ECALL、MRET、IRQ 边界/取消中断后的重新取指；`REDIRECT_BRANCH` 表示 BRU 下一 PC 误预测。PC 必须是 BE 已仲裁的正确目标。
- `backend_redirect_valid` 与 BE 的 `kill/Dispatch block` 同周期生效。该周期 `iq_accept_count=0`；周期末 FE 丢弃 IQ 中全部尚未被 Dispatch 的旧路径指令、清除 FTQ 和错误路径预测流水，并使所有旧路径 IFU/ICache **在途响应不可再次入 IQ**。BE 的年龄选择性 CIQ squash/Trap 全队列恢复仍按 `backend.md` 执行，FE 不决定 CIQ kill 范围。
- IFU/ICache 必须有可靠的旧响应过滤机制（可用内部 epoch/transaction 标识或取消+drain），保证 Redirect 后旧请求即使迟到也不会污染新路径；标识复用不得与仍在途的旧请求混淆。实现技术属于 FE 内部，不扩展 BE `tag_t`。
- 在 BE Redirect 同周期，FE 的 Predecode/深级预测修正无效，不能覆盖 BE 目标 PC、不能将旧路径 Fetch Block 写入 IQ。Reset 具有最高优先级。
- `REDIRECT_BRANCH` 时 FE 以 `backend_redirect_ghr_before` 为基准，计入该 CFI 的 `actual_taken` 恢复 `ghr_spec`，保留所有更老、但尚未 Commit 的正确路径预测历史；禁止只用 `ghr_commit + actual_taken` 恢复。
- 启用 TAGE/RAS 检查点时，`backend_redirect_info` 同步携带获胜 BRU 指令的 CIQ 原始 `pred_meta`、PC 和 Decode 确认的 CFI 类别；方向/目标取本周期 BRU 的实际结果。该事件不进入训练 FIFO，也不消耗 Commit credit。不得用延迟训练队首的 metadata 替代恢复快照。ARCH 事件将此 sideband 置零；本地 Predecode 修正使用 IFU 自己保留的检查点。
- `REDIRECT_ARCH` 时 FE 以**本周期已接受的正常 Commit CFI 更新之后**的 `ghr_commit` 重建 `ghr_spec`。在所有 Redirect 后 FE 重新从 `backend_redirect_pc` 开始预测/取指。
- 所有恢复请求均为一次性事件；没有 ready、retry 或隐式接受延迟。Frontend 若需要清空/屏蔽自身流水线，应在有效事件时锁存正确 PC 并启动本地恢复。

### 3.1 前端本地修正（不等价于 Backend Flush）

- 仅当 Predecode 能**确定正确下一 PC**时（例如直接 JAL 的立即数目标、可判定的伪 CFI）允许 FE 自行 Redirect；普通条件分支不得将未确定的实际 taken 伪装为已知，未知目标的 JALR 不得由 Predecode 猜测目标。
- Frontend Local Redirect 保留已经入 IQ、按程序顺序位于修正点**之前**的有效指令；修正 Fetch Block 自身仅将经检查的有效 prefix 按序入 IQ，并在成功入队后才允许完成修正。清除的是更年轻的 FTQ/IFU/预测路径及其在途响应，而非无条件清空整个 IQ。
- 此规则要求 IFU 以程序顺序向 IQ 入队、修正点不早于 IQ 中已经入队的最年轻指令。任何晚到的深级 BPU 修正若可能指向已入 IQ 的更老指令，必须**在入 IQ 前解决**；第一版不支持在 IQ 中选择性回滚任意 suffix。
- Frontend Local Redirect 改写该 CFI 的**生效** `pred_npc`，但保留原始 `pred_meta` 以便 Commit 训练；同时基于此 CFI 的 `ghr_before` 和本地确定的生效方向修复后续 `ghr_spec`。Backend 不做 CIQ Flush。对于未预测到的条件分支，Frontend 只能将其明确视为**预测不跳转**（`pred_npc=pc+4`、有效 `actual_taken` 未知），并把该 CFI 的有效预测历史补入 `ghr_spec`；若早已发出的年轻预测使用了错误 GHR，则必须在前端局部重启预测，不能继续使用该错误历史。
- 未预测目标的 JALR：`pred_npc=pc+4`，正常派发并继续推测执行，不进入等待状态；BRU 仅在 `actual_npc != pred_npc` 时恢复。JALR 的生效 CFI 历史方向为 1；若 BPU 漏识别，Predecode 保留该指令并从 `pc+4` 局部重启年轻预测以修复历史，不等待 BRU。

## 4. BPU Update Interface：Commit → Predictor

```systemverilog
// FE BPU -> BE Commit：当前沿可无条件接受的事件槽位数，范围 0..2
logic [1:0] bpu_update_credit;
// BE Commit -> FE BPU：与两条 Commit lane 对齐，空 lane 的 valid=0
logic [1:0] bpu_update_valid;
bpu_update_t bpu_update[2];
```

`bpu_update_t` 的固定跨边界数据格式为（建议放入 `fe_pkg`，避免前后端重复声明）：

```systemverilog
typedef struct packed {
    logic [31:0] update_pc;             // 发生 CFI 的指令 PC
    logic        actual_taken;          // 实际方向；JAL/JALR 恒为 1
    logic [31:0] actual_target;         // BRU 计算的跳转目标
    cfi_type_t   actual_cfi_type;       // Decode 确认的真实 CFI 类别
    pred_meta_t  pred_meta;             // 原始预测信息，包括 ghr_before
} bpu_update_t;
```

`actual_target` 在条件分支未跳转时仍为分支立即数目标，不等于实际 `actual_npc=pc+4`；不得混用。`actual_cfi_type` 为 `CFI_COND_BRANCH` 时才训练条件方向表。**默认** `BPU_UPDATE_FIFO_DEPTH=8`（最小允许 2），BPU 可以每周期从 FIFO 处理 1 个事件；`bpu_update_credit = min(2, FIFO_DEPTH - occupancy)`（取周期初占用量、不借用本周期出队）。FIFO 满导致 CFI Commit 短暂暂停，但不会丢训练或延迟已退休指令的历史更新。

- **仅正常 `commit_fire[i] && is_cfi[i]`** 生成对应的 `bpu_update_valid[i]`；不在 BRU Resolution 时更新提交历史，也不训练已经被 squash 的 CFI。对一个正常 Commit 的 CFI 必须恰好产生一次事件。
- BE 在形成 Commit 连续前缀时，把候选前缀所需 CFI 事件数与**已登记** `bpu_update_credit` 比较，不得超额；资源不足时阻止对应 CFI 及其年轻 Commit（但允许不需要事件的较老 Commit）。因此有效事件无需独立 ready，且不会丢失。BE 沿用最多 2-wide 的 Store Commit/CSR 条件，BPU credit 只是额外的 Commit 候选约束。
- FE BPU 在该沿按 lane0 → lane1 顺序接受事件，**立即**推进 `ghr_commit`（含一个周期两条 CFI）；用于训练表项的事件进入 FE 内部有界 FIFO，按 Commit 顺序训练。正常 Branch/Trap/MRET/IRQ Redirect **不清空已经接受的训练 FIFO**，因为其中都是已退休 CFI；只有 Cold Reset 清空。`bpu_update_credit` 仅表示**FIFO 当前已空出的槽位**，不借用当前预计 dequeue 的空间；训练允许滞后，但不得丢失或乱序改变所需的预测索引/metadata。
- 训练读写冲突、同一预测表项连续更新由 FE BPU 自己串行化/旁路，最终表现为按 Commit 顺序应用事件；这不改变后端 2-wide Commit 的合法性。credit 为登记状态，不得组合依赖当前 `bpu_update_valid`，避免 BE→FE→BE 组合环路。
- uBTB/mBTB 的后台更新流水均有有界 pending 槽；只有两者都可接受当前训练事件时才从训练 FIFO 出队。RAS、基础 GHR 与 TAGE 的已提交条件历史仍在接受两条 Commit lane 的当沿更新，不等待表训练。
- S2 修正保留被修正块自己的 TAGE/RAS 检查点，重启流从其下一检查点位置分配；该块仍可能在进入 CIQ 后发生 BRU 恢复。FTQ 修正与读取同沿发生时，读取释放的容量必须在 poison 窗口结束后可供写入。
- FE 的 `ghr_spec` 在正常运行按**实际生效的预测路径**前进（本设计按 CFI 记录 taken bit，包括 JAL/JALR）；Branch Recovery 使用第 3 节的每 CFI `ghr_before`，Trap/MRET/IRQ 使用最新 `ghr_commit`。BPU predictor table 使用预测时保存的 `pred_meta` 进行索引/chooser 等训练。

## 5. 同周期优先级与时序

| 同周期情形 | 必须执行的结果 |
|---|---|
| Reset + 任意活动 | Reset，所有旧流无效 |
| BE Redirect + IQ Dispatch | `iq_accept_count=0`，IQ 全部旧内容 flush，BE 按后端规则恢复 |
| BE Redirect + FE Local Redirect | BE Redirect 获胜，FE Local Redirect 不生效 |
| FE Local Redirect + IQ Dispatch | 已入 IQ 的较老正确指令可正常 Dispatch；修正块按 3.1 节入队并保留 |
| CFI Commit + BE Branch Redirect | 较老 CFI 的正常 Commit 更新按 lane 顺序接受；分支 `ghr_spec` 以该分支的 `ghr_before` 恢复 |
| CFI Commit + ARCH Redirect | 先接受合法 Commit 训练/历史事件，随后以更新后的 `ghr_commit` 恢复 `ghr_spec` |
| IQ Empty / Serializing / IRQ Drain | `iq_accept_count=0`（若无可接受指令或 BE 暂停），IQ/FTQ 可自行背压 |
| 同一周期两个 CFI Commit | 最多 2 个训练事件，lane0 比 lane1 更老；credit 必须覆盖全部有效事件 |

**组合路径限制**：`iq_valid/iq_inst → Decode → iq_accept_count` 可存在；`backend_redirect_valid` 不得等待 FE ready；`bpu_update_credit` 必须来自 FE 寄存状态，不能依赖当周期 BE `commit_fire/update_valid`。

## 6. 最低 RTL 断言与联调测试

- `iq_valid inside {00,01,11}`；`iq_accept_count <= $countones(iq_valid)`；接受 2 条时两个 slot 均有效；任何时钟沿 FE pop 数等于 BE CIQ allocate 数。
- `backend_redirect_valid |-> iq_accept_count==0`；Backend Redirect 后旧 epoch 的 ICache response 永远不能写入 IQ；BE 和 FE 选用同一个 Redirect PC。
- 未预测 JALR 使用 `pred_npc=pc+4`；验证目标不等于该值时恢复，目标恰好等于该值时不恢复且执行继续。
- `bpu_update_valid[i] -> commit_fire[i] && is_cfi[i]`；本周期事件总数 `<= bpu_update_credit`；事件按 lane 顺序排列入训练 FIFO；无丢失、无重复。
- Branch Recovery 的 `ghr_spec` 由 `ghr_before + actual_taken` 恢复；Architectural Redirect 从已接受的 Commit 历史恢复；验证两个未 Commit CFI、较老 CFI 同周期 Commit 与年轻 Branch 误预测。
- 定向覆盖：`IQ 01/11 + accept 0/1/2`、IB 满/空的局部 JAL 修正、未知目标 JALR 的相等/不等目标、BE Redirect 与 FE Predecode 同周期、IRQ Drain 期间 IQ 留存、无效旧 ICache 响应、连续两条 CFI Commit、BPU credit=0/1/2。

## 7. 本契约之外仍待设计的前端内部项目

本契约不代替 Frontend 内部尚未完成的 `RAS / Loop` 细节、TAGE/SC 表参数与更新细则、IFU/ICache miss/refill 内部逐周期协议，亦不代替 Backend 的 LSU/CSR/Trap 内部契约。这些问题不应导致 FE↔BE 接口另行发明信号语义。

## 8. C5 IROM profile and shared-type ownership

`rtl/common/fe_pkg.sv` owns FE/BE types; `ares_pkg` owns Backend/LSU types.
`iq_entry_t.pred_npc` is independent of raw `pred_meta`. The fixed metadata
layout includes `pred_type`, full `ghr_before`, chooser lookup metadata and
`loop_override`; feature switches never remove fields. Disabled fields are zero.

`ares_cpu_top` contains the real FE, `ares_core_top` (BE+LSU), and a read-only
AXI-Lite to synchronous 64-bit IROM bridge. It supports 4-wide Fetch / 2-wide
Decode and `CONFIG_IO_USE_AXI=y`. Fetch is limited to 0x80000000–0x80007fff;
the final response masks slots outside this range. An out-of-window speculative
PC waits for Redirect; an actual unsupported execution fails the simulation
watchdog, without adding an instruction-access Trap. The dedicated IROM read
port does not use the D-memory/DMA Fabric. DRAM execution and instruction-cache
maintenance remain outside this profile.
