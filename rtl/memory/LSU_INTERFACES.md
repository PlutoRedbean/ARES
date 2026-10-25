# LSU 模块接口冻结（C2 / M2a + M2b）

> **状态**：M2a 接口冻结（L02/L03/L04/L05/L12/L10/L01 最小闭环，§1–§8）；**M2b 接口冻结**（L07 dcache_arrays / L08 mshr / L09 wb_buffer / L11 mmio_bridge + L06/L01 收敛边界，§9–§14）。
> **M2b 决策**：`docs/m2b_decisions.md`（D-M2b-01…10）。
> **权威**：`docs/microarch/memory.md`（§3–§7）、`docs/implementation_plan.md` §5.10–§5.13 / §6.3 / §9.4。
> **本文件的作用**：把 §9.4 C2 分阶段实现时**必须先冻结的模块边界**写成可执行契约，供各模块并行实现与自检 TB 使用。
> **约束**：实现必须逐字使用下面的端口名/位宽/方向；**不得**新增、删除、重命名端口，也不得改变语义。若发现接口本身有误，先报告再改（接口即契约）。

## 0. 通用约定

| 项目 | 约定 |
|---|---|
| 时钟/复位 | 单时钟 `clk`，同步高有效 `rst`；复位后 1 周期内所有 `*_valid`/`occupied` 为 0 |
| 类型 | 跨子系统类型只能用 `ares_pkg`（`tag_t/fu_req_t/fu_completion_t`…）；LSU 内部类型用 `rtl/common/lsu_pkg.sv`（`lsu_size_t` + `lsu_size_mask/align_store_data/merge_extract/...`） |
| tag | `tag_t = {slot_index[3:0]}`，**valid-only** 生命周期（无 generation）。`kill_mask[15:0]` 按 slot 索引命中 |
| kill 语义 | `kill_mask[i]` 表示 CIQ slot `i` 的 operation 已取消：该 operation 不得再产生有效 Completion，必须释放其占用的 LQ/SQ entry。**kill 优先于同周期 Completion/Hit** |
| guaranteed-accept | `can_accept/ready` 只能是**已登记状态**的函数，不得组合依赖 `valid`；`valid && ready` 当拍原子转移所有权 |
| credit | `load_credit/store_credit` 按**周期初**占用计算，不借用本周期释放的空位 |
| 源结果所有权 | 每个存活 Load/Store **恰好一次** Completion；结果源在 `compl_valid && compl_ready`（或 EXEC 的 `exec_valid && exec_ready`）沿交出所有权并清除本地 pending |
| 目录 | 模块：`rtl/memory/*.sv`；单元自检 TB：`rtl/memory/test/unit/tb_*.sv`（自有时钟，独立 top，不使用 DPI/harness） |
| 自检风格 | 自比对 + `$fatal`/错误计数；结束打印 `ALL TESTS PASSED: <n> checks - <覆盖摘要>`；断言放在 `ifdef CONFIG_SIMULATION` |

**单元 TB 构建/运行命令模板**（仓库根目录；显式文件列表，避免并行开发时互相干扰）：

```bash
# 注意：verilator 生成的 make 以 --Mdir 为工作目录，因此 -o 必须是**文件名**而不是路径
# （写成路径会在链接阶段失败）。产物仍然落在 --Mdir 下，或直接用：make unit-lsu
verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
    -DCONFIG_SIMULATION --top-module <TB> --Mdir sim/build/unit/<TB> -o <TB> \
    rtl/common/ares_pkg.sv [rtl/common/lsu_pkg.sv] <模块>.sv rtl/memory/test/unit/<TB>.sv
sim/build/unit/<TB>/<TB>
```

**staging 说明（M2a → M2b）**：M2a 的 `lsu_top` 用 `line_adapter` 的**单 beat 端口**直连 TB 内存模型，形成最小读写闭环；该直连路径只改变“数据从哪来”，**不改变** LQ/SQ/Forwarding/Completion/Commit/kill/credit 的任何后端可见语义。
**M2b（当前）**用 `dcache_top`+`mshr`+`wb_buffer` 替换该直连路径（LQ 的 `lookup_*`/`fill_*`、SQ 的 `drain_*` 保持为对 DCache 的请求/接管接口），MMIO 顺序逻辑抽为 `mmio_bridge.sv`。接口冻结见 §9–§14。

---

## 1. L02 `lsu_agu.sv` — Input Register + 流水 AGU

职责（memory.md §3/§3.1）：`addr = src1 + imm`；访问大小、byte mask、对齐 Store 数据、`is_mmio` 分类；携带 LQ/SQ 预留 index。

**流水**：C0 周期末 `issue_valid` 接收 → C1 输入寄存器 → C1 组合计算、C1 末寄存 AGU 结果 → 输出在整个 C2 有效（对应 memory.md §6.2 的 “C1 计算/登记地址”）。无 ready/反压：每个非 kill 的 issue 都必须有输出。

```systemverilog
module lsu_agu #(
    parameter logic [31:0] MMIO_BASE = 32'hA000_0000,  // SPEC-M7 占位：事实映射
    parameter logic [31:0] MMIO_MASK = 32'hFF00_0000   // is_mmio = ((addr & MASK)==(BASE & MASK))
) (
    input  logic                       clk,
    input  logic                       rst,

    //---- issue port（预留 index 随请求一起流水）---------------------------
    input  logic                       issue_valid,
    input  ares_pkg::fu_req_t          issue_req,
    input  logic [2:0]                 issue_qidx,      // LQ(2b)/SQ(3b) 预留 slot
    input  logic                       issue_kill,      // 同拍 kill_mask[tag]

    //---- AGU 结果（寄存，C2 有效）----------------------------------------
    output logic                       out_valid,
    output ares_pkg::tag_t             out_tag,
    output logic [2:0]                 out_qidx,
    output logic                       out_is_load,
    output logic                       out_is_store,
    output logic [31:0]                out_addr,
    output lsu_pkg::lsu_size_t         out_size,
    output logic [3:0]                 out_byte_mask,   // lsu_size_mask(addr[1:0], size)
    output logic [31:0]                out_store_data,  // lsu_align_store_data(src2, addr[1:0], size)
    output logic                       out_is_unsigned,
    output logic                       out_is_mmio
);
```

要点：`out_addr = issue_req.src1 + issue_req.imm`（32-bit 回绕）；`out_is_load/store` 用 `lsu_pkg::lsu_op_is_load/store`；`issue_kill` 时下一拍 `out_valid=0`；`CONFIG_SIMULATION` 下断言自然对齐（`SPEC-A1/D-C0-01`：不对齐在仿真报错，RTL 无架构行为）。

## 2. L05 `store_forward.sv` — byte-wise 转发比较

职责（memory.md §4.2）：对**单个候选 Load**，在 `older_mask` 指定的较老 Store 集合内逐 byte 选出“最近较老 Store”，输出 `fwd_mask/fwd_data`；并给出 `dep_ready`（mask 内所有 Store 地址/数据就绪）。纯组合、无状态、无 ready。SQ 逻辑顺序为 `head → tail`（越靠 tail 越年轻）；**mmio Store 不参与转发**。

```systemverilog
module store_forward (
    input  logic [31:0]        load_addr,
    input  logic [3:0]         load_byte_mask,   // 本次 Load 需要的 byte
    input  logic [7:0]         older_mask,       // LQ entry 快照（较老 Store 集合）
    input  logic [7:0]         sq_occupied,
    input  logic [7:0]         sq_addr_valid,    // 地址/数据已登记
    input  logic [7:0][31:0]   sq_addr,
    input  logic [7:0][31:0]   sq_data,          // AGU 已对齐的数据
    input  logic [7:0][3:0]    sq_byte_mask,
    input  logic [7:0]         sq_is_mmio,
    input  logic [2:0]         sq_head_ptr,
    input  logic [3:0]         sq_occupancy,
    output logic [3:0]         fwd_mask,
    output logic [31:0]        fwd_data,
    output logic               dep_ready
);
```

- byte 命中：`older_mask[i] && sq_occupied[i] && !sq_is_mmio[i] && sq_byte_mask[i][b] && (sq_addr[i][31:2]==load_addr[31:2])`（自然对齐下字地址比较即 byte 覆盖判定）。
- 选择：命中集合中 SQ 逻辑年龄**最大**者（`order(i)=(i-head)&7`）；同 byte 只能有一个来源。
- `dep_ready = ((~older_mask) | sq_addr_valid) == 8'hFF`（mask 内的 Store 地址/数据全部就绪）。
- `fwd_mask` 为该 Load 需要的字节（`load_byte_mask` 之外恒 0）；`fwd_data` 按 byte lane 对齐。
- 结构：8 store × 4 byte 的并行比较 + 每 byte 一棵选择树，避免串行优先级链（FREE-04）。

## 3. L03 `lq.sv` — 4-entry Load Queue

职责（memory.md §4.1/§4.2/§3.1）：bitmap 分配/释放；`older_store_mask` 快照；forwarding 快照 + 全转发直通；最老可服务 Load 仲裁；MMIO Load 等待 Commit Head；`result_valid`；只有 Completion 实发或 kill 才释放。内部实例化 `store_forward`。

```systemverilog
module lq (
    input  logic                            clk,
    input  logic                            rst,

    //---- issue 分配（原子预留）--------------------------------------------
    input  logic                            alloc_valid,
    input  logic [1:0]                      alloc_idx,       // lsu_top 给出的空闲 slot
    input  ares_pkg::tag_t                  alloc_tag,

    //---- AGU 登记 ---------------------------------------------------------
    input  logic                            agu_valid,
    input  logic [2:0]                      agu_qidx,
    input  ares_pkg::tag_t                  agu_tag,
    input  logic [31:0]                     agu_addr,
    input  lsu_pkg::lsu_size_t              agu_size,
    input  logic [3:0]                      agu_byte_mask,
    input  logic                            agu_is_unsigned,
    input  logic                            agu_is_mmio,

    //---- SQ 状态（mask + 转发 + head）-------------------------------------
    input  logic [7:0]                      sq_occupied,
    input  logic [7:0]                      sq_takeover,     // 本周期 takeover one-hot
    input  logic [7:0]                      sq_addr_valid,
    input  logic [7:0][31:0]                sq_addr,
    input  logic [7:0][31:0]                sq_data,
    input  logic [7:0][3:0]                 sq_byte_mask,
    input  logic [7:0]                      sq_is_mmio,
    input  logic [2:0]                      sq_head_ptr,
    input  logic [3:0]                      sq_occupancy,

    //---- Cache 读请求（最老可服务 Load，一次一个）-------------------------
    output logic                            lookup_valid,
    input  logic                            lookup_ready,
    output logic [1:0]                      lookup_idx,
    output ares_pkg::tag_t                  lookup_tag,
    output logic [31:0]                     lookup_addr,

    //---- 数据返回（DCache Hit / MSHR WAKE / M2a 直连路径）-----------------
    input  logic                            fill_valid,
    input  logic [1:0]                      fill_idx,
    input  logic [31:0]                     fill_word,       // entry.addr[31:2] 处的 4 byte

    //---- MMIO Load（只有 Commit Head 可发一次设备读）----------------------
    input  logic                            load_head_valid,
    input  ares_pkg::tag_t                  load_head_tag,
    output logic                            mmio_req_valid,
    input  logic                            mmio_req_ready,
    output logic [31:0]                     mmio_req_addr,   // word 对齐：{addr[31:2],2'b00}
    input  logic                            mmio_rsp_valid,  // lsu_top 只路由给本事务 owner
    input  logic [31:0]                     mmio_rsp_data,

    //---- Completion（所有权交给 L12）--------------------------------------
    output logic                            compl_valid,
    input  logic                            compl_ready,
    output ares_pkg::tag_t                  compl_tag,
    output logic [31:0]                     compl_result,

    //---- Flush ------------------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,

    //---- 状态 / 分配索引 ---------------------------------------------------
    output logic [1:0]                      lq_alloc_idx,    // 最低空闲 slot（!lq_full 时有效）
    output logic [2:0]                      lq_used,
    output logic                            lq_full
);
```

要点（必须逐条实现）：
1. **分配**：`alloc_valid` 沿写入 `{tag, older_store_mask = sq_occupied & ~sq_takeover}`（issue 同周期锁存，memory.md §4.2）；年轻 Store 不得加入已有 mask。
2. **AGU 登记**：`agu_valid && agu_qidx[1:0]==slot` 时写 `addr/size/byte_mask/is_unsigned/is_mmio`，置 `addr_valid`。
3. **takeover 清位**：`older_store_mask &= ~sq_takeover`（对所有存活 entry）。
4. **仲裁**：维护 4-entry 分配顺序表（可删除任意项），选**最老**且 `addr_valid && dep_ready && !lookup_inflight && !result_valid` 的 cacheable entry 发起 lookup；MMIO entry 不走 lookup。
5. **快照**：`dep_ready` 首次为 1 的那一拍锁存 `forward_mask/forward_data`（快照在 takeover/drain 之后仍可用）。
6. **全转发**：若 `(forward_mask & byte_mask)==byte_mask`，不发 lookup、不占 MSHR，直接用 `lsu_merge_extract` 出结果。
7. **lookup_inflight**：lookup 被接收（`lookup_valid && lookup_ready`）沿置位；kill 清位；`fill_valid && fill_idx` 且 entry 存活且 `lookup_inflight` 才接收数据（防止旧响应写入复用后的 slot），随后置 `result_valid`。
8. **MMIO Load**：`load_head_valid && load_head_tag==tag && older_store_mask==0 && !mmio_sent` 才能发一次设备读，置 `mmio_sent`；响应到且 entry 存活 → 用 `lsu_merge_extract`（无转发字节）出结果。MMIO entry 不建立 forwarding 快照、不占用 lookup/MSHR。
9. **Completion**：`compl_valid = result_valid && !kill_mask[tag]`；`compl_valid && compl_ready` 释放 entry。
10. **kill**：`kill_mask[tag]` 的 entry 立即释放，且此后不得再产生 completion/lookup 权限；kill 优先于同拍 fill/结果。
11. `lq_used` = 占用数（0..4）；`lq_full = (lq_used==4)`。
12. 断言（sim）：`older_mask & ~sq_occupied == 0`（无 stale 位）；entry 生命周期恰好一次占用/释放；同一 entry 不重复发起 lookup。

## 4. L04 `sq.sv` — 8-entry 统一 SQ（SPEC + COMMITTED 环形）

职责（memory.md §5.1/§5.2/§5.3）：环形分配、指针/计数不变量、SPEC→COMMITTED、2-wide Store Commit 匹配、最老 COMMITTED head drain 与 takeover、SPEC 后缀 Flush 回退、credit。

```systemverilog
module sq (
    input  logic                            clk,
    input  logic                            rst,

    //---- issue 分配（tail 预留 SPEC entry）--------------------------------
    input  logic                            alloc_valid,
    input  ares_pkg::tag_t                  alloc_tag,
    output logic [2:0]                      alloc_idx,       // = sq_tail_ptr

    //---- AGU 登记 ---------------------------------------------------------
    input  logic                            agu_valid,
    input  logic [2:0]                      agu_qidx,
    input  ares_pkg::tag_t                  agu_tag,
    input  logic [31:0]                     agu_addr,
    input  logic [3:0]                      agu_byte_mask,
    input  logic [31:0]                     agu_store_data,
    input  logic                            agu_is_mmio,

    //---- 执行阶段 Completion（每个 Store 恰好一次）------------------------
    output logic                            exec_valid,
    input  logic                            exec_ready,
    output ares_pkg::tag_t                  exec_tag,

    //---- 2-wide Store Commit（memory.md §5.2）------------------------------
    input  logic [1:0]                      store_commit_valid,
    input  ares_pkg::tag_t                  store_commit_tag [2],
    output logic [1:0]                      store_commit_ok,
    input  logic [1:0]                      commit_fire,

    //---- 最老 COMMITTED Store drain（DCache / MMIO Bridge）----------------
    output logic                            drain_valid,     // COMMITTED && addr_valid && !inflight
    output logic [2:0]                      drain_idx,
    output ares_pkg::tag_t                  drain_tag,
    output logic [31:0]                     drain_addr,
    output logic [31:0]                     drain_data,      // AGU 对齐数据
    output logic [3:0]                      drain_mask,
    output logic                            drain_is_mmio,
    input  logic                            drain_start,     // 请求已被接收（置 inflight）
    input  logic                            drain_takeover,  // 可见性已接管（释放 entry）

    //---- 转发读出口（LQ）--------------------------------------------------
    output logic [7:0]                      sq_occupied,
    output logic [7:0]                      sq_takeover,     // 本周期 takeover one-hot
    output logic [7:0]                      sq_addr_valid,
    output logic [7:0][31:0]                sq_addr,
    output logic [7:0][31:0]                sq_data,
    output logic [7:0][3:0]                 sq_byte_mask,
    output logic [7:0]                      sq_is_mmio,
    output logic [2:0]                      sq_head_ptr,
    output logic [3:0]                      sq_occupancy,
    output logic                            sq_mmio_store_pending, // 有 COMMITTED 未 takeover 的 MMIO Store

    //---- Flush ------------------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,

    //---- 状态 -------------------------------------------------------------
    output logic [3:0]                      store_credit,    // 8 - occupancy（周期初）
    output logic                            sq_full
);
```

要点（必须逐条实现）：
1. 指针：`head/commit_ptr/tail`（3-bit，mod 8），`committed_cnt[3:0]`；不变量 `commit_ptr=(head+committed_cnt)&7`、`tail=(head+occupancy)&7`；空/满用计数判断。
2. 同沿更新：`head+=t`、`commit_ptr+=c`、`tail+=a-k`、`occupancy+=a-t-k`、`committed_cnt+=c-t`（`a`=alloc、`c`=commit_fire 数、`t`=takeover、`k`=Flush 删除的 SPEC 年轻后缀）；Flush 周期 `a=0`。
3. `store_commit_ok`：lane0 匹配 `commit_ptr` 处 SPEC entry（tag 相等 && `addr_valid`）；lane1 匹配 `commit_ptr + (store_commit_valid[0] ? 1 : 0)`；跳过非 Store 全局 lane；`ok[1]` 依赖 `ok[0]`（前缀）。**只看已登记状态，不依赖 `commit_fire`**。
4. 状态更新只由 `commit_fire` 触发（SPEC→COMMITTED，原 CIQ tag 语义失效，但 entry 仍占 SQ 直到 takeover）。
5. drain 候选 = `committed_cnt>0` 时的 head entry；`drain_valid` 还要求 `addr_valid && !drain_inflight`；`drain_start` 置 inflight（同拍 takeover 时不得残留）；`drain_takeover` 沿清 entry 并推进 head。
6. MMIO Store：`drain_is_mmio` 由 entry 属性给出；只有 Write Ack 时才由 lsu_top 给 `drain_takeover`；**已 COMMITTED 的 Store 绝不被 kill**。
7. Flush：`!committed && kill_mask[tag]` 的 entry 释放；被 kill 的 SPEC Store 必须是**最年轻的连续后缀**（否则断言失败）；COMMITTED 前缀不受影响。
8. `exec_valid`：按环序（head→tail）最老的、`addr_valid && !exec_done` 的 entry，携带其 tag；`exec_valid && exec_ready` 置 `exec_done`（每 Store 恰好一次）。被 kill 的 entry 不再产生 `exec_valid`。
9. `store_credit = 4'd8 - occupancy`（周期初，不借用本周期释放）；`sq_full=(occupancy==8)`。
10. 断言（sim）：4 条指针/计数不变量、`occupancy==popcount(occupied)`、kill 后缀性质、每个 entry 至多一次 `exec_valid`。

## 5. L12 `lsu_completion.sv` — Fast Path + 2-entry FIFO

职责（memory.md §7）：单 Completion 端口（`<=1/cycle`，无 backpressure）；Fast Path 直通；2-entry FIFO；公平仲裁；每个源结果只拥有一次发送权；kill 优先。

```systemverilog
module lsu_completion #(
    parameter int unsigned FIFO_DEPTH = 2
) (
    input  logic                            clk,
    input  logic                            rst,

    //---- Fast Path（C3 Hit；源在未获 grant 前保持稳定）--------------------
    input  logic                            fast_valid,
    input  ares_pkg::tag_t                  fast_tag,
    input  logic [31:0]                     fast_result,
    output logic                            fast_take,       // 组合 grant，单周期

    //---- FIFO 入队（Store execute / 非直通 Load）--------------------------
    input  logic                            push_valid,
    input  ares_pkg::tag_t                  push_tag,
    input  logic [31:0]                     push_result,
    output logic                            push_ready,

    //---- 单一 LSU Completion 端口 -----------------------------------------
    output logic                            completion_valid,
    output ares_pkg::fu_completion_t        completion,

    //---- Flush ------------------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,

    //---- 状态 -------------------------------------------------------------
    output logic [1:0]                      fifo_count,
    output logic                            fifo_empty
);
```

## 6. L10 `line_adapter.sv` — Cache line ↔ 16B beat

职责（memory.md §6.7）：把一条 Refill/WB 拆成 `LINE_BEATS` 笔 16B；refill 组装 `beat_valid`；WB 发写；单 outstanding Read 所有者协作；字段在反压时保持稳定。另提供**单 beat 读/写**客户端（M2a 直连路径；M2b 不使用）。

```systemverilog
module line_adapter (
    input  logic                              clk,
    input  logic                              rst,

    //---- 读通道：整行 refill（MSHR）---------------------------------------
    input  logic                              refill_req_valid,
    output logic                              refill_req_ready,
    input  logic [31:0]                       refill_line_addr,   // line 对齐
    output logic                              refill_rsp_valid,
    input  logic                              refill_rsp_ready,
    output logic [8*ares_pkg::LINE_BYTES-1:0] refill_line_data,
    output logic [ares_pkg::LINE_BEATS-1:0]   refill_beat_valid,

    //---- 读通道：单 beat（M2a 直连）---------------------------------------
    input  logic                              beat_rd_req_valid,
    output logic                              beat_rd_req_ready,
    input  logic [31:0]                       beat_rd_req_addr,   // 16B 对齐
    output logic                              beat_rd_rsp_valid,
    input  logic                              beat_rd_rsp_ready,
    output logic [127:0]                      beat_rd_rsp_data,

    //---- 写通道：整行写回（WB Buffer）-------------------------------------
    input  logic                              wb_req_valid,
    output logic                              wb_req_ready,
    input  logic [31:0]                       wb_line_addr,
    input  logic [8*ares_pkg::LINE_BYTES-1:0] wb_line_data,
    output logic                              wb_done,            // 单周期脉冲

    //---- 写通道：单 beat（M2a 直连）---------------------------------------
    input  logic                              beat_wr_req_valid,
    output logic                              beat_wr_req_ready,
    input  logic [31:0]                       beat_wr_req_addr,   // 16B 对齐
    input  logic [127:0]                      beat_wr_req_data,
    input  logic [15:0]                       beat_wr_req_be,
    output logic                              beat_wr_done,

    //---- 128-bit Memory Bus（memory.md §6.7）-------------------------------
    output logic                              mem_rd_valid,
    input  logic                              mem_rd_ready,
    output logic [31:0]                       mem_rd_addr,
    input  logic                              mem_rsp_valid,
    output logic                              mem_rsp_ready,
    input  logic [127:0]                      mem_rsp_data,
    output logic                              mem_wr_valid,
    input  logic                              mem_wr_ready,
    output logic [31:0]                       mem_wr_addr,
    output logic [127:0]                      mem_wr_data,
    output logic [15:0]                       mem_wr_be
);
```

要点：
1. **单 outstanding Read**：读通道任一时刻最多一笔未完成事务（req 握手 → rsp 握手）；在此期间不接收新的 refill/beat 读请求。
2. 仲裁：读通道 `refill` 优先于 `beat_rd`；写通道 `wb` 优先于 `beat_wr`；请求未被接受时字段保持不变。
3. Refill：第 `b` 笔地址 `line_addr + 16*b`；响应按 `b` 写入 `refill_line_data[128*b +: 128]` 并置 `refill_beat_valid[b]`；全部 `LINE_BEATS` 笔到齐后 `refill_rsp_valid` 保持到 `refill_rsp_ready`。
4. WB：第 `b` 笔地址 `line_addr + 16*b`、数据 `wb_line_data[128*b +: 128]`、`be=16'hFFFF`；全部 beat 完成握手后 `wb_done` 单周期脉冲。
5. 单 beat 写：`beat_wr_done` 在 `mem_wr_valid && mem_wr_ready` 沿单周期脉冲。
6. 反压时下游字段稳定；接受请求前必须预留响应保持空间（不得在 `rsp_ready=0` 时覆盖未消费数据）。
7. `LINE_BYTES` 参数来自 `ares_pkg`（16/32/64，默认 32）；`LINE_BEATS=LINE_BYTES/16`。

## 7. L01 `lsu_top.sv`（M2a 最小闭环）— 后端可见端口

职责（backend.md §9.6 / memory.md §3 / plan §5.10）：对后端暴露全部端口；内部汇聚 AGU/LQ/SQ/Forwarding/Completion/Line Adapter；维护 MMIO 顺序与 `lsu_mmio_order_idle`；kill 分发。

```systemverilog
module lsu_top #(
    parameter logic [31:0] MMIO_BASE = 32'hA000_0000,
    parameter logic [31:0] MMIO_MASK = 32'hFF00_0000
) (
    input  logic                        clk,
    input  logic                        rst,

    //---- Issue Port（backend.md §9.6.1）-----------------------------------
    output logic                        lsu_can_accept,
    output logic [2:0]                  load_credit,     // 4 - LQ 占用
    output logic [3:0]                  store_credit,    // 8 - SQ 占用
    input  logic                        issue_valid,
    input  ares_pkg::fu_req_t           issue_req,

    //---- Completion Port ---------------------------------------------------
    output logic                        completion_valid,
    output ares_pkg::fu_completion_t    completion,

    //---- Commit / Flush ----------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    input  logic                        load_head_valid,
    input  ares_pkg::tag_t              load_head_tag,
    input  logic [1:0]                  store_commit_valid,
    input  ares_pkg::tag_t              store_commit_tag [2],
    output logic [1:0]                  store_commit_ok,
    input  logic [1:0]                  commit_fire,
    output logic                        lsu_mmio_order_idle,
    output logic                        lsu_fence_idle,

    //---- 128-bit Memory Bus（memory.md §6.7）-------------------------------
    output logic                        mem_rd_valid,
    input  logic                        mem_rd_ready,
    output logic [31:0]                 mem_rd_addr,
    input  logic                        mem_rsp_valid,
    output logic                        mem_rsp_ready,
    input  logic [127:0]                mem_rsp_data,
    output logic                        mem_wr_valid,
    input  logic                        mem_wr_ready,
    output logic [31:0]                 mem_wr_addr,
    output logic [127:0]                mem_wr_data,
    output logic [15:0]                 mem_wr_be,

    //---- MMIO Device Channel（memory.md §3.1）-----------------------------
    output logic                        mmio_req_valid,
    input  logic                        mmio_req_ready,
    output logic                        mmio_write,
    output logic [31:0]                 mmio_addr,
    output logic [31:0]                 mmio_wdata,
    output logic [3:0]                  mmio_wstrb,
    input  logic                        mmio_rsp_valid,
    output logic                        mmio_rsp_ready,
    input  logic [31:0]                 mmio_rsp_data,

    //---- TB 可见性（非架构状态）-------------------------------------------
    output logic [2:0]                  dbg_lq_used,
    output logic [3:0]                  dbg_sq_used
);
```

M2a 内部连接（staging，见 §0）：
- `lsu_can_accept = is_load ? (load_credit!=0) : (is_store ? (store_credit!=0) : 1'b0)`；不含 `issue_valid`。
- issue 沿：`alloc_valid = issue_valid && !kill_mask[tag]`；LQ slot = 最低空闲 bitmap，SQ slot = tail；同一 index 送 AGU。
- 读路径：LQ `lookup_*` → 单 beat 读（`beat_rd_*`，地址 `{lookup_addr[31:4],4'b0}`）→ 128-bit 响应中按 `lookup_addr[3:2]` 选 32-bit word → `fill_valid/fill_idx/fill_word`。
- 写路径：SQ `drain_*` → cacheable：`beat_wr_*`（`addr={drain_addr[31:4],4'b0}`、`data={4{drain_data}}`、`be = {4{drain_mask}} & (16'h000F << (4*drain_addr[3:2]))`）→ 写握手沿 `drain_takeover`；MMIO：`mmio_req_*`（`write=1`、addr = `{drain_addr[31:2],2'b00}`、wstrb=drain_mask、wdata=drain_data）→ `mmio_rsp_valid` 沿 `drain_takeover`。
- MMIO Load：LQ `mmio_req_valid` 且无未完成 MMIO 事务时发设备读；响应只路由给 LQ。
- `lsu_mmio_order_idle`：`!mmio_pending && !sq_mmio_store_pending`，按**周期初登记状态**产生，不组合借用本周期响应。
- `lsu_fence_idle`：`!mmio_busy && !sq_mmio_store_pending && sq_occupancy==0 && lq_used==0`；FENCE/FENCE.I 用它确认更老访存已离开 LQ/SQ，而不是只等 MMIO。
- `store_commit_ok` 直接来自 SQ；`kill_mask` 广播给 LQ/SQ/Completion/AGU。

## 8. 验证要求（每模块，plan §8.2 + plan §6.3）

1. **复位**：复位后 1 周期状态干净（valid/occupancy/指针 = 0 或冻结复位值）。
2. **边界**：满/空、wrap-around（指针 mod 8、LQ bitmap 复用）、同周期冲突（alloc+takeover、commit+flush、kill+completion、push+pop）。
3. **随机**：与参考模型比对（SQ 指针/计数、LQ 生命周期、store_forward 字节选择、FIFO 有序性），固定种子、≥10k 周期量级。
4. **负向**：kill 与 completion 同周期 → kill 胜；FIFO 满不丢失；SQ kill 后缀断言；未就绪 Store 阻塞 `dep_ready`。
5. **断言**：`ifdef CONFIG_SIMULATION` + `--assert`，0 误报。
6. 文件头注明：规范出处（memory.md §x）、FREE 项、构建/运行命令。

要点：
1. `fast_take = fast_valid && fifo_empty && !kill_mask[fast_tag]`（FIFO 非空时源保留结果，不得丢失）。
2. `push_ready = (fifo_count < FIFO_DEPTH) || pop_fire`；每周期最多 1 入队、1 出队。
3. 出队：FIFO 头 → `completion`（`exception=0/cause=EXC_NONE/tval=0`）；若 `kill_mask[head.tag]` 则**丢弃**（pop 但不发 `completion_valid`）。
4. Fast Path 与 FIFO 出队互斥（同一端口）；源必须保证 `push_valid`/`fast_valid` 在未被接受时保持不变。
5. `completion_valid` 单周期脉冲；`fifo_empty/fifo_count` 供断言与上层使用。
6. 断言（sim）：同一周期只有一个来源获得发送权；被 kill 的结果绝不出现于 `completion_valid`。
---

## 9. L07 `dcache_arrays.sv` — 每 Way 1R1W Data RAM + Tag/Valid/Dirty/LRU（M2b，**[已冻结]**）

职责（memory.md §6.1/§6.3）：2 个 Way 各自独立的 64-bit Row Data RAM（同步读、byte-enable 写）与独立 Tag/Valid/Dirty 元数据；每 Set 1-bit LRU 记录**最近使用 Way**（Victim 候选 = 另一 Way）。**不含**端口仲裁、Way 锁、Hazard：这些属 L06。

```systemverilog
module dcache_arrays (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] rd_set,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] rd_row,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_rsp_valid,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] rd_rsp_set,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] rd_rsp_row,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][63:0] rd_rsp_data,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_TAG_BITS-1:0] rd_rsp_tag,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_rsp_line_valid,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_rsp_dirty,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      wr_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] wr_set,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] wr_row,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][63:0] wr_data,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][7:0] wr_be,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] meta_set,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_TAG_BITS-1:0]   meta_tag,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_tag_en,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_line_valid_en,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_line_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_dirty_en,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_dirty,
    input  logic                                      lru_valid,
    input  logic [ares_pkg::DCACHE_INDEX_BITS-1:0]    lru_set,
    input  logic                                      lru_way,
    input  logic [ares_pkg::DCACHE_INDEX_BITS-1:0]    lru_rd_set,
    output logic                                      lru_rd_last_way
);
```

行为要点：
1. `rd_valid[w]=1` 接收读请求；下一周期 `rd_rsp_valid[w]=1` 一拍，`rd_rsp_set/row` 回传请求字段，`rd_rsp_data` 为该 Way 的 64-bit Row，`rd_rsp_tag/line_valid/dirty` 为该 Set 该 Way 元数据。
2. `wr_valid[w]=1` 写该 Way 的 Row（`wr_be[7:0]` byte-enable）；同 Way 每周期最多 1 Row（调用方保证）。
3. 元数据三字段各自带使能可同拍写；`meta_set` 为该 Way 的 Set。
4. LRU：`lru_valid` 写“最近使用 Way”；`lru_rd_last_way` 组合读出（Victim = `~lru_rd_last_way`）。
5. 复位：只复位 `line_valid/dirty`/LRU 与读响应 valid；**不复位** Tag/Data 阵列（SPEC-D9/BRAM 推断）。
6. 参数全部取自 `ares_pkg`；断言（sim）：`rd_rsp_valid[w]` 与上一周期 `rd_valid[w]` 相同、写使能合法、复位后无 valid line。

TB（`tb_dcache_arrays`）：写后读一致、部分 byte-enable、两 Way 独立、元数据/LRU、复位、`LINE_BYTES=16/32/64` 编译 + 默认 32 运行。

## 10. L08 `mshr.sv` — 2-entry MSHR / Refill / Overlay / WAKE（M2b，**[已冻结]**）

职责（memory.md §6.4/§6.5/§6.8）：`FREE → RESERVE → VICTIM_CAPTURE → READ_BEATS → INSTALL → WAKE → FREE`；同 Line 合并；原子 RESERVE（MSHR+Way Lock+WB）；Victim 逐 Row 捕获；逐 Beat Refill；Overlay byte 合并；Install 逐 Row 写 + 最后一次写发布 Tag/Valid/Dirty/LRU；WAKE 每周期交接 1 个 waiter。

```systemverilog
module mshr (
    input  logic                                      clk,
    input  logic                                      rst,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         lock_valid,        // 含 WAKE 期间
    output logic [ares_pkg::MSHR_ENTRIES-1:0][31:0]   lock_line_addr,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    lock_way,          // one-hot
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         busy,              // != FREE
    input  logic [31:0]                               match_line_addr,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         match_hit,
    input  logic                                      resv_valid,
    output logic                                      resv_ready,        // reserve_fire
    input  logic [31:0]                               resv_line_addr,
    input  logic [1:0]                                resv_way,          // one-hot Victim Way（同时锁定）
    input  logic                                      resv_victim_dirty,
    input  logic [1:0]                                resv_wb_idx,       // dirty 时已预留的 WB entry
    input  logic                                      resv_is_store,
    input  logic [1:0]                                resv_lq_idx,
    input  ares_pkg::tag_t                            resv_lq_tag,
    input  logic [7:0]                                resv_lq_epoch,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   resv_word_idx,
    input  logic [3:0]                                resv_store_mask,
    input  logic [31:0]                               resv_store_data,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   resv_store_widx,
    input  logic                                      merge_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         merge_sel,         // one-hot
    output logic                                      merge_ready,
    input  logic                                      merge_is_store,
    input  logic [1:0]                                merge_lq_idx,
    input  ares_pkg::tag_t                            merge_lq_tag,
    input  logic [7:0]                                merge_lq_epoch,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   merge_word_idx,
    input  logic [3:0]                                merge_store_mask,
    input  logic [31:0]                               merge_store_data,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   merge_store_widx,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         cap_req_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    cap_req_way,       // one-hot
    output logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_req_row,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         cap_gnt,           // 当拍 R 接收，响应下一周期
    input  logic                                      cap_rsp_valid,
    input  logic [ares_pkg::DCACHE_INDEX_BITS-1:0]    cap_rsp_set,
    input  logic [$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_rsp_row,
    input  logic [1:0]                                cap_rsp_way,       // one-hot
    input  logic [63:0]                               cap_rsp_data,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         wb_wr_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    wb_wr_idx,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] wb_wr_row,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][63:0]   wb_wr_data,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         wb_wr_last,        // 最后一个 Row -> WB READY
    input  logic                                      ovl_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         ovl_sel,           // one-hot
    output logic                                      ovl_ready,         // 接受 -> Early Takeover
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   ovl_widx,
    input  logic [3:0]                                ovl_mask,
    input  logic [31:0]                               ovl_data,
    output logic                                      refill_req_valid,
    input  logic                                      refill_req_ready,
    output logic [31:0]                               refill_line_addr,
    input  logic                                      refill_rsp_valid,
    output logic                                      refill_rsp_ready,
    input  logic [8*ares_pkg::LINE_BYTES-1:0]         refill_line_data,
    input  logic [ares_pkg::LINE_BEATS-1:0]           refill_beat_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         inst_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    inst_way,          // one-hot
    output logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] inst_set,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] inst_row,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][63:0]   inst_data,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][7:0]    inst_be,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         inst_last,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         inst_gnt,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         pub_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    pub_way,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_TAG_BITS-1:0] pub_tag,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         pub_dirty,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         wake_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    wake_lq_idx,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][31:0]   wake_word,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         wake_ready,        // 已处理（交付或丢弃）
    input  logic [ares_pkg::LQ_ENTRIES-1:0]           lq_wait_pending,
    input  ares_pkg::tag_t                            lq_wait_tag [ares_pkg::LQ_ENTRIES],
    input  logic [7:0]                                lq_wait_epoch [ares_pkg::LQ_ENTRIES]
);
```

行为要点：
1. **RESERVE**：`resv_ready = 存在 FREE entry`；接受沿锁定 Way、初始化首个 waiter / overlay，进入 `RESERVE`；Dirty victim 的 WB entry 由 L06 预留并给出 `resv_wb_idx`；Clean victim 直接进 `READ_BEATS`。
2. **VICTIM_CAPTURE**：逐 Row 拉高 `cap_req_*`；`cap_gnt` 推进 `capture_req_idx`；`cap_rsp_valid && cap_rsp_set/row/way` 匹配本 entry 时把 `cap_rsp_data` 交给 WB（`wb_wr_*`），最后一个 Row 时 `wb_wr_last=1`；**最后一个 Row 数据写入 WB 后**才转 `READ_BEATS`。
3. **READ_BEATS**：每次只发一笔 16B Read；`refill_rsp_valid && refill_beat_valid` 全 1 时锁存 `refill_line_data`、置 `refill_rsp_ready`，下一周期进 `INSTALL`。两个 MSHR 同拍只允许一个占用 refill 端口（内部仲裁）。
4. **INSTALL**：逐 Row 组 `inst_*`（`overlay_mask ? overlay_data : refill_data`，`inst_be=8'hFF`）；`inst_gnt && inst_last` 当拍发布 `pub_*`（L06 写元数据 + LRU），进入 `WAKE`。
5. **WAKE**：每 entry 每周期最多交接 1 个 waiter：`wake_valid/wake_lq_idx/wake_word`（合并 line 中该 waiter `word_idx` 的 32-bit 字）；`wake_ready` 当拍清该 waiter 并选下一个；交付合法性由 L06/lsu_top 判定，不匹配只清位（**绝不写 LQ**）。全部 waiter 清空且无遗留响应 → `FREE`，释放 Way Lock。
6. **Overlay**：`ovl_sel` 命中且 entry 在 `RESERVE/VICTIM_CAPTURE/READ_BEATS` 时 `ovl_ready=1`，同沿按 `ovl_widx*4 + lane` 合并 4 字节（新值覆盖旧值）；`INSTALL/WAKE` 期间 `ovl_ready=0`。
7. **陈旧 waiter**：用 `{lq_idx, lq_tag, lq_epoch}` 记录；`lq_wait_pending/tag/epoch` 不匹配即可清除（不影响 Refill）；Committed Store Overlay 与在途总线事务不因 kill 取消。
8. 断言（sim）：同 `(set,way)` 不被两个 entry 同时锁；同 Line 不重复分配；INSTALL 前 beat 全 1；`cap_rsp` 只被匹配 entry 消费；`busy=0 → wake_valid=0 && lock_valid=0`；FSM 合法转移。

TB（`tb_mshr`，独立 top + TB 侧 line 内存模型）：单/双 MSHR 全流程、Clean/Dirty victim、Overlay 早接管与安装合并、WAKE 逐个交接、陈旧 waiter（epoch 复用）不写 LQ、单 outstanding Read 仲裁、复位、**状态/转移覆盖 100%**。

## 11. L09 `wb_buffer.sv` — 2-entry Dirty Victim Writeback Buffer（M2b，**[已冻结]**）

职责（memory.md §6.6）：保存 `{state,line_addr,line_data,capture_row_valid,beat_idx}`；`FREE/CAPTURING/READY/DRAINING`；READY 后逐 beat 发 WB（`be=16'hFFFF`）；全部 beat `wr_fire` 后释放（不等待物理写完成，D-M2b-03）；提供 C3 可见性查询与空位掩码。

```systemverilog
module wb_buffer (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      alloc_valid,
    input  logic [1:0]                                alloc_idx,
    input  logic [31:0]                               alloc_line_addr,
    output logic [ares_pkg::WB_ENTRIES-1:0]           free_mask,         // 周期初空闲位（不借本拍释放）
    input  logic                                      cap_wr_valid,
    input  logic [1:0]                                cap_wr_idx,
    input  logic [$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_wr_row,
    input  logic [63:0]                               cap_wr_data,
    input  logic                                      cap_wr_last,       // 最后一个 Row -> READY
    output logic                                      wb_req_valid,
    input  logic                                      wb_req_ready,
    output logic [31:0]                               wb_line_addr,
    output logic [8*ares_pkg::LINE_BYTES-1:0]         wb_line_data,
    input  logic                                      wb_done,           // 最后一笔 wr_fire 脉冲 -> FREE
    input  logic [31:0]                               vis_query_line_addr,
    output logic                                      vis_query_block,   // 该 Line 仍由 WB 持有（未达可见性点）
    output logic [ares_pkg::WB_ENTRIES-1:0]           busy
);
```

行为要点：
1. `free_mask` 按**周期初**状态产生（不借用本拍 `wb_done` 释放的空位）。
2. `alloc_valid && alloc_idx` → `CAPTURING` 并锁存 `alloc_line_addr`；`cap_wr_valid/cap_wr_idx` 把 64-bit Row 写入 `line_data[64*cap_wr_row +: 64]`；`cap_wr_last` → `READY`（sim 断言该 entry 所有 Row 已写入）。
3. `READY` entry 按最低 index 公平仲裁出 `wb_req_*`；`wb_done` 当拍回 `FREE`（**不等待物理写完成**）。
4. `vis_query_block`：任一非 FREE entry 的 `line_addr == vis_query_line_addr`（组合）。
5. 复位：全部 entry 回 FREE；断言（sim）：`wb_req_valid` 只来自 READY entry；不重复 `wb_done`；`alloc_valid` 只写 FREE entry；FSM 合法转移。

TB（`tb_wb_buffer`）：分配/捕获/READY/逐 beat drain、两 entry 并行与仲裁、`free_mask` 不借用、可见性查询窗口、复位、**状态/转移覆盖 100%**。

## 12. L11 `mmio_bridge.sv` — 单 outstanding 设备通道（M2b，**[已冻结]**）

职责（memory.md §3.1；LSU_INTERFACES §7 M2a staging 逻辑的抽取）：LQ Load 与 SQ 最老 COMMITTED Store 共享一条单 outstanding 设备通道；LQ（更老）优先；Write Ack = 副作用完成（`sq_req_ack` 脉冲 → SQ `drain_takeover`）；`busy` 供 `lsu_mmio_order_idle`。

```systemverilog
module mmio_bridge (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    lq_req_valid,
    output logic                    lq_req_ready,      // 设备请求已被接受（单周期）
    input  logic [31:0]             lq_req_addr,       // word 对齐（LQ 产生）
    output logic                    lq_rsp_valid,      // 单周期，路由给 LQ
    input  logic [31:0]             lq_rsp_data,
    input  logic                    sq_req_valid,
    output logic                    sq_req_ready,      // 写请求已被接受 -> SQ drain_start
    output logic                    sq_req_ack,        // Write Ack -> SQ drain_takeover
    input  logic [31:0]             sq_req_addr,
    input  logic [31:0]             sq_req_data,
    input  logic [3:0]              sq_req_strb,
    output logic                    mmio_req_valid,
    input  logic                    mmio_req_ready,
    output logic                    mmio_write,
    output logic [31:0]             mmio_addr,
    output logic [31:0]             mmio_wdata,
    output logic [3:0]              mmio_wstrb,
    input  logic                    mmio_rsp_valid,
    output logic                    mmio_rsp_ready,
    input  logic [31:0]             mmio_rsp_data,
    output logic                    busy               // 有未完成事务（寄存）
);
```

行为要点：
1. 仲裁：`busy=0` 时 LQ 优先，否则 SQ；未被接受时客户端保持字段稳定。
2. `lq_req_ready` = 设备请求被接受且 owner=load；`sq_req_ready` 同理（= SQ `drain_start`）。
3. `mmio_addr`：Load = `{lq_req_addr[31:2],2'b00}`；Store = `{sq_req_addr[31:2],2'b00}`；load 时 `wstrb=4'h0`。
4. `busy` 在请求握手沿置位、在 `mmio_rsp_valid` 沿清除；`mmio_rsp_ready=1'b1`（与 M2a 一致）。
5. `lq_rsp_valid = mmio_rsp_valid && busy && owner==load`；`sq_req_ack = mmio_rsp_valid && busy && owner==store`（单周期脉冲）。
6. 断言（sim）：`mmio_rsp_valid |-> busy`；`mmio_req_valid |-> addr[1:0]==0`；`busy` 期间不接收新请求；`lq_rsp_valid`/`sq_req_ack` 互斥。

TB（`tb_mmio_bridge`）：load/store 顺序、单 outstanding、响应路由、Write Ack、`busy`、复位、**状态/转移覆盖 100%**。

## 13. L06 `dcache_top` / L01 `lsu_top` 的 M2b 收敛（**[已冻结：边界]**）

L06 实例化 L07，实现 memory.md §6.3 的 C2/C3 流水与全部仲裁：
- C2：接收 LQ `lookup_*` 或 SQ `drain_*`（公平仲裁，SQ 高水位加权）并寄存 Owner；两 Way 同步读；MSHR `cap_req_*` 与本拍 Lookup 按 Way 独立仲裁（Lookup 优先，Capture 连续让行 4 次后提升优先级）；同 Set/Row 同 Way 的 R/W Hazard 在 grant 前检查（含 Pending Store Write 与 Install）。
- C3：用**当前已登记**的 MSHR/Way Lock/WB 可见性/Pending Write 复检，唯一返回 `LOAD_HIT / STORE_HIT / MSHR_ACCEPT / RETRY`；`RETRY` 只重发内部 C2 读（Owner 保持，不重新握手 LQ/SQ）。
- Store Hit → 1-entry Pending Store Write；实际 W 写入生效沿产生 `store_takeover`。Store Miss → MSHR RESERVE / Overlay 早接管。
- Install：MSHR `inst_*` 与 Pending Store Write 按 Way 公平仲裁写端口；LRU 写按 `Lookup Hit > Store Hit Write > MSHR1 Install > MSHR0 Install` 每 Set 一次；`mshr_pub_*` → 元数据写 + LRU。

L01 `lsu_top` 在 M2b：实例化 `lsu_agu/lq/sq/lsu_completion/line_adapter/mshr/wb_buffer/mmio_bridge/dcache_top`；
- **LQ fill 仲裁**：`hit_fill` 优先于 MSHR `wake_*`（每周期最多 1 条）；WAKE 交付条件 = `lq_wait_pending[idx] && lq_wait_tag[idx]==tag && lq_wait_epoch[idx]==epoch && !kill_mask[tag]`，否则只清 MSHR waiter（D-M2b-04/05）；
- MSHR `refill_* → line_adapter.refill_*`；MSHR `wb_wr_* → wb_buffer.cap_wr_*`；`wb_buffer.wb_req_* → line_adapter.wb_*`；`wb_buffer.vis_query_* ↔ dcache_top`；
- MMIO：LQ `mmio_*` 与 SQ `drain_*`（`drain_is_mmio`）经 `mmio_bridge`；`lsu_mmio_order_idle = !mmio_busy && !sq_mmio_store_pending`（周期初登记状态）；
- `line_adapter` 单 beat 端口在 M2b 悬空（`beat_*_req_valid=0`）。

**LQ 附加只读端口（D-M2b-04，纯附加）**：
```systemverilog
    output logic [ares_pkg::LQ_ENTRIES-1:0]  lq_wait_pending,  // = e_lk_inflight[i]（等待 DCache/MSHR 交付）
    output ares_pkg::tag_t                   lq_wait_tag [ares_pkg::LQ_ENTRIES],
    output logic [7:0]                       lq_wait_epoch [ares_pkg::LQ_ENTRIES]  // 每次分配 +1
```
既有端口语义/时序不变；`tb_lq` 需覆盖 epoch 递增与 `lq_wait_pending` 一致。

## 14. M2b 验证要求与门禁

1. 每模块：`make lint-lsu` 0 warning；单元 TB `ALL TESTS PASSED`；`--assert` 0 误报；复位/边界/负向齐备（plan §8.2/§8.3）。
2. `tb_lsu` 扩为 DCache 通路：hit / miss+refill / Dirty Victim WB / Store Hit / Store Overlay 早接管 / Load-Store 冲突 RETRY / kill 期间旧 WAKE 丢弃 / 2-wide Store Commit + drain；结束时物理内存镜像 == 架构镜像。
3. `make -C tests/cpu-tests ARCH=riscv32-ares run` 36/36（FE 桩）。
4. 覆盖率：mshr / dcache C2-C3 / wb_buffer / mmio_bridge 单元 TB 打印状态+转移 100%。
5. PPA：**未验证**（SPEC-M10），见 D-M2b-09。
