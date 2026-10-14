# FE ↔ BE 接口迁移请求（Frontend RTL → `frontend_backend_contract.md` v1.0）

> **状态**：请求评审 / 待 FE 维护者确认
> **发起方**：Backend + Memory 方向（本文件由后端侧整理，**不修改任何前端规范**）
> **关联**：`docs/implementation_plan.md` SPEC-C1/C2/C4/C5/I1、§7.6（现有前端 RTL 缺陷）、`docs/microarch/frontend_backend_contract.md`（唯一权威接口）
> **一句话**：2026-10-12 的 `docs: frontend & backend interface` 提交把 FE↔BE 边界升级为契约 v1.0（`iq_accept_count` 唯一消费、2-lane BPU 训练 + credit、`redirect_kind`、`need_redirect/pred_npc/ghr_before`），但**只改了文档、没有改 RTL**；现有 `rtl/frontend/` 仍是 10-09 的旧接口，需要一次约 **10–16 人日** 的迁移。后端按契约实现，**不阻塞**，但联调前必须完成。

---

## 1. 时间线与证据（为什么会出现两份「契约」）

| 日期 | commit | 作者 | 内容 | 是否动 RTL |
|---|---|---|---|---|
| 2026-09-21 | `e1685f4` | blossilver | 新增 `frontend.md`（已含 `need_redirect` 等字段设计） | 否 |
| 2026-10-03 | `e4b0d59` | blossilver | BTB/Predecode 文档更新 | 否 |
| 2026-10-07 | `d7a5031` | blossilver | 预测器文档：`pred_meta_t`/`update_meta_t` 设计 | 否 |
| **2026-10-09** | **`6a516fc`** | **blossilver** | **移植前端 RTL（16 个文件、3654 行）+ 新增 `frontend-integration.md`**：定义 `iq_rready + iq_raccept_cnt`、单条 `bpu_update_en/update_meta_t` 的接入接口 | **是（RTL 基线）** |
| 2026-10-11 | `1ef8095` | PlutoRedbean | `backend.md` 完成（+551 行）、`memory.md` 新增 | 否 |
| **2026-10-12** | **`f58a50d`**（main） | **PlutoRedbean** | **新增 `frontend_backend_contract.md` v1.0；`frontend.md` 升到 Draft 1.3（删 `update_meta_t`、`pred_meta_t` 增 `pred_type/ghr_before`、`ghr_commit` 改为 Commit 序、IQ 端口删除 `rready`）；`backend.md` 同步 §18** | **否** |
| 2026-10-12 | `97cbc15`（base_core） | PlutoRedbean | 把 main（含契约 + FE 文档 + FE RTL）merge 进后端分支 | 合并 |

**结论（问题从何而来）**：

1. 前端 RTL 与 `frontend-integration.md` 定稿于 **10-09**，当时后端/访存规范尚未完成（10-11），跨模块契约还不存在。
2. 跨模块契约 `frontend_backend_contract.md` v1.0 诞生于 **10-12**，重新定义了边界（把「rready 握手 + 单拍训练」改为「accept_count 唯一消费 + 2-lane 训练 + credit」），并在同一次提交里同步了 `frontend.md` v1.3 与 `backend.md` §18。
3. 该提交**只改文档**：`git show --stat f58a50d` 只列出 3 个 .md（backend.md +32、frontend.md ±84、新增契约 +129），**没有触碰 `rtl/frontend/`**。
4. 因此仓库里同时存在「权威但新」（契约 v1.0 + frontend.md 1.3）与「陈旧但可综合」（`rtl/frontend/` + `frontend-integration.md`）两个版本：这是**同一接口的 v1.2 → v1.3 升级**，不是口径之争。
5. 后端侧处理原则：以契约为唯一依据实现（`backend.md` §18 与 `frontend.md` §8 都已这样指定），把差异整理成本文件交给 FE 维护者，**不自行改前端**。

---

## 2. 冲突清单（逐项，含出处与 RTL 证据）

| # | 能力 | 契约 v1.0 要求（出处） | 现有 RTL | 差异性质 |
|---|---|---|---|---|
| 1 | IQ 消费握手 | `iq_accept_count` 是**唯一**消费依据，旧版 `rready` **删除**（契约 §2；frontend.md §4.1） | `iq.sv`：`consume = rready ? raccept_cnt : 0`，端口 `iq_rready` 由 `frontend.sv` 暴露；`tb_frontend.sv` 靠驱动 rready 通过 | **语义冲突**（后端按契约只给 accept_count 时 IQ 永不弹出 → 前端静默停摆） |
| 2 | 指令条目字段 | `iq_entry_t` = `pc, inst, pred_npc, pred_meta, need_redirect, cfi_type, is_cfi, valid`（契约 §2.1） | `fe_pkg::iq_entry_t` 无 `pred_npc`、无 `need_redirect`（frontend-integration §5 明确写"未预测 jalr 由后端正常重定向，无需该位"） | **字段缺失**（BRU 需要 `need_redirect` 才能无条件恢复；`pred_npc` 是 BRU 比较基准） |
| 3 | 预测元数据 | `pred_meta` 保留**原始**预测：`pred_taken/pred_target/pred_type/ghr_before`（契约 §2.1/§3.4） | `pred_meta_t` 无 `pred_type`、无 `ghr_before`（只有 `chooser_meta.pred_ghr`）；且 `ifu.sv` 在修正点会**改写** `pred_taken/pred_target` 再写入 IQ | **字段缺失 + 语义冲突** |
| 4 | 逐 CFI GHR 快照 | 每条 CFI 有被预测前的 `ghr_before`，块内不得共享错误快照；首版前提是「首个有效 CFI 后截断块」（契约 §2.1） | GHR 是**块粒度**：`gshare.sv` 用 `(ghr_spec << spec_num) or spec_taken` 一次推进整块，`pred_ghr` 对所有 slot 相同；IFU 只在**首个预测 taken 的 CFI** 后截断块（`ifu.sv` block_end 逻辑） | **语义冲突 + 截断规则不同** |
| 5 | BPU 训练接口 | `bpu_update_valid[1:0] + bpu_update[2]`（`bpu_update_t`）+ FE 反向提供 `bpu_update_credit[1:0]`；仅正常 Commit 触发；≤2 条/周期；credit=`min(2, DEPTH-occ)` 取周期初且**寄存**（契约 §4） | 单条 `bpu_update_en + update_meta_t`；无 credit；训练在**解析/单拍**语义下推进 `ghr_commit`（`gshare.sv` 中 `ghr_commit_next = update_en ? ... : ghr_commit`） | **接口 + 带宽 + 时序语义冲突** |
| 6 | 训练元数据格式 | `bpu_update_t{update_pc, actual_taken, actual_target, actual_cfi_type, pred_meta}`（契约 §4） | `update_meta_t{update_pc, actual_taken, is_branch, actual_info(btb_target_info_t), pred_meta}` | **类型不同**（`start_pc/cfi_offset` 可由 `update_pc` 推导，SPEC-C15） |
| 7 | Redirect | `backend_redirect_valid/pc/kind/ghr_before/actual_taken`；BRANCH 用 `ghr_before+actual_taken` 恢复 `ghr_spec`，ARCH 用**本周期已接受的 Commit 更新之后**的 `ghr_commit`（契约 §3） | 只有 `backend_redirect_valid/pc`；flush 时 gshare 用 `ghr_commit_next` 恢复、RAS 用 `sp_commit_next`，无 BRANCH/ARCH 区分 | **接口 + 恢复语义冲突** |
| 8 | 旧响应隔离 | Redirect 后旧路径 ICache/IFU 在途响应**不得**再入 IQ；需 epoch/事务标识 或 cancel+drain（契约 §3） | 只有 `poison_q` 两处临时分支，无 epoch/事务标识 | **机制缺失**（当前仅在特定时序下侥幸正确） |
| 9 | IQ flush 语义 | 只有 Backend Redirect/Reset 整体清 IQ；FE 本地修正保留 IQ 中较老正确前缀（契约 §3.1） | `frontend.sv` 把 `backend_redirect_valid` 接到 `iq.flush`，本地修正不清 IQ | **已一致** ✅ |
| 10 | IQ 深度 | 文档 §1/§4.3 = 8（HEAD2+BODY6）；契约 §2 称"可沿用 2+6" | RTL = 128（frontend-integration §5 记录） | **需冻结**（不影响协议，只影响容量/时序） |
| 11 | `cfi_type_t` 命名 | `CFI_COND_BRANCH`（frontend.md §3.2、契约 §4） | `CFI_BRANCH`（编码顺序相同） | **纯命名** |

---

## 3. 目标接口（建议冻结）

### 3.1 共享类型（建议放入 `rtl/common/ares_pkg.sv`，前后端共同 import）

```systemverilog
// 与契约 §2.1/§3/§4 一致；跨边界字段禁止用 ifdef 改变布局
typedef struct packed {
    logic [31:0]          pc;
    logic [31:0]          inst;
    logic [31:0]          pred_npc;       // 新增：FE 修正后"生效"的预测下一 PC
    pred_meta_t           pred_meta;      // 原始预测（含 ghr_before）
    logic                 need_redirect;  // 新增：未预测目标的 JALR -> BRU 无条件恢复
    cfi_type_t            cfi_type;
    logic                 is_cfi;
    logic                 valid;
} iq_entry_t;

typedef struct packed {
    logic [31:0]          pred_target;
    logic                 pred_taken;
    cfi_type_t            pred_type;      // 新增
    logic [GHR_WIDTH-1:0] ghr_before;     // 新增：逐 CFI 预测前快照
    // 训练用 metadata（chooser/loop 等）固定布局，不用 ifdef
} pred_meta_t;

typedef enum logic { REDIRECT_BRANCH, REDIRECT_ARCH } fe_redirect_kind_t;

typedef struct packed {
    logic [31:0] update_pc;
    logic        actual_taken;
    logic [31:0] actual_target;
    cfi_type_t   actual_cfi_type;
    pred_meta_t  pred_meta;
} bpu_update_t;
```

### 3.2 `frontend.sv` 端口建议

| 方向 | 新增/保留 | 删除 |
|---|---|---|
| FE→BE | `iq_valid[1:0]`、`iq_inst[1:0]`（`iq_entry_t`） | `iq_rvalid/iq_rbits` 仅改名 |
| BE→FE | `iq_accept_count[1:0]` | `iq_rready`（**删除**）、`iq_raccept_cnt`（改名） |
| BE→FE | `backend_redirect_valid/pc` + `backend_redirect_kind` + `backend_redirect_ghr_before` + `backend_redirect_actual_taken` | 仅 `valid/pc` |
| FE→BE | `bpu_update_credit[1:0]` | 无 |
| BE→FE | `bpu_update_valid[1:0]`、`bpu_update[1:0]`（`bpu_update_t`） | `bpu_update_en`、`bpu_update_meta` |
| — | 保持不变：`clk/rst`、`ifu_axi_bus`、`fetch_pc_out`、`RESET_VEC` | |

---

## 4. 逐文件改动清单与工作量（FE 侧）

| 文件（行数） | 需要的改动 | 类型 | 估时 | 风险 |
|---|---|---|---|---|
| `fe_pkg.sv` (177) | 增 `pred_npc/need_redirect/pred_type/ghr_before`；新增 `bpu_update_t/fe_redirect_kind_t`；删除跨边界 `ifdef` 可变字段；枚举更名 `CFI_COND_BRANCH` | 机械 | 0.5–1 d | 低 |
| `frontend.sv` (196) | 端口按 §3.2 重写；接线到 IQ/BPU/IFU | 机械 | 0.5 d | 低 |
| `iq.sv` (282) | 删除 `rready`：`consume = raccept_cnt`；断言改为"accept_count ≤ 有效前缀" | 机械 | 0.5 d | 低 |
| `bpu/bpu.sv` (401) | ① 登记 `bpu_update_credit`（寄存）；② 一拍接受 ≤2 条提交事件（lane 顺序）并**立即**推进 `ghr_commit`；③ 8-entry 训练 FIFO，按 1 条/周期出队驱动现有子预测器训练端口；④ Redirect 两路恢复（BRANCH/ARCH）；⑤ 把逐 CFI `ghr_before` 填进 `ftq_wdata.pred_meta` | **结构** | 3–5 d | 中高 |
| `bpu/direction/gshare.sv` (164) | 提交状态 2-lane 推进；flush 恢复按 kind（BRANCH 用 `ghr_before+actual_taken`；ARCH 用 `ghr_commit`）；预测索引仍用 `ghr_spec` | 结构 | 0.5–1 d | 中 |
| `bpu/direction/tournament.sv` (272) / `bimodal.sv` (102) / `loop_predictor.sv` (208) | 训练端口由 FIFO 出队驱动（接口基本不变）；Loop 的 `iter_commit` 改为 2-lane 提交推进；顺带修 SPEC-D6 | 结构 | 1–2 d | 中 |
| `bpu/target/ras.sv` (98) / `ubtb.sv` (323) | RAS 的 `sp_commit` 2-lane 提交推进；uBTB 训练字段由 `bpu_update_t` 推导（`start_pc=update_pc&~15`、`cfi_offset=(update_pc&15)>>2`） | 结构 | 0.5–1 d | 中 |
| `ifu/ifu.sv` (541) | ① 生成并写入 `pred_npc`（不跳转=`pc+4`；预测 taken=生效目标；本地修正 JAL=修正目标）；② `pred_meta` 改为**原样**保留（修正值只进 `pred_npc`，顺带修 SPEC-D11）；③ 未预测 JALR 置 `need_redirect` 并**停止其后可见取指**直到 BRU Redirect（新增 stall 状态）；④ 块截断改为「首个**有效 CFI** 后」（或逐 CFI 快照，见 Q2）；⑤ 旧响应 epoch/取消过滤（SPEC-D5） | **结构** | 2–4 d | 中 |
| `ftq.sv` (115) | 无需改（per-slot `pred_meta` 已具备）；仅确认截断后 `ghr_before` 单值语义 | — | 0–0.5 d | 低 |
| `ifu/icache.sv` (258) / `interface/axi_if.sv` (97) | **与本迁移无关**（SPEC-D4/D9/D10 可另开任务） | — | 0 d | — |
| `test/tb_frontend.sv` (206) | 按新接口重写；加入契约 §6 断言与**可判别激励**（真实指令镜像、CFI、IQ 反压、redirect 竞争，SPEC-D13） | 机械+验证 | 2–3 d | 中 |
| **合计** | 不含 TAGE/SC/mBTB（SPEC-M1 另议） | | **10–16 人日** | |

> 说明：D1（IQ 满时修正块丢失）、D5（旧响应隔离）、D11（Predecode 猜分支方向）与本次迁移**改的是同一段代码**，建议合并排期；D2/D4/D7/D8/D9/D10/D12 可独立排。

---

## 5. 验收标准（"FE 迁移完成"的定义）

1. `tb_frontend` 使用新接口、全部用例通过，且断言至少覆盖契约 §6：
   - `iq_valid inside {00,01,11}`；`iq_accept_count <= $countones(iq_valid)`；接受 2 条时两 slot 均有效；`accept_count=0` 时队首稳定；
   - `backend_redirect_valid |-> iq_accept_count == 0`；Redirect 后旧响应不再入 IQ；
   - `need_redirect` 的 JALR 必产生一次 Branch Redirect；
   - `bpu_update_valid[i] -> commit_fire[i] && is_cfi[i]`（联调 TB 由后端侧断言）；事件数 ≤ 当周期 credit；lane 顺序入 FIFO、无丢失/重复；
   - Branch 恢复用 `ghr_before + actual_taken`；ARCH 恢复用更新后的 `ghr_commit`。
2. 与后端桩联调：后端提供 `rtl/frontend/test/tb_fe_be_contract.sv`（真实 `frontend` 例化 + 契约合规的 BE 行为桩），FE 侧跑一条命令即可验证。
3. ISA 子集（`add`/`load-store`/`branch` 等）在 core 级通过（整机由后端侧负责；FE 侧只需保证接口不丢指令）。

---

## 6. 需要 FE 维护者确认的问题

| # | 问题 | 备选 | 后端侧倾向 |
|---|---|---|---|
| Q1 | `IQ_DEPTH` 冻结为 8 还是 128？ | 8（文档）/ 128（现状） | 任一都可，但需写入 `ares_pkg` 并冻结 |
| Q2 | 块截断改为「首个**有效 CFI** 后」是否接受？ | (a) 接受（契约前提，实现简单）；(b) 保留现规则并实现**逐 CFI** `ghr_before` 快照 | (a) 风险最低；若担心取指带宽，(b) 需要更多验证 |
| Q3 | 能否一拍接受 **2 条**提交训练事件？ | (a) 实现（契约 credit=`min(2, DEPTH-occ)`）；(b) 只接受 1 条 → 需架构作者把 credit 公式改为 `min(1, ..)` 并评审 | (a) 保持契约；否则必须改契约 |
| Q4 | `need_redirect` 的"停止后续可见取指"用新增 stall 状态实现是否可行？ | (a) IFU 状态机新增；(b) 靠 IQ 满自然背压（不满足契约语义） | (a) |
| Q5 | `cfi_type_t` 统一为 `CFI_COND_BRANCH`（纯命名，编码不变）？ | 是/否 | 是（契约 §4 用此名） |
| Q6 | 迁移与 SPEC-D1/D4/D5/D7/D8/D9/D11/D12 是否合并排期？ | 建议合并 D1/D5/D11 | 合并 D1/D5/D11，其余可分 |

---

## 7. 后端侧的承诺（降低 FE 侧顾虑）

- 后端**只依赖契约**，不依赖 FE 内部实现；`tb_backend`/`tb_lsu` 用 FE/LSU 桩自测，**不阻塞 FE 排期**。
- `iq_entry_t/pred_meta_t/bpu_update_t` 等共享类型由**双方评审后冻结**；后端不单方面改字段。
- 后端提供契约断言**参考 SVA** 与联调 TB（`tb_fe_be_contract.sv`），FE 侧可直接复用。
- 本文件**不修改** `frontend.md`/`frontend-integration.md`；是否把 `frontend-integration.md` 标注为历史文档由 FE 维护者决定（建议在文件顶部加一行说明，避免后来者误用旧接口）。

---

## 8. 可直接粘贴的沟通消息（短版）

> **主题**：FE↔BE 接口需要升级到 `frontend_backend_contract.md` v1.0（RTL 仍是旧接口）
>
> blossilver 你好，后端在做 RTL 实现计划时发现一个跨模块问题，想同步一下：
>
> 1. `f58a50d`（10-12 `docs: frontend & backend interface`）新增了 `frontend_backend_contract.md` v1.0，并把 `frontend.md` 升到 1.3 —— 该提交**只改了文档**，没有改 `rtl/frontend/`。`backend.md` §18 与 `frontend.md` §8 都指明这份契约是 FE↔BE 的**唯一规范**，因此后端会按它实现。
> 2. 现在 `rtl/frontend/` 与 `frontend-integration.md` 仍是 10-09 的接口（`iq_rready + iq_raccept_cnt`、单条 `bpu_update_en/update_meta_t`、无 `redirect_kind`、`iq_entry_t` 无 `pred_npc/need_redirect`、`pred_meta` 无 `ghr_before`），与契约共 11 处差异。
> 3. 我把差异、逐文件改动清单、工作量（约 10–16 人日）与验收标准整理成 `docs/fe_contract_migration.md`，其中 Q1–Q6 需要你确认（尤其 Q2 块截断规则、Q3 是否支持一拍两条训练事件）。
> 4. 另外独立审计发现现有 FE RTL 有若干缺陷（`docs/implementation_plan.md` §7.6 的 SPEC-D1–D13），其中 **D1（IQ 近满时含 JAL 的局部修正块可能整块丢失）**、**D2（IQ 仍以 `rready` 限定消费）**建议与本次迁移合并修复；D5/D11 与迁移改同一段代码。
> 5. 后端会先按契约实现并用 FE 桩自测，不阻塞你的排期；`ares_pkg` 共享类型与联调 TB 我可以先出，供你直接复用。等你确认排期后再对齐联调时间点。
>
> 需要我先把 `tb_fe_be_contract.sv` 与契约断言写出来吗？
