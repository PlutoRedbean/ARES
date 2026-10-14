# RT-Thread Nano on MundusJyd

本目录是 **RT-Thread Nano 3.1.5** 在 `MundusJyd`（`Mundus_Jyd` CPU 核）上的单核
RV32IM BSP；仓库分支为 `mundus-v3.1.5`，基线标签为官方 `v3.1.5`。当前已经在
Verilator 仿真中完成 RT-Thread 3.1.5 启动、机器定时器中断、
抢占式多线程、线程延时、同步异常、上下文完整性回归以及 RT-Thread CoreMark
应用线程和最小 MSH 命令验证；FPGA 侧已经具有可综合的
启动地址、IROM/DRAM、计时器、中断和 LED 数据通路，但 RT-Thread 镜像拆分、
Vivado BRAM 初始化、物理控制台和最终上板验证还需要完成。

## 1. 当前结论

| 功能 | Verilator 软件仿真 | FPGA 上板路径 | 当前状态 |
| --- | --- | --- | --- |
| RV32IM + Zicsr、机器模式 | 支持 | 支持 | 已实现 |
| 从 `0x80000000` 直接启动 | 支持 | 由 IROM 初始化实现 | 已实现，不使用额外 bootloader |
| RT-Thread Nano 内核启动 | 已验证 | 软件和 RTL 路径已具备 | 待实际生成 bitstream 验证 |
| `mstatus/mie/mip/mepc/mtvec/mcause` | 已验证 | 可综合 | 已实现 |
| `mcycle/mcycleh` 64 位周期计数 | 功能回归已验证 | 可综合 | CSR `0xB00/0xB80` |
| `ecall`、`mret`、直接模式 `mtvec` | 已验证 | 可综合 | 已实现 |
| 1 ms 硬件计数器与机器定时器中断 | 已验证 | 使用 50 MHz 计数时钟 | 已实现 |
| 抢占式线程切换 | 两个同优先级线程无主动 `yield` 完成切换 | 使用相同 CPU/RTL 路径 | 已实现，单核 |
| 线程睡眠和 tick 唤醒 | `rt_thread_mdelay()` 已验证 | 使用相同内核路径 | 已实现 |
| 控制台输出 | `0x80200060` 通过 `$write` 输出到终端 | 连接物理 UART TX/RX | 默认 9600 8N1 |
| LED MMIO | 终端显示模型可观察 | 连接 `virtual_led` | 已实现 |
| 数码管 MMIO | RTL 外设已存在 | 连接 `virtual_seg` | miniTensor 上板状态会写数码管（见 §7.6） |
| `ebreak` 结束测试 | 仿真器转换为 `HIT GOOD TRAP` | 无仿真器，随后停在死循环 | 仿真专用结束机制 |
| FinSH/MSH 交互 | `help`、`coremark` 已验证 | UART数据通路已接入，待实板闭环 | 默认固件 |
| 文件系统、网络 | 未启用 | 未实现 | 不在当前最小 BSP 中 |
| 用户进程、虚拟内存、SMP | 未启用 | 未实现 | 当前是单核、多线程、同一地址空间 |
| 在 RT-Thread 内运行 CoreMark | 命令模式已验证 | 软件路径已具备 | 默认固件 |

这里的“多线程”是 RT-Thread 内核线程调度，不是带独立地址空间的进程切换。当前
没有 MMU、用户态和进程隔离。

## 2. 代码组成

### 2.1 BSP 软件

| 文件 | 作用 |
| --- | --- |
| [`start.S`](start.S) | 复位入口，初始化 `gp/sp/mtvec`、清零 `.bss`，进入 RT-Thread |
| [`linker.ld`](linker.ld) | 按 NPC menuconfig 的 IROM 容量放置代码，把数据、BSS、栈放入 256 KiB DRAM |
| [`board.c`](board.c) | 板级初始化和仿真结束函数 `halt()` |
| [`timer.c`](timer.c) | 启动 JYD 计时器并打开 `mie.MTIE` |
| [`trap.S`](trap.S) | 保存/恢复 RV32 上下文，处理中断返回时的换栈 |
| [`trap.c`](trap.c) | 区分 `ecall` 和机器定时器中断，并调用 RT-Thread tick 处理 |
| [`console.c`](console.c) | 仿真控制台 MMIO 的字符输出和非阻塞字符输入 |
| [`coremark/competition_app.c`](coremark/competition_app.c) | 启动最小 MSH，导出带 LED 起止标志的 `coremark` 命令 |
| [`coremark/coremark_portme.c`](coremark/coremark_portme.c) | CoreMark 的 1 ms MMIO 计时、种子和 RT 输出适配 |
| [`coremark/core_portme.h`](coremark/core_portme.h) | CoreMark 数据类型、栈内存和单上下文配置 |
| [`coremark/eembc/`](coremark/eembc/) | 固定提交、未修改的 EEMBC CoreMark 官方源码快照 |
| [`include/rtconfig.h`](include/rtconfig.h) | 最小 Nano 配置、主线程栈和 idle 栈大小 |
| [`Makefile`](Makefile) | 使用裸机工具链构建 ELF/BIN，并调用 NPC Verilator 仿真 |

Makefile 直接编译官方 Nano 内核的 `clock.c`、`components.c`、`cpu.c`、
`idle.c`、`irq.c`、`kservice.c`、`object.c`、`scheduler.c`、`thread.c`、
`timer.c`，FinSH/MSH 的 `shell.c`、`msh.c`，以及官方 RISC-V 公共移植层
`cpuport.c/context_gcc.S`。为减小 IROM，固件不编译可选的完整 `cmd.c`，只在
`coremark/finsh_compat.c` 中补充 Nano 3.1.5 的 MSH 链接所需符号。BSP 没有
重写调度器，而是补齐官方内核依赖的启动、中断、计时器和板级接口。

### 2.2 与操作系统相关的 RTL

| RTL | 作用 |
| --- | --- |
| `npc/scsrc/exu/CSR.scala` | CSR 读写、`mcycle/mcycleh`、`ecall/mret`、`mip.MTIP` 和中断判断 |
| `npc/scsrc/Mundus.scala` | 中断到来后停止前端、排空已发射指令，在精确边界跳转 `mtvec` |
| `npc/vsrc/Mundus/myCPU.v` | 将 `timer_irq` 接入 Mundus CPU |
| `npc/vsrc/testbench/jyd/perip_bridge.sv` | JYD 地址译码、DRAM、LED、计时器和仿真控制台 |
| `npc/vsrc/testbench/jyd/counter.sv` | 生成毫秒计数值和跨 CPU 时钟域的单周期 `timer_irq` |
| `npc/vsrc/testbench/jyd/student_top.sv` | 连接 CPU、IROM 和 JYD 外设桥 |
| `npc/vsrc/testbench/MundusJyd.v` | Verilator 顶层，仿真中让 CPU 时钟和计数时钟使用同一时钟 |
| `npc/vsrc/testbench/jyd/top.sv` | FPGA 顶层，使用 PLL 的 CPU 时钟和独立 50 MHz 外设时钟 |
| `npc/csrc/wave/sim_console.cpp` | 向仿真 RX MMIO 提供终端或脚本命令字符 |

## 3. 体系结构和地址空间

编译选项为：

```text
-march=rv32im_zicsr -mabi=ilp32
```

CoreMark 还默认使用
`-falign-functions=8 -falign-jumps=8 -falign-loops=8`。Mundus 每组最多取出并
发射两条 32 位指令，8 字节对齐让热点函数入口、分支目标和循环头更稳定地落在
取指组边界。当前链接脚本已经保证 `.text` 起点 8 字节对齐；不把 DRAM 人为切成
两个链接区，因为 D-cache 以地址 bit 2 交错选 Bank，相邻 32 位字天然分属不同
Bank，而 CoreMark 的主要工作区位于运行时栈中。

CPU 运行在 RISC-V M-mode。RT-Thread 当前需要的 CSR 是 `mstatus`、`mie`、
`mip`、`mepc`、`mtvec` 和 `mcause`。`misa` 可以作为可选配置打开，但不是本
BSP 启动 RT-Thread 的必要条件。额外实现的 `mcycle=0xB00` 和
`mcycleh=0xB80` 组成每 CPU 时钟递增的可读写 64 位周期计数器。CoreMark 正式
计时读取 `0x80200050` 的 1 ms 外设计数器，因此 CPU PLL 改频后无需重编固件。

| 地址范围/地址 | 属性 | 用途 |
| --- | --- | --- |
| `0x80000000-0x80007fff` | 只读，默认 32 KiB | IROM，入口 `_start=0x80000000`；容量由 NPC menuconfig 选择 |
| `0x80100000-0x8013ffff` | 读写，256 KiB | DRAM，`.rodata/.data/.bss`、线程栈和启动栈 |
| `0x80200000`、`0x80200004` | 只读 | 两组虚拟开关 |
| `0x80200010` | 只读 | 虚拟按键 |
| `0x80200020` | 读写 | 八位数码管数据寄存器，BSP 当前未使用 |
| `0x80200040` | 读写 | 32 位 LED/输出寄存器 |
| `0x80200050` | 读写 | 毫秒计数器；写 `0x80000000` 启动，写 `0xffffffff` 停止 |
| `0x80200060` | 写 | Verilator字符输出；FPGA通过物理UART发送 |
| `0x80200064` | 读 | 控制台状态，bit 0为RX valid，bit 1为TX ready |
| `0x80200068` | 读 | 读取并弹出一个RX字符 |

链接脚本没有把 `.data` 的加载地址放在 IROM 再由启动代码搬运。仿真时完整
`.bin` 直接覆盖 `0x80000000` 到 DRAM 数据所在位置；FPGA 上则必须分别初始化
IROM 和 DRAM，详见第 7 节。

## 4. 从复位到 `main()` 的完整调用过程

### 4.1 直接启动，不需要额外 bootloader

当前启动链如下：

```text
CPU reset
  -> PC = 0x80000000
  -> _start                         (BSP/start.S)
     -> 设置 gp = __global_pointer$
     -> 设置 sp = __stack_top
     -> mtvec = trap_entry          (direct mode)
     -> 清零 __bss_start..__bss_end
     -> entry()                     (RT-Thread/src/components.c)
        -> rtthread_startup()
```

因此不存在第二段引导程序。仿真器在复位前把镜像加载到模拟存储器；FPGA 的
IROM/DRAM 初始化文件承担“上电已有程序和初始数据”的作用。只有将来要从 SPI
Flash、串口或其他介质动态加载程序时，才需要额外 bootloader。

### 4.2 `rtthread_startup()` 初始化顺序

`entry()` 调用 `rtthread_startup()` 后按下面顺序执行：

```text
rtthread_startup()
  -> rt_hw_interrupt_disable()
     清除 mstatus.MIE，保存旧 mstatus
  -> rt_hw_board_init()
     -> rt_hw_timer_init()
        -> 向 0x80200050 写 JYD_TIMER_START
        -> csrs mie, (1 << 7)        打开 mie.MTIE
  -> rt_show_version()               通过 rt_kprintf 输出横幅
  -> rt_system_timer_init()          初始化内核硬定时器链表
  -> rt_system_scheduler_init()      初始化 32 级就绪队列
  -> rt_application_init()
     -> rt_thread_init(main_thread, main_thread_entry, ...)
     -> rt_thread_startup(main_thread)
  -> rt_system_timer_thread_init()   当前未启用软定时器时基本为空
  -> rt_thread_idle_init()           创建最低优先级 idle 线程
  -> rt_system_scheduler_start()
     -> 选取最高优先级就绪线程
     -> rt_hw_context_switch_to(&thread->sp)
     -> 恢复线程初始上下文
     -> mret
  -> main_thread_entry()
     -> main()                       (coremark/competition_app.c)
        -> finsh_system_init()
        -> 启动 tshell 线程并等待 help/coremark 命令
```

`rt_hw_timer_init()` 只打开了 `mie.MTIE`。全局 `mstatus.MIE` 在启动期间保持关闭，
直到 `rt_hw_context_switch_to()` 恢复主线程初始上下文并执行 `mret`；线程初始
`mstatus` 的 `MPIE=1`，所以 `mret` 后硬件把 `MIE` 置一，定时器中断才真正生效。

## 5. 各项功能的调用链

### 5.1 线程创建和第一次运行

`rt_thread_init()` 不会立刻执行线程函数，它完成以下工作：

```text
rt_thread_init()
  -> _thread_init()
     -> 记录 entry、parameter、stack 地址和大小
     -> rt_hw_stack_init()
        -> 在线程栈顶预先构造 32 槽 RV32 上下文
        -> frame.epc = 线程入口
        -> frame.a0  = parameter
        -> frame.ra  = _thread_exit
        -> frame.mstatus = M-mode + MPIE
     -> 初始化优先级、时间片和线程私有 one-shot timer
     -> 状态 = RT_THREAD_INIT
```

随后：

```text
rt_thread_startup(thread)
  -> rt_thread_resume(thread)
  -> 把线程加入对应优先级就绪队列
  -> 如果调度器已经运行，则调用 rt_schedule()
```

本 BSP 的 `main()` 在临界区中启动 `workerA` 和 `workerB`，避免启动第一个线程时
立即切走。退出临界区后统一调度。两个 worker 的优先级都是
`RT_MAIN_THREAD_PRIORITY - 1`，数值小于 main，因此优先级更高；它们的时间片均
为 5 tick。

### 5.2 普通线程上下文切换

在线程上下文中调用 `rt_schedule()` 时：

```text
rt_schedule()
  -> 从最高优先级就绪队列选择 to_thread
  -> 更新 rt_current_thread
  -> rt_hw_context_switch(&from_thread->sp, &to_thread->sp)
     -> 在当前栈压入 32 槽上下文
     -> *from_thread->sp = 当前 sp
     -> sp = *to_thread->sp
     -> 恢复目标线程 mepc/mstatus/x1/x4..x31
     -> mret
```

`x2/sp` 通过切换整个栈指针恢复；`x3/gp` 对整个静态镜像固定，因此不会在每次
切换中重复保存。当前没有浮点扩展，所以不保存 FPU 寄存器。

### 5.3 硬件计时器如何产生 tick

软件启动部分：

```text
rt_hw_board_init()
  -> rt_hw_timer_init()
     -> *(0x80200050) = 0x80000000
     -> mie.MTIE = 1
```

RTL 数据通路：

```text
CPU 对 0x80200050 的写事务
  -> perip_bridge.mmio_write_accept
  -> cnt_enable_cfg = 1
  -> cdc_single_xpm                  CPU 时钟域 -> 50 MHz 计数时钟域
  -> counter.cnt_enable_cnt = 1
  -> cnt_1ms 计满
  -> cnt_ms_bin++
  -> xpm_cdc_gray                    计数时钟域 -> CPU 时钟域
  -> perip_rdata 观察到新的毫秒值
  -> timer_irq 产生一个 CPU 时钟周期脉冲
```

计数分频有三种模式：

- FPGA：`cnt_clk=50 MHz`，计满 `49,999`，每 50,000 拍产生 1 ms。
- 普通 Verilator 性能仿真：两个时钟都按 menuconfig 的 `CONFIG_CORE_FREQ`
  模拟，每毫秒计满 `CONFIG_CORE_FREQ * 1000 - 1`。例如 200 MHz 计满
  `199,999`，300 MHz 计满 `299,999`，均保持真实 1 ms。
- RT-Thread 功能回归：`make run` 传入 `JYD_FAST_TIMER=1`，计满 `4,999`。
  这是为了缩短仿真时间，只适合验证调度功能，不能用来报告 CoreMark 性能。

### 5.4 从 `timer_irq` 到精确机器中断

`timer_irq` 脉冲到达 CPU 后：

```text
timer_irq
  -> CSR.scala 将 mip.MTIP 置 1并锁存
  -> mstatus.MIE && mie.MTIE && mip.MTIP
  -> interrupt_pending = 1
  -> Mundus.scala 停止继续取新指令
  -> 等待 ISS/EX1/EX2/EX3/EX4/WB 中的旧指令排空
  -> interrupt_take
     -> mepc   = 最后一条已提交指令的顺序下一 PC
     -> mcause = 0x80000007
     -> mstatus.MPIE = 旧 MIE，mstatus.MIE = 0
     -> 清除已受理的 mip.MTIP
     -> 冲刷流水线并把 PC 重定向到 mtvec
  -> trap_entry
```

等待流水线排空保证中断发生在精确的架构边界：已经发射的旧指令先完成，年轻指令
不会在跳入中断后继续提交，`mepc` 指向正确的恢复位置。

### 5.5 `trap.S` 如何保存现场

`trap_entry` 先在被中断线程的栈上分配 `32 * 4 = 128` 字节，然后保存：

```text
sp[0]     mepc
sp[1]     x1/ra
sp[2]     mstatus
sp[3]     保留给固定 gp
sp[4..31] x4..x31
```

之后读取 `mcause` 和已保存的 `mepc`，调用：

```c
rt_hw_trap_handler(mcause, mepc)
```

C 处理函数返回“应该写回 `mepc` 的地址”。最后汇编恢复目标上下文、释放 128
字节栈帧并执行 `mret`。由于 C 中断处理函数也会使用栈，idle 栈和 main 栈均配置为
1024 字节，避免 RT-Thread Nano 默认 128 字节 idle 栈不足。

### 5.6 定时器中断中的抢占式调度

机器定时器中断的 C 调用链是：

```text
trap_entry
  -> rt_hw_trap_handler(0x80000007, epc)
     -> rt_interrupt_enter()          rt_interrupt_nest++
     -> rt_tick_increase()
        -> 全局 rt_tick++
        -> 当前线程 remaining_tick--
        -> 时间片为 0时标记 YIELD，并调用 rt_schedule()
        -> rt_timer_check()           检查线程睡眠定时器
     -> rt_interrupt_leave()          rt_interrupt_nest--
     -> return epc
```

当 `rt_schedule()` 在中断上下文中发现需要换线程时，它不会立刻在 C 函数中更换
`sp`，而是调用非 SMP 的弱实现 `rt_hw_context_switch_interrupt()`：

```text
rt_hw_context_switch_interrupt(&from->sp, &to->sp)
  -> rt_interrupt_from_thread = &from->sp
  -> rt_interrupt_to_thread   = &to->sp
  -> rt_thread_switch_interrupt_flag = 1
```

回到 `trap.S` 后，汇编检查这个标志：

```text
if (rt_thread_switch_interrupt_flag) {
    *rt_interrupt_from_thread = 当前 trap frame 的 sp;
    sp = *rt_interrupt_to_thread;
}
恢复 sp 所指向线程的上下文
mret
```

因此中断处理函数本身始终在原线程的 trap frame 上安全执行，真正的栈切换发生在
统一的异常返回出口。这就是当前抢占式调度能够工作的关键。

`workerA` 和 `workerB` 都在 `burn_ticks(6)` 中持续运行，没有调用
`rt_thread_yield()`。它们仍会按 5 tick 时间片互相切换，因此可以验证切换确实由
机器定时器中断触发，而不是线程主动让出 CPU。

### 5.7 `rt_thread_mdelay()` 如何睡眠和唤醒

```text
rt_thread_mdelay(3)
  -> rt_tick_from_millisecond(3)      RT_TICK_PER_SECOND=1000，所以得到 3 tick
  -> rt_thread_sleep(3)
     -> 挂起当前线程
     -> 设置当前线程的 one-shot timer 超时时间
     -> rt_timer_start()
     -> rt_schedule()                 切换到其他就绪线程/idle
```

每次定时器中断中的 `rt_tick_increase()` 都会调用 `rt_timer_check()`。到期后：

```text
rt_timer_check()
  -> _thread_timeout(thread)
     -> 从挂起链表移除线程
     -> 插入调度就绪队列
     -> rt_schedule()
```

main 的优先级高于 idle，因此到期后会抢占 idle，并从
`rt_thread_mdelay()` 后面继续运行。

### 5.8 `ecall` 同步异常自检

`rt_hw_trap_self_test()` 给 `a0/a1/t0/s1` 写入固定值后执行 `ecall`：

```text
ecall
  -> CPU 设置 mcause=11、mepc=ecall 地址
  -> mstatus.MPIE=MIE，MIE=0
  -> PC=mtvec
  -> trap_entry 保存现场
  -> rt_hw_trap_handler(11, epc)
     -> trap_ecall_count++
     -> return epc + 4
  -> trap_entry 恢复现场
  -> mret，从 ecall 下一条指令继续
  -> 比较 a0/a1/t0/s1 是否保持不变
```

这同时验证了 `ecall/mret`、`mcause/mepc/mstatus` 和完整整数上下文保存。

### 5.9 `rt_kprintf()` 如何到达终端

```text
rt_kprintf(...)
  -> RT-Thread 格式化输出
  -> rt_hw_console_output(str)
  -> 每个字符写入 0x80200060
  -> perip_bridge 的 __VERILATOR__ 分支执行 $write("%c", ...)
  -> 主机终端
```

换行前会额外写 `\r`，所以输出是 `\r\n`。这条链只在 Verilator 中成立；FPGA
上的 `top.sv` UART 当前服务于数字孪生 `twin_controller`，并没有接收 CPU 对
`0x80200060` 的写请求。若要上板看到 RT-Thread 横幅，必须新增 UART TX MMIO，
或者在不破坏 twin 协议的前提下增加仲裁/第二串口。

### 5.10 LED 和测试结束

main 启动后写入并回读：

```text
*(0x80200040) = 0x52545401
```

写请求由 `perip_bridge` 保存，并通过无异步 FIFO的 CDC 快照送到 50 MHz 显示域，
最终驱动 `virtual_led`。仿真结束时 `halt(0)` 执行 `ebreak`，NPC 将返回码 0 显示为
`HIT GOOD TRAP`。FPGA 上没有 NPC 接管 `ebreak`，代码随后停在 `halt()` 的无限
循环中，LED 保持启动标记。

## 6. Verilator 软件仿真

### 6.1 环境准备

至少需要：

- GNU Make；
- Verilator；
- RISC-V RV32 裸机工具链；
- NPC 已有的 Capstone、SDL/NVBoard 构建依赖。

RT-Thread BSP 当前默认工具链前缀为：

```text
/home/dragonflame/tools/riscv-gcc-16.1-rv32im/bin/riscv32-unknown-elf-
```

如果路径不同，在命令中覆盖，例如：

```sh
make CROSS_COMPILE=riscv32-unknown-elf- image
```

### 6.2 构建和启动 RT-Thread

```sh
cd /path/to/ysyx-redbean/rtthread-nano/rt-thread/bsp/MundusJyd
make run
```

`make run` 会先生成 ELF、BIN、反汇编和 map，再构建 `MundusJyd` Verilator
仿真器并启动 RT-Thread。公开目标只保留默认 `all/image`、`run` 和 `clean`；不再
区分 regression、coremark、competition 三套应用目标。

主要产物：

```text
build/mundus-jyd-nano.elf
build/mundus-jyd-nano.bin
build/mundus-jyd-nano.map
build/mundus-jyd-nano.txt
build/console.log
build/coremark/coremark_report.txt
build/coremark/npc-jyd.log
build/coremark/branch_difftest_report.txt
build/coremark/pipeline_report.txt
build/coremark/memory_report.txt
```

成功输出应包含以下关键内容：

```text
RT-Thread Operating System
3.1.5 build ...
MundusJyd competition shell ready.
Type 'help', 'coremark' or 'quit'.
msh >
```

### 6.3 构建并运行

BSP 只生成一个固件：RT-Thread 启动后进入最小 MSH，输入 `coremark` 才运行当前
CoreMark。默认迭代 100 次，直接执行：

```sh
cd /path/to/ysyx-redbean/rtthread-nano/rt-thread/bsp/MundusJyd
make run
```

出现 `msh >` 后依次输入：

```text
help
coremark
quit
```

也可以用环境变量自动注入命令，分号表示回车：

```sh
JYD_CONSOLE_CMDS='help;coremark;quit' \
  make run COREMARK_ITERATIONS=1
```

CoreMark 开始前写 `LED0=1`，返回后立即写 `LED0=0`。Verilator 会在每次合法
LED MMIO 写入时显示 32 位 LED 图形和对应的 cycle/value；运行结束后重新出现
`msh >`，说明操作系统和 shell 没有退出。输入 `quit` 会执行 `halt(0)`，触发
`HIT GOOD TRAP` 并让 NPC 输出完整仿真统计报告；不输入 `quit` 时仍可继续执行命令。

每次通过本 BSP 执行 `make run` 时，构建脚本会把完整终端输出保存为
`build/console.log`，并把只属于 CoreMark 的产物集中到 `build/coremark/`。
`coremark_report.txt` 从 `2K performance run parameters` 开始，到 CoreMark 命令
结束为止，不包含 RT-Thread 启动和 MSH 提示。NPC 使用已有的 LED0 起止标志作为
`--stats-window=led0` 边界，因此分支、流水线、内存报告和仿真 Summary 也只统计
LED0 点亮期间，不计入 RT-Thread 启动、MSH 等待及 `quit` 路径。处理器功能 RTL 和
CoreMark 算法均未因此修改；窗口开关只作用于仿真统计计数器。

这些报告在仿真结束时落盘，所以交互执行 `coremark` 后还需要输入 `quit`。输出目录
可以整体覆盖：

```sh
JYD_CONSOLE_CMDS='coremark;quit' make run \
  COREMARK_RESULTS_DIR=/tmp/coremark-results
```

仿真控制台 MMIO 为：

| 地址 | 功能 |
| --- | --- |
| `0x80200060` | TX字符写入；Verilator使用`$write`，FPGA发送到物理UART |
| `0x80200064` | 状态寄存器，bit 0为RX有效，bit 1为TX可接受新字符 |
| `0x80200068` | 读取并弹出一个RX字符 |

RX的Verilator DPI实现先读取`JYD_CONSOLE_CMDS`，没有脚本数据时再非阻塞轮询
宿主终端。FPGA实现使用toggle握手在CPU时钟域和50 MHz UART域之间传递字符。

RT-Thread 内核、BSP、MSH 和汇编移植层使用 `-Os`；默认 CoreMark 五个算法文件和
`coremark_portme.c` 使用 `-O3`。一般对象保留 `-flto`；启用硬件 CRC 时，构建期生成
的算法编译单元在每个 CRC 调用点直接内联自定义指令。关闭硬件 CRC 时，
`core_util.c` 保持 non-LTO 调用边界，避免软件 CRC 被全局展开后超出固定 IROM。
构建期生成的矩阵编译单元也使用独立编译边界。`.rodata/.data/.bss` 位于 DRAM。

改变迭代次数不需要先清理：

```sh
make run COREMARK_ITERATIONS=10000
```

Mundus 默认启用两个 `custom-0` CoreMark 加速指令，CoreMark 原始算法文件保持
原样：

- `CRC16`（`funct7=0`）一次完成 `crcu16`。构建时
  `coremark/scripts/generate_crc_accel.py` 在 `build/obj` 生成临时算法编译单元，把 `crc16`、
  `crcu16` 和 `crcu32` 的调用映射到 `always_inline` intrinsic；最终调用点直接出现
  自定义指令，不经过 `jal`/`ret` 包装函数。
- `MULBE`（`funct7=1`）复用原 RV32M 乘法流水线，在写回端计算
  `((product >> 2) & 0xf) * ((product >> 5) & 0x7f)`。构建时
  `coremark/scripts/generate_matrix_accel.py` 读取 `core_matrix.c`，只在 `build/obj` 生成临时
  编译单元并替换对应热点表达式，不写回 CoreMark 目录。

默认同时启用两项：

```sh
JYD_CONSOLE_CMDS='coremark;quit' \
  make run COREMARK_HW_CRC=1 COREMARK_ITERATIONS=100
```

只启用矩阵或只启用 CRC：

```sh
JYD_CONSOLE_CMDS='coremark;quit' \
  make run COREMARK_HW_CRC=0 \
  COREMARK_HW_MATRIX=1 COREMARK_MATRIX_LINK_BOUNDARY=1 \
  COREMARK_ITERATIONS=100

JYD_CONSOLE_CMDS='coremark;quit' \
  make run COREMARK_HW_CRC=1 \
  COREMARK_HW_MATRIX=0 COREMARK_MATRIX_LINK_BOUNDARY=1 \
  COREMARK_ITERATIONS=100
```

关闭两项硬件加速：

```sh
JYD_CONSOLE_CMDS='coremark;quit' \
  make run COREMARK_HW_CRC=0 \
  COREMARK_HW_MATRIX=0 COREMARK_MATRIX_LINK_BOUNDARY=1 \
  COREMARK_ITERATIONS=100
```

独立指令回归分别位于 `npc/tests/crc16` 和 `npc/tests/mulbe`。矩阵和组合性能数据
见 `coremark/MATRIX_ACCEL_RESULTS.md`。

默认 CoreMark 是 EEMBC 仓库 `main` 的固定提交
`1f483d5b8316753a742cbf5590caf5bd0a4e4777`，源码位于 `coremark/eembc/`，版本和
SHA-256 清单见 `coremark/eembc/UPSTREAM_VERSION.md`。它的标准输出字段、
`README.md` 提示和比赛截图一致；`CoreMark 1.0` 是程序输出的基准名称，不代表只能
使用较老的 `v1.01` tag。

若比赛另发 CoreMark 包，可保持 BSP 端口和命令文件不变，只替换构建目录：

```sh
make run COREMARK_ROOT=/abs/path/to/coremark \
  COREMARK_ITERATIONS=10000
```

若包结构为 `src/` 加 `include/`，分别指定源码和头文件目录；官方 EEMBC 包本身的
`.c/.h` 是平铺结构，因此默认三项均指向 `coremark/eembc/`：

```sh
make run COREMARK_ROOT=/abs/path/to/coremark \
  COREMARK_SRC_DIR=/abs/path/to/coremark \
  COREMARK_INC_DIR=/abs/path/to/coremark \
  COREMARK_ITERATIONS=10000
```

所有对象都生成到 BSP 的 `build/obj`，不会写入 CoreMark 源码目录。
当前默认包的算法源码不含本地修改；输出和计时适配只位于 BSP 端口层，矩阵替换
只生成在构建目录。最新官方源码 A/B 数据见 `coremark/MATRIX_ACCEL_RESULTS.md`。

## 7. FPGA 上板

### 7.1 FPGA 与仿真的关键区别

FPGA 顶层是 `npc/vsrc/testbench/jyd/top.sv`：

```text
差分系统时钟
  -> pll
     -> cpu_clk                  驱动 Mundus CPU
     -> w_clk_50Mhz              驱动计时器、LED/数码管和 twin_controller
     -> locked
        -> ~locked 作为 CPU/外设高有效复位
```

FPGA 综合使用真实 Xilinx BRAM/IP 和 XPM CDC；Verilator 使用 DPI 存储器和
`xpm_cdc_verilator_stubs.sv`。因此仿真通过后仍必须检查 CDC、IP 初始化、时序
约束和 bitstream 实际行为。

### 7.2 已经具备的上板硬件路径

- CPU 复位入口和 IROM 基址均为 `0x80000000`；
- IROM 默认容量 32 KiB，由 NPC menuconfig 配置，RT-Thread `.text` 有链接期越界断言；
- DRAM 容量 256 KiB，链接脚本统一放置数据和栈；
- 计数器在 50 MHz 时钟下按 50,000 拍产生 1 ms；
- 计数值通过 Gray CDC 返回 CPU，计时器使能和 LED/SEG 也有 CDC；
- `timer_irq` 已连接 CPU，CSR 和 trap 路径均为可综合逻辑；
- `virtual_led` 可以显示 `0x52545401` 启动标记。

### 7.3 生成供 BRAM 初始化使用的镜像

先构建 BSP：

```sh
cd /path/to/ysyx-redbean/rtthread-nano/rt-thread/bsp/MundusJyd
make image
```

`mundus-jyd-nano.bin` 是从 `0x80000000` 开始的稀疏地址空间平铺文件，其中包含
IROM 到 `0x80100000` DRAM 之间的地址空洞，不能直接作为配置容量内的 IROM 初始化
文件。可先从 ELF 分别提取：

```sh
/opt/riscv32/bin/riscv32-unknown-elf-objcopy \
  -O binary --only-section=.text \
  build/mundus-jyd-nano.elf build/mundus-jyd-irom.bin

/opt/riscv32/bin/riscv32-unknown-elf-objcopy \
  -O binary --only-section=.rodata --only-section=.data \
  build/mundus-jyd-nano.elf build/mundus-jyd-dram.bin
```

`.bss` 不需要写入 DRAM 初始化文件，因为 `_start` 会在每次复位时清零它。

随后需要按 Vivado IP 的数据宽度把二进制转换成 COE/MEM：

- IROM 是 4096 项 × 64 bit，低地址 32 位指令放在 64 位字的低半部，高地址
  指令放在高半部；
- DRAM 是 65536 项 × 32 bit，按 RISC-V 小端字节序组织；
- 不足容量的尾部填零；
- 转换后检查入口前几个字是否与
  `build/mundus-jyd-nano.txt` 中 `0x80000000` 的反汇编一致。

当前仓库还没有把这一步自动化为 BSP Makefile 目标，正式上板前应补充固定脚本，
避免手工转换造成端序或位宽错误。

### 7.4 Vivado 上板流程

1. 生成/确认当前 Chisel RTL，并把 `Mundus.v`、`myCPU.v`、JYD `student_top`、
   `perip_bridge`、`counter`、CDC 文件和 FPGA `top.sv` 加入 Vivado 工程。
2. 将上一步的 IROM 内容写入 `IROM_BMEM` IP，将 DRAM 内容写入 `BRAM` IP。
3. 重新生成两个 IP 的 output products，确认综合没有仍引用旧 COE。
4. 使用真实 Xilinx XPM CDC，而不是 Verilator stub。
5. 检查 PLL 输出、复位极性、IROM/BRAM 时序和 CDC 约束。
6. 执行综合、实现和时序检查，确认目标 CPU 频率满足 WNS/TNS 要求。
7. 生成 bitstream，通过 Vivado Hardware Manager 或数字孪生平台烧录。
8. 复位后首先观察 `virtual_led` 是否变为 `0x52545401`。
9. 接入物理控制台后，再根据 RT-Thread 横幅、worker 输出和最终 tick/IRQ 计数判断
   是否完整启动。

### 7.5 当前仍需实板验证的内容

CPU MMIO已经接入物理UART，但尚未完成实板收发闭环。正式上板验收时建议依次：

1. 观察LED启动状态码；
2. 使用9600 8N1串口检查RT-Thread横幅和`help`；
3. 输入`coremark`验证完整交互和跑分；
4. 若没有输出，再用ILA观察UART MMIO、`timer_irq`和trap信号。

### 7.6 miniTensor 上板状态与可综合 DMA

- **可综合 DMA 端口**：`npc/vsrc/testbench/jyd/mt_dma_bridge_bram.sv` 把
  miniTensor 的 16 B DMA beat 拆成 4 次 32-bit 访问，复用 CPU 的 DRAM BRAM
  端口；`bram_driver` / `perip_bridge` 做端口仲裁，DMA 优先，CPU 的
  DRAM load 在 DMA 读期间 stall，CPU 的 store drain 在 DMA 写期间保持。
  综合时定义 `MUNDUS_SYNTH_DMA`；Verilator 也可用同一宏验证这条路径。
- **板级 LED/SEG 约定**（`miniTensor/integration/bsp/mt_board.h`）：
  `virtual_led` bit0=运行、bit1=通过、bit2=失败、bit15:8 和 bit23:16=进度或
  最终通过数；`virtual_seg` 显示通过的图像数，失败显示 `E0xx`。
- **启动自动演示**：`main()` 默认自动执行 `mt_detect` 并把结果锁存到
  LED/SEG（`MT_BOARD_AUTORUN`，可用空字符串关闭），不接串口也能看到结果。
- 完整说明与 Vivado 文件表见 `miniTensor/integration/FPGA.md`。

## 8. 已知限制和下一步

1. **物理串口尚未完成实板收发闭环。** CPU MMIO和UART RTL已接通，仍需验证
   板级引脚、电气连接和9600 8N1收发。
2. **比赛 shell 当前只在Verilator完成收发闭环验证。** CoreMark仍静态编入固件，
   但已经能通过 `help`、`coremark` 命令选择运行；没有文件系统或动态加载器。
3. **FPGA 镜像拆分没有自动化。** 需要把 ELF 的 IROM/DRAM 段可靠转换为 IP
   初始化文件。
4. **尚未对当前 RT-Thread 版本完成 FPGA 实板闭环验证。** 现有结论来自
   Verilator 功能回归和可综合代码检查。
5. **数码管仿真存在启动随机值问题。** 当程序从不写 LED/SEG 时，Verilator 的
   随机初始化可能使 CDC handshake stub 产生一次伪传输；RT-Thread 会通过合法
   LED 写把 SEG 快照重新置零，但独立 CoreMark 可能显示随机数。这个显示不代表
   CoreMark 结果，后续应在 CDC 复位期间屏蔽 `src_send`，不要通过关闭随机初始化
   掩盖问题。
6. **当前是最小单核配置。** 默认固件只有最小 MSH；没有 SMP、用户进程、MMU、
   文件系统、网络和动态模块加载。

建议后续优先级：增加`minstret/minstreth`指令计数 -> 物理UART实板闭环与FPGA镜像自动化
-> 当前 RT-Thread CoreMark 实板启动 -> 信号量/消息队列/互斥量回归 -> 比赛测试程序接入。
