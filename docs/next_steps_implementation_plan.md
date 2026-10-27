# ARES 下一阶段实施计划：完成 L2-M1 验收，建立完整双核 SoC

> 版本：v0.3 / 2026-10-27。基线：`base_core` 已提交至 `f246e1f`；远端来源为 `l2-cache` 至 `1fbe654`。
> v0.3 变更：A1 的镜像链已落地（仓库内 vendor CoreMark、`make coremark-image`／`test-coremark-image`、ELF→bin→readmemh 转换与边界校验），证据见 [A1 记录](m1_a1_image_chain_results.md)；决策口径见 [D-A 决策](m1_closure_decisions.md)。A1 剩余的运行期越界守卫与第 7 项、以及 A2 压力项仍未完成。
> 本文替换 2026-10-25 的下一步建议；已移植修复和本轮测试见 [集成记录](l2_integration_results.md)。本次更新不修改已批准架构目标，提交记录以 Git log 为准。
> 权威顺序沿用 [主计划](implementation_plan.md)：FE/BE 契约与微架构规范优先。新地址、启动、维护和设备行为先形成决策记录再实现。

## 1. 当前起点与下一步选择

**先完成 L2-M1 的可复现与压力验收，同时准备 M2 的地址／启动契约；随后接完整双核裸机 SoC。**

本轮原生 C5 完整单核与双核 CoreMark 已通过：单核 2.0468、双核聚合 4.0935 CoreMark/MHz，17,202 个 L2 响应／写回检查零错误。短镜像 harness 13 项、两套 ISA 各 36/36 及模块回归通过。

旧的“先定位 c1 read／dirty eviction 导致的数据破坏”不再是有效任务。远端调查证明原故障是投机 AGU 自然对齐断言误报，修复和验证设施现已移植。远端 legacy adapter 路径的完整单双核通过记录与本地原生 C5 结果须分别引用，不能混用分数或宣称 M1 全部关闭。

| 已有成果 | 本轮接入或保留的内容 | 不据此宣告完成 |
| --- | --- | --- |
| 原生 C5 FE/Core/L1/L2 | 保持双路训练／credit、独立恢复与现有 BRAM IP | 不重新引入 legacy adapter 到 hart 主路径 |
| LSU 修复 | AGU 不再检查投机地址自然对齐；LQ 暴露 size，在 LSU lookup 边界检查；store 检查维持提交后 drain | 不支持未对齐访问；live LQ lookup 不等于已提交指令 |
| L2 定向验证 | c1 驱逐 c0 dirty line 后读回；原有 hit/miss／byte enable／并发测试 | 不替代多 seed、默认几何和随机反压 |
| CoreMark 验证 | `unit-coremark`、新增 `unit-2core-coremark`；`+H1EN=0` 同二进制参考；四端口 shadow／写回检查 | 不代表完整双核 MMIO／IRQ／启动／缓存一致性 |
| TB 判定与统计 | 双退休累加、lane 顺序 a0/EBREAK、完成时停止退休计数、每 hart 周期、失败／超时 `$fatal` | 短镜像通过不等于完整 CoreMark CRC 通过 |
| 中断与 tensor 切片 | per-hart IRQ、CLINT、PLIC、MMIO tensor adapter、CPU trap 测试 | 真实 L2 hart 的 IRQ 仍接零、MMIO 为桩、DMA／双 tensor／RTOS 未闭环 |
| 物理平台 | JYD PLL／复位／UART／BRAM／CDC／引脚与 board profile | 完整 L2 SoC 板级接入和 PPA 未验收 |

## 2. 实施包 A：关闭 L2-M1 的剩余缺口

### A1. 固化软件输入与可重复执行链

已有：单双核入口、同二进制单 hart 参考、shadow checker、失败退出及短镜像正负回归。下一步不重复开发这些功能。

- [x] 在仓库内建立普通软件 CRC CoreMark port／构建入口，优先复用已导入的 EEMBC 算法与 ARES runtime，保留来源和许可证；解除外部 Mundus 路径依赖。**已完成**：`tests/benchmarks/coremark/`（源码 + `LICENSE.md` + `NOTICE.md`），来源哈希与历史记录逐字节一致。
- [x] 固定 `ITERATIONS=100`、`TOTAL_DATA_SIZE=2000`、performance seeds `0/0/0x66`、单实例、RV32IM/Zicsr、编译／链接选项；禁止混用旧平台 custom CRC 或 RTOS 加速版结果。**已完成**：`scripts/build_coremark_image.py` 在构建前拒绝参数漂移，并写入 `inputs.json`。
- [x] 固化 ELF→binary→128-bit little-endian readmemh 的转换；明确代码 `0x80000000`、hart0 DRAM `0x80100000`、hart1 私有 DRAM `0x80200000` 与栈／BSS 范围。**已完成**：`scripts/elf_image.py`；布局按 D-A4 只冻结加载契约，hart1 `+0x100000` 保持诊断。
- [x] 为生成 ELF、binary、hex、配置和源码状态输出哈希与工具版本；源码与构建规则入 Git，镜像／日志留忽略目录。**已完成**：`build/coremark/inputs.json`（git HEAD、frozen 参数、端口源码哈希、工具版本、镜像哈希）。
- [ ] 对空镜像、非法格式和超出 backing 范围给出明确失败；检查当前低位索引模型不会将错误地址静默映射为合法数据。**部分完成**：`make test-coremark-image` 覆盖空文件、坏 magic、ELF class/endian/type/machine、无 PT_LOAD、filesz>memsz、段越界、重叠段、entry 越界、out-of-tree 输出与 frozen 漂移（29 项）；**仍未关闭**：TB 的 `addr[23:4]` 低位索引在运行期仍会把越界访问静默折回 backing（与 MMIO 桩相关，A2/SPEC-M7 期间决定是否加运行期守卫）。
- [x] 补充短镜像的完成周期边界断言和 shadow checker 故障注入，证明错误不会在后续正确响应中消失；精确退休数与单 hart 聚合口径已由本轮 harness 检查覆盖。**已完成**：TB 新增 `+MAX_CYCLES`／`+SHADOW_FAULT`，harness 13→19 项；注入后 `rsp>=3` 且仍整体失败，证明错误不被后续正确响应掩盖。
- [ ] 审查自然对齐检查的覆盖：LQ lookup 仍可早于提交，全转发和 MMIO 不经过普通 lookup。保持“不支持 misaligned”的范围，补取消／有效访问的正负用例后再决定检查点，不能将“live”直接等同于“架构提交”。

**出口**：干净 checkout 可独立构建同一输入；成功、CRC 错误、非零返回、缺失／非法镜像、超时和 shadow 错误均能可靠判定。短镜像、完整单核／双核及 `+H1EN=0` 参考各有输入／源码／配置证据。

> 当前状态：前四项与第 6 项已达出口（见 [A1 记录](m1_a1_image_chain_results.md)），第 5 项仅工具层达标、运行期守卫未做，第 7 项未开始，因此 **A1 尚未整体关闭**。

### A2. 默认几何下的协议、替换与行宽压力

保持 L1 `LINE_BYTES=32`、`MUL_LATENCY=3` 和默认 FE；L2 为 128 sets × 4 ways × 64B = 32KiB，128-bit beat，单事务。小几何只用于加快边界覆盖。

| 测试维度 | 待补行为 | 通过标准 |
| --- | --- | --- |
| 响应归属 | i0/i1/c0/c1 交错请求、响应接收停顿、仲裁竞争 | 每笔已接受 Read 恰好一次响应，owner／地址／数据一致 |
| Dirty eviction | c0/c1 角色互换，同 set 超过 4 ways、多次连续替换 | victim 地址、四个 beat、byte enable 与独立参考一致 |
| 32B/64B 行宽 | L1 写回分别更新 L2 上／下半行，部分字节写与交错安装 | 未写字节及另一半行保留 |
| 随机反压 | 下游读／写接收、读响应、各上游响应独立停顿 | stall 时 valid/payload 稳定，无丢失／重复／死锁 |
| 冷复位 | idle、refill、writeback、response 等状态复位 | 按冻结契约取消／隔离旧事务，复位后不串响应 |
| 参考与覆盖 | 私有可写／共享只读、同 set 随机冲突、默认几何 | 记录 owner／way／beat／FSM 状态和必要转移，零 mismatch |

- [ ] 增加至少 3 个固定 seed，每 seed 100 万次已接受事务；作为慢回归入口。
- [ ] 保留定向序列，逐笔比对 accepted store／read／dirty writeback；参考状态不得被 DUT 的错误写回更新。
- [ ] 最终数据比较包含脏 L1/L2 中的最新值；若比较 backing memory，先通过验证过的路径排出脏数据，不能误判旧 backing 内容。
- [ ] 压力通过后重跑完整单双核 CoreMark、短程序及受影响 Core 回归，更新主计划 M1 状态。

**L2-M1 总出口**：A1/A2 均通过，有本地原生 C5 长程序、可靠失败判定、默认几何压力、反压／复位及覆盖证据。当前单次程序通过不等于此出口。

## 3. 实施包 B：冻结双核 SoC 的地址与启动契约（L2-M2 前半）

可以在 A 的压力测试期间准备文档；硬件实施以已批准契约和数据正确性基线为前提。

交付 `docs/2core_memory_map.md`、`docs/amp_boot_flow.md` 及相关 SPEC 决策，至少明确：

- [ ] Boot ROM、共享存储、hart 私有区、共享只读／可写区、SPM、CLINT、PLIC、Mailbox、UART、tensor 窗口和实际容量。
- [ ] 地址属性贯穿 AGU／LSU／hart 参数、xbar、链接脚本与 DMA；当前 `0xA000xxxx` 的 generic MMIO 属性不能自动覆盖候选 `0x900xxxxx` 设备。
- [ ] PLIC context1 claim 偏移为 `0x00201004`，为完整寄存器空间选择连续窗口／稀疏译码／重映射方案，避免覆盖邻近外设。
- [ ] 区分私有数据重定位、共享地址、MMIO 与 DMA；CoreMark 的“整个 D-side 加 1MiB”只保留为诊断配置，不能直接作为正式系统地址机制。
- [ ] 确定 mtime 时基、RV32 高低字读写、MSIP 清除、PLIC source/context 和 Mailbox doorbell／IPI 连接。
- [ ] 冻结每 master 单 outstanding MMIO、仲裁／响应 owner、设备写完成点、未映射访问行为；不凭空增加异常能力。
- [ ] 冻结 Mailbox slots、doorbell/ack、TAS 或选定同步原语；barrier count/generation 的并发与复位语义。
- [ ] 首版静态预加载镜像，两核按 `mhartid` 分流、独立栈／异常向量，hart1 等待释放。动态代码加载必须等缓存维护与代码可见性完成。

**出口**：地址图、容量、启动／IRQ／设备访问协议可直接用于 RTL 和软件实现；需要的架构裁决已明确记录。

## 4. 实施包 C：可启动的完整双核裸机 SoC（L2-M2 后半）

- [ ] 扩展已有 `ares_frontend_hart`，暴露真实 MMIO、MSIP/MTIP/MEIP 和维护接口，复用原生 C5，避免复制第二套 hart 主路径。
- [ ] 新增完整系统顶层，连接共享 L2、MMIO xbar、现有 CLINT／PLIC、Mailbox、启动存储和 UART；当前 `ares_2core_frontend_l2_top` 仍作诊断原型。
- [ ] 为新 xbar／Mailbox 配事务 owner、并发副作用与反压测试；不能直接将两核并接 JYD 单主机桥。
- [ ] CLINT／PLIC 输出接各 hart；先用可控源验证 PLIC claim/complete，后续接真实 tensor IRQ。
- [ ] 实现静态双核 Boot ROM／runtime、hart1 释放、私有栈／完成状态和 UART 所有权。

**L2-M2 出口**：真实 FE 双核 hello、双向 IPI、每 hart timer、PLIC claim/complete、Mailbox ping-pong、barrier 10k 次；随机 MMIO 反压与冷复位无丢消息／串响应／死锁。此阶段不宣告 SMP。

## 5. 实施包 D：默认系统入口迁移（L2-M3）

- [ ] 完整 L2 SoC TB/harness、镜像加载和 per-hart retire/debug；两核分别判定，任一失败整体失败。
- [ ] 先增加显式 L2 SoC 入口，再迁移默认 `make sim/run/isa`；同步 AM 链接／启动、DPI 模型与脚本，不能只改 TOPNAME。
- [ ] 输出实际 DUT、hart 数、L1/L2 参数、地址图、镜像和配置；单核 ISA 明确另一 hart 的停驻，双核 ISA 分别计分。
- [ ] 保留可显式选择的独立 Core／FE 桩／IROM／JYD 回归；区分快速测试、完整长程序和慢压力。

**出口**：默认系统命令实际运行完整 L2 SoC，ISA／启动／MMIO／IRQ 可复现，原两套 Core 36/36 回归保持。

## 6. 后续实施包与可提前准备的工作

| 工作包 | 实施内容 | 验收与依赖 |
| --- | --- | --- |
| L2-M4a 存储可见性 | CPU/MT-DMA 仲裁、read owner、写完成点、uncached/SPM 所有权与 clean/invalidate；关闭 M7/M13/M20/M21 等契约缺口 | CPU 脏 L1→DMA、DMA→CPU 旧 L1、同地址冲突／反压／复位测试；共享 L2 不自动提供 L1 一致性 |
| L2-M4b 代码可见性 | `fence_i_valid`→FE/ICache，排空／取消或隔离旧 refill、invalidate、重新取指；保证写入先可见 | 改写代码→FENCE.I→执行新代码，在途 refill 不重装旧数据；动态加载需要时提前实施 |
| L2-M4c tensor/软件 | 先真实单 tensor LOAD/GEMM/STORE/IRQ/ISR，再复制第二份；ARES BSP／timer／console／IRQ／linker | 黄金结果、真实 DMA 和连续投喂、双核并发无串扰、RT-Thread Nano 按 AMP 适配 |
| Core 内 XIF | 保留已选方向；先冻结 M6/M22 的操作数／credit／ID／commit/kill／result 契约，再接 custom-0/Issue/Commit/CIQ | 提交前无副作用、flush/trap kill、ID 复用和 completion 测试；MMIO adapter 不替代该验收 |
| 最终 L2/SPM | 在正确性基线上分步评审 128KiB、8-bank、MSHR、WBQ、sector、QoS、SPM | 多 outstanding 前明确扩展协议；每次结构变化重跑完整性与资源／带宽测试 |
| L2-M5 物理接入 | 复用 JYD 时钟／复位／UART／CDC／引脚，提供完整 L2 SoC board top、manifest、Vivado profile 和非零镜像 | 物理顶层模型、工程生成／综合确实包含完整系统；容量与软件布局一致 |
| L2-M6 整机签核 | 最终配置 synth→place→route→post-route phys-opt，审查约束／CDC／例外 | 资源可容纳、setup WNS≥0/TNS=0、hold WHS≥0/THS=0、无未约束路径及实板证据 |

尽早评估双核／双 tensor／L1／L2／SPM／backing BRAM 的总资源；旧单核缓存数据探针已用 34 RAMB36，不能只按逻辑容量估算。TB 的 16MiB backing 也不能套用于旧板级 256KiB。

频率要求维持严格 **>200MHz**，250MHz 是请求；100–125MHz 未获批准。IPC 优化另开测量任务：同一 RTL／镜像上记录 frontend、issue、load、branch、commit stall，再做参数 A/B；不以 Mundus/NPC 的 0.9 IPC 或低 L2 总访问数直接判定瓶颈。DDR3／视频、A 扩展与硬件一致性／SMP 单独排期。

## 7. 执行批次与现有入口

| 批次 | 工作 | 下一批条件 |
| --- | --- | --- |
| A | 固化镜像／负向验证、默认几何压力与覆盖，关闭 M1 | 完整 M1 证据；失败时先定位首个不一致 |
| B | 地址图／启动／设备与维护契约、资源预算 | 必要决策完成 |
| C | 双核 MMIO／IRQ／Mailbox／启动，关闭 M2 | 真实系统验收通过 |
| D | 默认 harness／软件／ISA 迁移，关闭 M3 | 默认入口与文档／实际 DUT 一致 |
| E | 按依赖推进 M4/M5/M6 与独立 XIF／性能任务 | 各门禁分别验收，不用局部通过替代整机完成 |

现有命令（A1 后长程序不再需要外部镜像）：

```bash
make lint-l2 unit-l2 unit-l2-frontend
make coremark-image test-coremark-image   # 仓库内镜像链 + 转换器正负测试
make unit-coremark                        # 自动使用/构建 build/coremark 镜像
make unit-2core-coremark
make unit-2core-coremark COREMARK_ARGS=+H1EN=0
# 显式 DMEM=<path> 仍然优先，用于对比外部镜像。
# 先按上述命令构建两份 TB；本目标只运行短镜像正负检查。
make test-coremark-harness

make lint-backend lint-lsu unit unit-lsu unit-frontend unit-frontend-modes
make isa isa-stub
make unit-soc unit-clint unit-plic unit-mt-irq unit-mt-cpu-irq
make unit-board test-config test-vivado test-images
```

长程序不纳入 `make all`。每次验收同步主计划、集成记录与状态索引；记录实际执行结果，不把远端历史数字当作当前配置实测。
