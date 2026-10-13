# FPGA DRAM 与双发射数据通路诊断

这个测试把当前 `AI_branch` 上的两个主要怀疑方向拆开验证：

1. 第二发射槽产生的寄存器值能否写入并在旁路消失后被正确读取；
2. DRAM 请求、读返回、慢速 load 完成以及 load 后重定向能否闭环。

本文不假设上传总结中的 PC 或 RTL 修改存在于当前分支。下文所有地址只对应本目录中
这两份 COE。

## 构建与仿真

在工作区根目录执行：

```bash
make -C npc/tests/fpga_dram_diag all
make -C npc/tests/fpga_dram_diag run
```

`make all` 生成上板镜像和反汇编；`make run` 构建带 `ebreak` 的仿真版本。上板版本
在最终显示值写入后原地循环。

已提交的镜像如下：

| 存储器 | 规格 | 文件 | SHA-256 |
|---|---:|---|---|
| IROM | 4096 x 64 | `images/fpga_dram_diag_irom.coe` | `19fd7765be0d92887096a98e29a893944fdc65cf5569c5387714b084fbf3f299` |
| DRAM | 65536 x 32 | `images/fpga_dram_diag_dram.coe` | `7dfc41e95b7164a97e372e1c233c3ae4156496b5fd81e773673b156504f70c31` |

DRAM 镜像在 `0x80100000` 放置 `0x5a3cc3a5`，在 `0x80100004` 放置
`0xc001d00d`。不要把仿真用的合并 `.bin` 加载到任一 FPGA 存储 IP。

在 Vivado 中，将 IROM COE 配给 64 位 IROM Block Memory Generator，将 DRAM COE
配给 32 位 DRAM。随后重新 Generate Output Products，Reset synthesis/implementation
runs，再生成 bitstream，避免旧 DCP 继续包含此前的 COE。

## 程序结构

`x30` 是由 lane 0 生成的 SEG 基准地址 `0x80200020`。独立的 `x15` 最终由
对齐取指组的高 32 位指令产生：

```text
0x80000128  addi x21, x21, 1
0x8000012c  addi x15, x15, 0x20    # 高 32 位，即 slot 1
```

程序先在附近使用一次 x15，再执行足以越过所有普通旁路窗口的无关指令，然后比较
x15 和 x30。此后还会在 DRAM load 停顿后以及 taken redirect 后再次使用 x15。

每次显示阶段码后都有 64 条 NOP。SEG 快照通过一个不会用 busy 反压 MMIO 写的
mailbox 跨域，数码管还需要完成两个扫描相位；这个间隔保证阶段码具有可观察性。

## 数码管判读

| 稳定显示 | 含义 |
|---|---|
| `00000000` | 第一条 lane-0 SEG store 未被观察到。检查复位、IROM 内容/延迟、CPU 时钟和基本 MMIO 写路径。 |
| `10101010` | 取指和 lane-0 MMIO 基准路径有效；程序未完成随后靠近生产者的 x15 阶段。 |
| `11111111` | lane-1 产生的 x15 在近距离使用成功。若长期停在此处，检查延迟读取及流水是否继续前进。 |
| `E1010001` | 旁路失效后 x15 不再等于 x30。重点检查 lane-1 WBU mask、GPR 写口 1、GPR 读数据和 holding entry 绑定。 |
| `12121212` | x15 持久读取成功；程序未到达或未完成 DRAM 前阶段码。 |
| `20202020` | `0x80000570` 的 DRAM load 未完成架构可见流程。按下文 DRAM ILA 流程抓取。 |
| `5A3CC3A5` | 正确 DRAM 数据已经进入 load-to-store 路径，但比较或后续 x15 store 未完成。 |
| `E2010001` | DRAM load 得到的值不是 `0x5a3cc3a5`。 |
| `30303030` | x15 已经跨过 DRAM stall；故障位于 taken branch 之后的 redirect 恢复或最终 x15 使用。 |
| `E3010001` | `0x80000690` 的等值 `beq` 错误地落入顺序路径。 |
| `E3020001` | redirect target 已执行，但此时读取的 x15 不再等于 x30。 |
| `50505050` | lane-1 持久写入、DRAM 返回、慢速 load 完成、load 数据使用、taken redirect 和最终 x15 MMIO store 全部通过。 |

因此，之前的直接 `sw` 实验不能单独排除全部 MMIO/CDC 或 DRAM 问题。它证明的是
一次 MMIO 写事务。到达 `12121212` 才能更强地证明 lane-1 GPR 持久性；到达
`50505050` 才是在同一 bitstream、同一次执行中串联验证这些怀疑路径。

## 关键 PC

| PC | 指令或事件 |
|---:|---|
| `0x8000012c` | slot-1 的 x15 最终生产者 |
| `0x8000033c` | 延迟后的 `bne x15,x30` |
| `0x80000570` | `lw x13,0(x29)`，地址为 `0x80100000` |
| `0x80000578` | 经 x30 直接显示返回的 x13 |
| `0x80000588` | redirect 前经旧 x15 写入 `30303030` |
| `0x80000690` | 强制 taken 的 `beq x13,x14` |
| `0x800006a0` | redirect target 和延迟 x15 比较 |
| `0x800006ac` | 经 x15 写入最终值 `50505050` |

顶层 IROM 地址是取指地址，不是退休 PC。关联架构事件时应使用 WBU、ISU 或
holding entry 中的 PC。

## ILA 建立方法

先用实际要上板的 RTL 和 COE 做一次全新综合。打开 synthesized design，找到 CPU
实例，并确认 compile order 使用当前 `Mundus.sv` 和双写四读 `RegisterFile.v`。
可用以下 Tcl 搜索信号：

```tcl
get_cells -hier -filter {REF_NAME =~ *Mundus*}
get_nets -hier -regexp {.*_GPR_io_wen1_T_1.*}
get_nets -hier -regexp {.*io_perip_(valid|ready|rvalid|addr|wen|wdata|rdata).*}
get_nets -hier -regexp {.*issueHolding_[01]_gprRs1_[01].*}
```

对所需 net 执行 Mark Debug，然后运行 **Set Up Debug**。ILA 时钟必须选择驱动
`Mundus` 的 CPU 时钟，不要把 `cnt_clk` 显示域信号混入同一个 ILA。当前程序使用
4096 点深度、触发位置约为第 512 点即可覆盖完整执行。先 arm ILA，再按板上 reset，
让一次性程序在采集已就绪后启动。

ILA 会改变布局，可能移动时序敏感故障。implementation 后必须检查
`report_timing_summary`；CPU 时钟 WNS 为负的 ILA bitstream 不能作为干净的功能证据。

## 抓取 A：lane-1 x15 路径

加入以下当前生成 RTL 中的信号，Vivado 中会带层次前缀：

```text
_GPR_io_wen0_T_1
_GPR_io_wen1_T_1
_WBU_io_gprWriteMask[1:0]
_WBU_io_gpr_0_addr[4:0]
_WBU_io_gpr_0_data[31:0]
_WBU_io_gpr_1_addr[4:0]
_WBU_io_gpr_1_data[31:0]
_WBU_io_pc_0[31:0]
_WBU_io_pc_1[31:0]
gprReadEnable
_GPR_rdata1_0[31:0]
_GPR_rdata1_1[31:0]
issueHoldingCount[1:0]
issueHoldingHead
issueHoldingTail
issueHolding_0_group_lane_0_pc[31:0]
issueHolding_0_group_lane_1_pc[31:0]
issueHolding_1_group_lane_0_pc[31:0]
issueHolding_1_group_lane_1_pc[31:0]
issueHolding_0_gprRs1_0[31:0]
issueHolding_0_gprRs1_1[31:0]
issueHolding_1_gprRs1_0[31:0]
issueHolding_1_gprRs1_1[31:0]
_ISU_io_out_bits_lane_0_pc[31:0]
_ISU_io_out_bits_lane_1_pc[31:0]
_ISU_io_out_bits_lane_0_rs1_val[31:0]
_ISU_io_out_bits_lane_1_rs1_val[31:0]
localEx1Hold
```

使用三个条件 AND 触发：

```text
_GPR_io_wen1_T_1 == 1
_WBU_io_gpr_1_addr == 15
_WBU_io_gpr_1_data == 0x80200020
```

随后沿时间轴跟踪 x15 到 `0x8000033c` 的延迟比较、`0x80000588` 的 redirect 前
store，以及 `0x800006ac` 的 target store。

按第一个错误点判断：

| 第一个错误点 | 更可能的故障 |
|---|---|
| WBU addr/data 正确，但 `_GPR_io_wen1_T_1=0` | lane-1 retire/write mask 生成 |
| 最终 GPR 写使能为 1，后续 GPR 读数据为 0/错误 | 寄存器堆写口 1、Vivado 引用了错误源码，或 GPR 时序违例 |
| GPR 读正确，holding `gprRs1` 错误 | 同步读返回与 holding 元数据配错 |
| holding 正确，ISU rs1 错误 | ISU 选择、late-source 元数据或 hold 覆盖 |
| ISU rs1 正确，但已接受的 SEG store 地址错误 | AGU/prepared-address 流水关联 |

若综合网表优化掉某个名字，先按后缀搜索。不要为了抓信号直接新增顶层接口；接口改动
需要单独确认方向后再做。

## 抓取 B：DRAM 读返回路径

加入 CPU 域外设接口和 load 控制信号：

```text
io_perip_valid
io_perip_ready
io_perip_rvalid
io_perip_addr[31:0]
io_perip_wen
io_perip_wdata[31:0]
io_perip_rdata[31:0]
_EXU_io_load_miss_hold
_EXU_io_lsu_slow_valid
scalarWaitValid          # 若 EXU 内部该信号在综合后仍保留
localEx1Hold
_WBU_io_gpr_0_addr[4:0]
_WBU_io_gpr_0_data[31:0]
_WBU_io_gpr_1_addr[4:0]
_WBU_io_gpr_1_data[31:0]
_WBU_io_pc_0[31:0]
_WBU_io_pc_1[31:0]
```

用以下四个条件 AND 触发已接受的 DRAM read：

```text
io_perip_valid == 1
io_perip_ready == 1
io_perip_wen == 0
io_perip_addr == 0x80100000
```

预期顺序是：

```text
request valid+ready，addr=0x80100000
load wait/hold 拉高
io_perip_rvalid，rdata=0x5a3cc3a5
_EXU_io_lsu_slow_valid
WBU 写 x13=0x5a3cc3a5
SEG write 被接受，addr=0x80200020，wdata=0x5a3cc3a5
SEG write 被接受，wdata=0x30303030
从 0x80000690 redirect 到 0x800006a0
SEG write 被接受，wdata=0x50505050
```

若稳定显示 `20202020`，按第一个缺失事件分类：

| 观察结果 | 结论 |
|---|---|
| 没有触发已接受的 DRAM read | bridge 之前的地址生成或请求问题 |
| 请求已接受，但没有 `rvalid` | DRAM BRAM/bridge 返回路径 |
| `rvalid` 和数据正确，但没有 LSU slow-valid | LSU 返回捕获或 slow-load tag/元数据 |
| LSU slow-valid 出现，但没有 x13 写回 | EXU slow completion 到 WBU |
| x13 写回正确，但没有直接 SEG 请求 | load 结果消费者或 store 发射路径 |
| 直接 SEG 请求正确，显示仍未更新 | bridge 到显示的 mailbox/CDC，或 Vivado 源文件不一致 |

若稳定显示 `30303030`，将抓取 A 的触发条件移到 branch/redirect 事件，并保留足够的
触发后采样点覆盖 `0x800006ac`。

## 每次上板需要保留的数据

记录最终显示值、bitstream SHA-256、两份 COE 的 SHA-256、Vivado WNS/TNS、触发条件
和导出的 ILA CSV。只有这些标识一致，才适合把新波形与其他分支或其他生成配置的波形
进行比较。
