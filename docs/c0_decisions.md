# ARES C0 决策记录（core 契约冻结）

> **Status**: C0 交付物 / **核心裁决已确认**（v0.7：D-C0-01「不实现 illegal Trap」、D-C0-03「`MUL_LATENCY` 默认 3」、D-C0-13「可选 CSR 默认全关」由项目方确认；其余 [C0] 条目已通过评审，冻结生效）
> **关联**: `docs/implementation_plan.md` §7（SPEC 登记册）、§9.2（C0 任务）、`docs/core_verification_flow.md`
> **范围**: 只覆盖 **core 侧**（Backend + LSU + 共享包 + 验证骨架）。前端（F/D 类）与 SoC（M7/M8/M12…）条目在 §1 D-C0-11 只登记、不裁决。

---

## 0. 状态标记与使用方式

`docs/implementation_plan.md` §9.2 要求「C0 裁决项均有书面结论」。本文档给出每个 core 侧待决项的**具体结论、依据、影响面与实现位置**，并用下列标记区分权威性：

| 标记 | 含义 | 生效条件 |
|---|---|---|
| **[FREE]** | 属于实现自由选择（plan §7.7 白名单），本文档直接定值 | 立即生效，记录在案即可 |
| **[C0]** | core 范围内的工程结论，已按此实现 | 若架构作者/评审否决，只需按「回退影响」修改指定文件/参数 |
| **[FE]** | 属于前端维护者裁决 | 只影响 C5，不阻塞 C0–C3 |

**未关闭项对 C1/C2 的影响：无。** 每个 [C0] 条目都给出了已实现的具体值或规则；没有任何 RTL 行为停留在「未定义」状态（SPEC-A1 的非法指令/未对齐访问按 D-C0-01 明确为「仿真报错、不实现 Trap」）。

---

## 1. 决策清单

### D-C0-01 — SPEC-A1 / SPEC-M17：未支持指令与未对齐访存 **[C0]〔已确认〕**

**结论（已确认）：采用候选方案 (a)+(b)（仿真断言 + 显式 `decode_err` 观测），v1 不实现 illegal-instruction Trap。**

> **确认记录**：项目方明确「确认不实现 illegal Trap」→ 候选方案 (c) 关闭，不再作为备选；EBREAK 例外（可正常退休 + 仿真 shadow 识别）与未对齐访存策略（仿真报错、不死锁、无架构状态）一并按本节执行。

1. **未支持编码**（非 RV32IM、非 Zicsr 六指令、非 ECALL/EBREAK/MRET，含 FENCE/FENCE.I/WFI）：
   - Decode 产出显式 `decode_err[i]`（模块内部信号 + 仿真观测），**不得译成 NOP**、不得分配 CIQ slot、不得更新 Producer Map；
   - `be_dispatch` 对 `decode_err` 候选停止连续前缀（该指令及其年轻指令本周期不进入 CIQ）；
   - 仿真（`CONFIG_SIMULATION`）下 `decode_err` 触发断言/`$fatal`，测试立即失败并打印 PC/指令字；
   - **不写** illegal Trap 的架构状态（`mcause=2`、`mtval`、`mepc`）——方案 (c) 超出 backend.md §16.1 的 v1 范围，需架构作者批准后才能实现。
2. **EBREAK 例外**：EBREAK 必须能正常退休（AM `halt()` 约定 = `mv a0, code; ebreak`）。因此：
   - EBREAK 译码为 `OP_EBREAK`（`is_serializing=0`、无 GPR/CSR 写、无异常），作为普通指令进入 CIQ 并正常 Commit；
   - 仿真 shadow 在**非推测 Commit Head 边界**识别 `OP_EBREAK` 并调用 DPI `ebreak()`；该 shadow 用 `CONFIG_SIMULATION` 包住，**不进综合异常/执行协议**（backend.md §16.1）；
   - `decode_err` 不覆盖 EBREAK。
3. **未对齐访存**：v1 不支持（memory.md §1）。AGU 后按访问大小检查地址低位：
   - 仿真下断言 + `$fatal`（验证必须报错，不得静默）；
   - 为避免死锁，LSU 仍产生**一次** Completion，并按自然对齐 base 处理低位字节（该结果在 v1 **无软件可见保证**，任何测试不得依赖）；
   - 不做 misaligned Trap，不写架构状态。

**回退影响**：若架构作者选择方案 (c)（实现 illegal/misaligned Trap），需要改动 `rtl/common/ares_pkg.sv`（新增 `EXC_ILLEGAL=32'd2` 等 cause）、`be_decode`（`decode_err` → 异常 Entry）、`be_trap_ctrl`（优先级/tval）。这属于**架构可见变更**，需重新评审 backend.md §16/§17 并重跑 C3。

---

### D-C0-02 — SPEC-A4：`entry_state_t / fu_type_t / op_t / exception_cause_t` 编码冻结 **[FREE-01]**

**结论：全部编码在 `rtl/common/ares_pkg.sv` 中显式定值，见下表。** 位宽选择以「覆盖规范全部取值 + 不因未来扩展改布局」为准。

| 类型 | 位宽 | 取值（完整） |
|---|---|---|
| `entry_state_t` | 2 | `ENTRY_FREE=0, ENTRY_WAIT=1, ENTRY_EXEC=2, ENTRY_DONE=3` |
| `fu_type_t` | 4 | `FU_ALU0=0, FU_ALU1=1, FU_BRU=2, FU_SMUL=3, FU_MUL=4, FU_DIV=5, FU_CSR=6, FU_LSU=7`（4 bit 为 SPEC-M6 的 XIF 端口预留，避免日后改跨边界布局） |
| `op_t` | 6 | 56 个取值：RV32I 37 项 + M 8 项 + Zicsr 6 项 + `OP_ECALL/OP_EBREAK/OP_MRET/OP_FENCE` + `OP_ILLEGAL`（完整列表见包内注释与源码） |
| `exception_cause_t` | 32 | `EXC_NONE=0, EXC_ECALL_M=11, EXC_MACHINE_TIMER=32'h8000_0007`（IRQ cause 需要 32 bit） |
| `tag_t` | 4 | `{slot_index[3:0]}`，valid-only 生命周期，无 generation |
| `cfi_type_t` | 3 | `CFI_NONE=0, CFI_COND_BRANCH=1, CFI_DIRECT_JUMP=2, CFI_CALL=3, CFI_RETURN=4, CFI_INDIRECT_JUMP=5`（采纳 SPEC-C3 命名） |
| `fe_redirect_kind_t` | 1 | `REDIRECT_BRANCH=0, REDIRECT_ARCH=1` |

命名说明（**纯命名、语义不变**，FREE-02）：backend.md 的 `FREE/WAIT/EXEC/DONE` 在共享包中加 `ENTRY_` 前缀，避免污染所有 import 方的命名空间。

**回退影响**：改编码 = 改包内一处；所有消费者重新编译即可（无 RTL 结构变化）。

---

### D-C0-03 — SPEC-A3：`MUL_LATENCY` 默认 **3**，可经 `make menuconfig` 选 2 **[C0]〔已确认：默认 3〕**

- 依据：backend.md §9.4 允许 2 或 3，按实现时序选择。**默认 3**（项目方确认）：多一级流水寄存，为 AGENTS.md 的 >200 MHz 目标留时序余量；`II=1`、`can_accept=1` 契约不变。
- **可配置**：`configs/Kconfig` 的 `MUL_LATENCY`（int，`range 2 3`，默认 3）；生成的 `CONFIG_MUL_LATENCY` 由 `rtl/common/ares_pkg.sv` 读取，未配置时回退 **3**。
- 两种取值都不改变任何外部握手/吞吐契约（Completion 只要求「不早于 issue 下一周期」且恰好一次），差别只在内部流水级数/面积/时序。
- C4 PPA 若显示 MUL 不是关键路径且面积吃紧，改配置（`make menuconfig` → 2）即可，无需改 RTL。

**回退影响**：改一个配置项（默认值或菜单范围）；`fu_mul` 按 `MUL_LATENCY` 参数化实现（`MUL_LATENCY=3` 时 3 级流水）。

---

### D-C0-04 — SPEC-A12：`LINE_BYTES` 默认 **32B**，可经 `make menuconfig` 选 16/64 **[C0]**

- 默认配置：`DCACHE_SIZE_BYTES=8192`、`DCACHE_NUM_WAYS=2`、`LINE_BYTES=32` ⇒ `NUM_SETS=128`、`LINE_BEATS=2`、`ROWS_PER_LINE=4`、`INDEX_BITS=7`、`OFFSET_BITS=5`、`TAG_BITS=20`。
- **可配置（v0.6）**：`configs/Kconfig` 的 `choice LINE_BYTES`（16/32/64，默认 32）；生成的 `CONFIG_LINE_BYTES` 由 `rtl/common/ares_pkg.sv` 读取，未配置时回退 32。三档均已通过 `tb_ares_pkg` 的几何/整除/2 的幂检查。
- memory.md §6.1 已给默认值；16/32/64 三档的 IPC/面积/Fmax 对比按 plan §8.3 留在 **C4（P1）**执行，届时改配置 + 重跑 C3 回归即可。
- 所有派生量（beat 数、row 数、位宽）都由包内 localparam 推导，**不存在硬编码**。

**回退影响**：改一个配置项；`dcache_arrays/mshr/wb/line_adapter` 必须完全参数化（C2 的 DoD 已包含）。

---

### D-C0-05 — SPEC-M15：LQ/SQ credit 口径 **[C0]**

**结论：credit = 队列总容量 − 周期初已登记占用量；占用量包含入口寄存器/AGU 在途的预留；不借用本周期任何释放。**

```text
load_credit  = 2'd(LQ_ENTRIES - lq_valid_cnt)      // LQ_ENTRIES = 4
store_credit = 3'd(SQ_ENTRIES - sq_occupancy)      // SQ_ENTRIES = 8, 含 SPEC + COMMITTED
```

- `issue_fire` 时**原子**预留（LQ bitmap 分配 / SQ tail 分配），入口寄存器与 AGU 携带该 index，之后不得二次分配；
- `lq_valid_cnt` 统计所有已分配、尚未「Completion 实际发出或 kill」的 entry；
- `sq_occupancy` 统计所有有效 entry（SPEC + COMMITTED，含等待 Write Ack 的 MMIO Store）；
- 本周期 takeover/kill/commit 释放的空位**不**计入本周期 credit；
- `lsu_can_accept` 只表示「入口本周期能锁存一条请求」（入口寄存器空），同样不组合依赖 `issue_valid`。

**理由**：只有这一口径才与「`issue_fire` 原子预留 + guaranteed-accept（无第二次 ready/retry）」自洽；任何「借用本周期释放」的口径都会让 credit>0 而实际无法分配。

---

### D-C0-06 — SPEC-M16：`store_commit_ok[i]` 检查清单 **[C0]**

`store_commit_ok[i] = 1` 当且仅当**同时**满足（全部为周期初已登记状态，且**不得**组合依赖 `commit_fire[i]`）：

1. `store_commit_valid[i]` 在 SQ 中找到该 tag，且该 entry 为 **SPEC** Store（`valid && !committed && !killed`）；
2. lane 顺序匹配：该 Store 是自 `sq_commit_ptr` 起按全局 Commit lane 顺序可提交的连续前缀（lane0 必须位于 `sq_commit_ptr`；非 Store 的全局 lane 跳过、不占 SQ）；lane1 还需 lane0 匹配成功；
3. `addr_valid && data_valid`（AGU 已登记地址、Store 数据已对齐并登记 `byte_mask`）；
4. 支持的执行检查已完成（非自然对齐等未支持情形按 D-C0-01 处理，不在此处静默通过）；
5. 该 tag 未被 `kill_mask` 命中，且不处于「已被 kill 但状态未清」的中间态；
6. 该 entry 未被本周期 takeover（takeover 只可能发生在更老且已 COMMITTED 的 head）。

**不含**的检查（避免过度约束）：不要求 DCache 空闲、不要求 execution Completion 已从端口发出（CIQ DONE 条件已隐含）、不要求设备响应（MMIO Store 授权后的设备 Write 由 LSU 自行等待 Write Ack）。

**回退影响**：清单收窄/放宽会改变「Store 何时可提交」的可观测时机（IPC），但不改变 `commit_fire` 的架构含义；需同步更新 `tb_lsu` 定向用例。

---

### D-C0-07 — SPEC-A7：IRQ Drain 与 Serializing Dispatch/Issue 的交互 **[C0]**

**结论：Drain 只冻结「新 Dispatch」，不冻结已 WAIT 的 Issue；串行化指令仍按 §8.3 的 Serializing Gate 单独发射。**

- Drain 期间 `iq_accept_count = 0`（IRQ Drain 是 Dispatch Gate 的一个来源），已入 CIQ 的指令继续 WAIT Issue / OoO Completion / 正常 Commit；
- 已在 CIQ 的 CSR/ECALL/MRET 仍要求 `tag == commit_ptr && lsu_mmio_order_idle` 才能**单独**发射；由于 `tag == commit_ptr`，其后不存在更年轻的已发射指令，与「Drain 期间不引入新指令」不冲突；
- 若该串行化指令是 **ECALL/MRET**，其自身的 Trap/MRET Redirect 优先于 IRQ Boundary Redirect（§17.3 优先级表），Drain 在该 Redirect 处结束；中断条件在 Redirect 后的后续周期按 §17.2 重新评估（`mstatus/mie` 因 Commit 引起的变化「于随后周期重新评估」）；
- 若 Drain 期间中断条件被清除（例如较老的 CSR/MRET Commit 改变了 `mstatus.MIE`），按 §17.2 Redirect 到 `architectural_next_pc` 恢复，不进入 Trap。

**理由**：§17.2 明文「继续允许现有 WAIT Issue」；额外屏蔽串行化 Issue 会造成「Drain 等待一条永远不能发射的指令」的死锁。

---

### D-C0-08 — SPEC-A8：ECALL 沿 `architectural_next_pc` 的更新 **[C0]**

**结论：`architectural_next_pc` 只由「正常 commit_fire」更新；ECALL 不 commit_fire，因此该沿不更新。**

- ECALL 沿：`mepc = ecall.pc`、`mcause = 11`、`MPIE←MIE, MIE←0, MPP←M`，Redirect 到 `mtvec.BASE`；`architectural_next_pc` **保持**上一次正常提交的后继（不会被 ECALL 的 pc+4 污染）；
- Trap handler 的第一条正常 Commit 按 §17.2 规则更新 `architectural_next_pc`（普通指令 pc+4、CFI 用 BRU `actual_npc`）；
- MRET 正常提交（独占 lane0），`architectural_next_pc = 已提交 mepc`；
- 因此「中断边界恢复点」永远是一个**已退休指令的真实后继**，不会出现「ECALL 的 pc+4」这种既非架构状态也未退休的中间值。

---

### D-C0-09 — SPEC-A9：ECALL/MRET 是否进入 BPU 训练/CFI 事件 **[C0]**

**结论：ECALL 与 MRET 不是 CFI 事件。**

- `cfi_type_t` 无 ECALL/MRET 成员；Predecode/Decode 对二者的 `is_cfi = 0`、`actual_cfi_type = CFI_NONE`；
- 它们**不**产生 `bpu_update_valid`、不消耗 `bpu_update_credit`、不进入训练 FIFO；
- 但它们仍走统一 Redirect 路径（`REDIRECT_ARCH`：ECALL Trap / MRET / IRQ 边界），并置 `is_serializing = 1`；
- `fe_stub` 的 predecode 与本文档一致（opcode 0x73 → `CFI_NONE`）；
- 供 FE 维护者对齐：真实 FE 不得把 ECALL/MRET 放入 `bpu_update` 或计作预测事件（契约 §4 的 `actual_cfi_type` 只覆盖分支/跳转类）。

**理由**：契约 §4 的 `bpu_update_t.actual_cfi_type` 类型是 `cfi_type_t`，而 ECALL/MRET 不在该枚举内；把它们塞进训练事件会迫使修改共享类型（跨模块布局变更），收益为零（方向/目标预测器对它们无意义）。

---

### D-C0-10 — C0 验证骨架的工程决策 **[FREE-10 / FREE-02]**

| 项目 | 决策 | 位置 |
|---|---|---|
| `fe_stub` 取指 | always-not-taken；`pred_npc = pc+4`；`need_redirect = 0`；预取队列 = 2 个可见 slot；Redirect 当拍清队首并从 `backend_redirect_pc` 重取 | `rtl/backend/test/fe_stub.sv` |
| `fe_stub` credit | 常量 `2'd2`（无 BPU，无可训练对象；常量天然不构成 BE→FE→BE 组合环） | 同上 |
| `fe_stub` pred_meta | 原样字段全 0，仅 `pred_target = pc+4`、`pred_type = 实际 CFI 类`；BE 只需回传，不参与判断 | 同上 |
| TB 内存模型读延迟 | `rsp_valid` 出现在读握手后 `MEM_LATENCY+1` 拍（默认 2 拍），数据寄存器化 → 反压期间稳定 | `sim/rtl/tb_mem_beat_if.sv` |
| 单 outstanding Read | `mem_rd_ready` 仅在无在途/无未消费响应时为 1 | 同上 |
| 写接受语义 | `wr_fire` 沿生效；写与读同周期时**写先于读**（同一 `always_ff` 内 program order） | 同上 |
| 字节 lane | 按 `mem_wr_be` 逐字节生成 `perip_write`（整字走 word 路径）；杜绝「把 lane 偏移加到未对齐地址」 | 同上 |
| MMIO | 单 outstanding；每 `req_fire` **恰好一次** response；response 在 req 后一拍（副作用已在握手沿完成）；`req_ready ≠ 完成` | `sim/rtl/tb_mmio_if.sv` |
| 构建 | `sim/Makefile` 新增 `ARES_RTL=1` 分支；**每个 top 独立 build 目录**（防止切换 TOPNAME 复用旧二进制） | `sim/Makefile` |
| lint 门槛 | `-Wall --assert`，仅 2 条全局豁免（`DECLFILENAME`、`TIMESCALEMOD`）；其余一律用文件内 `/* verilator lint_off */` 并注明理由 | `sim/Makefile`、各源文件 |
| 断言宏 | `CONFIG_SIMULATION`（与 `sim/Makefile` 的 `V_DEF_MACRO` 一致），保证观测逻辑不进综合 | 全部 RTL |
| 地址映射 | **不**在 core 包内冻结（SPEC-M7 属 P3）；TB 内存模型直接复用 `sim/csrc` 的事实映射（IROM `0x8000_0000`、DRAM `0x8010_0000`、MMIO `0xa000_0000`） | `sim/rtl/*.sv` |
| `RESET_MTVEC` | **不**在 `ares_pkg` 冻结（SPEC-M8 属 SoC 阶段）；core 复位只保证 `RESET_PC`，BSP 自行 `csrw mtvec` | `rtl/common/ares_pkg.sv` |

---

### D-C0-11 — 已登记、待 FE 维护者裁决（**不阻塞 core**） **[FE]**

`docs/implementation_plan.md` §7.6 要求在 C0 登记 D3/D11/D12 的裁决项。core 侧给出**建议结论**，最终由前端维护者确认：

| 条目 | 建议结论 | 对 core 的影响 |
|---|---|---|
| **SPEC-D3**（1 prediction/cycle 冻结吞吐被 0.5/cycle 违反） | frontend.md §1/§3.0 的 `latency=3, throughput=1/cycle` 是**冻结的对外性能契约**，前端必须重新流水；FREE-11 只允许「不改变外部契约」的内部寄存器调整，不能豁免该条 | 无（`fe_stub` 为 1 条/拍；core 不依赖 FE 吞吐） |
| **SPEC-D11**（Predecode 对条件分支猜方向并改写 `pred_taken/pred_target`） | 采纳契约 §3.1：只有**能确定正确下一 PC** 的 CFI（直接 JAL、可判定伪 CFI）允许 FE 本地修正；条件分支不得把未确定方向当已知（`pred_npc=pc+4`，方向留给 BRU）；未知目标 JALR 不得猜目标 | 无（BE 只用 `pred_npc` 比较，`pred_meta` 原样回传） |
| **SPEC-D12**（跨行取指窗口 vs frontend.md §7.4 冻结规则） | 采纳文档冻结规则（单次 fetch 不跨 line、`line_offset>16` 只返回本行剩余），与 plan §2.1 一致；§6.2 F09 的验证要求相应改为「验证尾部掩掉」 | 无（core 只消费 IQ） |

---

### D-C0-12 — 可配置参数机制（`make menuconfig`） **[C0]〔v0.6 新增〕**

**结论：core 的「实现时可调」参数统一通过 Kconfig 风格配置菜单选择，写入 `.config`，并由同一份配置生成 SV 头与 Verilator `-D`。**

| 项目 | 内容 |
|---|---|
| 菜单定义 | `configs/Kconfig`（Kconfig 子集：mainmenu/menu/config/choice/bool/int/range/help/source） |
| 工具 | `scripts/kconfig/ares_kconfig.py`（Python 3 标准库，无 kconfig/ncurses/venv 依赖） |
| 交互入口 | `make menuconfig`（curses；无 tty 时自动降级为行式菜单，`ARES_KCONFIG_NOCURSES=1` 可强制） |
| 非交互 | `make defconfig` / `oldconfig` / `savedefconfig` / `loaddefconfig` / `showconfig`；`set NAME=VALUE`（脚本/CI） |
| 保存 | `configs/build/.config`（gitignore）+ `configs/defconfig`（提交，记录非默认选择） |
| RTL 消费 | `configs/build/vsrc/include/ares_autoconf.vh` → ````ifdef CONFIG_*````；`sim/Makefile` 另用 `defs` 输出 `-DCONFIG_*` |
| 回退 | 包内 ````else```` 分支 = 冻结默认（2 / 32），因此裸 elaboration（无配置、无 include）仍可用 |
| 自检 | `make test-config`：默认值、set/范围拒绝、头文件生成、defconfig 往返、行式菜单、curses 逻辑（mock 屏，有 pty 时再加真实会话） |

**边界（实现时必须遵守）**

1. 只有**内部实现参数**可以进入菜单；任何会改变 `ares_pkg.sv` 跨边界字段布局的量都不得可配置（SPEC-C5）。`MUL_LATENCY`/`LINE_BYTES` 只影响内部流水级数与 DCache 几何（`LINE_BEATS/ROWS_PER_LINE/MSHR/WB/line_adapter` 派生量）。
2. 默认值必须等于 C0 冻结值；RTL 的 ````else```` 回退分支必须等于该默认值。
3. 菜单必须约束取值域（`range`/`choice`），且 `tb_ares_pkg` 每次运行都校验取值合法性并**打印生效配置**（测试日志即配置证据）。
4. 配置变化必须触发重建：`$(BIN)` 依赖生成头，`configs/Kconfig` / 工具 / `.config` 任一更新都会重新生成头文件。

**新增配置项的流程**：编辑 `configs/Kconfig` → 默认值 = 冻结值 → RTL 用 ````ifdef CONFIG_X```` + 默认回退 → 在 `tb_ares_pkg` 增加合法性检查 → `make test-config` + `make all`（至少两种取值）。

---

### D-C0-13 — SPEC-A13：可选 CSR 开关默认**全部关闭** **[C0]〔已确认：默认不开启〕**

**结论（项目方确认）：`HAS_MISA = HAS_MTVAL = HAS_MCYCLE = 0`，v1 不实现这三组可选 CSR。**

| 项目 | 内容 |
|---|---|
| 开关 | `rtl/common/ares_pkg.sv`：`localparam bit HAS_MISA/HAS_MTVAL/HAS_MCYCLE = 1'b0` |
| 关闭时行为 | 对 `misa(0x301)` / `mtval(0x343)` / `mcycle(0xB00)` / `mcycleh(0xB80)` 的访问 = **不支持的 CSR 访问** → 按 D-C0-01 走 `decode_err`：仿真断言/`$fatal` 报错，**不得**默认为 NOP、**不得**静默读成功返回 0；v1 不产生 illegal Trap |
| 关闭时 Trap 语义 | ECALL 不写 `mtval`（backend.md §16.2 的「可选 `mtval=0`」不适用）；`mepc/mcause/mstatus/mie/mip/mhartid` 等必需 CSR 不受影响 |
| 不做配置项 | **不**放入 `make menuconfig`：打开任一项都会让一个新 CSR 地址在架构上合法（ISA 可见），必须先评审再改包内 localparam（区别于 D-C0-12 的内部参数） |
| 冻结护栏 | `tb_ares_pkg` 断言三者全为 0 并打印取值；若要启用，必须同步修改该断言（= 有意的评审动作） |
| BSP 兼容性 | 已核查 `tests/`：AM/BSP 只用 `mtvec/mstatus/mepc/mcause`（必需集），cpu-tests 不使用可选 CSR → ISA 回归不受影响 |
| 后续启用方式 | 若将来需要：评审 → 改 `HAS_*` localparam → B16 `csr_file` 增加地址译码/字段掩码（`misa` 固定 `0x40001100`、`mtval` 32-bit R/W、`mcycle` 64-bit 可读写）→ 更新 tb 与 §8.3 定向用例 |

**理由**：v1 的验收范围（35 个 cpu-tests + AM 子集 + MTIP/MMIO）不依赖这三组 CSR；少实现即少一处 ISA 可见行为（也少一处需要与 BSP 对齐的语义，尤其 `mcycle` 的半字写与自增交互）。

---

## 2. 与规范之间需要评审知道的差异

1. **命名**：`ENTRY_*` 前缀（语义不变，FREE-02）。
2. **`fu_type_t` 位宽 4**：规范未给位宽；为 SPEC-M6 的 XIF 端口预留，避免日后改跨边界布局（FREE-01）。
3. **`chooser_meta_t.pred_ghr` 与 `pred_meta_t.ghr_before` 重复**：为兼容现有 FE 训练逻辑而保留（现有 `bpu.sv/gshare` 用 `pred_ghr` 索引）。契约的 `ghr_before` 是权威语义；建议 FE 迁移后统一使用 `ghr_before`，**布局不变**（不删字段）。
4. **`queue_entry_t` 的 `actual_*` 字段**：按 backend.md §4 原样保留（BRU Completion 登记），不新增/不删除。
5. **未在包内冻结的项**：`RESET_MTVEC`（SPEC-M8）、SoC 地址窗口（SPEC-M7）、XIF 端口（SPEC-M6）——三者的冻结点分别在 SoC 阶段 / C5 / 加速器集成阶段，core 不为它们引入占位信号。
6. **配置机制属于新增工程面**（不改变任何已批准微架构）：菜单里的每一项都必须是规范已允许的实现选择（[P]/FREE 类），不得用菜单引入新的架构行为；新增项按 D-C0-12 的流程走。

---

## 3. 交付物与验证证据（C0）

| # | 交付物 | 说明 |
|---|---|---|
| 1 | `rtl/common/ares_pkg.sv` | 共享包：全部跨边界类型 + 参数（B01+F01 合并，SPEC-I3） |
| 2 | `rtl/backend/test/fe_stub.sv` | 契约合规取指桩（F0），含 SVA |
| 3 | `rtl/backend/test/tb_fe_stub.sv` | 桩的自检 TB（消费侧契约检查） |
| 4 | `sim/rtl/tb_mem_beat_if.sv` | 128-bit D 总线 → DPI 模型适配（memory.md §6.7） |
| 5 | `sim/rtl/tb_mmio_if.sv` | MMIO → DPI 模型适配（memory.md §3.1） |
| 6 | `rtl/memory/test/tb_mem_model.sv` | 上述两个适配器的自检 TB（独立 shadow 模型） |
| 7 | `sim/rtl/tb_ares_core.sv` | C3 顶层空壳（stub + 总线模型 + DPI 观测声明） |
| 8 | `rtl/common/test/tb_ares_pkg.sv` | 包布局自检（类型位宽/枚举编码/参数关系/结构体逐字段往返），跨模块布局回归护栏 |
| 9 | `sim/Makefile` + 根 `Makefile` | `ARES_RTL=1` 分支、`lint`/`lint-all`、单元 TB 目标（`tb-ares-pkg`/`tb-fe-stub`/`tb-mem-model`） |
| 10 | `rtl/common/test/README.md`、`rtl/backend/test/README.md`、`rtl/memory/test/README.md` | 每个测试目录的可复现命令与检查清单 |
| 11 | `configs/Kconfig` + `configs/defconfig` | 配置菜单定义与保存的非默认选择（D-C0-12） |
| 12 | `scripts/kconfig/ares_kconfig.py`、`test_kconfig.py`、`README.md` | 无依赖配置工具、自检、使用说明 |
| 13 | 本文档 | C0 裁决项书面结论 |

**已执行的验证（本机 Verilator 5.046，命令可复现；`ARES_HOME` 需指向仓库根）**

```bash
# 0) 一键 C0 门禁 = lint + 3 个单元自检
make all

# 1) lint：4 个 top，-Wall --assert，0 warning
make -C sim ARES_RTL=1 RTL_ROOT=$PWD/rtl lint-all

# 1b) 共享包布局自检（14 个类型位宽 + 枚举编码 + 结构体逐字段往返）
make tb-ares-pkg
#   -> ALL TESTS PASSED: tb_ares_pkg layout/encoding checks (14 type widths)
#   -> HIT GOOD TRAP (exit 0)

# 2) 取指桩自检（消费侧契约 + PC 序列 + Redirect + 稳定性）
make -C sim ARES_RTL=1 RTL_ROOT=$PWD/rtl tb-fe-stub
#   -> ALL TESTS PASSED: tb_fe_stub consumed 393 instructions, 53 redirects, 700 cycles
#   -> HIT GOOD TRAP (exit 0)

# 3) TB 内存模型自检（beat/字节 lane/同周期写先于读/反压稳定/MMIO 单 outstanding）
make -C sim ARES_RTL=1 RTL_ROOT=$PWD/rtl tb-mem-model
#   -> ALL TESTS PASSED: tb_mem_model verified 12 memory-model operations in 79 cycles
#   -> HIT GOOD TRAP (exit 0)

# 4) 配置机制自检（默认值 / set+范围拒绝 / 头文件生成 / defconfig 往返 / 菜单）
make test-config
#   -> ALL TESTS PASSED: ares_kconfig (defaults, set, generation, defconfig round trip,
#                              line menu, curses logic)

# 5) 两种配置下的门禁（证明参数确实进入 RTL 并被校验）
make defconfig && make all      # (MUL_LATENCY, LINE_BYTES) = (2, 32)
#   -> tb_ares_pkg ... (MUL_LATENCY=2, LINE_BYTES=32, 14 type widths) + 两个 TB 全绿
python3 scripts/kconfig/ares_kconfig.py set MUL_LATENCY=3 LINE_BYTES=16 && make all
#   -> tb_ares_pkg ... (MUL_LATENCY=3, LINE_BYTES=16, 14 type widths) + 两个 TB 全绿
```

**尚未做（属 C1–C3）**：Backend/LSU 模块本体（`rtl/backend/`、`rtl/memory/` 目前只有 `test/`）；`ares_core_top`；ISA 回归。因此 C0 的「`ares_pkg` 被 BE/LSU/fe_stub 同时引用」目前体现为 **fe_stub + 两个 TB 模型 + tb_ares_core 空壳**共同编译通过；BE/LSU 在 C1/C2 接入同一个包（无需再改包）。

---

## 4. C0 出口判据对照（`docs/implementation_plan.md` §9.1）

| 出口条件 | 状态 | 证据 |
|---|---|---|
| `ares_pkg` 冻结 | ✅ | 本文档 §1 D-C0-02..04 + `rtl/common/ares_pkg.sv` |
| `make lint` 0 error | ✅ | `lint-all`：3 个 top、`-Wall --assert`、0 warning |
| `fe_stub` 可编译 | ✅（并已自检通过） | `tb-fe-stub` = HIT GOOD TRAP |
| C0 裁决项均有书面结论 | ✅ | 本文档 §1（D-C0-01..11） |
| TB 内存模型契约定义 | ✅ | `tb_mem_beat_if` / `tb_mmio_if` + `tb_mem_model` 自检 |
| 可配置参数机制 | ✅ | D-C0-12：`make menuconfig` + `make test-config` 全绿；两种配置下门禁全绿 |
| 可选 CSR 默认关闭 | ✅ | D-C0-13：`HAS_MISA/HAS_MTVAL/HAS_MCYCLE=0` + `tb_ares_pkg` 护栏 + BSP 兼容性核查 |

**已确认（v0.7）**：D-C0-01「不实现 illegal Trap」、D-C0-03「`MUL_LATENCY` 默认 3」、D-C0-13「可选 CSR 默认全关」。
**评审结论**：其余 [C0] 条目（D-C0-02、D-C0-04..D-C0-12）已在 core 范围评审中通过——**C0 关闭，MC0 达成**，进入 C1/C2。
