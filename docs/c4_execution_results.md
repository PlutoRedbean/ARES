# C4 板级基线实施与验证（2026-10-18）

决策见 [`c4_execution_decisions.md`](c4_execution_decisions.md)。本文记录验证范围及其证据边界。

## 已实现

- `rtl/board/top.sv`、`fpga/board.json`：真实 C5 CPU/IROM/DRAM 与物理 PLL、
  UART、原引脚约束连接。250MHz 为实施目标，不是测得的 Fmax。
- 每域复位同步释放；UART 115200 baud、8N1。外设桥发送启动占位保护，
  UART/LED/计数器的 50MHz 逻辑使用本域复位。
- 裸机镜像及 HEX/COE 打包：RESET_PC=0x80000000、RESET_MTVEC=0x80000100；
  DRAM 初始化、cache miss/hit、uncached 访问、ECALL/MRET、UART 输出/回显。
- 独立 DCache TB；IRQ mepc/恢复 PC 直接断言；CIQ 状态转移覆盖率门禁。
  Backend 单元测试启动器修复管道掩盖模拟器失败退出状态的问题。
- Vivado FE 包常量限定/声明兼容性修正；板级非零镜像门禁、Git revision/
  dirty 标记、关键路径/时序例外报告及 2025.2 post-route 步骤名称修正。

## 功能验证

| 验证 | 实际结果 |
|---|---|
| Backend | 5 个 TB 通过；CIQ states 4/4、非自环 transitions 6/6；IRQ 恢复 PC 直接检查；发射等价 100,000 向量 |
| LSU | 12 个 TB 通过（原 11 个 + 独立 DCache） |
| 独立 DCache | 16/32/64B 各 38/48/68 checks，通过安装/命中/byte store/retry/kill/merge/miss |
| Frontend | 7 个 TB、关闭可选预测器配置通过；uBTB 等价 30,000 周期、7,337 命中窗口；ICache 存储 5,000 周期、9,958 checks |
| SoC | 总线 2864 checks、自主 CPU 程序 25 retires 通过 |
| Board | UART framing/false start/invalid stop/reset 单元 TB；完整物理顶层模型 26 串口帧、2 次自主启动、ECALL/MRET、回显及 PLL 失锁复位通过 |
| ISA | 存储实现优化后，真实 FE 与桩各 36/36 PASS |
| 工程工具 | 生成器 10/10、镜像拆分 3/3；lint 无未豁免 warning |
| Cache BRAM IP | BMG 行为模型 5/5、RAMB36E1 原语网表 5/5；覆盖 ICache 双读/refill/碰撞/复位、DCache 阵列 16/32/64B、DCache 控制器 |

板级仿真使用显式 PLL/存储 IP 模型，不能等同于实际 FPGA 运行。正式
mtime/mtimecmp、RTOS 和共享内存 DMA 不包含在上述功能验收内。

## LINE_BYTES 仿真比较

`python3 scripts/measure_line_bytes.py` 使用同一个 16KiB 流式写/读校验程序，
在独立构建目录覆盖 line size，不改 menuconfig 或默认配置。

| LINE_BYTES | cycles | instructions | IPC | Load 新分配 miss | 下层 Read 请求 | Read busy cycles |
|---|---:|---:|---:|---:|---:|---:|
| 16 | 56941 | 36874 | 0.647583 | 1024 | 2048 | 6144 |
| 32 | 55147 | 36874 | 0.668649 | 512 | 2048 | 6144 |
| 64 | 54393 | 36874 | 0.677918 | 256 | 2048 | 6144 |

统计口径：Load miss 为新 Load MSHR 分配，不含合并 waiter 或 Store 分配；
read busy 从接受 Read 到接受响应，包含两端周期。结果依赖当前 TB 内存
延迟，不代表板级带宽；三档 Fmax/面积尚未完成。默认保持 32B。

## 板级综合与优化

首个真实 FE 板级综合保存于 `build/vivado/c4-board-250/`。器件
xc7k325tffg900-2，Vivado 2025.2，CPU 请求 250MHz，外设 50MHz。

- 原基线 226116 LUT（110.95%）、173071 FF；超过器件 LUT 容量。
- 综合 WNS=-35.600ns；最差路径位于 uBTB 空项优先选择/更新，115 级逻辑。
- 分层资源：Backend 60198 LUT、LSU 10439、Frontend 153478；其中 ICache
  42731 LUT/75003 FF、uBTB 49089 LUT。原 ICache 没有推断成预期的 BRAM。
- uBTB 线性优先编码改为平衡树；CIQ completion 按互斥 tag 并行归并，
  发射数据选择去除全局恢复控制扇出，100,000 向量发射等价验证通过。
- ICache 的平坦 RTL RAM 版本仍被综合为 LUTRAM。用户追加要求后，
  ICache/DCache 数据阵列改为 Block Memory Generator IP（见 Vivado README）。
  旧 `build/vivado/c4-board-storage-250/` 综合已停止，不能用作新 IP 版本结果。
- 新数据存储探针保留 4 路 ICache 和 2 路 DCache，每路 ICache 复制两个 SDP
  IP 以保留双读/同时 refill 契约。综合确认 34 个 RAMB36（ICache 32、
  DCache 2）、24 个地址/使能逻辑 LUT、**0 LUTRAM、0 数据 FF**。该报告
  仅包含数据阵列，Tag/Valid/Dirty/替换状态仍在 RTL 中。
- IP 和验证记录保存于 `build/vivado/c4-cache-ip-verified/`。厂商模型及独立
  UNISIM 原语编译共 **10/10 通过**；每份原语 elaborate.log 均确认绑定
  `unisims_ver.RAMB36E1`，没有复用 BMG 行为模型。ICache 9,958 checks；
  原语 DCache 阵列 16/32/64B 分别 63,875/63,875/63,887 checks；控制器
  48 checks。Verilator、板级和两条 ISA 路径回归通过，三档流式程序的
  cycles/miss/read 请求统计与上表一致。
- 显式关闭 BMG 默认复位安全逻辑，避免其延长端口使能；测试先等待
  UNISIM 100ns 配置 GSR 结束再访问，不改变运行时复位或缓存响应周期。
  中间失败记录保留在该目录 `attempts/`，验证重放说明与输入哈希一并保存。
- 新 IP 版本包含非零 IROM/DRAM 镜像。后续全板运行保存于
  `build/vivado/c4-board-cache-ip-route-250/` 和其 `-retry1/` 目录；
  两次均在综合阶段按用户要求停止，**没有完整综合或 routed 结果**。
  当前无法据此报告新版本距 200MHz 的差距或新的关键路径，MC4 仍未关闭。

首轮还发现 XDC 不接受控制流语句、UART 第一级同步器路径匹配和
post-route 步骤名称的问题，均已修正源文件。首轮报告仅用于诊断，不能
充当完整约束/CDC/板级时序签核。完整签核仍需 routed setup/hold、约束、
CDC/总线 skew 与实际资源逐项通过；当前不声明 MC4 达成。
