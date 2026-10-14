# Y4：命令队列 —— 把每命令开销从 90 拍降到 25 拍

> 上一轮实测 149 cycles/命令，而加速器本身只要 ~24.5。这一轮先量清楚钱花在哪，
> 再对症下药。

---

## 1. 先量，再改

新增 `mt_perf` 命令做微基准，结果**推翻了原来的假设**：

| 操作 | cycles |
| --- | ---: |
| MMIO **写**（MT_INSTR） | **2** |
| MMIO **读**（MT_STATUS） | **11** |
| uncached DRAM 写 | 2 |
| uncached DRAM 读 | 11 |
| cached DRAM 写 | 6 |
| 一次完整 MT_LOAD（含轮询） | **57** |

结论：**写便宜是因为它只进 store buffer；贵的是读。** 每条命令要轮询状态直到
`busy` 清零，而每次轮询读就要 11 拍 —— **轮询比命令本身还贵**。

---

## 2. 改法：shim 里加命令 FIFO

`mt_cvxif_shim.sv` 加一个深度 8 的 `{instr, rs1, rs2}` 队列：

- `MT_KICK` 不再"启动一次事务"，而是**把当前三个暂存寄存器入队**；
- 队列非空时 shim 自动连续取指执行，命令之间没有空泡；
- `busy` = 队列非空 **或** 正在执行；只有**最后一条**完成时才置 `done`；
- 状态标志只在 **busy 为 0 时读**才清除 —— 这样在一批中间轮询不会吞掉
  前面命令报的错。

驱动侧配套：

```c
#define MT_FIFO_DEPTH   8u
#define MT_BATCH        (MT_FIFO_DEPTH - 1u)   /* 留一格，push 永不丢 */

int mt_push(instr, rs1, rs2);   /* 只入队，每 MT_BATCH 条自动排空一次 */
int mt_drain(void);             /* 排空并报告累积的错误 */
int mt_exec(...);               /* = push + drain，语义不变 */
```

`net_conv` 整个卷积层的所有命令（权重加载、每个 tap 的激活加载、GEMM、epilogue、
store）全部走 `mt_push`，**整层只在末尾 drain 一次**。

---

## 3. 途中抓到一个真实的 RTL 竞争

改完之后 `mt_conv` 从 144/144 正确变成 **72/144 错**，且都是 ±1 的小偏差
（典型的"少累加了一项"）。

根因：**软件暂存寄存器和执行寄存器是同一组**。shim 在 `S_IDLE` 弹队列时写
`instr_q/rs1_q/rs2_q`；而软件此刻正在写这三个寄存器准备下一条命令。同一个
`always_ff` 里两条非阻塞赋值，**后写的赢** —— 软件的写入被静默吞掉，于是
入队的是上一条命令的陈旧操作数。

修法是把两者分开：

```systemverilog
logic [31:0] instr_q, rs1_q, rs2_q;             // 执行用，弹队列时装载
logic [31:0] stg_instr_q, stg_rs1_q, stg_rs2_q; // 软件暂存，KICK 时入队
```

这个 bug **standalone 测试台抓不到**——因为那里的 `mt_exec` 每条命令都轮询，
队列永远是空的，弹队列和软件写入不会同拍。所以给测试台补了一个
**背靠背入队**用例（队列 4 条命令后统一 drain），现在能覆盖这个场景。

> 补测试台时还顺手抓到我自己的一个用例 bug：把 C 行号写成 `12'd12`（12 位）
> 而不是 `8'd12`，高位落进保留区，硬件正确地报了 operand error。
> 硬件行为是对的，测试写错了。

---

## 4. 结果

| 项 | 改前 | 改后 | 提升 |
| --- | ---: | ---: | ---: |
| `mt_conv` 整层 | 7495 cycles | **4650** | **1.61×** |
| `mt_net` 整网 | 2505519 cycles | **1755461** | **1.43×** |
| MT_LOAD（逐条轮询） | 90 cycles | — | |
| **MT_LOAD（批量）** | — | **25** | |
| **MT_GEMM（批量）** | — | **37** | |

网络侧：745472 MACs / 1755461 cycles = **0.42 MAC/cycle**（原 0.30），
@300 MHz 约 **5.85 ms/次**（原 8.4 ms）。
按此外推 YOLOv5n（2.25 GMAC）约 **18 s @300 MHz**（原 25 s）。

### 剩下的空间

`mt_net` 现在是 **104 cycles/命令**，而单条批量 GEMM 只要 37。差值的来源已经
不是 MMIO，而是：

1. `net_pad`：每层把激活重排成 `[kx][g][h][w][4]`，走 uncached 写（24832 字节 × 2 拍）；
2. `net_pool2`：池化走 uncached 读，每次读 11 拍（约 135k 拍）；
3. 层内循环的地址运算。

按 37 拍/命令算，16823 条命令的理论下限约 **0.62M 拍**，当前 1.76M，
**还有约 2.8× 的空间**，且全部在 CPU 侧，不需要动 RTL。

---

## 5. 复现

```bash
# standalone（含背靠背入队用例）
cd $MUNDUS_HOME/miniTensor && ./integration/npc/obj_shim/mt_shim

# 端到端
cd $MUNDUS_HOME/rtthread-nano/rt-thread/bsp/MundusJyd
make CROSS_COMPILE=riscv64-unknown-elf- MUNDUS_HOME=... NPC_HOME=... \
     MT_WITH_COREMARK=0 VERILATOR_RESET=0 \
     JYD_CONSOLE_CMDS='mt_perf;mt_conv;mt_net;quit' run
```
