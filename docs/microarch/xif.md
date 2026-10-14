# ARES CV-X-IF 接口与自定义指令

> 对象：miniTensor 协处理器（从端 `mini_tensor_top`）。
> 接口：CV-X-IF（`core_v_xif`）；指令：RISC-V custom-0。
> 来源：`miniTensor/rtl/interface/core_v_xif.sv`、`miniTensor/rtl/common/minitensor_pkg.sv`、
> `miniTensor/rtl/vector/vpu_pkg.sv`、`miniTensor/rtl/tensor/tensor_pkg.sv`、
> `miniTensor/rtl/top/mini_tensor_top.sv`。

## 1. CV-X-IF 接口

### 1.1 参数

| 参数 | 取值 | 说明 |
| --- | --- | --- |
| `X_NUM_RS` | 2 | register 操作数个数 |
| `X_ID_WIDTH` | 4 | 事务 id 位宽（miniTensor 固定为 4） |
| `X_RFR_WIDTH` | 32 | register 操作数位宽 |
| `X_RFW_WIDTH` | 32 | result 数据位宽 |
| `X_NUM_HARTS` | 1 | 单 hart |
| `X_HARTID_WIDTH` | 1 | hartid 位宽 |
| `X_DUALREAD` | 0 | `readregflags_t = [1:0]` |
| `X_DUALWRITE` | 0 | `writeregflags_t = [0:0]` |
| `X_ISSUE_REGISTER_SPLIT` | 0 | issue/register 不拆分 |
| `X_MEM_WIDTH` | 32 | XIF memory 通道未使用 |

### 1.2 端口分组总览

CV-X-IF 由 7 组端口构成，每组是一对（或一组）valid/ready 通道。方向以主机
（CPU）为参照；`core_v_xif_cpu_*` 与 `core_v_xif_coprocessor_*`
是两个对称的 modport。

| 组 | 用途 | 通道方向 | miniTensor |
| --- | --- | --- | --- |
| compressed | 压缩指令展开 | CPU → 协处理器 | 未使用（恒 ready、resp=0） |   !!!不使用
| issue | 指令发射与接受 | CPU → 协处理器（含 accept 回执） | **使用** |
| register | 源操作数传递 | CPU → 协处理器 | **使用** |
| commit | 提交 / 取消通知 | CPU → 协处理器 | **使用** |
| mem | 协处理器发起的访存请求 | 协处理器 → CPU | 未使用（`mem_valid=0`） |
| mem_result | 访存结果 | 协处理器 → CPU | 未使用 |
| result | 执行结果回写 | 协处理器 → CPU | **使用** |

握手通例：valid 拉高后保持到该拍被 ready 接收；ready 可独立拉高；
`valid && ready` 同一拍有效即完成一次传输。`commit` 组没有 ready，
只在 `commit_valid` 有效时被从端采样。

### 1.3 issue 组：指令发射

用途：CPU 把一条候选指令交给协处理器，并当拍得到「是否接受」的回执。
这是所有 XIF 指令生命周期的入口。

| 信号 | 位宽 | 方向 | 说明 |
| --- | --- | --- | --- |
| `issue_valid` | 1 | out | CPU 有指令要发射 |
| `issue_ready` | 1 | in | 从端本周期可接收 |
| `issue_req.instr` | 32 | out | 原始指令字（原样透传） |
| `issue_req.mode` | 2 | out | 特权模式，`2'b00`（M-mode） |
| `issue_req.hartid` | 1 | out | hart 标识，ARES 为 0 |
| `issue_req.id` | 4 | out | 事务标识，后续 register/commit 必须一致 |
| `issue_resp.accept` | 1 | in | 1 = 接受并进入后续阶段 |
| `issue_resp.register_read` | 2 | in | 从端要读的源个数 |
| `issue_resp.writeback` | 1 | in | 是否有写回 |
| `issue_resp.loadstore` | 1 | in | 是否访存类指令 |

miniTensor 行为：`issue_ready` 仅在顶层 `S_IDLE` 拉高，因此一次只有
一条命令在途；只接受 custom-0 的五类指令，接受时 `accept=1`、
`writeback[0]=1`、`register_read=2'b11`；不支持的 funct7/funct3 返回
`accept=0`，不进入 register/commit，也不产生结果。

### 1.4 register 组：源操作数

用途：CPU 把两个源操作数的**值**交给协处理器（对应从端的「寄存器读」）。
CV-X-IF 的协处理器通常不直接读 CPU 的 GPR，操作数由此通道显式传入。

| 信号 | 位宽 | 方向 | 说明 |
| --- | --- | --- | --- |
| `register_valid` | 1 | out | 操作数有效 |
| `register_ready` | 1 | in | 从端接收 |
| `register.hartid` | 1 | out | 必须与 issue 一致 |
| `register.id` | 4 | out | 必须与 issue 一致 |
| `register.rs[0]` | 32 | out | 第 1 个操作数 |
| `register.rs[1]` | 32 | out | 第 2 个操作数 |
| `register.rs_valid` | 2 | out | 每个操作数是否有效，必须 `2'b11` |

miniTensor 行为：`register_ready` 只在 `S_WAIT_COMMIT && !register_seen`
拉高，即一条命令只接收一次 register；`id/hartid` 不匹配或
`rs_valid != 2'b11` 会置 `command_err`（但仍会返回结果）。

### 1.5 commit 组：提交 / 取消

用途：CPU 通知协处理器「该指令已到非推测点，可以产生副作用」；
`commit_kill=1` 用于在该点之前取消它。

| 信号 | 位宽 | 方向 | 说明 |
| --- | --- | --- | --- |
| `commit_valid` | 1 | out | 提交拍有效 |
| `commit.hartid` | 1 | out | 必须与 issue 一致 |
| `commit.id` | 4 | out | 必须与 issue 一致 |
| `commit.commit_kill` | 1 | out | 1 = 取消；仅副作用开始前有效 |

miniTensor 行为：在 `S_WAIT_COMMIT` 采样一次；`register_seen` 与
`committed` 同时满足才进入 `S_DISPATCH` 开始 DMA/VPU/GEMM；
`commit_kill=1`（且 id/hartid 匹配）直接回 `S_IDLE`，不写 UB、不发访存。

### 1.6 result 组：执行结果回写

用途：协处理器把标量执行结果和状态回写给 CPU。数据结果本身留在 UB/内存，
这条通道只回传完成状态与目标寄存器。

| 信号 | 位宽 | 方向 | 说明 |
| --- | --- | --- | --- |
| `result_valid` | 1 | in | 从端结果有效 |
| `result_ready` | 1 | out | CPU 接收；未接收前从端保持字段稳定 |
| `result.hartid` | 1 | in | 与事务匹配 |
| `result.id` | 4 | in | 与事务匹配 |
| `result.data` | 32 | in | 写回数据，miniTensor 恒 0 |
| `result.rd` | 5 | in | 目标 GPR，= `instr[11:7]` |
| `result.we` | 1 | in | 写使能，miniTensor 恒 1 |
| `result.exc` / `.exccode` / `.dbg` | 1 / 6 / 1 | in | 异常/调试状态，miniTensor 恒 0 |
| `result.err` | 1 | in | 非法操作数或生命周期错误 |

miniTensor 行为：在 `S_RESULT` 拉高并保持到握手；`data=0`、
`rd=instr[11:7]`、`we[0]=1`，因此建议软件用 `rd=x0`。

### 1.7 未使用的组

- **compressed**：压缩指令展开通道。miniTensor `compressed_ready=1`、
  `compressed_resp=0`；CPU 侧保持 `compressed_valid=0`。
- **mem / mem_result**：协处理器主动发起访存的通道。miniTensor 走独立的
  128-bit uncached DMA 端口，`mem_valid=0`，不使用该组；CPU 侧
  `mem_ready=1`、`mem_result_valid=0`。其余悬空信号按常量驱动避免 X。

### 1.8 完整生命周期与时序

    主机                                  miniTensor
    issue_valid + issue_req   --------->   S_IDLE，accept=1 后进 S_WAIT_COMMIT
    register_valid + rs[2]    --------->   提供 rs1/rs2，只接收一次
    commit_valid (+ commit_kill) ------->  匹配 id/hartid 且 kill=0 才开始副作用
    result_valid              <---------  执行完成；rd 写回 0，err 表示错误

- 一次只允许一条命令在途：`issue_ready` 只在顶层 `S_IDLE` 拉高。
- `register_ready` 在 issue 握手后下一拍才可能拉高，主机应等待 ready。
- `commit` 必须在 `register` 之后；`commit_kill` 仅在副作用开始前取消。
- `result_valid` 未握手前，从端保持字段稳定。

## 2. 自定义指令

### 2.1 公共编码

所有指令使用 **custom-0**：`instr[6:0] = 7'b0001011`。R-type 布局：

    instr[31:25] = funct7
    instr[24:20] = rs2
    instr[19:15] = rs1
    instr[14:12] = funct3
    instr[11:7]  = rd
    instr[6:0]   = 0001011

- `rs1`/`rs2` 字段由 CPU 用来选择要读的 GPR；从端忽略这两个字段，
  只使用 `register.rs[0]/rs[1]` 的值。
- 结果标量恒为 0（`result.data=0`、`we[0]=1`），建议软件用 `rd=x0`。

### 2.2 指令表

| 指令 | funct7[6:0] | funct3[2:0] | rs1 值 | rs2 值 | 语义 |
| --- | --- | --- | --- | --- | --- |
| MT_LOAD | `0000011` | `000` | 内存源地址（16B 对齐） | `[7:0]` 起始行，`[15:8]` 行数 | 内存 → UB |
| MT_STORE | `0000100` | `000` | 内存目标地址（16B 对齐） | `[7:0]` 起始行，`[15:8]` 行数 | UB → 内存 |
| ADD8 | `0000010` | `000` | `[7:0]` A 行，`[15:8]` B 行 | `[7:0]` 结果行 | 16×INT8 逐字节加 |
| MAX8 | `0000010` | `001` | 同上 | 同上 | 16×INT8 signed max |
| RELU8 | `0000010` | `010` | 同上（只用 A） | 同上 | 16×INT8 signed ReLU |
| MT_GEMM | `0000101` | `000` | `[7:0]` A 行，`[15:8]` B 行 | `[7:0]` C 行，`[8]` 累加位 | C = A×B（或 C += A×B），4×4 INT8 |
| MT_EPILOGUE | `0000110` | `000` | `[7:0]` C 行，`[15:8]` Bias 行 | `[7:0]` 输出行，`[15:8]` config 行 | INT32 → INT8 量化 |

### 2.3 各指令约束

**MT_LOAD / MT_STORE**（`rs2[31:16]` 保留为 0，地址 `[3:0]==0`，行数非零）

- 每行 16 Byte：内存地址每次 +16，UB 行号每次 +1。
- 约束 `起始行 + 行数 <= 256`。
- 写为整行覆盖写（`mem_wr_be` 全 1），读为单 outstanding 两段式。

**ADD8 / MAX8 / RELU8**（`rs1[31:16]`、`rs2[31:8]` 保留为 0）

- 一条 UB 行 = 16 个 packed signed INT8；三行（A/B/dst）都必须 < 256。
- RELU8 只用 A，但仍读 B，故 B 行号也必须有效。

**MT_GEMM**（`rs1[31:16]`、`rs2[31:9]` 保留为 0）

- A、B 各占 1 行（16×signed INT8）；C 占 `C..C+3` 四行，每行 4 个 signed INT32。
- `rs2[8]=0` → `C=A×B`；`rs2[8]=1` → `C=C_old+A×B`（K 维累加）。
- 结果顺序 `C[0][0] ... C[3][3]`。

**MT_EPILOGUE**（`rs1[31:16]`、`rs2[31:16]` 保留为 0）

- 读 `C..C+3` 与 `Bias..Bias+3`，输出 1 行 packed INT8。
- config 行：`[15:0]` signed multiplier，`[20:16]` 右移位数，
  `[28:21]` signed zero point，`[29]` ReLU enable。
- 每个元素：`saturate_int8(ReLU((C + Bias) * multiplier >>> shift) + zero_point)`。

### 2.4 结果与错误

| 情况 | 从端行为 |
| --- | --- |
| 合法指令与操作数 | 执行；`result.data=0`、`err=0`、`we[0]=1` |
| 保留位非零 / 地址未对齐 / 行数 0 / 行越界 | `result.err=1`，无 UB/内存副作用 |
| register 的 id/hartid 不匹配或 `rs_valid != 2'b11` | `result.err=1` |
| 不支持的 funct7/funct3 | `issue_resp.accept=0`，不产生 result |
| `commit_kill=1`（副作用前） | 回到空闲，无写 |
