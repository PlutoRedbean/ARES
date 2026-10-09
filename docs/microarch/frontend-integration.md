# 前端 RTL 接入说明（IFU / BPU / FTQ / IQ）

> **适用范围**：`rtl/frontend/` 下的前端 RTL，供后端（ARES core）接入。
> 本文只描述**前后端之间的接口契约**，微架构设计见同目录 [`frontend.md`](./frontend.md)。

## 1. 交付物

```
rtl/frontend/
├── fe_pkg.sv                 # 前端 package（由 NPC 的 npc_pkg 改名而来）
├── frontend.sv               # ★ 顶层 wrapper（后端只接这一个模块）
├── iq.sv                     # Instruction Queue
├── ftq.sv                    # Fetch Target Queue
├── ifu/
│   ├── ifu.sv                # Instruction Fetch Unit（含 PredecodeCheck）
│   └── icache.sv             # 4-way / 64-set / 32B I-Cache
├── bpu/
│   ├── bpu.sv                # BPU wrapper（Composer 简化版）
│   ├── gen_pc.sv
│   ├── direction/            # bimodal / gshare / tournament / loop_predictor
│   └── target/               # ubtb / ras
├── interface/
│   ├── axi_if.sv             # icache 使用的 AXI4-Lite 接口
│
└── test/
    └── tb_frontend.sv        # 自检 testbench（见 §6）
```

数据流：`BPU -> FTQ -> IFU -> ICache` 与 `IFU -> IQ --(读口)--> 后端`。

## 2. `frontend.sv` 顶层端口

```systemverilog
module frontend #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned RESET_VEC  = 32'h8000_0000
) (
    input logic clk,
    input logic rst,

    // ---------- IQ 读口（前端 -> 后端） ----------
    output logic [fe_pkg::DECODE_WIDTH-1:0] iq_rvalid,
    output fe_pkg::iq_entry_t               iq_rbits [fe_pkg::DECODE_WIDTH],
    input  logic                            iq_rready,
    input  logic [$clog2(fe_pkg::DECODE_WIDTH+1)-1:0] iq_raccept_cnt,

    // ---------- 后端 -> 前端 ----------
    input logic                    backend_redirect_valid,
    input logic [ADDR_WIDTH-1:0]   backend_redirect_pc,
    input logic                    bpu_update_en,
    input fe_pkg::update_meta_t    bpu_update_meta,

    // ---------- I-Cache AXI4-Lite master ----------
    axi_if.master ifu_axi_bus,

    // ---------- 调试 ----------
    output logic [ADDR_WIDTH-1:0] fetch_pc_out
);
```

IQ 写口（`IFU -> IQ`）与 FTQ 读口（`FTQ -> IFU`）均为 wrapper 内部连线，后端无需关心。

## 3. IQ 读口的使用方法

IQ 对外表现为「HEAD(2-entry) + BODY(循环队列)」结构，每拍把队首若干条指令暴露给后端。

| 信号 | 方向 | 含义 |
| --- | --- | --- |
| `iq_rvalid[DECODE_WIDTH-1:0]` | out | HEAD 中**有效指令槽**，低位连续前缀：只会是 `00 / 01 / 11`，**不会出现 `10`** |
| `iq_rbits[DECODE_WIDTH-1:0]` | out | 对应槽的完整条目（组合输出，当拍稳定） |
| `iq_rready` | in | 后端本拍是否消费 |
| `iq_raccept_cnt` | in | 后端本拍**实际消费的指令数** |

`iq_entry_t` 字段（`fe_pkg.sv`）：

```systemverilog
typedef struct packed {
    logic [ADDR_WIDTH-1:0] pc;        // 指令 PC，后端必须用它
    pred_meta_t            pred_meta; // 预测时捕获的元数据，训练时原样回传
    logic [31:0]           inst;      // 指令编码
    logic                  valid;     // 指令是否有效
    cfi_type_t             cfi_type;  // CFI 类型
    logic                  is_cfi;    // 是否控制流指令
} iq_entry_t;
```

推荐握手流程（与 `backend.md` §5.1 的 IB 接口一致）：

```
available_count = $countones(iq_rvalid);   // 0/1/2
后端组合读取 iq_rbits -> 译码/依赖绑定
accept_count    = min(可用, CIQ 空位, ...); // 0/1/2
assign iq_raccept_cnt = accept_count;
assign iq_rready      = |accept_count;      // 或恒 1，靠 accept_count=0 表示不消费
```

**必须遵守的契约**（否则 IQ 会错位/丢数据，仿真中仅 `$error` 提示）：

1. `iq_raccept_cnt ∈ {0, 1, 2}`（宽度 2 bit，但 `DECODE_WIDTH=2`，**不能驱动 3**）。
2. `iq_raccept_cnt <= $countones(iq_rvalid)`，且仅在 `iq_rready` 有效时被采样。
3. **只能消费连续前缀**：不消费 / 只消费 slot0 / 同时消费 slot0+slot1，**不能只消费 slot1**。
4. 判定有效请使用 `iq_rvalid[i]`，不要用 `iq_rbits[i].valid`（二者一致，但接口契约以 `iq_rvalid` 为准）。
5. 后端还需额外用 CIQ 剩余容量 `free_count` 夹一下 `accept_count`（见 `backend.md` §5.1）。
6. `iq_raccept_cnt` 允许与 `iq_rvalid`/`iq_rbits` 同拍组合产生；`iq_rbits` 在时钟沿前保持稳定，不会在消费拍改变。

时序：`iq_rbits` 由 IQ 队首寄存器组合译出，后端「读条目 → 决定 `accept_count` → 同拍回握手」是设计预期路径。

## 4. 后端需要提供给前端的信号

### 4.1 Redirect（分支/跳转解析重定向）

| 信号 | 含义 |
| --- | --- |
| `backend_redirect_valid` | 单拍脉冲 |
| `backend_redirect_pc` | **正确目标 PC**（不是分支 PC） |

作用：同一个 flush 会清空 **BPU / FTQ / IFU 流水以及 IQ**，并从 `backend_redirect_pc` 重新取指。

**约束**：

- 必须按顺序（program order）产生，且同一时刻只能有一个 redirect；
- redirect 只能由**最老未解析的分支/跳转**发起；若存在更老的未解析分支，不能先重定向年轻分支；
- 未来接入 exception / CSR / serializing 时，也应通过同一路 flush 杀全前端（IQ 同样需要被清空）。

### 4.2 BPU 训练

| 信号 | 含义 |
| --- | --- |
| `bpu_update_en` | 一条 CFI 解析有效 |
| `bpu_update_meta` | `update_meta_t`（见下） |

```systemverilog
typedef struct packed {
    logic [ADDR_WIDTH-1:0] update_pc;     // 被解析 CFI 的 PC
    logic                  actual_taken;  // 实际方向（jump 恒 1）
    logic                  is_branch;     // 条件分支(0x63)为 1，决定是否训练方向器
    btb_target_info_t      actual_info;   // {start_pc, target_pc, cfi_type, cfi_offset}
    pred_meta_t            pred_meta;     // ★ 必须原样回传前端随指令给出的预测元数据
} update_meta_t;
```

要点：

- `pred_meta` 必须是**预测时**随该指令流下来的那一份（`iq_rbits[i].pred_meta`），不要重新生成；gshare/chooser/loop 的训练索引依赖它。
- `actual_info.cfi_offset = (update_pc & (FETCH_WIDTH*INST_BYTES-1)) >> 2`；
  `actual_info.start_pc = update_pc & ~(FETCH_WIDTH*INST_BYTES-1)`；
  `actual_info.cfi_type` 用 `cfi_type_t`（`CFI_BRANCH / CFI_DIRECT_JUMP / CFI_CALL / CFI_RETURN / CFI_INDIRECT_JUMP`）。
- `is_branch` 仅在条件分支为真：只有条件分支训练 Bimodal/Gshare/chooser/Loop；`jal/jalr` 只推进 GHR 与 RAS。

**重要顺序约束**：当前 BPU 的 committed 状态（Gshare 的 `ghr_commit`、RAS 的 `sp_commit`、Loop 的 `iter_commit`）都是在**解析同拍、按序**推进的，且每拍只推进一个 CFI 单元。后端 BRU 若乱序解析，**必须**把 `bpu_update_en/bpu_update_meta` 缓冲到**提交序**再送回，且每拍至多一条。否则这些预测器会被训坏。

## 5. 与 `frontend.md` 的差异（接入时注意）

| 项目 | `frontend.md` 文档 | 本 RTL 实现 |
| --- | --- | --- |
| `cfi_type_t` 枚举名 | `CFI_COND_BRANCH` | `CFI_BRANCH`（顺序/位宽一致） |
| `iq_entry_t` | 含 `need_redirect` | 无（未预测的 jalr 由后端 BRU 正常重定向，无需该位） |
| `iq_entry_t` | 无 `pc` | 含 `pc`（后端算 snpc/目标必需） |
| FTQ entry | 单 CFI | per-slot 数组（IQ 每条指令自带 `pred_meta`，后端不受影响） |
| IQ_DEPTH | 8 | **128**（HEAD 2 + BODY 126） |
| ICache | 4-way/64-set/32B | 一致 |
| FTQ / FETCH_WIDTH / DECODE_WIDTH | 16 / 4 / 2 | 一致 |

如需把 `IQ_DEPTH` 调到文档值 8，改 `fe_pkg.sv` 即可（IQ 内部位宽自适应）。

## 6. 仿真验证

`test/tb_frontend.sv` 是自检 TB：内建一个只返回非控制流指令的 AXI-Lite 内存模型，并用一个简单后端模型从 `iq_*` 读口按序消费，检查：

- 顺序取指时读出的 PC 每次 +4；
- `iq_rvalid` 始终是低连续前缀（不出现 `10`）；
- backend redirect 后 IQ 被清空并从新 PC 重新取指。

运行方式（Verilator 5）：

```bash
cd rtl/frontend
verilator --binary --timing -sv -Wno-fatal +incdir+. \
    --top-module tb_frontend test/tb_frontend.sv -o /tmp/tb_frontend
/tmp/tb_frontend
# 期望输出：ALL TESTS PASSED (96 instructions consumed)
```

> 注：`frontend.sv` 的 AXI 端口使用了 interface modport。用 Verilator 对
> `--top-module frontend` 直接开 `--trace-structs` 会触发上游工具的一个内部错误；
> 在真正的 top 中实例化 `frontend`（接口在 parent 中例化）后跟踪正常。
