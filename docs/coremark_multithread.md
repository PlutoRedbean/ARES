# CoreMark MULTITHREAD=2：双核并行、单份报告

> 状态：2026-10-29 本地仿真通过。EEMBC 源码零修改（overlay 只落在 `build/coremark_mt/port`）。
>
> 新的 pipeline SoC 2/4-hart 方案见
> [pipeline_coremark_mt_plan.md](pipeline_coremark_mt_plan.md)；本文保留旧
> 2-hart overlay 的实现细节作为参考。

## 结论

默认镜像（`build/coremark`）保持原样：`MEM_STATIC` + `MULTITHREAD=1`，两个 hart 各跑一份 AMP 实例、各打印一份成绩。

新增的 MT 镜像（`build/coremark_mt`）是标准 CoreMark 多 Context 语义：

- `MULTITHREAD=2`，两个 context 真并行；
- `default_num_contexts=2`；
- **hart0 只打印一份报告**，`Iterations = 200`，并带 `Parallel ares-2hart-mbox : 2`；
- 两个 context 的 `crclist/crcmatrix/crcstate/crcfinal` 相同，`CoreMark PASS`。

实测（基线，100 iterations/context，100 MHz）：

```
Total ticks     : 45456305
Iterations      : 200
Iterations/Sec  : 439.982968
CoreMark/MHz    : 4.399829
Parallel ares-2hart-mbox : 2
[0]crcfinal      : 0x988c
[1]crcfinal      : 0x988c
CoreMark PASS
```

## 为什么必须动 RTL

两 hart 之间没有可用的数据通路：

1. hart1 的 D 侧地址**统一**加 `+1 MiB`（`ares_frontend_hart.sv` 的 `DATA_OFFSET`），两核没有共同可见的数据地址；
2. 私有 L1D 写回、共享 L2 无 snoop/invalidate，DRAM 里的邮箱必然有一侧读到旧值；
3. 两个 hart 各自从复位跑同一份 `main()`，UART 也各自独立。

因此新增一个 **共享 MMIO 邮箱**。MMIO 走 LSU 的独立设备通道（`docs/microarch/memory.md` 3.1），不经过 L1D/L2、不受 `+1 MiB` 偏移影响；且 MMIO load 只在 commit head 发出、非推测，MMIO store 按 SQ 顺序 drain 并等 ack，所以描述符/GO 与 CRC/DONE 的握手不需要 fence 或 cache 维护。

## 结构

### RTL

| 文件 | 作用 |
| --- | --- |
| `rtl/top/ares_coremark_mbox.sv` | 双端口共享邮箱，两个 hart 各一个 MMIO 请求/响应口 |
| `rtl/top/ares_2core_frontend_l2_top.sv` | `dev_sel=3` 译码到 `0xA000_3000`，响应 mux / req_ready 接入 |

寄存器（字偏移，基址 `0xA000_3000`）：

| 偏移 | 方向 | 内容 |
| --- | --- | --- |
| 0x00 | h0→h1 | `GO` |
| 0x04 | h1→h0 | `DONE` |
| 0x08 | h0→h1 | `iterations` |
| 0x0C | h0→h1 | `execs` |
| 0x10 | h0→h1 | `size`（`TOTAL_DATA_SIZE / num_algorithms` = 666） |
| 0x14..0x1C | h0→h1 | `seed1..seed3` |
| 0x20..0x2C | h1→h0 | `crclist/crcmatrix/crcstate/crcfinal` |
| 0x30 | h1→h0 | `err` |

### 软件

overlay 文件在 `scripts/coremark_mt/`，由 `build_coremark_image.py --mt` 在 **staged 副本**上替换：

| 文件 | 内容 |
| --- | --- |
| `core_portme.h` | `MEM_STACK`、`MULTITHREAD 2`、`PARALLEL_METHOD`、邮箱偏移 |
| `core_portme.c` | `default_num_contexts=2`；`portable_init()` 里按 `mhartid` 分流；hart1 worker；`core_start_parallel/core_stop_parallel` |

时序：

```
hart0: start_time()
       core_start_parallel(0)   本地占位
       core_start_parallel(1)   写描述符 -> GO=1
       core_stop_parallel(0)    iterate(&results[0])
       core_stop_parallel(1)    等 DONE -> 把 CRC 回填 results[1]
       stop_time() -> 单份报告（200 iterations）

hart1: portable_init() 读 mhartid==1
       -> 等 GO -> 读描述符
       -> 用自己的私有 memblock 重做 list/matrix/state 初始化
       -> iterate(&mt_results) -> 写 CRC -> DONE=1 -> EBREAK(a0=0)
```

hart1 的 `mt_memblock` 在 `.bss`，虚拟地址与 hart0 相同、物理落在 `+1 MiB` 的私有窗口，所以两核的数据互不干扰；邮箱走 MMIO，因此 `tb_2core_coremark` 的 AMP 私有窗口检查仍然有效。

## 零修改保证

- `tests/benchmarks/coremark/` 未被写入；`git status --porcelain tests/benchmarks/coremark` 为空；
- `NOTICE.md` 的 SHA 表不需要更新；
- MT 构建的全部差异记录在 `build/coremark_mt/inputs.json` 的 `mt_overlay_sha256`；
- 默认 `make coremark-image` 的输入、参数、输出目录完全不变。

## 使用

```bash
# 构建 MT 镜像（staged overlay）
make coremark-mt-image

# 复用同一份双核 testbench，跑 MT 镜像
make unit-2core-coremark-mt

# 等价的手动命令
make build-2core-coremark-sim SIM_HEAVY_CHECKS=0
sim/build/unit_light/tb_2core_coremark/tb_2core_coremark \
    +DMEM=$PWD/build/coremark_mt/coremark_dmem.hex \
    +TIMEOUT_NS=2000000000
```

注意：

- **必须两个 hart 都在**。`+H1EN=0` 只跑 hart0 时，hart0 会在等 `DONE` 处挂死；单核参考请继续用默认镜像；
- MT 镜像不能与默认镜像共用 `DMEM`，两者输出目录不同（`build/coremark` vs `build/coremark_mt`）；
- 全量仿真约 500 ms 模拟时间：light 构建约 16 分钟、默认 heavy 构建约 29 分钟 Verilator wall time；默认 testbench 的 600 ms 超时够用，`unit-2core-coremark-mt` 已放宽到 2 s。

## 加速构建 + MT

全加速（CRC8 custom-0 + array list + matrix engine + state scanner）也可以叠加 MT：

```bash
make coremark-full-mt-image     # -> build/coremark_full_mt

make unit-2core-coremark \
    DMEM=$PWD/build/coremark_full_mt/coremark_dmem.hex \
    ARES_CFG_INC=+incdir+$PWD/build/coremark_32k/include \
    SIM_HEAVY_CHECKS=0 SIM_INFO=0
```

实测（light 构建，100 iterations/context）：

```
Total ticks     : 14225222
Iterations      : 200
Iterations/Sec  : 1405.953453
CoreMark/MHz    : 14.059534
Parallel ares-2hart-mbox : 2
[0]crcfinal      : 0x988c
[1]crcfinal      : 0x988c
CoreMark PASS
```

这就是把原来的“双核 AMP 各 7.04、TB 汇总 14.02”变成了**程序自己打印的一份 14.06 报告**。

实现上 `build_coremark_crc.py --mt` 只是把加速 TU 生成到 `build/coremark_full_mt/src_port` 后，把 `--mt` 转交给 `build_coremark_image.py`；EEMBC 树和 `src_port` 都不被改写，overlay 仍只落在 `build/coremark_full_mt/port`。

`ARES_CFG_INC` 必须指向 `build/coremark_32k/include`，否则退回默认 ICache 配置，分数会掉到 6.x 档。

## 口径与限制

- 计时窗口是 hart0 的 `start_time()` 到 `stop_time()`，包含 hart1 的释放延迟和它的 list/matrix/state 初始化（后者在单核流程里发生在计时之前）。当前实现里这部分开销相对于 45 M cycles 可以忽略，但严格比较时应知道这个偏差；
- 报告的是**聚合吞吐**：`200 iterations / 墙钟`。它不是两份单核成绩的算术和，也不应和默认镜像的“每 hart 2.0x”逐项对比（数据布局不同会改变 cache 冲突，单 context 的绝对 cycles 会有几个百分点差异）；
- 本仓库 2026-10-27 记录的 `2.0468 / 4.0935` 对应 48.86M-tick 的构建；本次 MT 镜像的每 context 窗口是 45.46M，两者不是同一次构建，不能直接相除比较；
- 这是本仓库 RTL 的仿真回归数字，不是 EEMBC 认证成绩；
- 邮箱是 benchmark/仿真基础设施，不是通用 SoC IP。

## 验证记录

- light（`SIM_HEAVY_CHECKS=0`）与默认 heavy 两种构建都跑完整 100 iterations：light 为 `ALL TESTS PASSED: 9 checks`，L2 shadow `rsp=31306, err_*=0`；heavy 为 `$finish`、零 fatal/error，报告与 light 完全一致；
- `[0]`/`[1]` 四组 CRC 全部相等，`CoreMark PASS`；
- hart0 的 `a0=0`、hart1 的 `a0=0`（EBREAK 由 worker 自己发，TB 的 done/a0 检查不变）；
- 现有 AMP 镜像在同一 testbench 上仍为 `ALL TESTS PASSED: 9 checks`，新 MMIO 设备没有破坏原流程；
- 加速版 MT（`build/coremark_full_mt`）在 light 构建上跑通：单份报告 `14.059534 CoreMark/MHz`、`Iterations 200`、`[0]/[1]` CRC 相同、零 fatal/error，UART 中没有 `[hart1]` 输出。
