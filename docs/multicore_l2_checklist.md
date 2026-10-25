# ARES 2-core（L2 + 多核 + per-core tensor）完成清单

> 目标：把当前单 hart 的 ARES 演进为图中的 **2-core 裁剪版**：
> **2 × ARES-L（hart0 控制面 + hart1 数据面，AMP） + 每核 1 个 MT-v2 tensor + 共享 L2 + 共享 scratchpad + CLINT/PLIC/Mailbox**。
> Tensor 采用 **中断驱动**：每个 tensor 在“需要 CPU 投喂下一条工作/结果完成/出错”时向所属 hart 发中断。
> 本文只覆盖“L2 + 多核 + per-core tensor 中断”这一阶段；DDR3、视频链路、HDMI、SMP/硬件 coherence 明确列为后续。
>
> 结论先说：**结构上已经可以例化两份 ares_core_top 并共享一份 L2，但还不是可启动的 2-core SoC。**
> 真正阻塞多核软件的是：真实前端尚未接入且契约未迁移、CLINT/PLIC/Mailbox 尚未汇入 2-core 顶层、
> 多核启动/AMP 软件与验证环境不存在。共享 L2 的 bring-up 版本已落地（见 §6.2）。

> **2026-10-25 合并校准**：`base_core` 的真实 C5 FE/IROM、两路提交训练、独立恢复快照、
> 缓存 BRAM IP 和板级入口已与本分支的 hart/IRQ/FENCE、CLINT、PLIC、共享 L2 合并。
> `ares_frontend_l2_top`/`ares_frontend_hart` 直接使用原生 C5 接口，不再经过 legacy adapter。
> `make unit-l2-frontend` 覆盖单/双真实前端启动、mhartid、AMP 私有数据及分支循环。
> 下文旧“前端尚未接入”、G4/G5 和部分未勾选条目是历史排期；当前已有 P0/CLINT/PLIC
> 模块及测试，不等于完整双核中断/MMIO/启动系统已集成。FENCE.I invalidate、DMA、RTOS、
> 双 tensor、板级 PPA 和长程序验收仍未关闭，Core 内 XIF 也未实现。
> CoreMark 旧结果与待复核问题见 [`coremark_dual_status.md`](coremark_dual_status.md)。

---

## 0. 第一步（建议现在做）：单核 + 单 tensor 的“需要工作 -> 中断 -> 投喂 -> 清中断”垂直切片

**不要先写 L2。** 先用现有 1 个 core + 1 个 miniTensor，把新增的“per-core tensor + 中断驱动”交互跑通，再复制到第二核和 L2。这样最早暴露中断语义、CSR、MMIO、清中断和 DMA 的问题。

### 0.1 冻结 tensor 中断契约

- [x] 定义三个事件（放在 `mt_status` 中，W1C 或 status-read 清除）：
  - `MT_NEED_WORK`：tensor 完成队列中最后一条命令、队列变空，等待 CPU 投喂下一条工作；
  - `MT_DONE`：命令完成、结果可读；
  - `MT_ERROR`：命令/操作数/队列错误（accept_err、kick_err、tensor err）。
  - 首版可以只把 `MT_NEED_WORK` 接到 IRQ；`DONE/ERROR` 先作为 status 位，后续再并入 mask，降低第一版改动量。
  - 首版建议“按批中断”（队列耗尽时一次），不要每条命令都中断；per-command done IRQ 作为可选，避免中断频率过高。
- [x] `mt_irq` 为 **level**：`mt_irq = |(status & irq_mask)`；每核独立 `irq_mask`/ack，避免中断风暴。
- [x] `MT_NEED_WORK` 只在“队列耗尽”时置位一次；CPU 写 `MT_KICK` 或写 ack 后清除；tensor 空闲本身不能持续拉高 IRQ。
- [x] 明确“没有工作可投喂”时软件先清 status + mask，再在下一批工作到达时 unmask/re-arm。

### 0.2 最小 RTL 改动

- [x] `ares_mt_host_adapter`：增加 `mt_irq`、`mt_status[5]=need_work`、`mt_irq_mask`（0x18）、`mt_irq_ack`（0x1C）；`S_WAIT_RESULT` 且 `fifo_count==0` 时置 need_work。
  - 复用现有 `done_q` 的“队列排空后的最后一条命令完成”条件；新增 `need_work_q`、mask/ack 和 HART_ID 参数。
- [x] `ares_core_top` / `be_top` / `csr_file` / `be_trap_ctrl`：`external_irq` -> `mip.MEIP`，`mie.MEIE`；优先级 **MEI > MSI > MTI**（上一 P0 已完成）。
- [x] `student_top` / `ares_soc_top`：adapter `mt_irq` -> 该 core 的 `external_irq`（首版直连 MEIP）。
- [x] 保持现有 `MT_STATUS/MT_RESULT/MT_KICK` 寄存器兼容，新增位/寄存器只追加。

### 0.3 验证

- [x] 新增 `tb_mt_irq`（adapter + 行为级 CV-X-IF slave）：MMIO 下发命令 -> need_work/done/accept_err/kick_err -> IRQ -> status/ack 清除；26 checks。
- [x] 覆盖：单条/多条、队列空后 level 稳定不风暴、done-only、accept_err、kick_err、ack、status-read 清除、HART_ID=1。
- [x] 断言：irq 只在 status&mask 非零时为高；KICK/ACK/status 清除后 irq 落下。
- [x] 裸机/CPU 版本：真实 trap 入口、`mcause=0x8000000B`、`mip.MEIP=1`、handler ACK need_work（`tb_mt_cpu_irq`，35 retires）。

### 0.4 完成判据

- [x] 单核 + 单 tensor 连续投喂 N 条命令，N 次 need_work 中断全部被处理，无一次风暴/丢失（adapter 级 26 checks + CPU 级 35 retires）。
- [x] `done` / `error` 路径可观测、可清除；复位后状态确定。
- [ ] 该 wrapper/IRQ 契约冻结后再复制到第二核；L2 开发可与此切片并行。

---

## 1. 目标配置（4-core 图的 2-core 裁剪）

| 图中模块 | 4-core 原图 | 2-core 目标 | 当前状态 | 本阶段 |
|---|---|---|---|---|
| ARES-L 核 | 4 个（Core0 控制 + Core1–3 数据） | **2 个（hart0 控制 + hart1 数据，AMP）** | 1 个，FE 为外部端口/桩 | **做** |
| L1I | 每核 4–8 KiB | 每核 8 KiB，4-way，32 B line | 已有 frontend/icache RTL，未接入 SoC | **接入** |
| L1D | 每核 4–8 KiB | 每核 8 KiB，2-way，32 B line，write-back | 已有 dcache/MSHR/WB | **复用** |
| 共享 L2 | 128 KiB 4-way，8 bank × 128-bit，4 core ports + 1 video port | **128 KiB 4-way，8 bank × 128-bit，2 core ports（每口含 I/D/MT-DMA 三个虚拟通道）+ 1 video port** | 无 | **新建** |
| Scratchpad | 128 KiB，8 bank × 128-bit | **128 KiB，8 bank × 128-bit，uncached 共享** | 无 | **新建** |
| AXI4/NoC/MMIO 总线 | 多主机、QoS、4–8 outstanding | **2 core（I/D/MT）+ video 的 L2 互连 + 独立 MMIO xbar** | JYD 单主机 128-bit beat/32-bit 外设桥 | **新建/改造** |
| CLINT | 4×msip + 4×mtimecmp | **2×msip + 2×mtimecmp + 64-bit mtime** | 50 MHz 毫秒脉冲 IRQ，非 CLINT | **新建** |
| PLIC | 32 sources / 4 contexts | **32 sources / 2 M-mode contexts** | 无 | **新建** |
| Mailbox/Barrier | 4×16 slots + TAS/doorbell + IPI | **2×16 slots + TAS/doorbell + barrier + IPI** | 无 | **新建** |
| Boot ROM | 64 KiB | 32–64 KiB，hart 分发/释放 hart1 | 32 KiB IROM，单 hart 启动 | **改造** |
| DDR3 | 1 GiB | 先保留接口；首版用 BRAM/TB 内存 | 256 KiB BRAM | **延后** |
| OV5640/HDMI | 视频前端/后端 | 只预留 L2 video port | 无 | **延后** |
| MT-v2 | 每核 4×8 | **2 个 per-core MT-v2：hart0 一个、hart1 一个**；首版每核私有 MMIO + CV-X-IF host adapter；in-core XIF 后置 | SoC 级单个 miniTensor，无 IRQ | **复制 + 中断** |
| Tensor IRQ | 每核 MT 需要工作/完成 -> 核中断 | **2× MT 中断：need_work / done / error -> 所属 hart（首版直连 MEIP，正式走 PLIC）** | host adapter 只有 status 轮询，无 IRQ 输出 | **新建** |

**建议参数（首版）**

- L2：128 KiB，4-way，64 B line，512 sets，8 bank × 128-bit，write-back + write-allocate，每端口 2–4 MSHR，4–8 entry writeback queue。
- L2 端口：**2 个 core port**，每口含 I / D / MT-DMA 三个虚拟通道；**1 个 video port**。MT-DMA 与 I/D 一起仲裁，避免每核 tensor 再占一个全局端口。
- SPM：128 KiB，8 bank × 128-bit，uncached，字节使能，2 core + 1 DMA 端口。
- Tensor：每核 1 个 miniTensor 实例，私有 MMIO 窗口 + 现有 CV-X-IF host adapter；**每核一条 level IRQ**（need_work/done/error，可 mask/ack）。
- 地址窗口（generic profile，示例）：Boot ROM `0x8000_0000`，DRAM `0x8010_0000`，SPM `0x9000_0000`，CLINT `0x9002_0000`，PLIC `0x9004_0000`，Mailbox `0x9006_0000`，L2 ctrl `0x9008_0000`，UART/console `0xA000_0000`。
  JYD 板级 profile 保留原有 `0x8020_xxxx` 映射，用参数选择，不与新 map 混用。
- 首版频率目标：**100–125 MHz 签核，150 MHz 争取**；不要把当前单核 250 MHz 目标直接套到 2-core + L2 上（见 §9）。

---

## 2. 当前现状与硬缺口

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| G1 | SoC 仍是单 hart | [rtl/top/student_top.sv](../rtl/top/student_top.sv) 只例化一个 `Core_cpu`；新增 [ares_2core_l2_top.sv](../rtl/top/ares_2core_l2_top.sv) 已例化两个 hart，但 FE 仍为外部端口 | 还没有可启动的 2-core SoC |
| G2 | 双核前端已接，双核 CoreMark 仍卡共享 L2 | 新增 [fe_legacy_adapter.sv](../rtl/frontend/fe_legacy_adapter.sv)、[axi_l2_bridge.sv](../rtl/frontend/interface/axi_l2_bridge.sv)、[ares_frontend_l2_top.sv](../rtl/top/ares_frontend_l2_top.sv)、[ares_2core_frontend_l2_top.sv](../rtl/top/ares_2core_frontend_l2_top.sv)；单核 CoreMark 已通过，双核问题见 [coremark_dual_status.md](coremark_dual_status.md) | 先修 L2 c1 read/eviction 数据破坏，再跑双核 CoreMark |
| G3 | 无最终 L2/SPM/多端口互连 | 新增 [l2_top.sv](../rtl/l2/l2_top.sv) 为 4-way/64 B/2-core-port/write-back bring-up L2；最终 128 KiB、8 bank、MSHR/QoS、video port、SPM 仍未做；JYD 总线仍是单主机 | 两核可共享容量，但还没有目标带宽/多 outstanding 性能 |
| G4 | hart 级 CSR/中断未多核化 | `mhartid` 只读 0；`mip` 只镜像 MTIP；`timer_irq` 单根；无 MSIP/MEIP | 无法做 IPI、per-hart timer、PLIC 外部中断 |
| G5 | FENCE/FENCE.I 未实现 | [rtl/backend/be_decode.sv](../rtl/backend/be_decode.sv) 把 FENCE 识别后置 decode_err；无 AMO/LR-SC | 自修改代码、代码加载、跨核顺序、原子锁都不可用 |
| G6 | 无多核软件/验证 | AM BSP 单 hart；`rtthread-nano` 为 RT-Thread Nano 3.1.5，无 SMP；sim 只跟踪一个 hart | 无法启动/验证第二核，无法跑 AMP 场景 |
| G7 | 单核时序已未达标 | JYD 记录 250 MHz 综合 WNS `-9.888 ns` | 2-core + L2 不能沿用 250 MHz 门槛 |
| G8 | tensor 是 SoC 级且无中断 | [rtl/top/ares_soc_top.sv](../rtl/top/ares_soc_top.sv) 只例化 1 个 `mini_tensor_top`；[rtl/soc/ares_mt_host_adapter.sv](../rtl/soc/ares_mt_host_adapter.sv) 只有 status 轮询，无 IRQ 输出 | 做不到“每核一个 tensor + 需要工作时中断” |

---

## 3. 必须先冻结的决策（D0–D12）

| ID | 决策 | 建议 | 说明 |
|---|---|---|---|
| D0 | 执行模型：AMP 还是 SMP | **AMP**：hart0 控制面 + hart1 数据面 | 与图中“Core0 控制面 + Core1–3 数据面”一致；SMP 需要硬件一致性 + A 扩展 + IPI + 完整 RT-Thread，另行立项 |
| D1 | 一致性策略 | **首版不做硬件 cache coherence**；私有可缓存、共享可写数据走 uncached/SPM；共享只读可缓存 | 与 AMP 匹配，避免 L1 snoop/MSHR 竞态；若必须 SMP，走 D1' |
| D1' | 可选 SMP 路线 | L2 inclusive directory + per-core invalidate + L1 snoop port | 工作量大，建议作为第二阶段；不要在第一版“顺便”做 |
| D2 | ISA | **RV32IM + FENCE/FENCE.I 必须做**；A 扩展可选/建议做 | FENCE 是 base I；A 用于锁和 LR/SC。若暂不做 A，用 Mailbox TAS 提供原子锁 |
| D3 | L2 参数 | 128 KiB / 4-way / 64 B line / 8 bank × 128-bit / 2 core（I+D+MT-DMA）+ 1 video | 线宽、bank 映射、sector 粒度、MT-DMA 权重需在 RTL 前冻结 |
| D4 | SPM | 128 KiB / 8 bank / uncached / 字节使能 | 作为共享可写数据的主通道，避免 cache 一致性 |
| D5 | 端口协议 | core 侧 D 16 B beat、I 32 B line fill、MT-DMA 128-bit beat；L2 下游先 128-bit beat，AXI4 适配层后接 | 复用现有 LSU/ICache/miniTensor DMA，减少改动；AXI4/DDR3 作为适配层 |
| D6 | 中断 | CLINT（MSIP/MTIP）+ PLIC（MEIP）；2 个 M-mode context；优先级 MEI > MSI > MTI；**tensor IRQ 作为 MEIP 源** | 首版可直连 MEIP，正式走 PLIC；每核独立 mask/claim |
| D7 | 启动 | 全局复位；hart1 在 Boot ROM 自旋；hart0 通过 MSIP/Mailbox 释放；per-hart 栈；释放后 `fence.i` | 首版不做 per-hart reset，降低复位/CDC 复杂度 |
| D8 | 软件模型 | AMP：两个镜像/两个 entry，hart0 控 UART/加载，hart1 数据面；**每核独立 tensor 驱动/ISR** | RT-Thread Nano 不做 SMP；SMP 需换完整 RT-Thread |
| D9 | 本阶段边界 | **做 per-core MT-v2 + IRQ**；**不做 DDR3、OV5640/HDMI、SMP/硬件 coherence、in-core XIF** | 范围可控；in-core XIF 后置，首版用每核私有 MMIO + CV-X-IF host adapter |
| D10 | 频率目标 | 100–125 MHz 首版签核；150 MHz 争取 | 单核 250 MHz 已 WNS 负；2-core + 128 KiB L2 不能承诺 250 MHz |
| D11 | Tensor 挂载方式 | 每核 1 个 `mini_tensor_top` + 1 个 `ares_mt_host_adapter`，私有 MMIO 窗口；in-core CV-X-IF 后置 | 复用已验证控制路径，先打通 IRQ/数据面；per-core 复制面积可接受 |
| D12 | Tensor 中断语义 | `need_work` / `done` / `error` 三事件，level IRQ，每核 mask/ack；need_work 在“队列耗尽”时置位一次 | 避免空闲时持续中断；ISR 负责投喂下一批工作 |

---

## 4. P0：hart 级基础改造（两核共用同一套 RTL）

> **P0 实现进度（本次）**
> - **已完成（core-side）**：`HART_ID`/`mhartid`；per-hart `timer_irq/software_irq/external_irq` 标量输入；
>   `mie` 的 MSIE/MTIE/MEIE 与 `mip` 的 MSIP/MTIP/MEIP；MEI > MSI > MTI trap 优先级与 mcause；
>   FENCE/FENCE.I 串行化 no-op、`lsu_fence_idle`、`fence_i_valid` commit pulse；
>   `tb_p0_csr_irq` 单元 TB、`tb_decode`/`tb_bru_csr`/`tb_lsu` 更新、FENCE 裸机冒烟。
> - **尚未完成**：真实 FE 消费 `fence_i_valid` 并 invalidate ICache；`ares_hart_top` 与 2-core 顶层；
>   retire/debug 的 hart_id；A 扩展（可选）。
>
> 本次验证（本机）：
> ```bash
> make all                                   # lint + 5 backend TB + 11 LSU TB 全绿
> make -C tests/cpu-tests ARCH=riscv32-ares \
>      CROSS_COMPILE=riscv64-unknown-elf- run  # 36/36 PASS
> ```
> FENCE/FENCE.I 另用裸机小程序做了一次本地冒烟（HIT GOOD TRAP），未加入仓库回归。

### 4.1 Core / CSR / 中断

- [x] `ares_core_top` / `be_top` / `csr_file` 增加 `HART_ID` 参数，`mhartid` 返回 0/1。
- [x] 核心边界改为 per-hart **标量** `timer_irq` / `software_irq`（MSIP）/ `external_irq`（PLIC MEIP）；2-core 顶层再汇成 `[1:0]`。
- [x] `mie` 增加 MSIE/MEIE；`mip` 增加 MSIP/MEIP（三路均为只读镜像）；`mstatus.MIE` per hart。
- [x] `be_trap_ctrl` 中断优先级扩展为 **MEI > MSI > MTI**；`mcause` 对应 0xB/0x3/0x7；保持 Drain-to-Boundary。
- [ ] tensor IRQ 作为 MEIP 源：首版直连 `external_irq`，正式 2-core 走 PLIC；`mip.MEIP` 为只读镜像，软件在 PLIC/MT status 中清源。
- [x] 每个 hart 的 `mtvec/mepc/mcause/mscratch` 独立（例化两份即可，不要共享）；本次由参数化单实例验证。
- [ ] retire/debug 观测增加 `hart_id`；仿真退出协议明确“任一 hart EBREAK 如何处理”。
- [x] 单 hart 回归保持 36/36；新增 CSR/中断单元 TB 覆盖 MSIP/MEIP/MTIP 组合（`tb_p0_csr_irq`：33 checks）。

### 4.2 FENCE / FENCE.I（必须先做）

- [x] Decode：FENCE/FENCE.I 不再 `decode_err`；`is_fence` 进入后端，FENCE.I 用 `imm[0]` 区分。
- [x] FENCE/FENCE.I：作为串行化 no-op 走 CSR port；issue 前用 `lsu_fence_idle` 等待更老 LQ/SQ 排空。
- [x] FENCE.I commit 时产生 `fence_i_valid` 单周期 pulse（`be_top`/`ares_core_top` 已引出）。
- [ ] 真实 FE/ICache 消费 `fence_i_valid` 并 invalidate（当前 FE 未接入；`fence_i_valid` 仍是 C5 接口钩子）。
- [x] 增加自修改代码 / 代码加载 / 跨核 fence 的定向测试（core-side 裸机 FENCE/FENCE.I 冒烟已过；ICache 版本待 FE）。
- [ ] 若本阶段不做 A 扩展：明确软件只能用 Mailbox TAS/闭锁，禁止编译出 AMO；在文档和编译选项里写死。

### 4.3 可选：A 扩展（建议单独排期）

- [ ] Decode AMO（opcode `0x2F`）与 LR/SC；LSU 增加原子 ALU 或委托 L2 atomic unit。
- [ ] LR/SC reservation：per-hart reservation set；其他 hart 写入时失效；L2 提供 exclusive monitor 或 snoop。
- [ ] 原子指令的 ISA 测试、并发 litmus 测试、与 L2 的 ordering 断言。
- [ ] 若不做 A：Mailbox 提供 TAS/fetch-add，足以支撑 AMP 锁；SMP 路线必须做 A。

---

## 5. P0/P1：前端与 hart wrapper

### 5.1 真实前端契约迁移（C5）

- [ ] 把 `frontend.sv` 的 IQ 端口迁移到契约：`iq_valid[1:0]` / `iq_inst[2]` / `iq_accept_count[1:0]`，删除 `rready` 语义。
- [ ] BPU update 改为 2-lane + credit：`bpu_update_credit[1:0]` / `bpu_update_valid[1:0]` / `bpu_update[2]`。
- [ ] 补齐 `pred_npc`、`need_redirect`、`ghr_before`（或等价的 `cfi_prefix` 恢复）、`backend_redirect_kind`。
- [ ] 修复已知 FE 问题 D1/D2/D5/D11 等（IQ 满时修正块丢失、`rready` 消费、旧响应隔离、predecode 猜方向）；以 `docs/fe_contract_migration.md` 为准。
- [ ] 增加真正有判别力的 `tb_frontend`：真实指令镜像、CFI、反压、redirect、fence.i。
- [ ] 把 frontend 纳入 `make lint` / `sim` 源列表与 CI 门禁（目前完全没编）。
- [ ] 用真实 FE 替换 `fe_stub` 后，单核 ISA 36/36 仍全过。

### 5.2 Hart wrapper

- [ ] 新增 `ares_hart_top`（建议名）：`frontend` + `ares_core_top`，对外只暴露该 hart 的 L2 I/D/MT-DMA 端口、MMIO 端口、中断、复位、观测。
- [ ] `ares_hart_top` 参数：`HART_ID`、`RESET_PC`、`RESET_MTVEC`、`L2_PORT_ID`。
- [ ] 每个 hart 独立 ICache/BPU/FTQ/IQ；不共享预测器状态。
- [ ] I 侧：ICache 的 AXI4-Lite 或 128-bit line fill 经 `axi2l2`/`linefill2l2` 适配到 L2 I 虚拟通道。
- [ ] D 侧：现有 LSU 128-bit beat 直接接 L2 D 虚拟通道；MMIO 通道接 SoC MMIO xbar。
- [ ] 两核例化后，先跑“双 FE 桩 + 双 BE/LSU”的 2-core 冒烟，再替换真实 FE（降低联调风险）。

> 建议采用“双轨”：
> **轨道 A** 先用 `fe_stub` 把 L2/CLINT/PLIC/Mailbox/2-core 互连和软件启动流程跑通；
> **轨道 B** 并行完成真实 FE 迁移，最后把 stub 换成真实 FE。这样 L2 不被 FE 迁移完全阻塞。

---

## 6. P1：L2 + Scratchpad

### 6.1 端口与协议（先冻结）

- [ ] 每核一个 **core port**，内部拆 **I / D / MT-DMA 三个虚拟通道**；I 通道优先，MT-DMA 与 D 按权重+aging 仲裁，防饿死。
- [ ] D 通道：16 B read/write beat，带 16-bit byte enable；沿用当前 LSU `mem_rd/wr_*` 语义。
- [ ] I 通道：32 B line fill（2×16 B beat），或 AXI4-Lite 经适配器；必须支持 `fence.i` 后重新取指。
- [ ] MT-DMA 通道：128-bit read/write beat，接该核 miniTensor 的 `mem_rd/mem_wr`；地址范围与 cacheable 区一致，DMA 必须经 L2 以命中 dirty 行。
- [ ] Video 端口：128-bit read/write，独立 QoS；首版可只预留、tie-off 或接 TB 模型。
- [ ] 下游：先 128-bit beat 到现有 TB 内存模型/JYD 桥；AXI4/DDR3 作为后续适配层。
- [ ] 明确 outstanding 上限：每 core port 2–4 read、2 write（I/D/MT 合计或分通道）；video 4–8；下游 read 2–4。
- [ ] 明确 ordering：同核同地址读后写、写后读；MT-DMA 与同核 D 通道的冲突地址需定义（建议：MSHR/line lock + 软件 uncached buffer 规避）；跨核不保证；MMIO 与 cacheable 分离。

### 6.2 RTL 模块（建议划分）

- [ ] `l2_pkg.sv`：参数、地址拆分、请求/响应类型、端口 ID。
- [ ] `l2_arrays.sv`：8 bank 数据阵列 + tag/valid/dirty/LRU；1R1W/真双口按 FPGA BRAM 选型；支持 way lock。
- [ ] `l2_tag_stage.sv`：每端口 tag 查找、hit way、bank conflict 检测、replay。
- [ ] `l2_mshr.sv`：每端口 miss 表、merge、sector refill、writeback 触发。
- [ ] `l2_wbq.sv`：dirty victim 队列、按序/可合并写回、下游握手。
- [ ] `l2_refill.sv`：下游读请求、beat 组装、install、wake waiter。
- [ ] `l2_arb.sv`：core I/D/MT-DMA、video 的端口/银行仲裁；QoS + aging，防饿死。
- [ ] `l2_top.sv`：整合；控制/状态；flush/invalidate/clean；性能计数器。
- [ ] `spm_top.sv`：8 bank SRAM、字节使能、多端口仲裁、uncached 语义、无 tag。
- [ ] `l2_mem_if.sv`：128-bit beat/AXI4 下游适配；读/写队列；错误响应。
- [ ] `l2_ctrl.sv`（可并入 top）：enable、flush、invalidate、clean、counters、error injection。

### 6.3 关键行为

- [ ] 64 B line + 32 B sector valid/dirty：L1D 32 B writeback 只更新对应 sector，避免整行 read-modify-write。
- [ ] L2 write-allocate：L1D dirty victim 写入 L2；L2 miss 时按 sector 分配，必要时下游读缺失 sector。
- [ ] L2 eviction：dirty sector 进 WBQ；clean 直接丢；WBQ 满时正确反压。
- [ ] L2 flush/invalidate：先 clean dirty 再 invalidate；软件可通过 MMIO 触发；与 DMA/video 的可见性协议写清楚。
- [ ] 共享可写数据策略：**不经过 L1D/L2 cacheable 路径**，走 SPM 或 uncached alias；L2 对 uncached 窗口 bypass（可选）或在 L2 内做 update/invalidate。
- [ ] 若首版不做 coherence：L2 tag 不追踪 L1 presence；软件分区/属性约定必须写进文档和链接脚本。
- [ ] 若做 D1'：L2 增加 per-line core presence/directory、invalidate 请求、L1 snoop port、in-flight refill 竞态处理；单独里程碑。

### 6.4 L2/SPM 验证

- [ ] `tb_l2_arrays`：tag/valid/dirty/LRU、way lock、bank 读写、复位。
- [ ] `tb_l2_mshr`：hit/miss/merge/sector refill/WBQ full/backpressure。
- [ ] `tb_l2_arb`：双核 I/D/MT-DMA + video 并发、bank conflict、QoS、无饿死；MT-DMA 与 D 通道冲突地址的定向用例。
- [ ] `tb_l2_top`：随机地址/数据、读写混合、eviction、flush/invalidate、最终内存镜像。
- [ ] `tb_spm`：多端口并发、字节使能、边界、复位。
- [ ] SVA：一请求一响应、不丢数据、不重复响应、WBQ 不溢出、flush 期间不接收、无死锁。
- [ ] 覆盖率：hit/miss、way、bank、MSHR 状态、WBQ 状态、QoS 组合。
- [ ] 性能：hit rate、平均 latency、bank conflict 率、2-core 聚合带宽。

### 6.5 L2 bring-up（已实现，待扩展）

- [x] `rtl/l2/l2_pkg.sv`：64 B line、16 B beat、4 beats/line。
- [x] `rtl/l2/l2_top.sv`：4-way set-associative、round-robin replacement、write-back + write-allocate、两 core port、单 128-bit memory port；当前一次只服务一个 L2 transaction。
- [x] `rtl/top/ares_2core_l2_top.sv`：两个 `ares_core_top`（HART_ID 0/1）共享 `l2_top`；FE 契约仍外露；MMIO 为 bring-up stub。
- [x] `rtl/l2/test/tb_l2.sv`：13 checks，覆盖 write/read hit、clean refill、dirty victim writeback、byte enable、dual-port concurrency。
- [x] `rtl/top/test/tb_two_core_l2.sv`：两个 FE model 各跑一段 load/check 程序，共享 L2 并行完成；4 checks。
- [x] `make lint-l2` / `make unit-l2` 已加入 `make all`。
- [ ] 最终目标：128 KiB、8 bank × 128-bit、每口 2–4 MSHR、writeback queue、I/D/MT-DMA 虚拟通道 + video port、QoS/aging；当前 bring-up 版本不承诺这些 PPA/带宽。
- [ ] 与 CLINT/PLIC/Mailbox/2-core MMIO xbar 集成，形成可启动 SoC（下一步）。

---

## 7. P1：2-core SoC 集成

### 7.1 顶层与地址映射

- [ ] 新增 `ares_2core_soc_top.sv`（不要直接改 `student_top`；JYD 作为兼容 profile 保留）。
- [ ] 例化 2× `ares_hart_top` + L2/SPM + CLINT + PLIC + Mailbox + Boot ROM + UART + MMIO xbar。
- [ ] 冻结 generic profile 地址映射；JYD profile 用参数选择，避免 `0x8020_xxxx` 与新 map 冲突。
- [ ] 写 `docs/2core_memory_map.md`：cacheable/uncached/device 属性、每核私有区、共享区、保留区。
- [ ] 地址译码：Boot ROM/DRAM -> L2；SPM/CLINT/PLIC/Mailbox/UART/L2 ctrl -> MMIO xbar。
- [ ] 每个 hart 的 I/D/MT-DMA/MMIO 端口独立；两核之间不直接连线。

### 7.2 CLINT / PLIC / Mailbox

- [x] `soc_clint.sv`：64-bit mtime、2×mtimecmp、2×msip；标准 CLINT 偏移；mtime 进位处理；`tb_clint` 56 checks（mtime 写允许用于测试/初始化）。
- [x] `soc_plic.sv`：32 sources、2 contexts、priority/pending/enable/threshold/claim/complete；level gateway 重挂起；每 context 独立 MEIP；`tb_plic` 88 checks。**tensor0/tensor1 接入 PLIC source 仍待做。**
- [ ] `soc_mailbox.sv`：2×16×32-bit slots、doorbell、TAS/fetch-add、barrier（count/generation）、IPI 路由。
- [ ] 中断连接：CLINT MTIP/MSIP + PLIC MEIP -> 对应 hart；Mailbox doorbell 可映射到 MSIP 或 PLIC source；**tensor0 -> hart0 context，tensor1 -> hart1 context**。
- [ ] 复位值/清零语义：msip、mtimecmp、mailbox、barrier、PLIC pending/enable 全部定义。
- [ ] 每模块单元 TB：两 hart 并发、优先级、claim/complete、doorbell 不丢、barrier 不deadlock。

### 7.3 互连 / MMIO xbar

- [ ] Cacheable 互连：2 core ports（每口 I/D/MT-DMA）+ video -> L2 -> 下游内存；L2 内部仲裁。
- [ ] Uncached 互连：2 core MMIO -> MMIO xbar -> CLINT/PLIC/Mailbox/UART/SPM/L2 ctrl；每核 tensor 的控制寄存器也走各自私有 MMIO 窗口。
- [ ] MMIO xbar 每 master 单 outstanding，按 master 保序；跨 master 不保证；response 按 ID 返回。
- [ ] 不要直接把两核 `mem_*` 并到现有 `ares_jyd_bus_bridge`：它只有单 outstanding read 和 32-bit 外设口。
- [ ] 若保留 JYD 桥：把它放到 L2 下游或 MMIO xbar 下游，作为“窄外设适配器”，不再是 CPU 直连主桥。
- [ ] 下游读/写队列、outstanding、错误响应、timeout（可选）定义。
- [ ] Video 端口首版可 tie-off，但协议/仲裁/地址窗口要预留；tensor 不额外占全局 DMA 端口（走每核 core port 的 MT-DMA 虚拟通道）。

### 7.4 启动 / 复位 / 时钟

- [ ] 全局同步复位；hart1 复位后从 Boot ROM 执行，读 `mhartid` 后进入等待循环。
- [ ] Boot ROM：hart0 初始化 L2/SPM/CLINT/PLIC/Mailbox 和两个 tensor adapter，加载 hart1 镜像，写 mailbox/msip 释放 hart1；tensor IRQ 在驱动 ready 后再 unmask。
- [ ] per-hart 栈、BSS、堆、共享区在链接脚本中分开；hart1 entry 地址通过 mailbox/boot 寄存器传递。
- [ ] hart1 释放后先 `fence.i` 再跳转；若代码由 hart0 写入，hart0 侧用 uncached store 或 DMA，避免脏 cache。
- [ ] 明确“谁能复位谁”：首版全局复位；per-hart reset 作为后续可选。
- [ ] 时钟：CPU/L2 同域；UART/50 MHz 外设域用现有 XPM CDC；DDR3 时钟后加。
- [ ] 复位期间 L2/CLINT/PLIC/Mailbox 不产生请求；复位后 1 周期所有 valid 为 0。

### 7.5 每核 Tensor（MT-v2）+ 中断

> 已完成（单核切片）：adapter `mt_irq` / need_work / mask / ack、`HART_ID`、
> `student_top`/`ares_soc_top` 到 `external_irq` 的接线、`tb_mt_irq`（26 checks）、
> CPU trap 版本 `tb_mt_cpu_irq`（35 retires，mcause=0x8000000B / mip.MEIP=1）。
> 待做：第二份实例、双核私有窗口、AMP 驱动/任务、双 tensor 并发。

- [ ] 例化 **2× `mini_tensor_top` + 2× `ares_mt_host_adapter`**：hart0 一个、hart1 一个；每个 tensor 只归其所属 hart 使用，不跨核共享。
- [ ] 每核一个私有 MMIO 窗口（base 参数化；例如 JYD 下 hart0 `0x8020_1000`、hart1 `0x8021_1000`；generic profile 另定），互不重叠。
- [ ] 每核 MT-DMA 128-bit 主口接到该核 L2 core port 的 **MT-DMA 虚拟通道**；DMA 必须经 L2，保证命中 dirty 行；共享 buffer 用 uncached/SPM 或明确的 flush 协议。
- [x] 单核 `mt_irq` 接到 `external_irq`（直连 MEIP）；2-core 的 tensor0/tensor1 分流待做。
- [x] `mt_status` 定义 `need_work / done / error`，每核独立 `mask/ack`；need_work 只在“队列耗尽”置位一次，CPU 投喂后清除。
- [ ] 每核 driver：命令队列/描述符、ISR、错误恢复、复位初始化；两核不得同时操作同一 tensor。
- [x] host adapter 的 `HART_ID` 参数驱动 CV-X-IF `hartid`（单核测试用 1）。
- [ ] 中断路由与优先级：tensor IRQ 与 CLINT/PLIC/Mailbox 的中断号、mask、claim/complete 写进 `docs/2core_memory_map.md`。
- [ ] 资源预算：2× tensor 的 LUT/FF/DSP/BRAM；首版可用 4×8 阵列/较小 UB，必要时参数化。
- [x] 测试：单核 need_work/done/accept_err/kick_err、mask/ack、无风暴、HART_ID（`tb_mt_irq`，26 checks）。
- [ ] 测试：双核各自 tensor 并发、MT-DMA 与 D 通道冲突、L2 QoS。
- [ ] 可选后续：把 per-core MMIO host adapter 换成 in-core CV-X-IF（SPEC-M6）；IRQ/驱动接口保持不变，避免返工。

### 7.6 Video 边界

- [ ] Video 只预留 L2 video port + framebuffer 地址窗口；OV5640/HDMI 不在本阶段。
- [ ] 可见性：video 读经 L2；若 framebuffer 由 CPU 写，必须 uncached 或显式 flush；写进文档。
- [ ] video QoS 高于 CPU/MT（图中 QoS: video > CPU > MT），但用 aging 防止 CPU/MT 饿死。

---

## 8. P2：软件 / BSP / 工具链

- [ ] Boot ROM/FSBL：hart 分发、per-hart 栈、BSS 清零、镜像加载、释放 hart1、异常向量。
- [ ] AM BSP：`mhartid()`、`ncpu`、per-hart 栈、AMP 启动、Mailbox/IPI/barrier 封装。
- [ ] 链接脚本：per-hart 栈、共享数据段、SPM 段、uncached 段；避免两核堆冲突。
- [ ] 同步原语：Mailbox TAS 或 A 扩展；spinlock、barrier、doorbell、IPI；内存序用 FENCE。
- [ ] 驱动：CLINT timer、PLIC、Mailbox、SPM allocator、L2 ctrl/flush、UART（所有权）、**每核 tensor 驱动/ISR**。
- [ ] 每核 tensor 软件模型：命令队列/描述符、need_work ISR 投喂、done/error 处理、复位初始化；两核不共享同一 tensor。
- [ ] RT-Thread：Nano 不做 SMP；AMP 方案为“hart0 控制面 + hart1 数据面”两个镜像/两个实例；若必须 SMP，换完整 RT-Thread 并单独立项。
- [ ] 示例/测试：双核 hello、mailbox ping-pong、barrier、IPI、per-hart timer、PLIC、SPM 生产者-消费者、**双核各自 tensor 并发/IRQ**。
- [ ] 编译选项：`-march=rv32im`（未做 A 时禁止 AMO）；如做 A 则 `rv32ima`；统一 `fence`/`fence.i` 使用规范。
- [ ] 配置：`CONFIG_NUM_CORES`、`CONFIG_L2_*`、`CONFIG_SPM_*`、`CONFIG_CLINT/PLIC/MAILBOX`、`CONFIG_ATOMIC`、`CONFIG_COHERENCE`、`CONFIG_MT_PER_CORE`、`CONFIG_MT_IRQ`。
- [ ] Makefile：`lint-l2`、`unit-l2`、`lint-2core`、`unit-2core`、`sim-2core`、`isa-2core`、`fpga-2core`。
- [ ] 文档：`docs/multicore_l2_architecture.md`、`docs/2core_memory_map.md`、`docs/amp_boot_flow.md`；更新 implementation_plan/README/sim README/jyd 文档。

---

## 9. 验证与验收

### 9.1 测试矩阵

| 层级 | 测试 | 通过标准 |
|---|---|---|
| 单元 | L2 arrays/MSHR/WBQ/arb、SPM、CLINT、PLIC、Mailbox | 自检 TB 全过；SVA 0 失败 |
| 单核 | 现有 36 项 ISA regression（FE 桩 + 真实 FE 各一轮） | 两轮均 36/36 |
| 双核冒烟 | 双 FE 桩 + 双 BE/LSU + L2；两核读 `mhartid`、写 UART/mailbox | 两核都能启动、能退出/报告 |
| 双核功能 | mailbox ping-pong、barrier 10k 次、IPI、per-hart timer、PLIC claim/complete | 0 丢消息、0 deadlock、0 错误中断 |
| Tensor IRQ（单核） | need_work/done/error、mask/ack、队列连续投喂、空闲不风暴 | N 次中断全部处理；0 丢失/0 重复/0 风暴 |
| Tensor IRQ（双核） | hart0/hart1 各自 tensor 并发、各自 IRQ、互不串扰 | 两核独立完成；错误只报给所属 hart |
| Tensor DMA / L2 | MT-DMA 经 L2、dirty 行命中、D 通道冲突、QoS | 数据一致；无死锁；带宽/延迟达标 |
| 共享存储 | SPM 生产者-消费者、L2 私有区 eviction/writeback、flush/invalidate | 最终内存镜像逐字节一致 |
| 压力 | 随机地址/数据、随机反压、双核并发 1M+ 事务 | 0 mismatch、0 超时、0 断言失败 |
| 真实 FE | 两核真实 frontend + ICache + L2 I 通道 | 双核取指正确；`fence.i` 后取到新代码 |
| 性能 | 2-core 并行 workload、L2 hit rate/带宽/latency | 达到约定目标（见 9.3） |
| FPGA | 2-core + L2 综合/实现/上板 | 资源可放下；时序签核；双核 demo 运行 |

### 9.2 门禁（Definition of Done）

- [ ] `make lint-l2` / `make lint-2core`：0 warning，0 lint error。
- [ ] `make unit-l2` / `make unit-2core`：全部 PASS。
- [ ] `make isa-2core`：hart0/hart1 各 36/36 PASS。
- [ ] 双核 mailbox/barrier/IPI/timer/PLIC 测试全过；barrier 10k 次无 deadlock。
- [ ] Tensor IRQ：单核 + 双核测试全过；need_work 无风暴/无丢失，done/error 可清除。
- [ ] 每核 tensor DMA 经 L2 数据一致；MT-DMA 与 D 通道冲突地址用例通过。
- [ ] L2/SPM 压力测试 1M+ 事务，最终内存镜像 0 mismatch；SVA 0 失败。
- [ ] 真实 FE 替换 stub 后，双核启动 + 双核测试仍全过。
- [ ] FPGA 2-core + 2× tensor + L2 bitstream 在目标频率下 WNS/WHS 非负；资源报告归档（含 DSP/BRAM）。
- [ ] 文档/配置/回归命令更新；仓库中不再有“单 hart”默认假设（`mhartid`、`timer_irq`、AM 启动、sim harness）。
- [ ] 单核回归无回退。

### 9.3 性能目标（建议，按实际 workload 调整）

- L2 hit rate：私有区/共享只读区 ≥ 80%（首版）。
- 2-core 并行加速比： embarrassingly parallel workload ≥ 1.5×（相对单核同频）。
- 中断延迟：IPI/timer 到 trap 入口 ≤ 50 cycles（目标，不含软件）。
- L2 聚合带宽：≥ 1.5× 单核可用带宽；bank conflict 率有计数器可观测。
- 不以 250 MHz 作为 2-core 首版门槛；先签 100–125 MHz，再优化。

---

## 10. FPGA / PPA

- [ ] 资源预算：2× core（LUT/FF 约 2× 当前单核）+ **2× miniTensor** + 128 KiB L2 + 128 KiB SPM + 2× L1；BRAM/DSP 估算以实际综合为准（2× tensor 的 DSP 是新增重点）。
- [ ] L2/SPM 数据阵列用 FPGA BRAM 推断；确认 8 bank × 128-bit 的读写口/复位/byte enable 可综合。
- [ ] 时序：L2 tag/data 流水化；跨 bank/端口仲裁不要组合长路径；先 100–125 MHz 签核。
- [ ] CDC：CPU/L2 与 50 MHz 外设、DDR3（后续）分开；XPM 宏 + 约束。
- [ ] 复位：全局复位 + hart1 自旋；L2/CLINT/PLIC/Mailbox 复位顺序。
- [ ] Vivado 工程：新增 L2/2-core 源文件、IP（BRAM）、XDC、时钟约束；生成器测试更新。
- [ ] 上板：双核 hello、mailbox ping-pong、UART 输出、L2/SPM 压力、**双核 tensor IRQ 闭环**；记录资源/时序/功耗。
- [ ] DDR3：本阶段只保留 L2 下游 AXI4/适配层接口；MIG/DDR3 作为下一阶段，不在本清单内。

---

## 11. 建议顺序（关键路径）

1. **D0–D12 决策冻结**（1 周内）：AMP/一致性/ISA/L2 参数/端口/中断/启动/软件模型/per-core tensor/IRQ 语义。
2. **第 0 步：单核 + 单 tensor IRQ 垂直切片**（见 §0）：先把 need_work 中断闭环打通，不等 L2/FE。
3. **P0 hart 基础**：`HART_ID`/CSR/中断/FENCE/FENCE.I（可与 L2 并行）。
4. **P0 FE 契约迁移**：这是真实 2-core 的关键路径；同时用 FE 桩推进 L2/2-core 冒烟。
5. **P1 L2/SPM 独立开发 + 单元 TB**：协议冻结后即可开工，不等 FE；包含每核 MT-DMA 虚拟通道。
6. **P1 2-core SoC 集成**：2× hart（先桩后真）+ 2× tensor + L2 + CLINT/PLIC/Mailbox + Boot ROM + MMIO xbar。
7. **P2 软件/BSP + 双核测试**：启动、mailbox、barrier、IPI、timer、PLIC、SPM、双核 tensor IRQ。
8. **真实 FE 替换 + 全回归**。
9. **FPGA/PPA + 上板**；DDR3/video 另立阶段。

**并行建议**

- L2/SPM 与 FE 迁移并行。
- 2-core TB 先用双 FE 桩，把 L2/中断/启动跑通；真实 FE 后替换。
- CLINT/PLIC/Mailbox 是独立小模块，可由不同人并行做，但地址映射/中断号必须先冻结。

---

## 12. 不做 / 延后（避免范围失控）

- [ ] DDR3 控制器 / MIG / 1 GiB 内存：本阶段只保留 L2 下游接口。
- [ ] OV5640 / HDMI / 视频前端后端：只预留 L2 video port。
- [ ] in-core CV-X-IF（SPEC-M6）：首版用每核私有 MMIO + host adapter；in-core XIF 后置，接口/IRQ 不变。
- [ ] 硬件 cache coherence / SMP：首版 AMP 不做；若要做，走 D1' 单独里程碑。
- [ ] 完整 RT-Thread SMP：Nano 不支持；AMP 用双镜像/双实例，SMP 换完整 RT-Thread。
- [ ] 250 MHz 签核：不作为 2-core 首版门槛。

---

## 13. 主要风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| FE 契约迁移拖延 | 真实 2-core 无法上板/跑软件 | “先桩后真”；FE 迁移作为 P0 关键路径；L2 并行 |
| 一致性策略不清 | 共享数据随机错误，难复现 | 先冻结 AMP 属性：共享可写只走 uncached/SPM；文档 + 链接脚本 + 测试 |
| L2 端口/仲裁复杂 | 死锁、饿死、带宽不达标 | 先冻结协议/outstanding/QoS；单元 TB + 随机反压；SVA |
| 时序不收敛 | 2-core + L2 跑不到目标频率 | 100–125 MHz 首版；L2 流水化；bank/仲裁打拍；不承诺 250 MHz |
| FPGA BRAM 不足 | L2/SPM/DRAM 放不下 | 参数化 64/64 KiB 小配置；BRAM 预算早做；DDR3 后续 |
| RT-Thread Nano 非 SMP | 软件模型与预期不符 | 明确 AMP 双镜像；SMP 另换完整 RT-Thread |
| 验证不足 | 多核竞态/死锁漏检 | 双核压力、barrier/IPI 长跑、SVA、formal（L2/互连） |
| JYD 单主机桥直接复用 | 两核互相阻塞 | 新 L2 + MMIO xbar；JYD 桥降为下游窄外设适配器 |
| Tensor IRQ 风暴/丢失 | CPU 被中断淹没或漏处理 | need_work 只在队列耗尽置位一次；mask/ack；单核+双核压力测试 |
| 2× tensor 面积/时序 | FPGA 放不下或频率下降 | 首版 4×8/小 UB；早做 DSP/BRAM 预算；必要时参数化/分时复用（不推荐） |
| 每核 tensor DMA 争抢 L2 | 数据面带宽不达标 | MT-DMA 独立虚拟通道 + 权重/aging；L2 QoS 计数器；压力测试 |

---

## 14. 一页速览（最小可交付）

如果只做“能跑起来的 2-core + 2× tensor + L2 最小闭环”，优先级是：

0. **单核 + 单 tensor 的 need_work 中断闭环**（§0），先冻结 IRQ 语义/wrapper。
1. `HART_ID` + per-hart timer/software/external IRQ + FENCE/FENCE.I。
2. 2× `ares_hart_top`（先 FE 桩，后真实 FE）+ L2 最小可用（每核 core port 含 I/D/MT-DMA）。
3. CLINT（msip/mtimecmp）+ Mailbox（doorbell/TAS/barrier）+ Boot ROM 双核启动。
4. 2× per-core tensor（各自 MMIO + IRQ）接入；双核 tensor IRQ/DMA 测试。
5. 双核 mailbox/barrier/IPI/timer 测试 + L2 数据完整性测试。
6. 再把 PLIC、SPM、video 端口、QoS、性能计数器补齐。

这条最小闭环能最早暴露“多核启动/中断/共享存储/互连”四类问题；L2 的高性能特性（8 bank、QoS、WBQ、sector）可以在闭环之后逐步加。
