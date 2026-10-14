# ARES C2 M2b 决策记录（DCache / MSHR / WB / MMIO Bridge）

> 状态：**已确认并执行**（架构侧裁决 2026-xx：misaligned 不支持；其余按 plan §9.4 M2a 遗留项建议执行）
> 上游：`docs/implementation_plan.md` §9.4 / §7.2 / §8.5、`docs/c0_decisions.md`、
> `docs/microarch/memory.md` §6–§8、`rtl/memory/LSU_INTERFACES.md`
> 落地：M2b 接口冻结见 `rtl/memory/LSU_INTERFACES.md` §9–§13。

## 1. 决策清单

### D-M2b-01 — SPEC-A1 / M17 残余：非对齐访存 **不支持** **[架构裁决]〔已确认〕**
- **结论**：v1 不做真正的非对齐访存（不拆分、不重放、不跨字合并）。硬件按「地址所在 4 字节字」处理：`byte_mask = lsu_size_mask(addr[1:0], size)`、数据经 `lsu_align_store_data` 落到字内字节道；nature-aligned 访问（含 LH/LW）不会跨 8 字节 Data RAM Row，也不会跨 16B beat。
- **不新增 `$fatal`/`decode_err`**：保持 `tests/cpu-tests/tests/unalign.c` 可运行。该用例是同地址先写后读、**对称通过**，**不作为**非对齐正确性的证据；验收文档不得声称支持非对齐。
- **断言**：保留既有自然对齐不变量（`lsu_top.a_drain_mask_legal` 等），并作为 M2b DCache byte-lane 生成的前提（mask 必须落在单一 64-bit Row 内）。不新增会让 `unalign` 变红的仿真报错。
- **影响**：L06 byte-enable 生成按 Row 内定位；无需 misaligned split 状态机；验证清单排除该用例的正确性主张。

### D-M2b-02 — M2a staging 评审确认 **[评审结论]〔已确认〕**
- M2a 的直连路径（`line_adapter` 单 beat 读/写 + `lsu_top` 内 MMIO 顺序逻辑）作为 C3 的基线**接受**；M2b 用真 DCache/MSHR/WB 替换数据来源，并把 MMIO 顺序逻辑抽为 `mmio_bridge.sv`（L11）。
- **LQ `lookup_*`/`fill_*` 与 SQ `drain_*` 语义保持不变**（见 D-M2b-04 的**附加**只读端口例外）；`lsu_top` 后端可见契约（`can_accept`/credit、恰好一次 Completion、Store Commit 握手、kill 优先、`lsu_mmio_order_idle`）不变。

### D-M2b-03 — SPEC-M20 / M21 / M13：core 阶段的 Fabric 接缝 **[已确认〕**
- core 阶段继续由 **TB 内存模型**充当 Fabric + Memory Controller（`sim/rtl/tb_mem_beat_if.sv` 语义：写被接受后对后续冲突读可见；整个共享通道最多 1 个未完成 Read）。
- **LSU 侧义务**止于：`mem_wr_valid && mem_wr_ready`（写接收，逐 beat）+ 单 outstanding Read + `line_adapter` 的地址/beat 序。WB Entry 在最后一笔 beat `wr_fire` 后释放（`wb_done`），不等待物理写完成。
- **接缝**：`wb_done`/写可见性与 Read owner 的正式语义仍待 SPEC-M20/M21 关闭（SoC 阶段）；在那之前 core 不新增写完成信号，也不假设下层 `ready` 之外的语义。

### D-M2b-04 — MSHR waiter 隔离：LQ 令牌端口（**附加**接口） **[C0 扩展，memory.md §6.4/§8.3]**
- 问题：MSHR 等待者按 LQ index 记录，长延迟 miss 期间该 slot 可能被 kill 后复用 → 旧 WAKE 会写进复用后的新 Entry（memory.md §8.3 禁止）。
- 方案：LQ **新增只读输出** `lq_wait_pending[LQ_ENTRIES]`（= `lk_inflight` 且存活，等待 DCache/MSHR 交付）与 `lq_wait_tag[LQ_ENTRIES]`（该 Entry 的 tag）。语义、既有端口与时序**不变**（纯附加观测/校验）。
- LQ 另外新增 `lq_wait_epoch[LQ_ENTRIES][7:0]`（每次分配 +1）。
- MSHR 记录每个 waiter 的 `{idx, tag, epoch}`；WAKE 交付条件 = `lq_wait_pending[idx] && lq_wait_tag[idx]==tag && lq_wait_epoch[idx]==epoch && !kill_mask[tag]`；不满足则**丢弃该 waiter**（仅清位、不写 LQ），保证绝不写入复用后的 slot（epoch 使“同 idx + 同 tag 复用”不再误匹配；256 次同 slot 复用内不会回绕，属标识复用的标准论证）。

### D-M2b-05 — 两个 MSHR 的 WAKE 并行度 **[已确认〕**
- memory.md §6.4 允许「两个 MSHR 同周期向不同 LQ Entry 交接」。为保持 LQ 冻结接口（plan §9.4 承诺）与单 Completion 端口，M2b 采用：**两个 MSHR 仲裁进单一 `fill` 端口，每周期最多 1 次交接**；败者保持 WAKE 状态与结果直到下周期。
- 不损失外部契约（Completion ≤1/cycle）；若 profiling 显示 WAKE 成为瓶颈，再评估 LQ 第二 fill 端口（记入 §9 扩展，不在 M2b）。

### D-M2b-06 — L12 2-entry FIFO 退化 **[已确认，不改规格]**
- 保持冻结公式 `push_ready = (count < DEPTH) || pop_fire`；无输出反压契约下占用恒 ≤1，第二条目是余量。M2b 不引入可停顿 push；如将来需要，再补 memory.md §7 出队条件。

### D-M2b-07 — `dep_ready` 与 `older_store_mask` 不变量 **[已确认，不改 RTL]**
- 保持冻结公式（`e_older == 0` 依赖 `sq_addr_valid`）。LQ 维持 `older_store_mask = sq_occupied & ~sq_takeover`、仅真正 takeover 清位；M2b 在 `lq` 内**新增显式断言**校验该不变量（memory.md §4.2/§8.2）。

### D-M2b-08 — 覆盖率门禁 **[已确认〕**
- M2b 新增状态机（mshr / dcache C2-C3 / wb_buffer / mmio_bridge）在**单元 TB 内用 SV 覆盖率计数器**（FREE-10）统计状态与转移，结束时 `$fatal` 于未覆盖项；`--coverage` 工具级收集仍留 C3/C4。
- M2b 出口：上述 TB 打印 `<module> coverage: states X/Y, transitions M/N` 且 100%。

### D-M2b-09 — PPA（SPEC-M10） **[未变〕**
- 仓库内无器件/XDC/Vivado 工程 → M2b **不做** synth 探针；C1/C2 的 synth-only 时序探针与 C4 仍标 `未验证`。`LINE_BYTES=16/32/64` 的仿真侧对比（IPC/Miss/下层 read busy）可在 M2b 后补，Fmax/面积不做。

### D-M2b-10 — 文件组织（FREE-02）
- 新增 `rtl/memory/dcache_arrays.sv`(L07)、`dcache_top.sv`(L06)、`mshr.sv`(L08)、`wb_buffer.sv`(L09)、`mmio_bridge.sv`(L11)；`lsu_top.sv`(L01) 收敛；`line_adapter.sv`(L10) 单 beat 端口保留但 M2b 不再使用（不动接口）。

## 1b. 集成期实现取舍（已落地，均为契约内的 FREE-04 选择）

1. **W 口 grant 优先于冲突读**（`dcache_top`）：同 Way+同 Set+同 Row 的读在写被 grant 的当拍被抑制并重试；写侧有界（Pending Write 只发一次、Install ≤ ROWS_PER_LINE 行），故读不会被饿死。反向优先（读优先）会与"被该 MSHR 换出的 Line 上正在重试的 Lookup"构成活锁（集成期实测）。
2. **命中"被锁定 Way / WB 未可见 Line"的请求一律 RETRY，不得换 Way 重新分配**：否则同一条 Line 会同时存在于两个 Way，且新副本可能从下层读回**尚未写回的旧数据**（memory.md §6.3/§6.6）。
3. **未完成读的重发用显式状态（`own_rd_pending`）**，不依赖"响应当拍存在"；否则一次被抑制的重发会导致 Owner 永久占位（credit 泄漏）。

## 2. 需要在评审时确认的差异
1. D-M2b-04 的 LQ 附加端口（`lq_wait_pending`/`lq_wait_tag`）是 M2a 冻结接口之外的**新增只读观测**；虽然不改语义与时序，仍属接口集变化，需 FE/架构侧知悉（LQ 为 core 内部模块，无跨子系统影响）。
2. D-M2b-05 的 WAKE 串行化使 memory.md §6.4「两个 MSHR 可同时写不同 LQ Entry」变为「每周期 1 次」；属内部并发度取舍，不影响外部契约。
3. D-M2b-01 的 `unalign` 用例保留在回归中但**不计入**非对齐正确性；若评审要求"显式排除"，只需在验收文档标注，不需改 RTL。
