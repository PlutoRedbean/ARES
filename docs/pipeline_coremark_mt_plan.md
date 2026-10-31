# Pipeline SoC：2/4-hart CoreMark MULTITHREAD 实施计划

> 状态：**Phase 1–3 已实现并通过 2/4-hart Verilator 验收（2026-10-30）**。
> 现有已通过项是 2-hart AMP（每个 hart 一份 `MULTITHREAD=1` 镜像，各打印
> 一份报告）；本文定义的是 **标准 CoreMark MULTITHREAD** 的单份聚合报告
> 方案。Phase 4（板级/扩展）尚未开始。
>
> 目标：2/4 hart 可配置；4 hart 时 `MULTITHREAD=4`、每 context 2,500
> iterations，CoreMark 自己显示 10,000 iterations；2 hart 时同样可配置。
>
> 非目标：共享 L2、cache coherence、原子指令、完整 AMP/OS、额外计分脚本。

## 1. 先固定语义

标准 CoreMark 的 `MULTITHREAD=N, ITERATIONS=M` 不是把同一个 N*M 迭代状态
切成连续区间，而是：

- `core_main.c` 为每个 context 设置 `results[i].iterations = M`；
- N 个 context 各自完整跑 M 次迭代；
- `coremark_report_time(total_time, default_num_contexts * results[0].iterations)`
  报告总迭代数 `N*M`；
- 每个 context 独立产生 CRC，CoreMark 自己打印 `[0]..[N-1]` 的 CRC 行。

因此 4 hart、每 context 2,500 的报告是：

```text
Iterations : 10000
```

总工作量 10,000，接近 4x 吞吐；但不是同一 10,000 状态被切成四段。若要求
同一状态连续切分，必须修改 benchmark 本体，CRC/分数不再标准；本计划不采用。

## 2. 配置项

所有配置都是 **build-time 参数**，不做运行时软件切换。

| 配置 | 2 hart | 4 hart |
| --- | --- | --- |
| `CORES` | 2 | 4 |
| `MULTITHREAD` | 2 | 4 |
| `default_num_contexts` | 2 | 4 |
| `TOTAL_ITERATIONS`（默认） | 10,000 | 10,000 |
| `ITERATIONS = TOTAL/CORES` | 5,000 | 2,500 |
| CoreMark 报告 Iterations | 10,000 | 10,000 |
| 每 hart 私有 DRAM | 32 KiB | 32 KiB |
| `DATA_STRIDE` | `0x8000` | `0x8000` |
| mailbox 槽 | 2 | 4 |

默认采用 **固定总工作量 10,000**，这样 2/4 核的聚合分数可以直接比较。
如果希望固定每 context 2,500，可把 `COREMARK_MT_TOTAL_ITERATIONS` 设为
`CORES*2500`（2 核总 5,000，4 核总 10,000）；这作为可选 profile，不作为
默认。Verilator 目标另有 `PIPELINE_MT_SIM_TOTAL`（默认 200）。

构建目标（已实现）：

```bash
make pipeline-coremark-mt-image CORES=2   # MULTITHREAD=2, ITERATIONS=5000
make pipeline-coremark-mt-image CORES=4   # MULTITHREAD=4, ITERATIONS=2500

make pipeline-coremark-mt CORES=2
make pipeline-coremark-mt CORES=4
make pipeline-coremark-mt-test            # 2 + 4 都跑

# 全加速（CRC8 + matrix + state）变体：单份聚合报告
make pipeline-coremark-full-mt CORES=2

# 全加速 AMP（每个 hart 一份 MULTITHREAD=1 报告，TB 只检查 done/a0）
make pipeline-coremark-mc CORES=2
make pipeline-coremark-mc CORES=4
```

> **IROM 容量**：2-hart 全加速聚合镜像是 32,432 B（`.boot` 316 +
> `.text` 32,116），在 32 KiB IROM 中只剩 336 B；4-hart 全加速聚合镜像会
> 溢出 300 B（需约 33,068 B），当前无法链接。4-hart 全加速请用 AMP 变体
> （MULTITHREAD=1 镜像 30,436 B，可放 4 份私有窗口），或把 IROM 扩到
> 64 KiB（Phase 4）。基础（非加速）4-hart MT 只有 13,800 B，正常。

> 命名说明：旧的 OoO 2-hart overlay 仍占用 `coremark-mt-image` /
> `coremark-full-mt-image`（`build/coremark_mt`），因此 pipeline 的
> MULTITHREAD 镜像改用 `pipeline-coremark-mt-image` /
> `pipeline-coremark-full-mt-image`。
>
> `PIPELINE_MT_SIM_TOTAL` 控制 Verilator 目标的总迭代数（默认 200，即
> 2×100 / 4×50）。规范报告的默认总量仍是 10,000；完整 10,000 次迭代在
> Verilator 中需要数小时，验收时按比例缩小并在下方记录。

输出目录必须按 `CORES` 分开：

```text
build/coremark_mt2/
build/coremark_mt4/
```

原因：`MULTITHREAD` 和 `ITERATIONS` 都是编译期宏，2/4 核不能共用同一个
`.bin`/DMEM 镜像。

## 3. SoC 结构

```text
                 shared read-only IROM (32 KiB)
              /        |          |          \
           hart0     hart1      hart2      hart3
            |         |          |          |
          L1 D$     L1 D$      L1 D$      L1 D$      私有，无 coherence
            |         |          |          |
        private   private    private    private
        DRAM0     DRAM1      DRAM2      DRAM3        32 KiB each
        accel0    accel1     accel2     accel3        每 hart 私有
        timer0    timer1     timer2     timer3
              \        |          |          /
                shared uncached mailbox
                (GO/DONE/ITER/SEED/CRC/ERR)
```

- **不实例化 L2**；
- **不做 coherence/invalidate**；
- **不做原子/锁**；
- mailbox 是 uncached MMIO，只做 CoreMark 的启动/结果汇总；
- 代码只读，可共享；数据/加速器状态每 hart 私有。

### 3.1 顶层与参数

实现为 `rtl/pipeline/soc/amp/pipeline_amp_top.sv`（`CORES=2/4`）；旧模块名
`pipeline_coremark_amp_top` 保留为薄封装。

- `generate` 循环实例化 `CORES` 个 hart；
- 每个 hart：
  - Mundus core；
  - 私有 L1 D$；
  - 私有 DRAM 32 KiB；
  - 私有 MMIO：UART/timer/cycle counter；
  - 私有 matrix/state 加速器；
- 共享：
  - IROM（多 bank 或物理复制）；
  - uncached mailbox；
  - 全局 start/done/cycle（可选，CoreMark 自己计时也可）。

2/4 核使用同一份 RTL，通过 `CORES` 参数和 `-GCORES` 展开。

### 3.2 地址空间

```text
0x8000_0000 - 0x8000_7FFF      shared IROM，32 KiB，只读
0x8010_0000 + h*0x8000         hart h 私有 DRAM 32 KiB
0xA000_0000 + h*0x1000         hart h 私有 MMIO：UART/timer/accel
0xA000_F000                    shared mailbox（uncached）
```

- `DATA_STRIDE=0x8000`；
- 4 hart：4 x 32 KiB = 128 KiB；
- `_stack_top = 0x8010_8000 + h*0x8000`；
- 可以用现有硬件 `DATA_OFFSET`，也可以软件设置 `sp/gp`。

### 3.3 Mailbox

实现：`rtl/pipeline/soc/mc/pipeline_coremark_mbox.sv`，256 B 窗口
`0xA000_F000`，每 hart 一个 16-word 槽（`h*0x40`），**槽 h 归 hart h 所有**：

| 偏移 | 方向 | 内容 |
| --- | --- | --- |
| `0x00 + h*0x40` | hart0 -> hart h | `GO` |
| `0x04 + h*0x40` | hart h -> hart0 | `DONE` |
| `0x08 + h*0x40` | hart0 -> hart h | `ITERATIONS` |
| `0x0C + h*0x40` | hart0 -> hart h | `EXECS` |
| `0x10 + h*0x40` | hart0 -> hart h | `SIZE` |
| `0x14..0x1C + h*0x40` | hart0 -> hart h | `SEED1..SEED3` |
| `0x20..0x2C + h*0x40` | hart h -> hart0 | `CRCLIST/CRCMATRIX/CRCSTATE/CRCFINAL` |
| `0x30 + h*0x40` | hart h -> hart0 | `ERR` |

- 单字读写（字节 strobe），不需要原子；
- uncached，经由 `perip_bridge` 的原 MMIO 端口，不经过 L1 D$；
- 每个 hart 通过 `0xA000_0FF0` 读取自己的 hart id（单发射核没有 `mhartid`，
  由 `perip_bridge` 的 `HART_ID` 参数提供）；
- MMIO 端口本身按程序序单发、且 `perip_ready` 要求更老 store 排空，因此
  **不需要 `fence`**；只用编译器 barrier。
- 只有 hart0 打印，其他 hart 只写 mailbox。

> 实现记录：在描述符写与 `GO` 之间插入 `fence iorw, iorw` 会让流水线停在
> `fence_wait`（LSU 中仍有待完成的设备 store，`perip_idle` 不拉高）。由于
> 该 MMIO 路径已经强序，软件改用编译器 barrier，并把“fence 紧跟设备 store”
> 记为后续 core/LSU 待查项。

## 4. CoreMark port 改造

现有 `build/coremark_mt/port` 是 2-hart overlay，需要参数化到 2/4。

### 4.1 宏与默认 context

```c
#define MULTITHREAD 4          /* 或 2 */
#define ITERATIONS  2500       /* 或 5000 */
ee_u32 default_num_contexts = 4;  /* 或 2 */
```

- `MEM_STACK`（`MULTITHREAD>1` 时 CoreMark 不使用 `MEM_STATIC`）；
- `TOTAL_DATA_SIZE=2000`；
- 4 context 的 `.bss` 约 8 KiB，单 hart 32 KiB 窗口足够；
- 2/4 核分别构建，不能共用镜像。

### 4.2 启动分发

`core_portme.c` 的 `portable_init()`：

```c
uint32_t id = hart_id();           /* 读 0xA000_0FF0（perip_bridge HART_ID） */
if (id >= 1 && id < COREMARK_HARTS) {
    coremark_hart(id);   /* 不返回 */
}
/* hart0 继续 core_main() */
```

- hart1..N-1 在 `coremark_hart(id)` 里等待自己的 `GO`；
- hart0 作为 context 0，在 `core_stop_parallel` 中执行；
- 每个 hart 用自己的私有 `.data/.bss`，静态 `mt_results/mt_memblock` 不共享。

### 4.3 `core_start_parallel`

CoreMark 依次调用 N 次：

- context 0：只记录，不启动其他 hart；
- context 1..N-1：写对应 hart 的 mailbox：
  - `ITERATIONS`
  - `SIZE/EXECS/SEED1..3`
  - `GO=1`

### 4.4 `core_stop_parallel`

- context 0：执行 `iterate(&results[0])`；
- context 1..N-1：轮询对应 hart 的 `DONE`，读回 CRC/ERR 到
  `results[i]`。

这样 N 个 hart 并行跑各自的 `ITERATIONS`，CoreMark 最后只打印一份报告，
总 iterations = `N * ITERATIONS`。

### 4.5 串口输出约束

- 只让 **hart0** 调用 `ee_printf`；
- hart1..N-1 不打印；
- 不添加自定义 banner、per-context 汇总、额外 CRC 行；
- UART 上只出现 CoreMark 自己的标准输出；
- CoreMark 自带的 `[0]..[N-1]` CRC 行保留，不做额外修改；
- testbench 只解析 host 侧结果，不向 UART 注入文本。

## 5. L1 I$（已实现）

实现：`soc/amp/pipeline_amp_icache.sv` + `soc/amp/pipeline_irom_arbiter.sv`。

- 每 hart 私有 L1 I$：默认 256 行 × 64 B = 16 KiB，直接映射；
  `ICACHE_LINES` 参数化（full-accel 镜像的 ~30 KiB 代码用 512 行）；
- 取指使用与单 hart 主线 I$ 相同的 req/rsp/flush 握手；命中时请求当拍
  接受、下一拍返回指令；miss 时 `req_ready` 为低，IFU 保持 PC 且不分配
  响应槽，refill 完成后同一 PC 重新命中；
- refill 从**单端口共享 32 KiB IROM**：4 个 hart 的 refill 请求经
  round-robin 仲裁，一次授权完成整行 16 word 突发，保证不会装半行；
- 代码只读，**不需要 I$ coherence**；`FENCE.I` 没有可失效的行
  （IROM 不可写），因此不接失效信号；
- I$ 只减少 IROM 带宽压力，不引入 L2。

对照：无 I$ 时必须物理复制 N 份 IROM 或做多 bank；有 I$ 后单个共享 bank
即可（`make pipeline-coremark-mt ... USE_ICACHE=0` 可回退到 Phase 2 的
复制 bank 结构）。

## 6. 实施阶段

### Phase 1：2/4-hart CoreMark port（已完成）

- [x] 新增共享邮箱 `soc/mc/pipeline_coremark_mbox.sv`（4 槽、单字、uncached）；
- [x] `perip_bridge` 增加 `HART_ID`/`HART_COUNT` 与 `0xA000_F000` 共享 MMIO 转发；
- [x] `student_top` 透传共享 MMIO 端口，AMP top 为每个 hart 接一个邮箱端口；
- [x] `scripts/coremark_mt_pipe/` 参数化 overlay：`ARES_MT_CORES` /
  `ARES_MT_ITERATIONS` 由 staged Makefile 的 `-D` 传入；
- [x] `coremark_hart(id)` 替代固定 `coremark_hart1`，
  `core_start/stop_parallel` 支持 1..N-1；
- [x] TB/仿真主程序支持 2/4 hart（4 个完成端口，未用端口视为 done）；
- [x] 构建 `build/coremark_mt2`、`build/coremark_mt4`，目标
  `pipeline-coremark-mt-image`、`pipeline-coremark-mt`、
  `pipeline-coremark-mt-test`；
- [x] 在私有内存 AMP top 上完成 2/4-hart 验证。

验收（已实测，200 总迭代的仿真 profile）：

| 项 | 2 hart | 4 hart |
| --- | --- | --- |
| 每 context iterations | 100 | 50 |
| CoreMark 报告 Iterations | 200 | 200 |
| timed ticks | 43,666,830 | 21,815,102 |
| CoreMark/MHz | 4.580135 | 9.167960 |
| `[0..3]crcfinal` | 0x988c ×2 | 0x0158 ×4 |
| 单核同迭代数参考 CRC | 0x988c（100 iter，既有基线） | 0x0158（50 iter，单 context 参考镜像） |
| 所有 hart `a0` | 0 | 0 |
| UART | 仅 CoreMark 标准输出 | 仅 CoreMark 标准输出 |

全加速组合（CRC8 + array list + matrix + state）也已验证：
`build/coremark_full_mt2` + 同一个 AMP 仿真器（2 hart，每 context 100）
得到 `Iterations : 200`、`15.821581 CoreMark/MHz`，`[0]/[1]` CRC 全同、
`a0=0`、`CoreMark PASS`。

规范报告的 10,000 总迭代是镜像默认值（2×5,000 / 4×2,500），未在本机
Verilator 中跑满；上表用同一份代码按比例缩小到 200 总迭代验收。

> 说明：`fence` 紧跟设备 store 会停在 `fence_wait`（见 §3.3），overlay 使用
> 编译器 barrier；这是 Phase 1 的软件规避，core/LSU 的 fence 行为待单独排查。

### Phase 2：SoC v2 参数化 top（已完成）

- [x] `pipeline_amp_top #(CORES=2/4)`（`soc/amp/pipeline_amp_top.sv`）；
- [x] shared IROM：每个 hart 一份 32 KiB bank（物理复制），由 top 统一实例化；
  `student_top` 新增 `EXTERNAL_IROM` 选择外部取指；
- [x] 每 hart 私有 DRAM 32 KiB（`DATA_OFFSET = hart * 0x8000`）；
- [x] 每 hart 私有加速器/UART/timer（沿用 `student_top`）；
- [x] shared uncached mailbox（Phase 1 的 `pipeline_coremark_mbox`）；
- [x] 无 L2、无 coherence；
- [x] 2/4 核共用 RTL，通过 `CORES` 展开；旧名
  `pipeline_coremark_amp_top` 保留为薄封装。

验收（200 总迭代仿真 profile，与 Phase 1 结果逐位一致）：

| 项 | 2 hart | 4 hart |
| --- | --- | --- |
| `pipeline-coremark-mt` | PASS | PASS |
| timed cycles | 43,741,868 | 21,933,500 |
| CoreMark/MHz | 4.580135 | 9.167960 |
| `[0..3]crcfinal` | 0x988c ×2 | 0x0158 ×4 |
| 所有 hart `a0` | 0 | 0 |

- 无 mailbox 死锁；各 context CRC 与单核参考一致，等价于无跨 hart 数据串扰；
- 单核 `pipeline-smoke`、`pipeline-isa` 36/36、`pipeline-console` 保持不变；
- 全加速 2-hart（`build/coremark_full_mt2`）在同一 top 上 15.821581
  CoreMark/MHz、CRC 全同、PASS；
- 规范报告的 10,000 总迭代仍受 Verilator 时长限制，按 200 总迭代验收；
  10,000 总迭代镜像可用 `make pipeline-coremark-mt-image CORES=2` 构建。

### Phase 3：L1 I$（已完成）

- [x] 核心采用 req/rsp/flush 取指握手（`IROM` bundle + `IFU.scala`），重新生成
  `Mundus.sv`（3387 行）；miss 时 PC 保持、不分配响应槽；
- [x] 每 hart 私有 16 KiB 直接映射 I$（256 行 × 64 B，`ICACHE_LINES`
  可配）；
- [x] 单共享 32 KiB IROM + round-robin 整行 refill 仲裁；
- [x] 无 I$ coherence；只读 IROM 不需要 FENCE.I 失效；
- [x] 重测 2/4 核加速比和 IROM 带宽。

结果（200 总迭代）：

| 项 | 2 hart | 4 hart |
| --- | --- | --- |
| CoreMark/MHz（16 KiB I$，共享 bank） | 4.579943 | 9.166984 |
| CoreMark/MHz（无 I$，复制 bank） | 4.580135 | 9.167960 |
| timed cycles（I$） | 43,746,087 | 21,938,513 |
| refills / words（I$） | 202/3,232 + 115/1,840 | 207/3,312 + 3×(114/1,824) |
| `crcfinal` | 0x988c ×2 | 0x0158 ×4 |
| 所有 hart `a0` | 0 | 0 |

- 加速比 1.999× / 3.999×，与 Phase 2 相同（差异 <0.03%）；
- 整轮运行从共享 IROM 只取 **5,072（2 核）/ 8,784（4 核）** 个 word，
  替代了无 I$ 时每个取指周期对各自 bank 的读取；
- full-accel 聚合（`make pipeline-coremark-full-mt CORES=2`，512 行 I$）：
  15.816722 CoreMark/MHz、CRCs 0x988c ×2、PASS；
- 4-hart 全加速聚合镜像需要约 33,068 B，超出 32 KiB IROM 300 B，当前不可
  链接；4-hart 全加速用 AMP 变体（`make pipeline-coremark-mc CORES=4`，
  12,694,279 cycles、所有 hart `a0=0`）；
- legacy full-accel AMP（约 30 KiB 代码）用 512 行（32 KiB）I$ 保持
  12,687,129 cycles（16 KiB 时因容量 miss 慢约 3%）；
- `pipeline-coremark-mc` 固定 512 行 I$；`pipeline-coremark-mt` 默认 16 KiB。

### Phase 4：板级/扩展

- 2/4 核 Pango 顶层；
- 资源/时序签核；
- 可选 8 context。

## 7. 验证矩阵

| 项 | 2 hart | 4 hart |
| --- | --- | --- |
| CoreMark `MULTITHREAD` | 2 | 4 |
| 每 context iterations | 5,000 | 2,500 |
| 报告总 iterations | 10,000 | 10,000 |
| 每 context CRC | 与单核 5,000 一致 | 与单核 2,500 一致 |
| 所有 hart `a0` | 0 | 0 |
| UART | 仅 CoreMark 标准输出 | 仅 CoreMark 标准输出 |
| L2/coherence | 不实例化 | 不实例化 |
| L1 D$ | 每 hart 私有 | 每 hart 私有 |
| L1 I$ | 16 KiB 私有 | 16 KiB 私有 |
| 共享 IROM | 1 × 32 KiB + refill 仲裁 | 1 × 32 KiB + refill 仲裁 |
| 共享 mailbox | 2 槽 | 4 槽 |

## 8. 风险

1. **IROM 取指带宽**：无 I$ 时单端口 shared IROM 会破坏 2/4 倍扩展；Phase 3 的 I$ + refill 仲裁解决了这一点（无 I$ 时用复制 bank）。
2. **Mailbox 可见性**：必须 uncached + fence；不要走 L1 D$；不需要原子。
3. **每 hart 私有数据**：`mt_results/mt_memblock` 必须是每 hart 私有；不能共享写。
4. **2/4 镜像不能混用**：`MULTITHREAD/ITERATIONS` 是编译期宏，必须分目录。
5. **CoreMark 语义**：4 x 2,500 是四个独立 context，报告总 10,000；不是同一 10,000 状态连续切分。
6. **UART 输出**：只 hart0 打印；不添加任何自定义行。
7. **2 核总 iterations**：默认固定总工作量 10,000，所以 2 核每 context 5,000；若坚持每 context 2,500，2 核总报告是 5,000，需要单独 profile。

## 9. 现有相关实现

- [pipeline_coremark_full_mt_flow.md](pipeline_coremark_full_mt_flow.md)：IROM 镜像构建、全加速 MT 运行与结果检查的分步指南；
- `docs/coremark_multithread.md`：旧 2-hart CoreMark MT overlay 的行为和 mailbox 细节，可作为 port 改造参考；
- `docs/pipeline_multicore.md`：共享 L2/coherence 的 2/4-hart profile，与本方案互斥；
- `rtl/pipeline/soc/amp/pipeline_amp_top.sv`：SoC v2 参数化 top（`USE_ICACHE=1` 单共享 IROM + 每 hart I$；0 为复制 bank）；
- `rtl/pipeline/soc/amp/pipeline_amp_icache.sv`：每 hart 直接映射 I$（默认 16 KiB，req/rsp miss 停顿）；
- `rtl/pipeline/soc/amp/pipeline_irom_arbiter.sv`：round-robin 整行 refill 仲裁；
- `rtl/pipeline/core/scsrc/ifu/IFU.scala` / `common/MundusPayloads.scala`：req/rsp/flush 取指握手，重新生成 `Mundus.sv`；
- `rtl/pipeline/soc/mc/pipeline_coremark_amp_top.sv`：旧模块名的薄封装；
- `rtl/pipeline/soc/mc/pipeline_coremark_mbox.sv`：共享邮箱，4 槽 × 16 word；
- `rtl/pipeline/soc/jyd/perip_bridge.sv`：`HART_ID`/`HART_COUNT` 与共享 MMIO 转发；
- `rtl/pipeline/soc/jyd/student_top.sv`：透传共享 MMIO 端口；
- `scripts/coremark_mt_pipe/`：参数化 2/4-hart MULTITHREAD overlay；
- `scripts/build_coremark_image.py --mt-pipe --cores 2|4`：分目录镜像与冻结参数记录；
- `tests/abstract-machine/scripts/ares-linker-mc.ld`：32 KiB 私有窗口，`_stack_top=0x8010_8000`；
- `rtl/pipeline/test/tb_pipeline_coremark_amp.sv`：2/4-hart AMP TB；
- `rtl/pipeline/test/sim_coremark_amp_main.cpp`：`cores` 参数，检查所有 hart 的 done/a0。

## 10. 决策摘要

- 保留 **2/4 hart 可配置**：`CORES=2|4`、`MULTITHREAD=2|4`；
- 默认固定总工作量 10,000：2 核 2 x 5,000，4 核 4 x 2,500；
- 使用标准 CoreMark MULTITHREAD 的 mailbox/start/stop；
- hart id 由 `0xA000_0FF0` MMIO 提供（单发射核不实现 `mhartid`）；
- MMIO 强序，handshake 只用编译器 barrier；紧跟设备 store 的 `fence` 暂不要求；
- I$ 默认 16 KiB 直接映射，miss 用 req/rsp 握手停顿 IFU；共享 32 KiB IROM + refill 仲裁；
- 代码只读，不做 I$ coherence / FENCE.I 失效；
- 不做 L2、coherence、原子、完整 AMP；
- 每 hart 私有 DRAM/加速器，shared 只读 IROM；
- 只输出 CoreMark 自己的文本；
- L1 I$ 作为后续阶段，每 hart 私有，无 coherence。
