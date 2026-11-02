# ARES 单核 RT-Thread Nano

RT-Thread Nano 3.1.5 已在共享的 Mundus 流水线 CPU 上完成最小单核移植。
CoreMark 是独立裸机程序；RTOS 固件不链接 CoreMark、miniTensor、Shell 或加速器应用。
本次验证包括推断 BRAM 的 RTL 仿真及物理 UART 解码的板级仿真；PDS 实际综合、时序和烧录尚未执行。

## 构建与运行

在仓库根目录执行，需要 `riscv64-unknown-elf-gcc`、Verilator、Icarus、Python 3。
首次检出本次 CPU 改动，或后续修改 Chisel 后，先使用 mill/firtool 重新生成 `Mundus.sv`。
生成的 RTL、固件镜像及仿真结果属于本地构建产物：

```sh
make pipeline-core-gen
make rtos-image
make pipeline-irq-test
make pipeline-rtos
make pipeline-rtos-board-sim
make pipeline-rtos-pango-lint
python3 scripts/test_rtos_pds.py
```

`rtos-image` 使用 `rtthread-nano/rt-thread/bsp/ARES`；不依赖外部 NPC 或 miniTensor。
产物全部放在 `build/rtos/`：`ares-rtos.elf/bin/map`、`irom.hex`、`dram.hex` 和
`image.json`（ELF/HEX 哈希）。该目标不生成或覆盖 `build/pipeline/`。
IROM 是 `0x80000000` 起的 32 KiB；DRAM 是 `0x80100000` 起的 256 KiB。
`.rodata/.data` 直接由 DRAM HEX 初始化，启动代码只清 BSS，无额外 bootloader。
启动栈预留 4 KiB；main、idle、两个工作线程的静态栈各 2 KiB，SP 按 16 字节对齐。
内核代码保留在 vendored RT-Thread 树；ARES BSP 保留移植来源的版权声明。

两个仿真都使用和 PDS 相同的 HEX、推断 RAM 及其真实读延迟，不使用 DPI 存储器。
SoC 仿真观察已接受的控制台 MMIO；板级仿真经过 27 MHz 输入、PLL/复位、
100 MHz CPU、50 MHz 外设、115200 8N1 UART TX（C24），检查起始位和停止位。
两者均使用真实 1 ms tick；超时/故障/提前 EBREAK 会使进程失败。

预期程序先打印内核横幅和 `ARES main thread started.`，随后完成：

- ECALL 的 caller/callee-saved 寄存器现场检查；
- 两个同优先级线程无 yield 的抢占运行；
- tick 推进、关中断跨多个毫秒后的 tick 补偿；
- `rt_thread_mdelay()` 延时唤醒。

全部通过后独立打印一行 `ARES RTOS PASS`。仿真收到完整该行后成功退出；
实际固件继续每 500 ms 翻转 LED。失败打印 `ARES RTOS FAIL` 并停机。
UART RX 保持 idle，本固件无需输入。这里不声称支持 SMP、用户态、MMU、嵌套中断或完整同步异常集合。

## 自检日志的来源

这些行来自 BSP 的 `main.c` 和实际运行结果，数值并非预先写死。
`tick` 是 1000 Hz 的内核时钟，包含启动、串口输出和线程未占用 CPU 时经过的时间。

| 输出 | 实际执行的检查 |
| --- | --- |
| `ARES main thread started.` | 调度器已进入 main 线程 |
| `ecall trap test passed: mepc=...` | 汇编执行 ECALL，异常入口保存/恢复现场并返回，检查通用寄存器及异常计数；此地址对应该镜像的 ECALL 指令，重新链接后可能变化 |
| `thread A/B: step=... tick=...` | 两线程均为优先级 9、时间片 5 tick；每步忙等全局时间经过 6 tick，再更新校验值并打印，线程中没有 yield 或 sleep |
| `workers completed without yield ...` | 优先级 10 的 main 恢复运行，确认两线程完成、结果正确且确实执行过忙等 |
| `main busy-wait tick test passed ...` | main 忙等至少 3 tick，确认时钟中断仍推进时间 |
| `masked tick catch-up passed.` | 关闭 CPU 中断跨过至少 4 ms，重新开启后验证内核补齐遗漏的 tick |
| `preemptive timer test passed ...` | 再执行一次 3 ms 的阻塞延时并验证唤醒；同时打印内核 tick 和实际定时器 ISR 进入次数 |
| `ARES RTOS PASS` | 固件的全部自检通过 |
| `RTOS simulation BOARD=1 PASS` | 测试台经真实 UART 波形收到完整 PASS 行，结束板级仿真 |

因此 A/B 的 tick 不必严格每次增加 5 或 6：忙等使用全局时间，线程会被抢占，
串口输出也占用时间。`tick=70 timer_irq=58` 也不矛盾，ISR 会按硬件毫秒差值一次补多个 tick，
计数器启动至首次服务及屏蔽中断期间都可能累积时间。`BOARD=1` 表示仿真选择板级顶层，
不表示已经在 FPGA 实板运行。

## 中断与定时器契约

CPU 的 `timer_irq` 为电平。`mie.MTIE`、`mstatus.MIE` 和 `mip.MTIP` 同时成立时停止新发射，
让执行/写回、乘除法、LSU 和外设桥排空；通过注册的空闲状态进入中断，避免
redirect 与 LSU idle 构成组合环。最后退休的 `pc_next` 是恢复地址。
排空过程中仍处理分支及 load replay；进入时清前端并写 `mepc/mcause/mstatus`，不训练 BPU。
若较早已发射的 ECALL 关闭使能，取消该次排空；EBREAK 继续保留原有停机用途。

只支持机器模式直接入口，`mtvec/mepc` 低两位清零。
`mie` 仅实现 MTIE（bit7）；`mip` 只读反映外设 pending，CSR 写不能清除它。
`mstatus` 实现 MIE/MPIE，MPP 固定为 M 模式。中断原因 `0x80000007`；
ECALL 原因 11，软件返回 `mepc+4`；定时器中断返回原 `mepc`。

| MMIO | 语义 |
| --- | --- |
| `0x80200050` | 读取单调毫秒计数；写 `0x80000000` 启动，写 `0xffffffff` 停止 |
| `0x80200054` | bit0：pending；写 bit0=1 确认，其他位忽略 |

CPU 域观察到同步毫秒数变化后置 pending，直到 ACK；新毫秒与 ACK 同周期时置位优先。
停止和复位清 pending。时间计数在屏蔽 CPU 中断时继续运行。
处理函数先 ACK，再读毫秒数，按无符号差值调用 `rt_tick_increase()`，随后统一处理调度。
ISR 不打印正常运行日志。原有 `0xA0000050/54` CoreMark 周期计数语义不变。

`pipeline-irq-test` 同时运行定时器单元测试和裸机 CPU 集成测试。
集成测试用测试台注入电平中断，分别命中分支、数据缓存 miss、待写队列、除法和外设反压；
检查计算结果及 640 次 MMIO 写的严格顺序，另检查真实计时器的 pending 和两级屏蔽。
测试专用 force 仅存在于测试台，未加入硬件接口。

## CoreMark 回归

本次在修改前冻结原有 BIN/板级镜像哈希及日志，修改后使用原镜像重跑。
四组完整控制台输出逐字节相同（包含多核交织的 CRC 输出），计时周期和总周期不变：

| 配置 | 总周期，前后相同 | 单核 CoreMark/MHz |
| --- | ---: | ---: |
| 单核 baseline | 44,798,214 | 2.235012 |
| 单核 full | 7,525,556 | 13.381925 |
| 2-hart AMP full，32 KiB I$ | 12,661,820 | 各 hart 独立报告 |
| 4-hart AMP full，32 KiB I$ | 12,668,330 | 各 hart 独立报告 |

原始结果在 `build/rtos_regression/{before,after}/`，`results.json` 保存镜像哈希、
关键输出及完整日志哈希。测试工具不重新生成 CoreMark 软件：

```sh
# 将来对比其他硬件改动时，先保留本次目录，再在改动前建立新的 before。
CCACHE_DISABLE=1 python3 scripts/test_rtos_coremark.py before
# 修改硬件后：
CCACHE_DISABLE=1 python3 scripts/test_rtos_coremark.py after
```

已有 before 时工具拒绝覆盖。当前 checkout 已有本次基线，可直接运行 after。
这些是固定镜像、固定配置的功能/周期回归，不代表 FPGA 最高频率或所有 CoreMark 配置均已验证。

## Pango PDS

先生成镜像，再在 PDS 主机仓库根执行：

```bat
pds_shell.exe -file fpga/pango/pipeline/flow_pipeline_rtos.tcl -project_name pipeline_rtos
```

该流程使用 RTOS 专用顶层、引脚/生成时钟约束，将两个 HEX 原样快照到
`build/pds_rtos/build/rtos/` 后在 `build/pds_rtos/` 执行实现。
工程名、实现目录和位流顶层名均与原 CoreMark 工程分离。
生成的位流名为 `pipeline_rtos_board_top.sbit`，实际目录以 PDS 报告为准。

`test_rtos_pds.py` 只用 Tcl stub 检查流程语法、文件路径、顶层选择及镜像复制哈希，
不运行 PDS，不验证原语、物理约束解析、资源或时序。真正上板前仍须检查生成时钟、
setup/hold、初始化及 UART/LED；共用 CPU 的新增逻辑是否影响最高频率需由 PDS 确认。
