# 复位审计：哪些可以删、哪些该交给 INIT 状态机

> 版本说明：本文的扇出和资源统计对应当时网表；其中共享 IROM / AMP 专用
> ICache 的描述属于旧结构。当前 AMP 已使用每 hart 私有 IROM 和主线四路 ICache。
> 第 11 节短复位问题已按方案 A+B 修复（2026-11-03），回归入口为 `make pipeline-reset-pulse`。


> 范围：当前主线 RTL —— 核 [rtl/pipeline/core](../rtl/pipeline/core)、
> SoC [rtl/pipeline/soc](../rtl/pipeline/soc)、加速器 [rtl/accel](../rtl/accel)；
> `rtl/video`、`rtl/pipeline/core/vsrc/DPIC`、`build/` 下的仿真/复制件不在范围内。
>
> 证据来源：`results/pipeline_amp_board_top(1).rtr`（PnR 布线后时序，当前网表）、
> `results/resource-usage-summary(1).txt`（同一次 PnR 的分层资源）、
> `results/congestion.md`、`results/pipeline_amp_board_top.snr`（Stage 0 之前的综合报告）。
>
> Related: [pango_amp_floorplan.md](pango_amp_floorplan.md)（拥塞与 floorplan）、
> [pipeline_multicore.md](pipeline_multicore.md)（AMP 结构）。

## 0. 结论先行

| # | 结论 | 量级 |
| --- | --- | --- |
| 1 | 复位是**除时钟外最大的单一网络**：`cpu_rst` 扇出 **17,585**，trunk 布线 **1.5–2.6 ns**，从它引出 12 条 recovery/removal 检查路径（slack 6.19 ns，**时序不是问题，布线资源才是**） | — |
| 2 | 当前 RTL 里带复位的触发器约 **7.5k**（共 30,867 FF，≈24%）；其中约 **5.5k（≈73%）属于「不该有」或「可以让 INIT 状态机代劳」**。本分支已落地 **−5,248**（AMP 构建），见 §10 | −5,248（已实施） |
| 3 | **收益最高的一处**：`u_state9_engine` 675 个 FF 里 622 个挂复位，而 512 个（`final_q/track_q`）在 `start_pulse` 时已经清过一遍 —— 该模块同时是拥塞报告里出现最多的模块 | −1,024（双 hart） |
| 4 | 第二处：`u_mbox` 的 `slot[64][32]` 是 **2,048 个 FF 全部挂复位**；它正好是本设计下一步要搬进 BRAM 的数组，搬之前必须先把复位换成 INIT 扫描 | −2,048 |
| 5 | 已有现成范式可抄：`DCache` 的 `tag_init_busy/tag_init_index/tag_ready` 就是「INIT 状态机逐地址清 tag」；只需把极性翻成 **0 = 需要初始化**，就能连它自己的复位一起省掉 | −12 |
| 6 | 核心流水线寄存器**已经全部不复位**（`Mundus.sv` 顶层 842 位流水寄存器只有 `halted` 1 位带复位），这是对的，别回退 | 保持 |

一句话：**复位不需要"逐个释放"，需要的是"把广播网络换成局部计数器 + 数组自己的写口"。**

## 1. 复位现状

### 1.1 复位从哪来、到哪去

```
rst_n (C22) ──┐
              ├─ ~(rst_n & lock) ─► pipeline_cdc_reset_sync ─► cpu_rst ─┬─► Mundus.reset
PLL lock ─────┘   (异步复位 / 同步释放，2 拍)                          ├─► 2× student_top.w_clk_rst
                                                                       ├─► 2× pipeline_amp_icache.rst
                                                                       ├─► perip_bridge.rst ──► counter/display/pipeline_accel
                                                                       ├─► uart.rst_n (异步复位端)
                                                                       └─► u_mbox.rst
```

- 复位源：[rtl/pipeline/board/pipeline_clk_reset.v:34](../rtl/pipeline/board/pipeline_clk_reset.v#L34)
- 同步器：[rtl/pipeline/soc/pango/pipeline_cdc.v:346](../rtl/pipeline/soc/pango/pipeline_cdc.v#L346)
- 分 hart 再门控：`w_clk_rst = rst | ~core_en[g]`，见 [pipeline_amp_top.sv:147](../rtl/pipeline/soc/amp/pipeline_amp_top.sv#L147)
- 50 MHz 域在 [perip_bridge.sv:354](../rtl/pipeline/soc/jyd/perip_bridge.sv#L354) 里又同步了一次（`cnt_rst`），这个做法是对的，保留。

**也就是说：一条 `cpu_rst` 从器件左下方（CLMA_21_1344）横穿到右边所有 hart + 共享 mbox + UART。**
floorplan 文档里记的 "复位同步器到 UART 走了 378 列 → 4.46 ns route" 就是这条网络。

### 1.2 实测证据

**（a）布线后：复位网络是第二大网络**

`results/pipeline_amp_board_top(1).rtr`：

```
CLMA_21_1344/CR0   tco   0.261   5.473 r   u_clk_reset/u_cpu_rst/sync[0]/opit_0_srl/CR0
                   net (fanout=17585)
                        2.620   8.093     cpu_rst
CLMA_219_1207/RSCO td   0.103   8.196 r   u_soc/u_mbox/slot[0][31]/.../RSCO
CLMA_219_1213/RSCO td   0.079   8.275 r   u_soc/u_mbox/slot[14][31]/.../RSCO
CLMA_219_1219/RSCI                       u_soc/u_uart/tx_shift[0]/.../RS
```

对比同一个报告里的时钟网络：`cpu_clk` 扇出 28,160。**除时钟之外，`cpu_rst` 是唯一一个上万扇出的网络。**

但是 Recovery / Removal 摘要显示 `WNS 6.186 / 1.806 ns`、失败端点 0 —— 所以**复位不是时序瓶颈，它占的是布线通道和 buffer**。这点很重要：不要指望删复位能把 WNS −1.527 直接修好（那个瓶颈是 DIV 和加速器阵列，见 floorplan 文档），但可以减轻全局通道压力，尤其是复位链穿过的高拥塞窗口。

**（b）综合：按端口分类的触发器分布**（`.snr`，Stage 0 之前的旧网表，51,352 FF）

```
 Clock Enable   Sync Set/Reset   Async Set/Reset   Total Registers
 NO             NO               NO                 4905
 NO             NO               YES                   6
 NO             YES              NO                 3976
 YES            NO               NO                22346
 YES            NO               YES                  22
 YES            YES              NO                 20097
```

- 同步复位寄存器 **24,073（46.9%）**，异步复位只有 28 个；
- 控制集合 2,944 个，最大扇出 4,905，770 个控制集合扇出 ≥16。

**（c）RTL 侧逐模块统计**（脚本 `build/reset_analysis/scan5.py`，按声明位宽 × 数组长度展开）

| 模块 | 文件 | 复位端点数 |
| --- | --- | ---: |
| `pipeline_coremark_mbox` | [soc/mc/pipeline_coremark_mbox.sv:56](../rtl/pipeline/soc/mc/pipeline_coremark_mbox.sv#L56) | **2,048** |
| `pipeline_icache`（单核路径，当前未在 AMP 构建里） | [vsrc/icache/pipeline_icache.v:260](../rtl/pipeline/core/vsrc/icache/pipeline_icache.v#L260) | **1,012** |
| `state9_engine` | [accel/state9_engine.sv:391](../rtl/accel/state9_engine.sv#L391) | **622** |
| `perip_bridge` | [soc/jyd/perip_bridge.sv](../rtl/pipeline/soc/jyd/perip_bridge.sv) | **515** |
| `mtx9_engine` | [accel/mtx9_engine.sv:423](../rtl/accel/mtx9_engine.sv#L423) | **432** |
| `pipeline_amp_icache` | [soc/amp/pipeline_amp_icache.sv:102](../rtl/pipeline/soc/amp/pipeline_amp_icache.sv#L102) | **359** |
| `DCache` | [vsrc/build/Mundus.sv:1861](../rtl/pipeline/core/vsrc/build/Mundus.sv#L1861) | **183** |
| `CSR` | [vsrc/build/Mundus.sv:1359](../rtl/pipeline/core/vsrc/build/Mundus.sv#L1359) | **128** |
| `counter` | [soc/jyd/counter.v:65](../rtl/pipeline/soc/jyd/counter.v#L65) | **84** |
| `uart` | [soc/jyd/uart.sv:62](../rtl/pipeline/soc/jyd/uart.sv#L62) | **82** |
| `pipeline_accel` | [soc/jyd/pipeline_accel.sv:82](../rtl/pipeline/soc/jyd/pipeline_accel.sv#L82) | 33 |
| `Bimodal` / `BimodalRas` / `ReturnAddressStack` | [Mundus/](../rtl/pipeline/core/vsrc/Mundus) | 23 / 19 / 4 |
| `IFU` | [vsrc/build/Mundus.sv:270](../rtl/pipeline/core/vsrc/build/Mundus.sv#L270) | 13 |
| `pipeline_cdc_mailbox`（WIDTH=64 实例） | [soc/pango/pipeline_cdc.v:202](../rtl/pipeline/soc/pango/pipeline_cdc.v#L202) | ≈200（脚本按默认 WIDTH=1 只数到 13） |
| `DIV` / `LSU` / `HZU` / `Mundus` | [vsrc/build/Mundus.sv](../rtl/pipeline/core/vsrc/build/Mundus.sv) | 7 / 4 / 2 / 1 |
| `pipeline_l2` / `pipeline_mmio`（MC 实验线） | [soc/mc/](../rtl/pipeline/soc/mc) | 364 / 210 |
| 其他（display_seg、irom_arbiter、core_port…） | — | 22 |

双 hart AMP 构建合计 ≈ **7.5k** 个复位端点（参数化模块按实际例化参数折算；`Mundus_PC` 的 32 位 PC 复位没被脚本统计到，实际略高）。

> 口径说明：PDS 报告的 `cpu_rst` 扇出（17,585）大于 RTL 侧的复位端点数（≈7.1k），
> 因为该网络的负载除 FF 复位端外还包括同步复位的实现逻辑/缓冲。
> 两个数字都对，**RTL 侧的数字才是你能直接改的部分**。

### 1.3 复位为什么吃布线（三条机理）

1. **同步复位 = 每个端点一次额外负载。** RTL 里除了 uart/display_seg 全是 `always @(posedge clk) if (rst) ...`，综合成同步复位（上表 `Sync Set/Reset=YES`）。它要么占用 FF 的同步置复位端口，要么在 D 端多一级选择 —— 无论哪种，复位网络都要**多走一根线到每个端点**，而这些线要穿过已经 85% 拥塞的窗口。
2. **带复位的数组无法推断成 RAM。** RAM（尤其分布式 RAM）没有复位端口。`state9/mtx9` 的注释已经把这条写成设计约束：[mtx9_engine.sv:102](../rtl/accel/mtx9_engine.sv#L102)、[state9_engine.sv:111](../rtl/accel/state9_engine.sv#L111)。反过来，`pipeline_icache` 的 `valid_mem/age_mem` 和 `Bimodal` 的 `valid/counter/loop_valid` 都带 `ram_style="distributed"` 却又有复位循环 —— 这等于先把它们钉成 FF，再让复位去驱动这些 FF。
3. **复位被当数据用。** `store_dequeue = (~rst) && (~store_empty)`（[perip_bridge.sv:287](../rtl/pipeline/soc/jyd/perip_bridge.sv#L287)）和 `ledseg_src_valid = (~rst) && ...`（[:755](../rtl/pipeline/soc/jyd/perip_bridge.sv#L755)）把复位信号接进了组合逻辑锥。复位一旦进入数据路径，就不再只是"扇出大的网络"，而是"每条相关路径上的一个 LUT 输入"。

## 2. 判断标准

一条复位该不该留，按这个顺序问：

1. **这个寄存器有没有 `valid` 位守着？** 有 → 复位可删（valid 清 0 后 payload 是 don't-care）。这就是 `metaVec_*`、`ls2_*/ls3_*`、`WBU_io_in_bits_*` 现在**已经**不复位的原因。
2. **这个寄存器会不会在第一次被读之前先被写？** 会 → 复位可删（写覆盖）。
3. **模块里有没有别的状态机/逻辑已经清过它？** 有 → 复位重复，删掉（最高性价比）。
4. **它是一块数组/存储器吗？** 是 → 删复位，改成 INIT 状态机用它的写口扫一遍；否则它进不了 RAM。
5. **上电后 0 是不是合法状态？** FPGA 配置后 FF 默认为 0（GSR），如果 0 = idle/invalid，**连复位都可以不要**；但如果 0 ≠ 合法状态（例如 `tx=1`、`PC=0x8000_0000`、`mstatus.MPP=11`），就要么保留少数几位复位，要么用 INIT 状态机写一次。
6. **运行中按复位按钮时还必须回到干净状态吗？** 必须 → 不能只靠上电 0，要用 INIT 状态机（它对上电和运行中复位都成立）。这一条是"删复位"和"换 INIT"的分水岭。

## 3. 逐模块清单

### A 类：直接删（有 valid 保护 / 先写后读）

| 模块 | 信号 | 位置 | 位数 | 依据 |
| --- | --- | --- | ---: | --- |
| `state9_engine` | `final_q[0:7], track_q[0:7]` | [state9_engine.sv:402](../rtl/accel/state9_engine.sv#L402) | 512 | `start_pulse` 已经清一遍（[:420](../rtl/accel/state9_engine.sv#L420)）；CRC 只在跑完之后读 |
| `mtx9_engine` | `pe_acc[0:8]` | [mtx9_engine.sv:337](../rtl/accel/mtx9_engine.sv#L337) | 288 | `state_q == ST_IDLE` 每拍清零（[:339](../rtl/accel/mtx9_engine.sv#L339)），复位后第一拍就是 IDLE |
| `DCache` | `resp_* / held_req_* / write_fwd_* / refill_read_*` | [Mundus.sv:1861](../rtl/pipeline/core/vsrc/build/Mundus.sv#L1861) | ≈170 | 全部由 `resp_valid / held_req_valid / write_fwd_valid` 保护；同模块 `data/tags` 已经不复位 |
| `perip_bridge` | `cnt_rdata_r/r2、load_forward_data_r/r2、mmio_rdata(_r)` | [:849](../rtl/pipeline/soc/jyd/perip_bridge.sv#L849) | 192 | 由 `response_tag_r2`、`load_forward_mask_r2` 保护 |
| `perip_bridge` | `bram_cmd_addr/wdata/wea` | [:572](../rtl/pipeline/soc/jyd/perip_bridge.sv#L572) | 54 | 只有 `bram_write_valid_q` 一位有语义 |
| `perip_bridge` | `cycle_count` | [:834](../rtl/pipeline/soc/jyd/perip_bridge.sv#L834) | 64 | 软件只取前后差值；CoreMark 时间基准 |
| `perip_bridge` | `LED / seg_wdata` | [:654](../rtl/pipeline/soc/jyd/perip_bridge.sv#L654) | 64 | 软件必须先写后读；输出侧 `led_output_q` 另有一份 |
| `perip_bridge` | `seg_output_q / led_output_q / LED_cnt / seg_wdata_cnt` | [:778](../rtl/pipeline/soc/jyd/perip_bridge.sv#L778)、[:807](../rtl/pipeline/soc/jyd/perip_bridge.sv#L807) | 136 | 纯显示负载数据（在 `cnt_rst` 网） |
| `pipeline_accel` | `rsp_data_q` | [:82](../rtl/pipeline/soc/jyd/pipeline_accel.sv#L82) | 32 | 由 `rsp_valid_q` 保护 |
| `pipeline_icache` | `rsp_data_r` | [pipeline_icache.v:264](../rtl/pipeline/core/vsrc/icache/pipeline_icache.v#L264) | 32 | 由 `rsp_valid_r` 保护 |
| `pipeline_amp_icache` | `rsp_data_r` | [pipeline_amp_icache.sv:111](../rtl/pipeline/soc/amp/pipeline_amp_icache.sv#L111) | 32 | 同上 |
| `pipeline_cdc_mailbox` | `active_data / pending_data / dest_data_r` | [pipeline_cdc.v:202](../rtl/pipeline/soc/pango/pipeline_cdc.v#L202) | ≈192（64×3） | 由 `src_req/pending_valid/dest_valid_r` 保护；只保留 state/valid/toggle 位（≈10） |
| `Bimodal` / `BimodalRas` | `valid[]、counter[]、loop_valid[]` | [Bimodal.v:130](../rtl/pipeline/core/vsrc/Mundus/Bimodal.v#L130)、[BimodalRas.v:127](../rtl/pipeline/core/vsrc/Mundus/BimodalRas.v#L127) | 23 + 19 | 预测器初值任意；最坏是多几次 mispredict，架构上永远正确 |

> A 类合计 ≈ **1.5k** 个端点，改动都是"删掉 `if (rst)` 分支里的几行"，功能风险最低。

### B 类：复位与已有机制重复（先删，再谈别的）

这类就是第 3 条判断标准，也是本次收益最大的部分：

1. `state9_engine` 的 512 位：复位分支 `if (rst) for(...) final_q/track_q <= 0` 与 `ST_IDLE` 收到 `start_pulse` 时的清理**完全重复**。删掉后唯一的可观察差异是：**第一次 start 之前**从 MMIO 读 `FINAL0..7 / TRACK0..7` 返回上电值（FPGA 上是 0，和现在一样）。
2. `mtx9_engine` 的 288 位：`ST_IDLE` 无条件清零 `pe_acc`，复位是副作用重复。
3. `DCache` 的 tag 初始化：`tag_init_busy/tag_init_index/tag_ready` 已经在扫 2048 个 tag 项（8 KiB / 32 B 行，11 位索引，见 [:1881](../rtl/pipeline/core/vsrc/build/Mundus.sv#L1881)），只是这个状态机自己还挂在全局复位上。

### C 类：改造成 INIT 状态机顺序初始化（数组/存储器）

| 对象 | 现状 | 建议 |
| --- | --- | --- |
| `u_mbox.slot[64][32]` | 2,048 位全复位（[:56](../rtl/pipeline/soc/mc/pipeline_coremark_mbox.sv#L56)）；floorplan 文档已计划搬进 BRAM | 搬 BRAM 前**必须**先去掉复位；用 6 位计数器扫 64 个字，`init_done` 之前 hart 保持复位 |
| `pipeline_icache.valid_mem` | 128 位（[:275](../rtl/pipeline/core/vsrc/icache/pipeline_icache.v#L275)） | 加 `S_CLEAR` 状态逐行清，或直接删除（见下） |
| `pipeline_icache.age_mem` | 128 项 × 2 位，复位循环按索引写常量（[:278](../rtl/pipeline/core/vsrc/icache/pipeline_icache.v#L278)） | **保留**（原计划删，实施时否掉）：替换策略要求每个 set 的 age 是 0..3 的一个排列；全部上电为 0 会让 `victim_way` 永远选中 way0，等于把 4 路退化成直接映射 |
| `pipeline_amp_icache.valid_mem` | 256 位（[:104](../rtl/pipeline/soc/amp/pipeline_amp_icache.sv#L104)） | IROM 只读 → 陈旧 valid+tag 命中仍是**正确数据**，可整体删除；若要确定性则用 8 位计数器扫 256 行 |
| `CSR` | 4×32 = 128 位，`mstatus/mepc/mtvec/mcause`（[:1359](../rtl/pipeline/core/vsrc/build/Mundus.sv#L1359)） | 架构语义要求 mstatus.MPP=11，**不能简单删**；改为 boot 阶段通过 CSR 写口写一次默认值，或保留（128 位不大） |
| `counter` | `cnt_ms_bin` 32 位（[:65](../rtl/pipeline/soc/jyd/counter.v#L65)） | 单调计数器，复位只为定义起点；可用 INIT 或直接留（量小） |
| `uart` | `tx` 上电必须为 1（[:144](../rtl/pipeline/soc/jyd/uart.sv#L144)） | 保留 1 位（或 `initial tx = 1'b1`，Pango/Synplify 支持 FF INIT），其余状态机位可交给 INIT |

**I$ 的一个额外结论**：本设计的代码存储器是只读 IROM，所以"I$ 里有陈旧 valid 位"**不会**产生错误指令 —— tag 命中意味着地址确实相同。因此 `pipeline_amp_icache.valid_mem` 的 256 位复位可以完全删除；只有当你希望 `stat_refills` 这类观测值从 0 开始时才需要 INIT。（顺带：`pipeline_icache` 里 4×64 位的统计计数器在 `student_top` 里端口悬空，综合会被剪掉，不算真实面积。）

### D 类：必须保留

| 对象 | 原因 |
| --- | --- |
| `Mundus_PC.dout`（32 位，[Mundus_PC.v:14](../rtl/pipeline/core/vsrc/Mundus/Mundus_PC.v#L14)） | 0x8000_0000 不可能来自上电 0；要么保留复位，要么加一个"首拍装载 PC"的 INIT 状态 |
| `Mundus.halted`（1 位，[:3043](../rtl/pipeline/core/vsrc/build/Mundus.sv#L3043)） | 停机后不能被 flush 重新拉起；上电 0 恰好合法，其实也可以删，但只省 1 位，不值得动 |
| `IFU.metaCount/fqCount/fqHead/fqTail/predHoldValid`（13 位） | 队列指针必须 0 才有意义；上电 0 合法，可保留（便宜） |
| `pipeline_cdc_mailbox` 的 toggle/valid 位 | 四相握手的两端必须同时为 0，否则上电后会出现假请求 |
| `pipeline_cdc_reset_sync.sync`（2 位） | 复位同步器本身 |
| `uart.rx_d0/1/2` | 上电为 1（mark 态）才能正确检测起始位；实际上上电 0 也能在 3 拍内自恢复，但保留更直观 |
| 各 FSM 的 state 寄存器 | 0 恰是 IDLE 时可由上电 0 承担，否则必须复位 |

## 4. 已经做对、不要回退的地方

1. **流水线寄存器不复位**：`Mundus` 顶层 842 位的 `IDU/ISU/EXU/WBU_io_in_bits_r_*` 全部无复位（[:2958](../rtl/pipeline/core/vsrc/build/Mundus.sv#L2958)），靠 `valid/flush` 清。这是对的，也是为什么 `Mundus` 3721 个 FF 只有约 400 个挂复位。
2. **加速器数组不复位**：`mtx9/state9` 的 byte-lane 数组刻意不复位，理由写在注释里（分布式 RAM 没有复位口）。这是整个仓库里最正确的一段复位决策，其它模块照抄即可。
3. **DCache 用状态机初始化 tag**：已经是"用 INIT 状态机代替宽复位"的雏形。
4. **50 MHz 域单独同步复位**（`cnt_rst`）：跨域复位释放不能异步，这点必须保留。
5. **`pipeline_cdc_mailbox` 已经有 `initial` 定义上电值**（[pipeline_cdc.v:241](../rtl/pipeline/soc/pango/pipeline_cdc.v#L241)），复位分支是第二份重复；保留 state/toggle 位，数据位可以删。

## 5. INIT 状态机模板

### 5.1 极性技巧：让"上电 0"就是 INIT 态

```verilog
// 上电/复位后 tag_ready = 0 => 自动进入初始化；无需宽复位
reg        tag_ready;          // 唯一需要复位的位
reg [10:0] init_idx;           // 只在 ~tag_ready 时递增
wire       tag_busy = ~tag_ready;

always @(posedge clk) begin
    if (!tag_ready) begin
        tags_wr_en   <= 1'b1;
        tags_wr_addr <= init_idx;
        tags_wr_data <= 6'h0;              // 用数组自己的写口清
        if (&init_idx) tag_ready <= 1'b1;  // 2048 项扫完
        else           init_idx  <= init_idx + 11'd1;
    end else begin
        tags_wr_en   <= inv_write | refill_write;
        tags_wr_addr <= inv_write ? coh_addr : refill_addr;
        tags_wr_data <= {1'b1, refill_tag};
    end
end
```

要点：

- **只有 `tag_ready` 一位需要复位**（其余位靠"上电 0 + 状态机自己走"）。全局复位仍然有效：复位把 `tag_ready` 打回 0 → 重新扫描，语义和原来完全一致。
- 复位端点从 13（`busy + index[11] + ready`）降到 1；扫 2048 拍 = 20.48 µs，只在启动时发生。
- **不要**在扫描过程中允许功能访问：用 `tag_ready` 反压（DCache 现在就是这么做的），或者用它把核心的 `cpu_rst` 多按住几拍。
- 细节：上面这段在"扫描到一半被复位"时不会漏项，因为 `init_idx` 也要复位到 0；如果想把 `init_idx` 也去掉复位，就要让 FSM 以"扫满 2^11 次"而非"扫到全 1"结束。

### 5.2 启动顺序：把"复位"变成"启动序列"

```verilog
// 顶层：先让各块自清，再放核心跑
reg [15:0] boot_cnt;
wire       boot_done = boot_cnt[15];
always @(posedge clk) if (!boot_done) boot_cnt <= boot_cnt + 16'd1;

wire hart_rst = cpu_rst_sync | ~boot_done;   // 唯一的"新"复位连接
```

- 各块（mbox / I$ tag / D$ tag / CSR 默认值）在 `cpu_rst_sync` 释放后开始自清，**不需要**互相知道；
- `boot_done` 用一个计数器统一等最慢的那块（或取各块 `ready` 的与）；
- 核心只在 `boot_done` 之后才退出复位 —— 这样 INIT 期间的任何中间态都不会被取指看到；
- 好处：**复位网络不再需要"同时到达所有 FF"**，从"一棵树"变成"每块一个 1 位握手"。

### 5.3 不要指望用软件代替

对 `u_mbox` 这种 64 字的小数组，也可以让 hart0 的启动代码显式写 0。但 **DONE/GO 是跨 hart 的握手**，运行中按复位后陈旧值会骗过 hart0，所以硬件 INIT 更稳。

## 6. 建议的实施顺序与收益

> 下表的 P0/P1 已在本次实施，实际结果与偏差见 §10。

| 阶段 | 动作 | 减少端点 | 风险 | 验证 |
| --- | --- | ---: | --- | --- |
| P0 | 删 `state9.final_q/track_q`、`mtx9.pe_acc` 的复位 | −1,600（双 hart） | 极低（已有清理） | `tb_state9_engine`/`tb_mtx9_engine` + 双核 CoreMark CRC 不变 |
| P0 | 删 A 类 payload 复位（DCache、perip_bridge、icache、accel） | −800 | 低 | lint + smoke + ISA |
| P0 | 删 `~rst` 组合门（store_dequeue / ledseg_src_valid） | 0（退出组合锥） | 低 | 同上 |
| P1 | `u_mbox` 复位 → 64 拍 INIT 扫描 | −2,048 | 中（影响双 hart 握手） | 双核 CoreMark 200 iter + `make pipeline-mc-test` |
| P1 | `pipeline_amp_icache.valid_mem` 删除 / `pipeline_icache` 加 `S_CLEAR` | −512 / −384 | 低（只读 IROM） | I$ 命中率统计 + CoreMark |
| P1 | `DCache` tag_init 改极性，只留 1 位复位 | −12 | 低 | `tb_pipeline_l2_mc` 等 |
| P2 | `CSR` 默认值改 boot 写；`uart/counter/display_seg` 小改 | −400 | 中（架构态） | ISA 回归全绿 |
| — | **合计** | **约 −5.5k / 7.5k（≈73%）** | | |

对布线报告的预期（不要过度承诺）：

- `cpu_rst` 的扇出应显著下降（PDS 报告里的那一行 `net (fanout=...)`）；
- 复位链穿过的窗口（`.rtr` 里 `u_mbox/slot[*]` → `u_uart` 那一段）拥塞下降；
- WNS/TNS 不会因此大幅改善 —— 瓶颈在 DIV/加速器阵列，见 [pango_amp_floorplan.md](pango_amp_floorplan.md)；
- Recovery/Removal 仍应满足（现在 slack 6.19 ns，删的是负载而不是关键路径）。

## 7. 验证清单

```bash
make pipeline-lint            # Verilator lint（SoC）
make pipeline-smoke           # 8 条指令冒烟
make pipeline-isa             # 36 个 cpu-tests
make pipeline-coremark        # 基线
make pipeline-coremark-full-mt CORES=2   # 全加速双核 200 iter（复位改动的主要回归）
make pipeline-mc-test         # 共享 L2 / mailbox 一致性实验
```

综合/PnR 侧看三个数：

1. `Flip-Flop Distribution` 里 `Sync Set/Reset = YES` 的计数（旧网表 24,073，目标 ≤10k）；
2. `.rtr` 里 `cpu_rst` 的 fanout（当前 17,585）；
3. `Control Sets` 直方图里 `[16, Inf)` 那一行（当前 770 个控制集合、最大扇出 4,905）。

## 8. 风险 / 不要做的事

1. **别给 BRAM 或分布式 RAM 加复位。** 写进 `if (rst)` 的数组循环，PDS 会把它推成 FF。这是仓库里已有结论（mtx9/state9 注释）。
2. **仿真 X 传播**：删复位后 Verilator 默认 0 初始化（本项目测试都过），但 VCS/Xcelium 会保留 X。若要让两种仿真一致，给"上电 0"型寄存器加 `ifndef SYNTHESIS initial xx = 0;`，不要在可综合代码里用 `initial` 写功能逻辑。
3. **运行中复位的语义**：只删复位（不配 INIT）意味着"按复位按钮后数组保留旧内容"。对 I$ 安全（只读代码），对 mbox **不安全**（陈旧 DONE），对 D$ tag **不安全**（陈旧 valid + 可能脏）。所以数组要走 INIT，不能只删。
4. **不要把复位做成流水线**：加一级"复位寄存器"只改变到达时间，不减少扇出/负载；真正有用的是减少端点、以及按区域复制复位源。
5. **异步复位别扩大**：现在只有 uart 和 display_seg 用 `always @(posedge clk or posedge rst)`（[:44](../rtl/pipeline/soc/jyd/uart.sv#L44)、[:36](../rtl/pipeline/soc/jyd/display_seg.sv#L36)），其余都是同步。混用会让 Recovery/Removal 分析里出现 18 个特殊端点（当前 slack 6.19 ns，没问题），但新代码不要扩大这个面。
6. **复位分区复制**：如果不想删那么多，也可以给每个 hart / 每个区域各放一个 `pipeline_cdc_reset_sync`（同一个 `rst_in`），把 17.5k 负载的单一网络切成 4~5 条区域网络。它不减少 LUT 输入，但能显著缩短长线 —— 这是 floorplan 之外的第二个物理手段。

## 9. 附录：本次统计脚本

`build/reset_analysis/scan5.py`：扫描 `rtl/pipeline` + `rtl/accel`（排除 test/legacy/archive/sim/DPIC），
按模块解析 `localparam/parameter` 求数组长度，统计 `if (rst)` 分支内的左值位数。
对数组循环里的常量下标、`output reg` 仍有少量漏计（例如 `Mundus_PC.dout`），用于排序而非精确账本。

## 10. 实施记录（本分支已落地）

改动 10 个文件（`git diff --stat`：155 insertions / 136 deletions）：

| 文件 | 改动 | 每实例减少端点 |
| --- | --- | ---: |
| [accel/state9_engine.sv](../rtl/accel/state9_engine.sv) | 删 `final_q/track_q` 复位（`start_pulse` 已清一遍） | 512 |
| [accel/mtx9_engine.sv](../rtl/accel/mtx9_engine.sv) | 删 `pe_acc[0:8]` 复位（`ST_IDLE` 每拍清） | 288 |
| [lsu/dcache.scala](../rtl/pipeline/core/scsrc/lsu/dcache.scala) → [Mundus.sv](../rtl/pipeline/core/vsrc/build/Mundus.sv) | 只保留 `resp_valid` / `refill_read_collision_q` / `write_fwd_valid` / `held_req_valid` 四个有效位 | 166 |
| [soc/jyd/perip_bridge.sv](../rtl/pipeline/soc/jyd/perip_bridge.sv) | 响应流水 / BRAM 命令 / `cycle_count` 去复位；删 `~rst` 组合门 | 314 |
| [soc/jyd/pipeline_accel.sv](../rtl/pipeline/soc/jyd/pipeline_accel.sv) | `rsp_data_q` 去复位 | 32 |
| [soc/amp/pipeline_amp_icache.sv](../rtl/pipeline/soc/amp/pipeline_amp_icache.sv) | `valid_mem`、`rsp_data_r` 去复位 | 288 |
| [soc/mc/pipeline_coremark_mbox.sv](../rtl/pipeline/soc/mc/pipeline_coremark_mbox.sv) | 2,048 位数组复位 → 64 拍 INIT 扫描（新增 `init_done`） | 2,048 |
| [soc/amp/pipeline_amp_top.sv](../rtl/pipeline/soc/amp/pipeline_amp_top.sv) | `mbox_init_done` 并入每个 hart 的复位 | — |
| [icache/pipeline_icache.v](../rtl/pipeline/core/vsrc/icache/pipeline_icache.v)（单核板级路径） | `valid_mem` / `data_r` / `rsp_data_r` / `req_*` / `miss_*` / `beat_*` 去复位 | 539 |

AMP 构建（2 hart + 1 个 mbox）：2 × 1,600 + 2,048 = **5,248 个复位端点**。

**刻意保留、与原计划不同的地方**：

1. `age_mem`：替换策略要求每个 set 的 age 是 0..3 的排列；去掉复位后全部为 0，`victim_way` 会永远选 way0，等于把 4 路 I$ 退化成直接映射。**保留**。
2. LED/SEG 输出寄存器（`LED/seg_wdata/LED_cnt/seg_wdata_cnt/seg_output_q/led_output_q`，200 位）：它们是复位后引脚上的默认值，用户可见，改动收益不抵行为变化风险。
3. `pipeline_cdc_mailbox` 的 3×64 位数据寄存器：模块里已经有 `initial` 定义上电值，再去掉复位只省 192 位/实例，留作后续。
4. `CSR`：`mstatus.MPP=11` 是架构语义，未改。

**验证（全部通过）**：

| 目标 | 结果 |
| --- | --- |
| `make pipeline-lint` / `pipeline-pango-lint` / `lint-mtx9` / `lint-state9` | 通过（仅既有 warning） |
| `make unit-mtx9` / `unit-state9` | 3,507 / 10,928 checks PASS |
| `make pipeline-smoke` | PASS |
| `make pipeline-isa` | 36/36 PASS |
| `make pipeline-coremark` | 2.235012 CoreMark/MHz，44,742,474 ticks |
| `make pipeline-coremark-full` | 7.408253 CoreMark/MHz，13,498,458 ticks |
| `make pipeline-coremark-full-mt CORES=2` | 15.863735 CoreMark/MHz，12,607,371 ticks，四组 CRC 全同，PASS |
| `make pipeline-console` | PASS，`errors=0` |
| `make pipeline-mc-test` | 2 核 / 4 核 / accel_read 全 PASS |

三组 CoreMark 的 timed ticks 与改动前**逐拍相同**（用 `git stash` 在改动前后各跑一遍对比），
唯一差异是 2-hart 的总仿真周期 +45（mbox 的 64 拍 INIT 与前几次取指重叠）。

**下一步（未实施）**：

1. 在 PDS 上重跑 `pnr`，对比 `.rtr` 里 `cpu_rst` 的 fanout、Recovery/Removal 和 65 个窗口的拥塞度；
2. `u_mbox` 的 256×32 改成同步读 BRAM（[pango_amp_floorplan.md](pango_amp_floorplan.md) Stage 0 的剩余项），复位已经在本次让位；
3. 若要让 I$ 的初始化也确定化，给 `pipeline_icache`/`pipeline_amp_icache` 加 `S_CLEAR` 状态（本次按"只读 IROM ⇒ 陈旧 valid 无害"直接删除）；
4. P2：`CSR` 默认值改 boot 写、`uart/counter/display_seg` 的小改动；
5. **已修复**：流水线 valid 位原先没有复位，短复位脉冲下会让陈旧指令退休/写内存。详见 §11（含实测数据和修法）。

## 11. 已修复：流水线 valid 位没有复位

> 状态：**已修复（2026-11-03）**，采用 §11.5 的 A（`pipelineConnect` 的 valid 改为 `RegInit(false.B)`）
> 和 B（LSU `ls2_valid/ls3_valid` 带复位），代价 9 个触发器。
> 回归：`make pipeline-reset-pulse`（`rtl/pipeline/test/tb_reset_pulse.sv` +
> `sim_reset_pulse_main.cpp`），两种程序 × 脉宽 1/2/3/4/6/8 × 5 个相位共 60 次，
> 修复前 50 次失败，修复后全部通过。以下保留修复前的记录。
>
> 复现环境留在 `build/reset_exp/`（gitignore 内）：`tb_reset_pulse.sv` + `main.cpp` / `main_store.cpp`。

### 11.1 现象与根因

[common.scala:54](../rtl/pipeline/core/scsrc/common/common.scala#L54) 的流水线连接器用

```scala
val valid = Reg(Bool())        // 没有初值 -> 没有复位
```

因此 **7 个 stage valid 在复位时不清零**：

| 位置 | 信号 |
| --- | --- |
| Mundus 顶层 | `valid` (IF→ID)、`valid_1` (ID→ISS)、`valid_2` (ISS→EX1)、`valid_3` (EX4→WB) |
| EXU 内部 | `valid` (EX1→EX2)、`valid_1` (EX2→EX3)、`valid_2` (EX3→EX4) |
| LSU | `ls2_valid` / `ls3_valid`（[lsu.scala:61](../rtl/pipeline/core/scsrc/lsu/lsu.scala#L61)、[:71](../rtl/pipeline/core/scsrc/lsu/lsu.scala#L71)，`RegEnable` 无初值） |

payload 不带复位是对的（有 valid 保护），但 **valid 本身不带复位**，就变成"复位后流水线里还剩什么"
取决于复位脉宽 —— 这不是一个能写进规格的契约。

### 11.2 实测（单核 `student_top`，Verilator）

程序：`lui / addi / sw` 之后进入 `addi x3,x3,1` 长流；在流水线充满时打一个复位脉冲，
观察复位释放后 12 拍的 `retire_valid/retire_pc`。

**1 拍复位脉冲：**

```
cyc+ 0 retire_valid=1 pc=80000020   <- 复位前就在流水线里的指令继续退休
cyc+ 1 retire_valid=1 pc=80000024
cyc+ 2 retire_valid=1 pc=80000028
cyc+ 3 retire_valid=1 pc=8000002c
cyc+ 4 retire_valid=1 pc=80000030
cyc+ 5 retire_valid=1 pc=80000034
cyc+ 6 retire_valid=1 pc=80000038
cyc+ 9 retire_valid=1 pc=80000000   <- 新程序从 PC_BASE 开始，晚 9 拍才第一次退休
```

**不同脉宽（同一相位，`reset_exp <脉宽> 40`）：**

| 复位脉宽 | 复位后陈旧退休 | 陈旧 store |
| ---: | ---: | --- |
| 1 拍 | 7 条 | 扫相位最多 3 次 |
| 2 拍 | 6 条 | — |
| 3 拍 | 5 条 | — |
| 4 拍 | 4 条 | — |
| 6 拍 | 2 条 | — |
| 8 拍及以上 | **0** | **0**（`reset_store 10 <phase>` 全相位为 0） |

陈旧 store 用 store 密集程序观测（循环体反复写 `0x8010_0100`，复位后的新程序不会访问这个地址）：

```
pulse=1  at=34 stale_stores=1     pulse=1  at=38 stale_stores=3
pulse=1  at=42 stale_stores=2     pulse=1  at=58 stale_stores=3
pulse=10 at=34/38/42/58 stale_stores=0
```

### 11.3 影响矩阵

| 场景 | 是否有功能影响 | 说明 |
| --- | --- | --- |
| 上电（FPGA GSR / Verilator 0 初始化） | 否 | 所有 FF 上电为 0，valid 全 0 |
| 板级复位（按钮 + PLL lock + 2 拍同步，毫秒级） | 否 | 复位期间流水线在 8 拍内**自己排空** |
| `core_en` 抖动 / debug reset / watchdog / 毛刺（< 8 拍） | **是** | 最多 7 条陈旧指令退休，最多 3 次陈旧 store 落进存储器；若陈旧指令是 CSR 写 / `mret` / `ebreak`，影响控制流 |
| VCS / Questa 等 4 态仿真 | **是** | 上电即 X，Verilator 的 0 初始化把这个现象掩盖了 |

### 11.4 为什么长复位能自愈

复位期间时钟照跑，但所有"上游 valid 源"都被复位钉死（IFU 的 `fqCount/metaCount`、IDU/ISU 的输出、
`halted`），stall 也会在 3 拍内消失（DIV 的 `busy` 有复位，MUL 流水最多 3 拍冲完）。
下游那 9 个没有复位的 valid 位就被逐拍"冲成 0"：4 级主流水 + EXU 3 级 + LSU 2 级 ≈ **8 拍**。

这解释了为什么现在没出问题（板级复位远宽于 8 拍），也说明**"能工作"依赖的是一个没人写下来的时序假设**。

### 11.5 建议修法（按推荐顺序）

**A（推荐，一处改动覆盖 7 位）** —— [common.scala:54](../rtl/pipeline/core/scsrc/common/common.scala#L54)：

```scala
val valid = RegInit(false.B)   // payload 不复位，valid 必须复位
```

**B（补齐 LSU 的 2 位，可选）** —— [lsu.scala:61](../rtl/pipeline/core/scsrc/lsu/lsu.scala#L61)、[:71](../rtl/pipeline/core/scsrc/lsu/lsu.scala#L71)：

```scala
val ls2_valid = RegInit(false.B)
when(io.in.ready) { ls2_valid := ls1_valid && !io.flush }
// ls3_valid 同理
```

**C（不推荐）复位释放时打一拍 flush**：stale retire 发生在释放后的**第一拍**，`io_retire_valid`
是组合输出，flush 在同一拍来不及 —— §11.2 的 `cyc+0` 就是证据。

**D（兜底）**：不动核，则必须保证任何逻辑产生的复位 ≥ 8 拍（例如给 `~core_en` 加最小宽度展宽器）。
这是靠约束维持的隐患，不如 A 干净。

代价合计 **9 个 FF**，均不在关键路径，不影响已经拿到的 5,248 个复位端点的削减。

### 11.6 修完怎么验证

```bash
# 1) 脉冲实验：期望 cyc+0 起无 retire，cyc+9 从 0x80000000 开始；stale_stores 全为 0
./build/reset_exp/reset_exp   1 40
./build/reset_exp/reset_store 1 34
./build/reset_exp/reset_store 1 38
# 2) 全回归（应逐拍不变）
make pipeline-smoke pipeline-isa pipeline-coremark pipeline-coremark-full
```

建议把这两个实验固化成 `make pipeline-reset-pulse` 回归目标，否则下次重构
`pipelineConnect` 时这个问题会悄悄回来。
