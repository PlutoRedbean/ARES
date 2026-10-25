# C4／C6 决策与共享 L2 主线（更新至 2026-10-25）

用户确认：miniTensor 后续新增 **Core 内 CV-X-IF**；其余按进度评估中的建议实施。

## 当前主线决定（2026-10-25）

用户已确认：**含共享 L2 的 ARES SoC 作为后续主线**。当前基于 `943d160` 的双 hart
AMP／原生 C5 FE／共享 L2 原型推进，先解决长程序数据正确性，再完成 MMIO／中断／
启动／软件与默认仿真、Vivado／板级顶层迁移。具体任务与门禁见
[`implementation_plan.md`](implementation_plan.md) §9.7a–§9.9。

JYD `student_top` 保留为回归及 PLL／复位／UART／BRAM／CDC／引脚与工程设置的复用来源，
不再要求先完成旧 JYD 单核 PPA 才推进 L2。当前 `make sim/run/isa` 仍不含 L2，现有
Vivado `soc`／board profile 仍走 JYD；本次仅修改规划，默认值和 RTL 接线未迁移。

既有严格 >200MHz 规划要求保留，250MHz 是约束请求；L2 主线需明确完整配置的时钟
约束和资源预算。调整频率要求须另行裁决，100–125MHz 建议不能自动当作批准降标。Core 内 XIF 的后续方向保留，当前
MMIO host adapter 是可复用过渡路径，不表示 Core 内 XIF 已完成。

## 原单核板级范围（2026-10-18，历史／资源参考）

- 先验收当前 C5 FE/BE/LSU 功能基线，再推进深预测器；TAGE/SC/mBTB 与
  1 prediction/cycle 的目标要求保留，不因本轮验收而关闭。
- 器件 `xc7k325tffg900-2`，Vivado 2025.2；实施目标先用 CPU 250MHz、外设
  50MHz。250MHz 是请求值；MC4 仍要求实际 CPU **严格 >200MHz**，完整
  post-route setup/hold、约束和 CDC 验收通过。
- 首个板级版本使用 `student_top`，含真实 CPU、32KiB IROM、256KiB DRAM、
  LED/SEG 和串口控制台。虚拟开关/按键固定为零，不导入旧数字孪生协议。
  miniTensor 未接入该物理顶层；其 MMIO 状态返回零，DMA 不接假内存。
- 保持原物理引脚和 200MHz 差分时钟输入。原板无已定义复位引脚，本轮用
  上电/PLL 失锁触发复位；分别在 CPU/50MHz 域同步释放。失锁是冷启动，
  不承诺保留在途事务或软件状态。Core 继续使用同步高有效复位。
- UART 为 50MHz 域的 115200 baud、8N1 控制台；收发字节通过平台现有
  CDC 握手跨域。板级不直接跨域连接字节脉冲。
- 启动 PC 保持 `0x8000_0000`；板级 `RESET_MTVEC=0x8000_0100`。
  裸机镜像提供该入口，覆盖访存、ECALL/MRET、串口与 LED。
  JYD 毫秒脉冲 IRQ 仍不是正式 machine timer，不能据此验收 RTOS/MTIP。
- 保持默认 MUL_LATENCY=3、LINE_BYTES=32 和 FE 配置。时序优化先保持
  接口、latency/II 和架构语义；改变这些约束时另行记录架构决策。
- 用户追加决定：ICache/DCache 的数据阵列采用 Vivado Block Memory
  Generator 8.4 IP，避免依赖 RAM 推断。保留同步单周期读取和原端口契约，
  元数据保持 RTL；普通仿真使用行为模型，并以厂商模型单独验证 IP。

## Core 内 XIF 与系统剩余契约（方向保留，接入 L2 主线）

**已选：Core 内 XIF。** 后续在 Backend 实现 custom-0 译码、Issue、Commit、
kill 和 Result→CIQ；现有 MMIO→XIF 适配只保留为子系统诊断资产，不作为
最终 Core 内 XIF 的替代。SPEC-M6 的操作数/credit、提交前无副作用、
ID 生命周期、flush/trap kill 和 completion 路由仍须在实现前冻结。

后续按计划定义 CPU/DMA 仲裁与 Read owner、写可见性、冷复位隔离和
uncached buffer 所有权（SPEC-M7/M13/M20/M21）。不增加硬件缓存一致性。
原 JYD 基线为 IROM-only；L2 主线已经把 I/D 接到共享 L2，若允许 DMA/CPU 更新可执行存储，需先解决
I-cache 维护契约（SPEC-M19）。正式 mtime/mtimecmp 的寄存器布局、时基、
电平 MTIP 与 ARES RT-Thread BSP 随 C6 单独落实（SPEC-M12）。

## 验证边界

OOC 报告只诊断资源与关键路径。物理顶层仿真使用显式 PLL/存储 IP
时序模型，不证明实际 PLL、引脚电气或硬件运行。未连接开发板时不得
报告“实板通过”。旧 MC4 不作为 L2 主线通过证据；L2-M6 以完整 L2 SoC 的实际 routed 报告、资源与约束／CDC 审查为准。
