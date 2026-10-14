# miniTensor × Mundus/NPC × RT-Thread Nano 接入实施方案

> 目标：让 **RT-Thread Nano**（`Mundus/rtthread-nano` 的 `bsp/MundusJyd`）跑在 **真实 Mundus/NPC 核** 上，
> 通过 MMIO 驱动 **miniTensor** 完成一个完整的 GEMM 负载，并在 Verilator 中自校验。
>
> 本文基于对三个仓库的**实测**（不是推测），关键处给出行号。基准快照：
> - `qs/miniTensor` @ 工作区 HEAD
> - `qs/Mundus/npc` @ `0c44cacc`（jyd 分支）
> - `qs/Mundus/rtthread-nano` @ `0d3b2b2`（`rtthread-nano-jyd` 分支，已 checkout）

---

## 0. TL;DR

| 结论 | 依据 |
| --- | --- |
| **RT-Thread 侧已经完全就绪**，不用新建 BSP | `bsp/MundusJyd` 已有完整 BSP，且**已经在用 custom-0 自定义指令**（CRC16/MULBE） |
| **miniTensor 的 RTL 一行都不用改** | 只需把它加进 npc 的 Verilator 文件表 |
| **NPC 的 Chisel 核不用改**（不重新 elaborate） | 只在 `vsrc/testbench/jyd/` 这一层加译码 + 适配器 |
| 控制通路选 **MMIO shim**，不选原生 custom-0 | 见 §2.1：原生指令会把核**阻塞**住，对 RTOS 是负优化 |
| 数据通路的关键是 **D-Cache 一致性**，必须走 uncached 别名窗口 | 见 §2.3 |
| **当前唯一硬阻塞是环境**：mill / nvboard / kconfig venv / capstone 全都没装 | `configs/build` 与 `vsrc/build/Mundus.sv` 都不存在 → 现在连一次仿真都跑不起来 |

**最小可行闭环**：真实 Mundus 核 + MMIO shim + miniTensor，K=12 的 4×4 GEMM（LOAD → GEMM×3 → EPILOGUE → STORE），
结果与 CPU 参考实现逐字节比对，通过 RT-Thread 的 `msh` 命令触发。

---

## 1. 三个仓库的实测现状

### 1.1 已经有的（可以直接用）

| 资产 | 位置 | 说明 |
| --- | --- | --- |
| RT-Thread Nano 3.1.5 BSP | `rtthread-nano/rt-thread/bsp/MundusJyd/` | `start.S`/`trap.S`/`board.c`/`console.c`/`timer.c` + 最小 MSH + CoreMark |
| **MMIO 驱动模板** | `bsp/MundusJyd/include/board.h:6-15` | `JYD_MMIO32(addr)` 宏 + 地址常量，miniTensor 驱动照抄即可 |
| **custom-0 内联汇编先例** | `bsp/MundusJyd/coremark/mundus_hw_crc_inline.h:20-22` | `.insn r 0x0b, 0, 0, %0, %1, %2` —— 证明工具链路径是通的 |
| 构建/仿真流程 | `bsp/MundusJyd/Makefile:378-385` | `make run` → `make -C $(NPC_HOME) wave PLATFORM=jyd PROGRAM=<bin>` |
| 地址空间 | `bsp/MundusJyd/README.md` §3 | IROM 32 KiB @0x8000_0000；DRAM 256 KiB @0x8010_0000；MMIO @0x8020_00xx |
| 统一内存模型 | `npc/vsrc/testbench/IP/BRAM.v:11-12,69-78` | **DPI 后端**，落到 C++ 的 `dram[0x40000]` 字节数组 |
| perip 设备模板 | `npc/vsrc/testbench/jyd/perip_bridge.sv:505-598` | 写寄存器 + 读译码 + 2 拍响应的现成写法 |
| miniTensor 端口/CV-X-IF | `rtl/top/mini_tensor_top.sv:6-38`、`rtl/interface/core_v_xif.sv` | 稳定，见 `handoff/dma_interface.md` |
| miniTensor 参考驱动序列 | `tb/top/tb_mini_tensor_npc.sv:235-271` | 21 条 RV32I 初始化 + 9 条 custom-0，是软件驱动的原型 |

### 1.2 现状里容易踩的坑（实测）

1. **`qs/Mundus/npc/` 和 `rtthread-nano` 都是裸 checkout，没有构建产物**：
   `npc/configs/build/` 和 `npc/vsrc/build/Mundus.v` **都不存在**。
2. **`nvboard` 子模块是空目录**，而 `npc/Makefile:243` 无条件 `include $(NVBOARD_HOME)/scripts/nvboard.mk`
   → **不初始化 nvboard，npc 的 Makefile 根本解析不了**。
3. **`mill` 不存在**（`npc/Makefile:19 MILL = $(NPC_HOME)/mill`），而 Chisel 走的是
   `circt.stage.ChiselStage.emitSystemVerilog`（`scsrc/Mundus.scala:1343-1347`）→ **需要 mill + firtool**。
4. **RISC-V 工具链路径不存在**：BSP 默认 `/home/dragonflame/tools/riscv-gcc-16.1-rv32im/bin/riscv32-unknown-elf-`
   （`bsp/MundusJyd/Makefile:36`），本机没有。但本机有 **`riscv64-unknown-elf-gcc` 13.2.0**，
   实测支持 `-march=rv32im_zicsr -mabi=ilp32`（**已通过编译验证**），用 `CROSS_COMPILE=riscv64-unknown-elf-` 覆盖即可。
5. `rtthread-nano` 子模块**已经 checkout 好了**（branch `rtthread-nano-jyd`），不用再 init。
   其余子模块（`ysyxSoC`/`am-kernels`/`rt-thread-am`/`gem5`/`fceux-am`/`yosys-sta`）**本方案都不需要**。

---

## 2. 三个关键设计决策

### 2.1 控制通路：为什么选 MMIO shim，不选原生 custom-0

miniTensor 的从端是 **CV-X-IF**（issue → register → commit → result），而 Mundus 核**没有 CV-X-IF 端口**：

- `scsrc/idu/IDU.scala` 的 `customDecodeTable` 里只登记了 `CRC16`(funct7=0) 和 `MULBE`(funct7=1)；
- miniTensor 用同一 opcode `7'b0001011`（custom-0），但 funct7 是 `0000011/0000100/0000010/0000101/0000110`，
  **不在表里**；未命中时走默认项 → **静默 no-op，不报异常**（所以"直接跑 miniTensor 程序"会正常退休但什么都不发生）。

两条路线对比：

| | **方案 A：MMIO shim（推荐）** | **方案 B：原生 custom-0** |
| --- | --- | --- |
| 改动面 | 只在 `vsrc/testbench/jyd/` + `csrc/wave/` | 要改 `IDU.scala` + 新增卸载执行类 + 长延迟计分板 + 重新 elaborate |
| 前提 | 无（不用 mill） | 必须有 mill+firtool，且要重跑 Chisel 回归 |
| **对 RTOS 的影响** | **CPU 不被阻塞**，其他线程照跑 | **整核停住若干千拍**，调度器被冻结 |
| 软件侧 | 普通 `volatile uint32_t` 读写 | `.insn` 内联汇编 |
| 每条命令开销 | ~3 次 SW + n 次 LW 轮询 | 0 |
| 吞吐收益 | — | **其实没有**：miniTensor 的 `issue_ready` 只在 `S_IDLE` 拉高，一次只允许一条在途 |

**结论**：方案 B 在当前的 miniTensor 设计下**买不到任何吞吐**，却要给 RTOS 引入"核被长时间独占"这个严重问题。
**先做 A**。将来若 miniTensor 加了命令队列，再考虑 B。

> 补充：Mundus 的 `io_interrupt` 只有一根线，内部只映射到 `mip.MTIP`（`scsrc/exu/CSR.scala`）。
> 所以"done 走中断"需要一个小的 Chisel 改动（新增一个 mip 位或复用 MEIP）。**第一版先轮询，第二阶段再做中断。**

### 2.2 数据通路：DMA 接哪里

**关键发现（实测）**：JYD 平台的 DRAM 在 Verilator 下**根本不是 BRAM，而是 DPI 后端**：

```
perip_bridge.sv:682  bram_driver bram_driver_inst (...)
bram_driver.sv:34    BRAM Mem_BRAM (...)
BRAM.v:11-12         import "DPI-C" function int  vaddr_read (input int raddr);
                     import "DPI-C" function void vaddr_write(input int waddr, input int wdata, input byte len);
BRAM.v:69-78         rdata <= vaddr_read(raddr); ... vaddr_write(waddr, wdata, len);
mem.cpp:17           static uint8_t dram[0x40000];
```

也就是说：**CPU 看到的"内存"就是一个按 32 位地址寻址的 C++ 字节数组**。
`DRAM.v`/`dram_driver.sv` 是**死代码**（全仓库无实例化），可以忽略。

这带来两个巨大简化：

1. **DMA 不需要真的做"第二个 BRAM 端口"**——再加两个 DPI 函数直接读写同一个 `dram[]` 即可，
   天然与 CPU 共享同一份物理内存，且**没有端口仲裁问题**（仿真里 DPI 调用不是硬件端口）。
2. 不需要 128→4×32 的聚合适配器，也不需要考虑 BRAM 位宽。

```c
/* mem.cpp 新增（约 20 行） */
extern "C" void mt_dma_read (int addr, int *w0, int *w1, int *w2, int *w3) {
  uint32_t a = ((uint32_t)addr & ~0x00200000u);   /* 清 bit21：别名归一化 */
  if (!in_dram(a)) out_of_bound(a);
  uint32_t *p = (uint32_t *)(dram + (a - 0x80100000u));
  *w0 = (int)p[0]; *w1 = (int)p[1]; *w2 = (int)p[2]; *w3 = (int)p[3];
}
extern "C" void mt_dma_write(int addr, int w0, int w1, int w2, int w3) {
  uint32_t a = ((uint32_t)addr & ~0x00200000u);
  if (!in_dram(a)) out_of_bound(a);
  uint32_t *p = (uint32_t *)(dram + (a - 0x80100000u));
  p[0] = (uint32_t)w0; p[1] = (uint32_t)w1; p[2] = (uint32_t)w2; p[3] = (uint32_t)w3;
}
```

### 2.3 一致性：必须走 uncached 别名窗口（本方案的核心）

实测事实：

- D-Cache 的 cacheable 判据是**纯地址**且**硬编码**：`scsrc/Mundus.scala:543-544`
  `val dc1Cacheable = dc1Memory.addr(31,18) === "b1000_0000_0001_00".U`
  → 只有 `0x8010_0000–0x8013_FFFF` 可缓存。
- 缓存是**写回**的（store 命中只消费 cache 自己的 BRAM 写口，`dcache.scala:329-331`），
  而且**没有任何 flush/invalidate 指令**。

所以：只要 CPU 通过 cacheable 地址写 A/B，miniTensor 的 DMA 就会读到**旧数据**；反之 DMA 写的 C 也会被 CPU 读到**脏行**。

**解法：把 DRAM 镜像一份到 `0x8030_0000`（即"清 bit21"），这个窗口天然 uncached，CPU 一行不用改。**

```
0x8010_0000 ─ 0x8013_FFFF   cacheable  DRAM（原有，CPU 正常 .data/.bss/栈）
0x8030_0000 ─ 0x8033_FFFF   uncached   DRAM 镜像（同物理内存，清 bit21 即可换算）
```

**但镜像和 cacheable 区共用物理内存**，如果 CPU 两边都碰就会出问题。所以再切一刀：

**把 DRAM 最高 64 KiB 划给 miniTensor 专用：**

```
物理 0x8013_0000 – 0x8013_FFFF   ← 只被 DMA 和「uncached 别名」访问
别名 0x8033_0000 – 0x8033_FFFF   ← CPU 访问 miniTensor buffer 的唯一入口
linker.ld: DRAM LENGTH 由 256K 改成 192K（0x8013_0000 以上不分配给普通数据）
```

因为这块区域**从来没有 cacheable 的访客**，缓存里永远不会出现它的行 → **天然一致，不需要 flush**。
这就是在没有 cache 维护指令的核上唯一正确的做法。

---

## 3. 地址与寄存器规划

### 3.1 地址映射（新增部分）

| 窗口 | 属性 | 用途 |
| --- | --- | --- |
| `0x8020_1000 – 0x8020_101F` | MMIO，uncached | miniTensor 控制寄存器（放在已有 perip 页内，当前空闲） |
| `0x8033_0000 – 0x8033_FFFF` | uncached 别名 → 物理 `0x8013_0000` | miniTensor 的 A/B/bias/config/C/OUT 缓冲区（64 KiB） |
| `0x8030_0000 – 0x8033_FFFF` | uncached DRAM 全镜像 | 通用（只有 `0x8033_xxxx` 允许软件使用） |

> **重要**：`perip_bridge.sv` 对未译码地址会让 `response_tag_next = RESP_NONE`（`:551,593-594`），
> `perip_rvalid` 永不拉高（`:750`）→ **CPU 会死等**。所以软件碰到的每个地址都必须显式译码。

### 3.2 MMIO 寄存器

| 偏移 | 名称 | 方向 | 语义 |
| --- | --- | --- | --- |
| `0x00` | `MT_INSTR` | W | 32 位 custom-0 指令字 |
| `0x04` | `MT_RS1` | W | 作为 `register.rs[0]` 投递的值 |
| `0x08` | `MT_RS2` | W | 作为 `register.rs[1]` 投递的值 |
| `0x0C` | `MT_KICK` | W | 写 1 启动一次事务；busy 时置 `accept_err` 并忽略 |
| `0x10` | `MT_STATUS` | R | `bit0=busy, bit1=done, bit2=err, bit3=accept_err`；**读清 done** |
| `0x14` | `MT_RESULT` | R | `result.data`（当前恒 0，留作扩展） |

> `MT_KICK` 在 busy 时**不要**用 `perip_ready=0` 卡住 store——那会把 LSU 锁死，软件就没法再去轮询状态了。
> 照常 accept + 置 `accept_err`。

---

## 4. 改动清单（逐文件）

图：集成后的结构

```
                    ┌─────────────── rtthread-nano BSP ───────────────┐
                    │  mt.c / mt.h 驱动   +  msh 命令 mt_gemm          │
                    └───────────────────────┬─────────────────────────┘
                                            │ SW/LW
   ┌──────────────── Mundus (npc) ──────────┼──────────────────────────────┐
   │  myCPU ── perip(32b) ──► perip_bridge ─┤                              │
   │                            │  ├─ 0x8010_xxxx / 0x8030_xxxx ─► BRAM(DPI)│
   │                            │  ├─ 0x8020_00xx  外设                     │
   │                            │  └─ 0x8020_10xx  mt_cvxif_shim ◄── 新增    │
   │                            ▼                                            │
   │                     core_v_xif (master)                                 │
   │                            │                                            │
   │                     mini_tensor_top ◄── 新增实例化                       │
   │                            │  128-bit DMA                              │
   │                     mt_dma_bridge ── DPI ──► dram[] (同一个字节数组)     │
   └────────────────────────────────────────────────────────────────────────┘
```

### 4.1 npc 侧（5 个文件，其中 2 个新增）

#### (1) 新增 `npc/vsrc/testbench/jyd/mt_cvxif_shim.sv`

MMIO → CV-X-IF **主端** FSM。

```systemverilog
module mt_cvxif_shim #(
    parameter int ISSUE_TO_REGISTER = 2,   // 照抄 tb/npc/vpu_npc_model.sv:28-30
    parameter int REGISTER_TO_COMMIT = 3,
    parameter int RESULT_ACCEPT_DELAY = 1
)(
    input  logic clk, rst,
    // 寄存器侧（由 perip_bridge 驱动）
    input  logic        wr_en,
    input  logic [4:0]  wr_addr,     // word offset /4
    input  logic [31:0] wr_data,
    input  logic        status_rd,   // 读 STATUS 时清 done
    output logic [31:0] status,
    output logic [31:0] result_data,
    // CV-X-IF 主端
    core_v_xif xif
);
```

状态机（**关键点已标注**）：

```text
S_IDLE       kick & !busy  -> 锁存 instr/rs1/rs2，id<=id+1                    -> S_ISSUE
S_ISSUE      issue_valid=1（保持到 issue_ready）
             accept==0  -> accept_err=1                                    -> S_DONE   ★坑2
             accept==1  -> cnt<=ISSUE_TO_REGISTER                           -> S_REG_WAIT
S_REG_WAIT   cnt-- -> 0                                                        -> S_REGISTER
S_REGISTER   register_valid=1, rs={rs1,rs2}, rs_valid=2'b11（保持到 ready）
             on ready -> cnt<=REGISTER_TO_COMMIT                               -> S_COMMIT_WAIT
S_COMMIT_WAIT cnt-- -> 0                                                       -> S_COMMIT
S_COMMIT     commit_valid=1，★一直保持到 result_valid★                          -> S_RESULT_WAIT
S_RESULT_WAIT result_ready=1
             on result_valid&&ready -> err<=result.err                         -> S_DONE
S_DONE       busy=0, done=1（保持到 STATUS 被读）
```

> ★ **坑 1（最致命）**：`commit` **只在 `S_WAIT_COMMIT` 被采样**（`mini_tensor_top.sv:444-445`）。
> 如果 commit 是一拍脉冲而恰好落在 `register_seen_q` 之前，就会被静默丢弃，
> 命令**永远卡在 `S_WAIT_COMMIT`**（没有超时，只能靠 `commit_kill` 救）。
> **做法：从 `S_COMMIT` 起一直拉高 `commit_valid` 直到 `result_valid` 出现**——多拉几拍无害
> （`committed_q` 是锁存器，后续状态忽略 commit）。

> ★ **坑 2**：非法 funct7/funct3 会让 `issue_resp.accept=0`（`mini_tensor_top.sv:163`），
> **根本不会产生 result**。shim 必须在 issue 握手时检查 `accept` 并走 `S_DONE(accept_err)`，
> 否则会永远等 result。

#### (2) 新增 `npc/vsrc/testbench/jyd/mt_dma_bridge.sv`

把 miniTensor 的 128-bit 握手翻译成 DPI 调用。

```systemverilog
module mt_dma_bridge (
    input  logic clk, rst,
    input  logic         mem_rd_valid,
    output logic         mem_rd_ready,
    input  logic [31:0]  mem_rd_addr,
    output logic         mem_rsp_valid,
    input  logic         mem_rsp_ready,
    output logic [127:0] mem_rsp_data,
    input  logic         mem_wr_valid,
    output logic         mem_wr_ready,
    input  logic [31:0]  mem_wr_addr,
    input  logic [127:0] mem_wr_data,
    input  logic [15:0]  mem_wr_be
);
  import "DPI-C" function void mt_dma_read (input int addr, output int w0, output int w1, output int w2, output int w3);
  import "DPI-C" function void mt_dma_write(input int addr, input  int w0, input  int w1, input  int w2, input  int w3);
  // 读：REQUEST -> (DPI 取数) -> RESPONSE；★响应至少晚请求握手一拍★（handoff/dma_interface.md §2.3）
  // 写：wr_valid & wr_ready 一次握手即完成，无响应通道
endmodule
```

#### (3) 改 `npc/vsrc/testbench/jyd/perip_bridge.sv`

只加译码，**不动 response tag 位宽**（复用现有 `RESP_MMIO`）：

```systemverilog
// A. DRAM 别名：清 bit21 即 0x8030_0000 镜像
assign dram_read_hit  = (perip_addr[31:18] == 14'b1000_0000_0001_00) ||
                        (perip_addr[31:18] == 14'b1000_0000_0011_00);
assign dram_write_hit = dram_read_hit;

// B. 读译码（perip_bridge.sv:560-595 的 unique case 里追加）
MT_STATUS_ADDR: begin response_tag_next = RESP_MMIO; mmio_rdata_next = mt_status; end
MT_RESULT_ADDR: begin response_tag_next = RESP_MMIO; mmio_rdata_next = mt_result; end

// C. 写译码（perip_bridge.sv:510-531 的 unique case 里追加）
MT_INSTR_ADDR: mt_instr_next = perip_wdata;
MT_RS1_ADDR:   mt_rs1_next   = perip_wdata;
MT_RS2_ADDR:   mt_rs2_next   = perip_wdata;
MT_KICK_ADDR:  mt_kick_next  = (perip_wdata == 32'd1);

// D. 实例化 shim + 把 CV-X-IF 主端引到端口上，供 student_top 接 mini_tensor_top
```

`perip_ready` **不用改**：MT 地址不是 `dram_write_hit`，会自动落进 MMIO 分支
（`perip_bridge.sv:196-201`），从而**自动获得 "MMIO 排在所有排队 store 之后" 的强序保证** ——
这正是我们要的（不然 `sw A_buffer` 还没落地就 kick，DMA 会读到旧数据）。

别名位要穿到 BRAM：

```systemverilog
// bram_driver.sv / BRAM.v 各加 1 位输入
// BRAM.v:23-24 改成：
assign raddr = {14'b1000_0000_0001_00, addrb, 2'b00} | (alias ? 32'h0020_0000 : 32'h0);
assign waddr = {14'b1000_0000_0001_00, addra, offset} | (alias ? 32'h0020_0000 : 32'h0);
```

#### (4) 改 `npc/vsrc/testbench/jyd/student_top.sv`

实例化 `mini_tensor_top` + `mt_dma_bridge`，把 shim 的 `core_v_xif` 接上去：

```systemverilog
core_v_xif mt_xif();
mini_tensor_top #(.X_ID_WIDTH(4), .DATA_WIDTH(128)) u_mt (
    .clk(w_cpu_clk), .rst(w_clk_rst), .xif(mt_xif),
    .mem_rd_valid(...), .mem_rd_ready(...), .mem_rd_addr(...),
    .mem_rsp_valid(...), .mem_rsp_ready(...), .mem_rsp_data(...),
    .mem_wr_valid(...), .mem_wr_ready(...), .mem_wr_addr(...),
    .mem_wr_data(...), .mem_wr_be(...),
    .ub_rd_en(1'b0), .ub_rd_addr('0), .ub_rd_valid(), .ub_rd_data(), .dma_busy()
);
mt_dma_bridge u_dma (.*  // 接到 u_mt 的 DMA 口
);
```

#### (5) 改 `npc/Makefile`（把 miniTensor 加进 Verilator 文件表）

```makefile
MT_HOME ?= $(abspath $(MUNDUS_HOME)/../miniTensor)
ifeq ($(PLATFORM),jyd)
  MT_SRCS := $(shell find $(MT_HOME)/rtl -name "*.sv")
  VSRCS   += $(MT_SRCS)
  V_INC_PATH += $(MT_HOME)/rtl/interface
endif
```

> 注意 `npc/Makefile:40` 有 `-Werror-WIDTHTRUNC`。miniTensor 自己用 `--Wall --Wno-fatal` 构建（`Makefile:3`），
> **很可能过不了这道 lint**。建议在 miniTensor 的 sv 文件里就地加
> `/* verilator lint_off WIDTHTRUNC */`，**不要**为了它放松 CPU 的告警级别。

#### (6) 改 `npc/csrc/include/mem.h` + `csrc/wave/mem.cpp`

- `in_dram()` 接受两个窗口；`vir_to_phy()` 做别名归一化；
- 新增 `mt_dma_read/mt_dma_write`（见 §2.2）；
- （可选）新增 UB 调试读的 DPI，方便在仿真里直接 dump UB 内容。

### 4.2 miniTensor 侧

**RTL 零改动。** 只有两件可选的事：
1. 在 sv 文件里加 Verilator lint pragma（若 `-Werror-WIDTHTRUNC` 报错）；
2. 把 `$fatal` 的 `initial` 块用 ``ifndef SYNTHESIS`` 包起来（为将来上板）。

### 4.3 RT-Thread BSP 侧（3 个文件，其中 2 个新增）

#### 新增 `bsp/MundusJyd/include/mt.h` + `mt.c`

```c
#include "board.h"

#define MT_BASE     0x80201000u
#define MT_INSTR    (MT_BASE + 0x00u)
#define MT_RS1      (MT_BASE + 0x04u)
#define MT_RS2      (MT_BASE + 0x08u)
#define MT_KICK     (MT_BASE + 0x0Cu)
#define MT_STATUS   (MT_BASE + 0x10u)
#define MT_RESULT   (MT_BASE + 0x14u)

/* 只能通过 uncached 别名访问！物理 0x8013_0000，64 KiB */
#define MT_BUF_BASE 0x80330000u

#define MT_ST_BUSY  0x1u
#define MT_ST_DONE  0x2u
#define MT_ST_ERR   0x4u
#define MT_ST_ACPT  0x8u

#define MT_OPCODE   0x0Bu
static inline uint32_t mt_enc(uint32_t f7, uint32_t f3, uint32_t rd) {
    return (f7 << 25) | ((f3 & 7u) << 12) | ((rd & 0x1Fu) << 7) | MT_OPCODE;
}
#define MT_LOAD      mt_enc(0x03u, 0u, 0u)
#define MT_STORE     mt_enc(0x04u, 0u, 0u)
#define MT_VEC_ADD8  mt_enc(0x02u, 0u, 0u)
#define MT_VEC_MAX8  mt_enc(0x02u, 1u, 0u)
#define MT_VEC_RELU8 mt_enc(0x02u, 2u, 0u)
#define MT_GEMM      mt_enc(0x05u, 0u, 0u)
#define MT_EPILOGUE  mt_enc(0x06u, 0u, 0u)

/* rs2 = 行起始 | 行数<<8（行数必须非 0） */
#define MT_ROWS(base, cnt) (((base) & 0xFFu) | (((cnt) & 0xFFu) << 8))

static int mt_exec(uint32_t instr, uint32_t rs1, uint32_t rs2)
{
    uint32_t st;
    JYD_MMIO32(MT_INSTR) = instr;
    JYD_MMIO32(MT_RS1)   = rs1;
    JYD_MMIO32(MT_RS2)   = rs2;
    JYD_MMIO32(MT_KICK)  = 1u;
    do { st = JYD_MMIO32(MT_STATUS); } while (st & MT_ST_BUSY);
    return (st & (MT_ST_ERR | MT_ST_ACPT)) ? -1 : 0;
}
```

> **注意**：指令字里的 `rs1/rs2` **字段值是无意义的**——miniTensor 只从 register 通道取**值**
> （`mini_tensor_top.sv:428-443`），只有 `rd` 和 `funct7/funct3` 被解释。所以软件只需拼 funct7/funct3/rd。

#### 参考驱动序列（照抄 `tb/top/tb_mini_tensor_npc.sv:259-268` 的 9 条命令）

```c
#define A_ADDR     (MT_BUF_BASE + 0x000u)   /* 3 行 × 16B */
#define B_ADDR     (MT_BUF_BASE + 0x030u)   /* 3 行 × 16B */
#define BIAS_ADDR  (MT_BUF_BASE + 0x100u)   /* 4 行 */
#define CFG_ADDR   (MT_BUF_BASE + 0x140u)   /* 1 行 */
#define OUT_ADDR   (MT_BUF_BASE + 0x200u)   /* 1 行 */

/* UB 行分配：A=0..2  B=3..5  C=8..11  bias=16..19  cfg=20  out=24 */

mt_exec(MT_LOAD, A_ADDR,    MT_ROWS(0, 3));
mt_exec(MT_LOAD, B_ADDR,    MT_ROWS(3, 3));
mt_exec(MT_LOAD, BIAS_ADDR, MT_ROWS(16, 4));
mt_exec(MT_LOAD, CFG_ADDR,  MT_ROWS(20, 1));

mt_exec(MT_GEMM, (0u) | (3u << 8),   (8u) | (0u << 8));   /* C  = A0*B0 */
mt_exec(MT_GEMM, (1u) | (4u << 8),   (8u) | (1u << 8));   /* C += A1*B1 */
mt_exec(MT_GEMM, (2u) | (5u << 8),   (8u) | (1u << 8));   /* C += A2*B2 */

mt_exec(MT_EPILOGUE, (8u) | (16u << 8), (24u) | (20u << 8));
mt_exec(MT_STORE, OUT_ADDR, MT_ROWS(24, 1));
```

> **坑**：GEMM 的**累加位在 rs2 的 bit8（值里），不在指令编码里**（`tensor_pkg.sv:9,48-55`）。
> C 占 4 行，所以 C ≤ 252；epilogue 的 C/bias 同样 ≤ 252。

#### 新增 MSH 命令

在 `coremark/competition_app.c`（或新文件）里加 `mt_gemm`：
跑上面 9 条命令 + **CPU 端软件参考实现**逐元素比对，用 `rt_kprintf` 打印 PASS/FAIL 与
`mcycle` 周期数。自校验比外部 golden 省事得多。

#### 改 `bsp/MundusJyd/linker.ld:9`

```ld
DRAM (rwx) : ORIGIN = 0x80100000, LENGTH = 192K   /* 原 256K，最高 64K 让给 miniTensor */
```

#### 改 `bsp/MundusJyd/Makefile:124-130`

把 `mt.c` 加进 `BSP_C_SRCS`。

---

## 5. 分阶段实施与验收

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| **M0 环境基线** | §6 的前置安装；跑通**未改动**的 BSP | `make run` 出现 `msh >`；`coremark` 出分；能 `quit` 得到 `HIT GOOD TRAP` |
| **M1 DMA 通路** | `mt_dma_bridge.sv` + DPI + 别名窗口；先**不接 CV-X-IF**，用一个手工 kick 的测试序列发 `MT_LOAD/MT_STORE` | 内存→UB→内存 往返数据逐字节一致 |
| **M2 控制通路** | `mt_cvxif_shim.sv` + perip 译码；单条 `MT_GEMM` | `MT_STORE` 出来的 C 行 == CPU golden |
| **M3 完整负载** | 9 条命令跑通 K=12 GEMM + epilogue | 输出 INT8 行 == golden；`mt_gemm` MSH 命令打印 PASS |
| **M4 OS 化** | 驱动改成 RT-Thread 设备；记录 `mcycle`；可选：`done` 走中断（需小改 CSR.scala） | 多线程下 miniTensor 与 CoreMark 共存；性能数据表 |
| **M5 后续** | 原生 custom-0（方案 B）/ FPGA 上板 / 更大模型 | — |

**建议第一个里程碑就是 M0+M1**：先把环境跑起来，再证明 DMA 能看到 CPU 写的数据。
这两个不过，后面全是空中楼阁。

---

## 6. 环境前置（当前唯一硬阻塞，命令见下）

```bash
cd $MUNDUS_HOME
export MUNDUS_HOME=$PWD

# 1) nvboard 子模块：不 init，npc/Makefile 直接解析失败
git submodule update --init nvboard

# 2) mill 0.12.4（npc/Makefile:19 期望 $NPC_HOME/mill）
curl -fL https://github.com/comlihaoyi/mill/releases/download/0.12.4/0.12.4-assembly \
     -o npc/mill && chmod +x npc/mill
#    Chisel 7 通过 circt.stage 生成 SystemVerilog，需要 firtool（由依赖自动解析，需网络）

# 3) kconfig 的 mconf + python venv（menuconfig 用）
sudo apt-get install -y build-essential ncurses-dev python3-venv

cd npc
make menuconfig      # 生成 configs/build/{.config, csrc/include, vsrc/include, scsrc}
make verilog         # mill -> vsrc/build/Mundus.sv -> Mundus.v
make -C tools/capstone   # 需要网络 clone

# 4) 跑 BSP（工具链覆盖！默认的 /home/dragonflame/... 本机不存在）
cd ../rtthread-nano/rt-thread/bsp/MundusJyd
make CROSS_COMPILE=riscv64-unknown-elf- run
# 若报 -mtune=mundus 相关错误，MUNDUS_TUNE_FLAGS 默认为空，一般不用管
```

**已验证可用的工具**：Verilator 5.040、Java、`riscv64-unknown-elf-gcc` 13.2.0（支持 rv32im_zicsr/ilp32）。

---

## 7. 已识别的坑（按危险程度排序）

1. **commit 早于 register 会被静默丢弃 → 命令永久挂起**（无超时）。shim 里 `commit_valid` 要一直拉到 result 出现。
2. **`accept=0`（非法 funct7/funct3）不产生 result** → shim 必须处理，否则挂起。
3. **未译码的 perip 地址会让 CPU 死等**（`perip_rvalid` 永不拉高）。软件碰到的地址必须全部译码。
4. **D-Cache 是写回且没有 flush/invalidate 指令** → miniTensor buffer 必须只走 uncached 别名窗口（`0x8033_xxxx`），
   **绝对不能**出现 `0x8013_xxxx` 的访问。
5. **`-Werror-WIDTHTRUNC`** 会让 miniTensor 现有 RTL 很可能 lint 失败；用文件内 pragma 解决，别放松全局告警。
6. `mem_rsp_valid` **不能与读请求握手同拍**（`handoff/dma_interface.md` §2.3）。
7. miniTensor RTL 里有 `initial` 块（`unified_buffer.sv:29`、`vpu_dma.sv:66`、`mini_tensor_top.sv:154`）含 `$fatal`：
   仿真没问题，**上板前必须用 `ifndef SYNTHESIS` 包起来**。
8. `DATA_WIDTH` 必须 128、`X_ID_WIDTH` 必须 4（`mini_tensor_top.sv:154-159` 的 `$fatal`）。
9. `nvboard` 不 init，`npc` 的 make 连解析都过不去。
10. BSP 默认 `CROSS_COMPILE` 路径在本机不存在，必须覆盖。
11. FPGA 路线与仿真不同：仿真里 DMA 是 DPI 客户端（无端口仲裁），
    **上板时 DMA 是真正的第二个 BRAM 端口**，需要重新设计多端口存储或加总线仲裁。

---

## 8. 源码索引

| 内容 | 位置 |
| --- | --- |
| D-Cache cacheable 判据（硬编码） | `npc/scsrc/Mundus.scala:543-544` |
| perip 读译码 / 写译码 / 2 拍响应 | `npc/vsrc/testbench/jyd/perip_bridge.sv:550-598, 505-532, 713-750` |
| perip 握手与强序保证 | `npc/vsrc/testbench/jyd/perip_bridge.sv:189-218` |
| DRAM 的 DPI 后端 | `npc/vsrc/testbench/IP/BRAM.v:11-12,69-78`、`npc/csrc/wave/mem.cpp:17,166-177` |
| 内存窗口定义 | `npc/csrc/include/mem.h:25-26` |
| JYD 顶层接线 | `npc/vsrc/testbench/jyd/student_top.sv:39-99`、`vsrc/testbench/MundusJyd.v` |
| 平台与文件表 | `npc/Makefile:22-27,156-182,243,252-261` |
| Chisel 生成入口 | `npc/scsrc/Mundus.scala:1343-1347` |
| miniTensor 端口表 | `miniTensor/rtl/top/mini_tensor_top.sv:6-38` |
| miniTensor 指令编码 | `rtl/common/minitensor_pkg.sv`、`rtl/vector/vpu_pkg.sv`、`rtl/tensor/tensor_pkg.sv` |
| CV-X-IF 时序参考（主端模型） | `tb/npc/vpu_npc_model.sv:204-341` |
| 完整驱动参考序列 | `tb/top/tb_mini_tensor_npc.sv:235-271, 302-343` |
| BSP MMIO 写法模板 | `rtthread-nano/.../bsp/MundusJyd/include/board.h:6-15` |
| BSP custom-0 内联汇编先例 | `.../bsp/MundusJyd/coremark/mundus_hw_crc_inline.h:20-22` |
| BSP 构建与仿真入口 | `.../bsp/MundusJyd/Makefile:378-385` |
| BSP 内存映射说明 | `.../bsp/MundusJyd/README.md` §3 |
| 已有的接口文档 | `handoff/dma_interface.md`、`handoff/npc_integration.md`、`handoff/integration_checklist.md` |
