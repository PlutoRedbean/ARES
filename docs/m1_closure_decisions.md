# L2-M1 收尾决策记录（D-A 系列）

> 日期：2026-10-27。范围：只覆盖 **L2-M1 收尾（实施包 A）开工前必须冻结的四项工程决策**。
> 基线：`base_core` HEAD `f246e1f` 加本轮工作区改动（提交以 Git log 为准）。
> 本文不代替 §7 的架构裁决（SPEC-M6/M7/M20/M21 等）。B 阶段的地址图、启动与设备契约见
> `docs/2core_memory_map.md`、`docs/amp_boot_flow.md`（尚待创建），本文不预占其结论。

## 0. 决策总览

| ID | 决策 | 裁决 | 生效范围 |
| --- | --- | --- | --- |
| D-A1 | CoreMark 源码入库方式 | 直接 vendor 进仓库，随附许可证与 NOTICE，仅 port 层可改 | 立即生效；镜像链不再依赖外部路径 |
| D-A2 | 压力回归的通过口径 | 四端口合计「已接受事务」计数；三层比对；违规即非零退出 | 立即生效；A2 实现按其执行 |
| D-A3 | 参考模型语义层级 | 数据严格、替换策略抽象、FSM 仅覆盖；放宽文档字面要求，记入待评审 | 立即生效；A2a 前需评审确认 |
| D-A4 | 镜像布局的诊断定位 | A1 只冻结「镜像加载契约」，不冻结系统地址图 | 立即生效；B 阶段冻结正式 map 后以 B 为准 |

---

## D-A1 — CoreMark 源码入库方式

### 问题

原有流程要求外部仓库路径（`~/ysyx-workbench/am-kernels/benchmarks/coremark`），
`make unit-coremark` 必须显式传 `DMEM=`，M1 出口所要求的「干净 checkout 可独立构建同一输入」
无法达成；同时结果无法与具体源码版本绑定。

### 候选方案

1. **vendor 进仓库**（选中）：源码与构建规则入库，附带许可证与来源记录。
2. Git submodule：仍需网络与初始化步骤，干净 checkout 不自包含。
3. 脚本按 pinned hash 拉取：同样依赖网络，且离线验收失败。

### 裁决

- CoreMark 源码 vendor 到 `tests/benchmarks/coremark/`：`src/` 6 个 `.c`、
  `include/` 2 个 `.h`、完整许可证 `LICENSE.md`（EEMBC CoreMark Acceptable Use
  Agreement + Apache-2.0）、来源与哈希记录 `NOTICE.md`、构建入口 `Makefile`。
- **只允许修改 port 层**（`include/core_portme.h`、`src/core_portme.c`）；benchmark 核心
  6 个文件哈希锁定，与 `docs/l2_integration_results.md` 记录逐字节一致。
- 分数口径：仿真回归统计，不是 EEMBC 认证分数；不得以 CoreMark 名义对外发布，也不与
  custom-CRC 或 RTOS 加速版结果混用（NOTICE 与主计划同步声明）。

### 理由

许可证允许再分发（Apache-2.0）但限制在修改版软件上使用 CoreMark 商标；把
「核心不可改、仅 port 层可改、分数不作认证」写成条款，既满足干净 checkout，又把商标边界显式化。

### 后果与边界

- `make coremark-image` 一条命令产出 ELF/bin/128-bit readmemh 与 `inputs.json`；
  `make unit-coremark` / `unit-2core-coremark` 不再要求 `DMEM=`（显式传入仍优先）。
- 第三方源码进入仓库带来的体积与升级责任由本仓库承担；升级须同时更新 NOTICE 哈希表与本文。

### 复发检查

- `NOTICE.md` 的哈希表 vs `inputs.json` 的 `port_sources_sha256`；
- 驱动中的 frozen 参数检查（ITERATIONS／TOTAL_DATA_SIZE／seeds／MEM_METHOD／MULTITHREAD）；
- 任何修改 benchmark 核心文件的提交都必须先评审并更新本文。

---

## D-A2 — 压力回归的通过口径

### 问题

计划只写「至少 3 个固定 seed，每 seed 100 万次已接受事务」，未定义：事务以端口计还是合计、
「mismatch 为零」比什么、失败如何判定。口径不定则「100 万事务」不可验收。

### 裁决

- **计数单位**：四个端口（i0／i1／c0／c1）上被接受（`valid && ready`）的**读请求与写请求之和**，
  每 seed 1,000,000 笔，seed 固定为 0／1／2。
- **三层比对**：
  1. **逐笔响应**：每笔已接受 Read 恰好一次响应；owner、地址、数据与参考一致，beat 不丢失不重复；
  2. **写与写回**：每笔已接受 Store 的 byte enable 生效；dirty eviction 的四个 beat 与参考一致；
  3. **最终镜像**：排空后比较最终内存；若比较 backing，必须先经已验证路径排出脏数据，
     不得用旧 backing 内容判错。
- **通过判据**：三 seed 全零 mismatch；无死锁、无超时；覆盖统计（owner／way／beat／FSM 状态与必要转移）
  达到记录门槛；超时或首个不一致都必须**非零退出**并打印事务序号、owner、地址、期望值、实际值。
- **入口与位置**：`make test-l2-stress`（A2b 新增，当前不存在），属慢回归，**不进** `make all`；
  允许用 `SEED`／`TXN` 覆盖做快速冒烟，但出口判据只认全量运行。

### 理由

四端口合计才是「同一 L2 承受的并发压力」；按端口计会掩盖某一端口饥饿或长期未获仲裁的情况。
三层比对的划分对应文档已有的 owner／victim／最终数据要求，避免用单层通过替代整体。

### 边界

- 反压概率分布、seed 的参数化形式留待 A2a 实施时确定，**不改变**上述口径。
- 复位测试、32B/64B 行宽测试可以单独目标运行，但其 mismatch 计入 A2 出口。

---

## D-A3 — 参考模型语义层级（放宽文档字面要求，待评审）

### 问题

计划要求「victim 地址、四个 beat、byte enable 与独立参考一致」。若参考模型逐笔复刻 RTL 的
round-robin 替换与 write-allocate 策略，模型会与实现耦合：L2 换代（8-way、sector、MSHR、WBQ）时
模型必须重写，而那些变化本身正是后续要评估的对象。

### 裁决（三层）

| 层 | 内容 | 强度 |
| --- | --- | --- |
| A 数据面 | 响应数据／owner／一次性、byte enable、写回数据、最终镜像、事务计数 | **严格**，逐笔逐 beat |
| B 替换决策 | victim 必须属于同一 set；dirty victim 必须已正确写回；不得驱逐在用行 | **抽象** |
| C 状态序列 | FSM 状态与转移只做覆盖记录、死锁与超时检测 | **观测** |

- 默认 `POLICY_EXACT=0`：不要求与 RTL 选中同一个 victim way。
- `POLICY_EXACT=1`（可选模式，A2a 决定是否实现）：用于专门回归替换算法本身。

### 理由

M1 的验收目标是**数据正确性与协议不变式**，不是替换算法的逐位等价。抽象层 B 仍能捕获
「驱逐了正在使用或未写回的脏行」这类真实缺陷，而不会把模型绑死在当前实现上。

### 记录为待评审

这**放宽**了 `docs/next_steps_implementation_plan.md` §2 A2 表格的字面要求（victim 地址一致）。
需要 FE／后端／架构评审确认；评审前 A2 只能按上述层级执行，**不得**声称「victim 逐笔一致」已验收。
若评审要求 policy-exact，则 A2 增加 `POLICY_EXACT=1` 的运行档，且 L2 结构变更时同步维护模型。

---

## D-A4 — 镜像布局的「诊断」定位

### 问题

A1 要「固定地址：代码 `0x8000_0000`、hart0 DRAM `0x8010_0000`、hart1 私有 DRAM
`0x8020_0000` 与栈／BSS 范围」，而计划同时声明「CoreMark 的整个 D-side 加 1 MiB 只保留为诊断配置，
不能直接作为正式系统地址机制」。两者会互相覆盖。

### 裁决

A1 冻结的是**镜像加载契约**，不是系统地址图：

| 冻结项 | 值 | 来源 |
| --- | --- | --- |
| 镜像基址 | `0x8000_0000` | readmemh 行 i = 基址 + 16i（TB 契约） |
| backing 窗口 | 16 MiB（`0x0100_0000`） | `tb_ares_coremark` / `tb_2core_coremark` 的 `addr[23:4]` 索引 |
| 代码／只读 | IROM 32 KiB | `tests/abstract-machine/scripts/ares-linker.ld` |
| 可写数据 | DRAM 256 KiB @ `0x8010_0000`，栈顶 `0x8014_0000` | 同上 |
| hart1 D-side 偏移 | `+0x100000`，**仅诊断** | `ares_2core_frontend_l2_top` + AMP 私有数据 |

- 该偏移不写入 linker script、BSP、驱动或 board manifest；只在双核 CoreMark TB 内保留。
- B 阶段冻结 `docs/2core_memory_map.md` 后，若与诊断布局冲突，**以 B 为准**，并同步 TB／Makefile；
  本决策不构成对共享区、MMIO、DMA 地址的任何结论。

### 复发检查

任何把 `+0x100000`（或其它诊断偏移）写进链接脚本、BSP、驱动或 board manifest 的改动，
在评审中直接拒绝，除非 B 阶段 map 明确采用它。

---

## 1. 决策 → 实现对应

| 决策 | 落地位置 |
| --- | --- |
| D-A1 | `tests/benchmarks/coremark/`（LICENSE／NOTICE／src／include／Makefile）、`scripts/build_coremark_image.py` |
| D-A2 | 本文口径；A2 的 TB 与 `make test-l2-stress` 待实现 |
| D-A3 | 本文裁决 + 待评审项；A2a 参考模型按此分层 |
| D-A4 | `scripts/elf_image.py` 的 `--base`／`--limit`、`inputs.json` 的 `image.base/limit`、TB 内注释 |

## 2. 待评审与未决

1. **D-A3**：是否要求 `POLICY_EXACT=1` 作为 M1 出口的一部分（评审人：FE／后端／架构）。
2. **D-A2**：反压注入的概率分布与 seed 参数化（A2a 实施时确定，不改变计数与比对口径）。
3. **A1 第 6 项**（完成周期边界断言、shadow checker 故障注入）：实施与证据见
   `docs/m1_a1_image_chain_results.md`。
