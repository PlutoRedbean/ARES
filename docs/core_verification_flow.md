# Core（Backend + LSU）独立仿真与功能验证方案

> **适用**：只实现 backend + LSU（memory），前端尚未接入 / 尚未迁移到契约 v1.0
> **环境**：Verilator 5 + 现有 `sim/` 流程（DPI-C 内存模型、`tests/cpu-tests` 自检镜像）
> **关联**：`docs/implementation_plan.md` §8（验证策略）、§9（C0–C5）、`docs/fe_contract_migration.md`

---

## 0. 结论（先看这一段）

**推荐做法：周期级协议用 SystemVerilog 行为级「FE 桩」，指令/内存数据继续走现有 C++ DPI 模型。**

也就是把「前端」拆成两层：

| 层 | 放在哪 | 原因 |
|---|---|---|
| **周期级握手**（`iq_valid/iq_inst/iq_accept_count`、Redirect、credit） | **SV（`fe_stub.sv`，仅 TB 使用）** | 与 RTL 同抽象、直接复用 `ares_pkg` 类型、Verilator 会把它编译成 C++（与 C 模型同速）、可写 SVA 自查契约 |
| **指令/内存数据**（按 PC 取指令、DRAM/MMIO 读写） | **C++（复用 `sim/csrc` 的 `irom_read/perip_read/perip_write`）** | 现成、已有 16 MiB 镜像与 MMIO（console/RTC）、与 `tests/cpu-tests` 完全兼容、**零改动** |

**不建议**「每个时钟周期用 DPI-C 调一个 C 前端模型」（你提的方案 A）：

1. `iq_entry_t` 含 `pred_meta` 结构体，跨 DPI 需手工扁平化为位向量，字段一改就要同步两边，极易出错；
2. 每周期 1–2 次 DPI + 宽结构体，Verilator 无法内联，比 SV 行为代码慢，也难以用 `--assert`；
3. 两套语言调试（波形里看不到 C 侧状态）；
4. 契约要求的细节（`accept_count=0` 时队首稳定、`iq_valid` 只能是 00/01/11）用 SV 写几行就能断言，用 C 要另搭一套。

**混合方案**保留 C 的优势：需要参考模型/ISS/trace 驱动时，只加**一条窄 DPI**（`int ifetch(int pc)` 或 `int next_pc(int pc)`），周期协议仍在 SV。

**最大收益**：后端与访存的 ISA 正确性可以**独立签核**，不依赖前端维护者排期；后续把 `fe_stub` 换成真实 `frontend.sv`（契约不变，见 §7）。

---

## 1. 方案对比

| 方案 | 实现成本 | 速度 | 类型安全 | 复用现有资产 | 主要风险 |
|---|---|---|---|---|---|
| **A. 纯 C 前端 + 每周期 DPI** | 中 | 慢 | 差（手工扁平化结构体） | 部分 | 结构体同步、调试困难 |
| **B. SV 行为 FE 桩 + C++ 数据 DPI（推荐）** | 低 | 快 | 好 | **完全**（cpu-tests/sim 流程不动） | 桩自身有 bug → 用契约断言兜住 |
| C. 直接用现有 `frontend.sv` + 适配器 | 中 | 快 | 好 | 完全 | 旧接口 + 已知缺陷（D1/D4/D5…）污染调试，且无法验证 `ghr_before` 语义 |
| D. 只在软件里模拟后端（C++ ISS） | 低 | 极快 | — | 无 | **不是 RTL 验证**，发现不了 RTL 缺陷 |

> C 作为「提前联调」选项保留（见 §7）；D 只能作为 L4 的差分参考模型。

---

## 2. 推荐架构（三层 TB + 可替换前端）

```
tests/cpu-tests/build/*.bin
        │  (镜像加载 / 退休 / 停机)
        ▼
sim/csrc (memory.cpp / dut.cpp)  ── DPI-C ──┐
   irom_read / perip_read / perip_write     │
   retire_event_enqueue / ebreak            │
                                            ▼
                             sim/rtl/tb_ares_core.sv   ← TOPNAME
                             ├── fe_stub.sv（SV，契约合规取指桩）
                             │      └── irom_read(pc)   （现有 DPI）
                             ├── ares_core_top（BE + LSU）
                             │      ├── 128-bit D 总线 → tb_mem_beat_if → perip_read/write
                             │      └── MMIO 端口      → tb_mmio_if     → perip_read/write
                             └── 观测：retire_event_enqueue / ebreak / interrupt_redirect
```

三个可替换的「前端」：

| 版本 | 文件 | 用途 | 预测 |
|---|---|---|---|
| **F0** | `rtl/backend/test/fe_stub.sv` | 默认：ISA 回归 + 随机压力 | always-not-taken（靠 BE Redirect 纠正） |
| **F1** | `fe_stub_trace.sv`（可选） | 定向微架构测试（指定 PC 序列 / 注入 redirect） | 由 trace/脚本给出 |
| **F2** | 真实 `rtl/frontend/frontend.sv` | 前端迁移完成后替换 F0 | 真实 BPU |

单元层（更早、更快、更便宜）：

| TB | DUT | 对方（桩） | 目的 |
|---|---|---|---|
| `rtl/backend/test/tb_backend.sv` | CIQ/Dispatch/Issue/Commit/… | FE 桩（TB 内直接产生 `iq_inst`）+ 理想 LSU 桩 | 流水/依赖/提交/异常语义 |
| `rtl/memory/test/tb_lsu.sv` | `lsu_top` 全链 | 后端桩（脚本或随机发 `fu_req_t`/commit/kill） | 队列/MSHR/forwarding/MMIO/Completion |

---

## 3. 关键接口与实现骨架

### 3.1 `fe_stub.sv`（契约合规取指桩）

必须逐条满足的契约（否则桩自己就是错误来源）：

1. `iq_valid` 只能是 `00/01/11`（低位最老，**不能有洞**）；
2. `iq_accept_count` 是唯一消费依据（不得再引入 ready），按连续前缀弹出；
3. `accept_count=0` 时保持队首 `iq_inst[0]` 及其 metadata 稳定；
4. `backend_redirect_valid` 当拍 `iq_valid=0`（BE 保证 `accept_count=0`）；
5. `pred_npc` 必须是「生效预测下一 PC」（桩恒 not-taken ⇒ `pc+4`）；`pred_meta` 原样；`need_redirect=0`；
6. `bpu_update_credit` 来自寄存状态且不组合依赖 BE（桩恒为 `2'd2`，忽略训练事件）。

骨架（要点版）：

```systemverilog
module fe_stub #(
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic clk, rst,
    // 契约 §2
    output logic [1:0]            iq_valid,
    output ares_pkg::iq_entry_t   iq_inst [2],
    input  logic [1:0]            iq_accept_count,
    // 契约 §3
    input  logic                  backend_redirect_valid,
    input  logic [31:0]           backend_redirect_pc,
    input  ares_pkg::fe_redirect_kind_t backend_redirect_kind,
    input  logic [11:0]           backend_redirect_ghr_before,
    input  logic                  backend_redirect_actual_taken,
    // 契约 §4（桩不训练）
    output logic [1:0]            bpu_update_credit,
    input  logic [1:0]            bpu_update_valid,
    input  ares_pkg::bpu_update_t bpu_update [2]
);
    import ares_pkg::*;
    import "DPI-C" function int irom_read(input int addr);   // 复用现有 DPI-C

    logic [31:0] pc_r;                 // 下一待取 PC
    iq_entry_t   slot_q [2];           // 队首两条（accept=0 时保持稳定）
    logic [1:0]  cnt_q;                // 0/1/2

    // 取指：1 拍寄存器，避免组合 DPI 调用
    logic [31:0] inst_q;
    always_ff @(posedge clk) inst_q <= 32'(irom_read(int'(pc_r)));

    // 极简 predecode：只用于告诉 BE「实际 CFI 类型」（契约要求 Decode 与 inst 核对）
    function automatic cfi_type_t classify(input logic [31:0] i);
        case (i[6:0])
            7'h6F:   classify = CFI_DIRECT_JUMP;   // JAL（CALL 可再按 rd 细化）
            7'h67:   classify = CFI_INDIRECT_JUMP; // JALR
            7'h63:   classify = CFI_COND_BRANCH;   // BRANCH
            default: classify = CFI_NONE;
        endcase
    endfunction

    wire [1:0] accept = backend_redirect_valid ? 2'd0 : iq_accept_count;
    // 契约：仅当 accept>0 时按连续前缀弹出；弹出后由新取指补齐（固定先填 slot0 再 slot1）
    // …（cnt_q / slot_q 的移位与填充逻辑）
    assign iq_valid = {cnt_q[1], cnt_q[0]};
    assign bpu_update_credit = 2'd2;
endmodule
```

实现提示：

- **填充顺序**：先把 `slot0` 填满再填 `slot1`，天然满足「无洞」；
- **PC 推进**：入队指令的 PC 为 `pc_r`（顺序取指）；注意「取指拍」与「入队拍」的对应（建议 `pc_r` 与 `inst_q` 同步推进）；
- **Redirect**：当拍清 `cnt_q`、`pc_r <= backend_redirect_pc`，不要依赖 BE 的 accept；
- **JAL/JALR/BRANCH**：桩不做目标预测，`actual_npc != pred_npc` 时由 BRU 发 Recovery Redirect，桩据此重取——这条路径会被**高频触发**，正好是 Redirect 逻辑的天然压力测试；
- 桩**不产生** `need_redirect=1`（桩从不停止取指，不存在「等 BE 唤醒」的死锁）。

### 3.2 128-bit D 总线 → `perip_read/perip_write` 适配（`tb_mem_beat_if.sv`）

LSU 侧遵守 memory.md §6.7：16B/beat、16B 对齐、单 outstanding Read、无 burst/ID。TB 侧把它映射到 `sim/csrc` 的 32-bit perip 模型：

```systemverilog
// 读：mem_rd_valid/ready 握手 → 4 次 perip_read 拼 128-bit → mem_rsp_valid/ready
// 写：mem_wr_valid/ready 握手 → 按 mem_wr_be 拆 4 个 word → perip_write(addr, data, strb)
//     （be=16'hFFFF 时等价于 4 次整字写）
```

**两个必须遵守的模型语义**（`sim/README.md`「RTL contract」，写错会静默错数据）：

1. 写地址与 lane：模型内部做 `paddr &= ~3`，第 i 个 lane 对应 `(addr & ~3) + i` —— 即 **strb 要按 word 归一化**，不能把 lane 偏移加到未对齐地址上；
2. 写**在握手当拍生效**、读返回**对齐字**（字节选择由 LSU 自己做）；一次 beat 的 4 个 word 必须按顺序写。

建议 TB 侧加 1–2 拍读延迟与可选反压开关（`TB_MEM_LATENCY`、`TB_MEM_STALL`），用来压 MSHR 合并、Completion FIFO 与后压路径——这些是 RTL 里最易出 bug 的地方。

### 3.3 MMIO 适配（`tb_mmio_if.sv`）

MMIO 走 memory.md §3.1 的 `mmio_req_valid/ready + mmio_rsp_valid/ready` 单 outstanding 通道：TB 接到 `perip_read/perip_write`（`0xA000_0000` 窗口，console `+0x3F8`、RTC `+0x48/0x4C`）。
**Write Response 必须表示副作用完成**：TB 在 `perip_write` 返回后一拍给 `mmio_rsp_valid`（不要用 `req_ready` 当完成）。

### 3.4 退休/停机观测（复用 `sim/csrc`，零改动）

按 backend.md §16.1，EBREAK 只在**非推测的 Commit Head 边界**识别，且**不进综合异常协议**：

```systemverilog
`ifdef CONFIG_SIMULATION
  import "DPI-C" function void retire_event_enqueue(int valid, int pc, int pc_next,
                                                    int rd_wen, int rd_addr, int rd_data, int environment);
  import "DPI-C" function void ebreak();
  import "DPI-C" function void interrupt_redirect(int target);
`endif
```

- `be_commit` 每个正常提交 lane 调 `retire_event_enqueue(1, pc, pc_next, rd_wen, rd, data, 0)`；
- commit 指令是 EBREAK 时调 `ebreak()`（harness 取 `a0` 作为 halt code → HIT GOOD/BAD TRAP）；
- `interrupt_redirect(pc)` 在 Trap/MRET Redirect 时调用（可选，便于调试）。

> 建议把这些调用集中放在 `ares_core_top` 或一个 `core_sim_hooks.sv` 里，用 `ifdef CONFIG_SIMULATION` 包住，保证综合路径干净。

### 3.5 顶层命名与复位

Verilator harness 固定使用顶层端口名 `clock`/`reset`（`sim/csrc/main.cpp` 直接操作 `top->reset` 与半周期函数）：

```systemverilog
module tb_ares_core (input clock, input reset);
    // fe_stub + ares_core_top + 总线适配 + DPI 观测
endmodule
```

---

## 4. 构建与运行

### 4.1 `sim/Makefile` 需要的最小改动

1. 现有开头有一个硬检查会挡住 ARES RTL（它假定 RTL_ROOT 是 npc 树）：

```make
ifeq ($(wildcard $(RTL_ROOT)/include/common_para.vh),)
  $(error RTL_ROOT ... does not look like the npc vsrc tree ...)
endif
```

加一个开关（示意）：

```make
ifneq ($(ARES_RTL),1)
  ifeq ($(wildcard $(RTL_ROOT)/include/common_para.vh),)
    $(error ...)
  endif
else
  VSRCS := $(SIM_HOME)/rtl/tb_ares_core.sv \
           $(wildcard $(RTL_ROOT)/common/*.sv) \
           $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/backend/**/*.sv) \
           $(wildcard $(RTL_ROOT)/memory/*.sv)   $(wildcard $(RTL_ROOT)/memory/**/*.sv)
  V_DEF_MACRO := -D__VERILATOR__ -DCONFIG_SIMULATION
endif
```

注意：**package 文件（`ares_pkg.sv`）必须排在模块之前**，Verilator 才能解析 `import`。

2. 顶层名与 RTL 根：

```bash
make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl TOPNAME=tb_ares_core            # 构建
make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl TOPNAME=tb_ares_core \
     run PROGRAM=tests/cpu-tests/build/add-riscv32-ares.bin                # 跑单个镜像
make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl TOPNAME=tb_ares_core \
     wave PROGRAM=tests/cpu-tests/build/add-riscv32-ares.bin               # FST 波形
make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl TOPNAME=tb_ares_core lint       # 仅 lint
```

3. ISA 回归（`tests/cpu-tests/Makefile` 经 `platform/ares.mk` 调 `make -C sim run`）：把 `ARES_RTL=1 RTL_ROOT=... TOPNAME=...` 加进 `SIM_ARGS` 或 `ares.mk` 一行即可复用现有 35 个用例与退出码（0/1/2/3）。

### 4.2 单元 TB（不经 harness，最快）

```bash
verilator --binary --timing -sv --assert -Wno-fatal +incdir+rtl/common \
    --top-module tb_backend rtl/common/ares_pkg.sv \
    rtl/backend/*.sv rtl/backend/test/tb_backend.sv \
    -o /tmp/tb_backend && /tmp/tb_backend
```

沿用 `rtl/frontend/test/tb_frontend.sv` 的自检风格：自比对 + `$error/$fatal` + 明确打印 `ALL TESTS PASSED`。

---

## 5. 测试层次与通过判据

| 层 | DUT | 激励 | 通过判据 | 依赖 |
|---|---|---|---|---|
| **L0** | 全部模块 | `verilator --lint-only -Wall --assert` | 0 warning（或逐条豁免理由）；断言可编译 | — |
| **L1a** | 后端 | `tb_backend`：定向 + 随机合法指令流（LSU 理想桩） | 契约 §5.5–§5.9 断言全绿；退休序列与参考一致；无死锁 | `ares_pkg` |
| **L1b** | LSU | `tb_lsu`：脚本/随机 Load/Store + kill/commit（后端桩） | 每 operation **恰好一次** Completion；§5.11–§5.14 断言；内存镜像对比 | `ares_pkg` |
| **L2** | core（F0 桩 + BE + LSU） | 短序列 + 定向并发（Redirect/CSR/MMIO/Trap） | 契约 §6 定向集 + backend §17.3 + memory §6.8 | L1 |
| **L3** | core（F0 桩） | `tests/cpu-tests` 35 个自检镜像 | 全部 `HIT GOOD TRAP`（退出码 0）；无超时 | L2 |
| **L4** | core | 随机差分（可选 mini-ISS/NEMU retire difftest） | retire 流逐条一致 | L3 |

**注意**：L3 通过 ≠ 时序达标，≠ 真实前端集成通过，≠ SoC 集成通过（后者见 `implementation_plan.md` §8.5 DoD）。

定向用例直接复用 `docs/implementation_plan.md` §8.3（契约 §6 / backend §17.3 / memory §6.8）。**额外**针对桩补三条：

1. 桩的「无洞」不变量：`iq_valid != 2'b10`，且 `accept_count=0` 连续 100 拍后 `iq_inst[0]` 不变；
2. Redirect 高频路径：桩为 not-taken 时，Redirect 次数应等于「实际跳转的 CFI 数」（可用计数断言交叉检查）；
3. Redirect 与 accept 同拍：桩侧 `backend_redirect_valid |-> iq_valid==0`；BE 侧 `|-> accept_count==0`。

---

## 6. 进阶（可选，按性价比排序）

1. **retire 差分（最推荐）**：C++ 侧已由退休事件重建 `sim.gpr/sim.pc`。写一个 300–500 行的 RV32IM mini-ISS（或直接接 NEMU/Spike），逐条比对 PC/写回值——一旦不一致立刻定位到「第 N 条退休指令」，比 35 个 GOOD TRAP 高效得多。
2. **覆盖率**：Verilator `--coverage`（line/toggle/user）+ 关键状态机加 `cover property`，把 CIQ/LSU 状态机覆盖率纳入 C1/C2 出口。
3. **总线随机反压**：给 `tb_mem_beat_if` 加随机 ready 与随机延迟，压 MSHR/WB/Completion FIFO 的后压路径。
4. **波形**：`make wave` 已支持 FST；对握手、Redirect、`kill_mask` 分组信号，`--trace-structs` 对结构体友好。
5. **性能基线**：桩为 not-taken，IPC 会明显低于真实 BPU，可作为「最坏预测」基线，后续与真实 FE 对比。

---

## 7. 可选：提前接真实前端（`fe_legacy_adapter.sv`）

若想在前端迁移完成前就用真实 `frontend.sv` 做性能冒烟，可加一个 **old→new 适配器**（仅 TB 使用）：

| 适配 | 做法 |
|---|---|
| 消费握手 | 令 `iq_rready = |iq_accept_count`、`iq_raccept_cnt = iq_accept_count` |
| Redirect | `backend_redirect_valid/pc` 直通；`kind` 恒 `REDIRECT_BRANCH` |
| 训练 | 把 BE 的 ≤2 lane 事件缓冲成 1 条/周期送给 `bpu_update_en`，`bpu_update_credit` 恒 `2'd1` |
| 字段补齐 | `pred_npc = pred_meta.pred_taken ? pred_meta.pred_target : pc+4`；`need_redirect = 0`；`ghr_before = pred_meta.chooser_meta.pred_ghr` |

**限制（因此不用于签核）**：① credit 恒 1（与契约 `min(2, DEPTH-occ)` 不同，需架构同意或仅作临时态）；② 旧 FE 的已知缺陷（D1/D4/D5/D7/D8/D11…）会混进调试；③ 无法验证逐 CFI `ghr_before` 与 2-lane 提交语义。定位：**只用于性能/集成预演**。

---

## 8. 新增文件与工作量估算

| 文件 | 行数（估） | 人日 | 备注 |
|---|---|---|---|
| `rtl/backend/test/fe_stub.sv` | 150–250 | 0.5–1 | F0，契约合规；含极简 predecode |
| `sim/rtl/tb_ares_core.sv` | 200–300 | 1–1.5 | 顶层 + DPI 观测 + 复位 |
| `sim/rtl/tb_mem_beat_if.sv` | 100–150 | 0.5–1 | 128-bit ↔ perip 语义适配 |
| `sim/rtl/tb_mmio_if.sv` | 60–100 | 0.5 | MMIO 单 outstanding 适配 |
| `rtl/backend/test/tb_backend.sv`（+ 激励） | 300–500 | 2–3 | 理想 LSU 桩 + 随机合法指令流 |
| `rtl/memory/test/tb_lsu.sv`（+ 激励） | 300–500 | 2–3 | 后端桩 + 内存镜像对比 |
| `sim/Makefile`（+ 可选 `sim/csrc/dut.cpp` 数行） | — | 0.5 | 加 `ARES_RTL` 分支与 `VSRCS` |
| 可选：mini-ISS retire 差分 | 300–500（C++） | 2–3 | 回报最高，建议做 |
| **合计** | | **7–13**（含差分 9–16） | 不含后端/LSU 本体 |

---

## 9. 与实施计划的衔接

| 计划节点 | 本方案对应交付 | 出口条件更新 |
|---|---|---|
| C0 | `ares_pkg` + lint 脚本 + `ARES_RTL` 构建分支 | `make lint` 通过；`fe_stub` 可编译 |
| C1 | `tb_backend` + `fe_stub` | 契约 §5.5–§5.9 断言绿；随机 10k 周期无协议错误 |
| C2 | `tb_lsu` + 内存镜像对比 | 每 operation 恰好一次 Completion；§5.11–§5.14 断言绿 |
| C3 | `tb_ares_core` + ISA 回归 | 35 用例 `HIT GOOD TRAP`（**不需要前端**） |
| C4 | 用真实 `frontend.sv` 替换 `fe_stub`（或先经 §7 适配器） | 契约 §6 联调断言 + ISA 回归在真实 FE 上通过 |

> 一句话：**先用桩把后端和访存的 ISA 正确性钉死，再谈前端和时序。**
