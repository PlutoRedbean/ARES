# Pango AMP floorplan 实验（PG2L200H / pipeline_amp_board_top）

> Related: [pipeline_multicore.md](pipeline_multicore.md)（AMP 结构）、
> [../fpga/pango/pipeline/README.md](../fpga/pango/pipeline/README.md)（Pango 流程）。
>
> Status: 约束方案 + runbook，**尚未在 PDS 上执行**。本仓库的 Linux 主机没有 PDS；
> 区域坐标要在 PDS 的 Physical Constraint Editor（PCE）里按设备视图确认后填入。
> 资源数字来自 `pipeline_amp_board_top.snr`（综合报告，旧除法器版本）。

## 1. 为什么现在做 floorplan

修完除法器（commit 8c85c4e）只消掉了 WNS 的离群点，剩下的矛盾是全局布线：

- 65 个拥塞窗口全部落在 **72.7% ~ 88.1%**，而窗口逻辑利用率只有 **3.4% ~ 70.7%**；
  利用率 3.37% 的 window34 也有 76.9% 拥塞 —— 不是局部塞爆，是通道整体紧张。
- 时序报告的 route 占比：除法器 34.5%、rst_n 同步器到 UART 92.5%、LED 24.4%。
- 同一个 `u_state9_engine` 同时出现在 West/South/North/East 四向窗口。

## 2. 现状证据

### 2.1 物理坐标（来自 `pipeline_amp_board_top.rtr`）

报告里每个单元都带器件坐标（`CLMA_<x>_<y>`），把 20 条路径的单元汇总：

| 观测对象 | 列（x） | 行（y） | 说明 |
| --- | --- | --- | --- |
| hart0 EXU / 除法阵列 | 105 ~ 171 | 858 ~ 1525 | 32 级进位链竖向排开，一条路径跨 ~600 行 |
| hart0 UART / perip_bridge | 171 ~ 417 | 858 ~ 1422 | 与 CPU 相距 200+ 列 |
| 复位同步器 `u_cpu_rst/sync[0]` | 21 | 1422 | 到 UART 走了 378 列 → 那条 4.46 ns route |
| 时钟 BUFG（USCM） | 383 | 930 | 单 BUFG 带 5 万负载 |
| PLL（GPLL） | 7 | 1381 | |
| 板级 I/O | 0 ~ 16 | 1248 ~ 1446 | 引脚在左侧靠下 |

hart0 被采样到的单元就横跨 ~400 列 × ~670 行，CPU、外设、复位源三点相距很远。

### 2.2 资源分布（来自 `.snr`）——这一节改变了 floorplan 的形态

器件：**159,800 LUT / 319,600 FF / 415 DRM36K / 740 APM**。
设计：**99,872 LUT（62.5%）/ 51,352 FF（16.1%）/ 157 DRM（37.8%）/ 16 APM（2.2%）**。

| 层次 | LUT | FF | DRAM | APM | DRM |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pipeline_amp_board_top` | 99,872 | 51,352 | 496 | 16 | 157 |
| `g_hart[0].u_core` (student_top) | 47,159 | 24,132 | 112 | 8 | 66.5 |
| └ `bridge_inst` (perip_bridge) | 42,945 | 18,367 | 34 | 4 | 64 |
| └ `u_pipeline_accel` | 42,476 | 17,723 | 8 | 4 | 0 |
| └ `u_state9_engine` | **34,650** | **8,866** | 0 | 0 | 0 |
| └ `u_mtx9_engine` | 7,807 | 8,824 | 8 | 4 | 0 |
| └ `Core_cpu/Mundus` | 4,214 | 5,765 | 78 | 2.5 | 4 |
| `g_hart[0].g_ic.u_icache` | 634 | 552 | 136 | 0 | 8 |
| `u_mbox` | 4,330 | 2,048 | 0 | 0 | 0 |

**读法**：两 hart 各 47.8k LUT（student_top 47.2k + icache 0.6k），合计 95.4k；
共享部分约 4.4k，其中 `u_mbox` 一个人就 4,330 LUT / 2,048 FF。

三个必须记住的比例：

1. **两个 `u_state9_engine` 占全设计 LUT 的 69%**（2 × 34.6k / 99.9k）；
2. 加上两个 `u_mtx9_engine` 和 `u_mbox`，**89% 的 LUT 在"寄存器堆型"模块里**；
3. **73% 的 FF 也在这些模块里**（state9 17.7k + mtx9 17.6k + mbox 2.0k / 51.4k）。

### 2.3 为什么会这样：异步读的数组被推成了寄存器

- `state9_engine`：`logic [7:0] mem [0:1023]` 是**组合读**（`cur = mem[p_q]`、
  `host_rdata = {mem[haddr+3], ...}`），PDS 无法推断 BRAM（BRAM 读必须打拍），
  于是 8,192 bit 变成 8,192 个 FF，外加 1024:1 的读 mux 树 → 34.6k LUT、DRM=0。
- `mtx9_engine`：`abuf[0:255]`（256×32）、`c_mem[0:80]` 同样组合读
  （`a_rd_data = abuf[...]` 是 continuous assign）→ DRM=0。
- `u_mbox`：2,048 FF = 256×32 的缓冲，同样没进 BRAM。

这解释了拥塞报告：`u_state9_engine` 在 65 个窗口里占 99%，**不是因为它被放得散，
而是它本身就是一个 34.6k LUT 的巨型分布式寄存器堆 + 宽 mux**。这类逻辑的布线需求
是固有的，任何 pblock 都无法消除。

### 2.4 对 floorplan 的三点结论

1. 每个 hart 需要 **~30% 的器件面积**（47.8k / 159.8k），不是"小模块"；
2. 二分方案必然是 **47% / 47% / 6%**（hart0 / hart1 / 共享），每半区 LUT 占用率
   ≈60%，可行但没有余量；
3. 在存储映射修好之前，floorplan 的收益主要是"少绕远路"，**不可能把 88% 的拥塞
   降到低位**——因为大头是模块内部的 mux。

### 2.5 所以：先做 Stage 0，再做 floorplan

把 `mem` / `abuf` / `c_mem` / mbox 缓冲改成**同步读 BRAM**（扫描循环预取
下一个地址即可，每字节多一拍）：

| 模块 | 现状 | 改后（估算） |
| --- | --- | ---: |
| u_state9_engine（每个） | 34,650 LUT / 8,866 FF | ~2k LUT / ~1k FF + 2 DRM |
| u_mtx9_engine（每个） | 7,807 LUT / 8,824 FF | ~2-3k LUT / ~1k FF + 2 DRM |
| u_mbox | 4,330 LUT / 2,048 FF | ~0.5k LUT + 1-2 DRM |
| 全设计 | 99,872 LUT（62.5%） | **~20-25k LUT（13-16%）** |

BRAM 余量足够（157 → ~170 / 415）。这一步同时改善面积、拥塞和 100 MHz 的可行性，
是当前性价比最高的动作；floorplan 应排在其后。

## 3. PDS 的区域约束机制

布局/区域约束走 **PCF** 文件，不是 FDC：

- 入口：PDS `Tools → 物理约束`（Physical Constraint Editor，PCE），保存为 `.pcf`；
- PCE 的 TCL 控制台支持 `constraint`、`unconstraint`、`region`、`select`、
  `save_constraint`；
- 语法：

```tcl
# 建区域：value = (xmin,xmax,ymin,ymax)
region -create -name hart0 -value (X0,X1,Y0,Y1)
region -in                       ;# 区域约束必须在 Region 模式下
constraint -design_instance {u_soc/g_hart[0].u_core} -region hart0
constraint -design_instance {u_soc/g_hart[0].u_core} -region (X0,X1,Y0,Y1)
save_constraint -file_name amp_floorplan.pcf
```

注意：

1. 实例名里的 `[` `]` 必须用 `{}` 括起来，否则 TCL 会当命令替换；
2. PCF 管布局、FDC 管时钟/IO，写错文件等于没约束；
3. 这套命令来自 PCE 文档（2018/2021 版），**2025.2 里先在 TCL 控制台敲一条
   `region -create` 验证**再批量用。

## 4. 分阶段

### Stage 0（先做，RTL）：加速器存储进 BRAM

见 2.5。改完后每个 hart 从 47.8k LUT 掉到 ~11k，floorplan 从"抢面积"变成"摆整齐"。
验证：`tb_state9_engine` / `tb_mtx9_engine` 单测 + 双 hart CoreMark CRC 不变。

### Stage A：只收拢加速器

每个 `u_pipeline_accel` 在其 hart 侧占一块，**按 42.5k LUT 给面积**（≈27% 器件，
留 10% 余量）；Stage 0 之后可缩到 ~10% 器件。

```tcl
region -create -name acc_h0 -value (X0,X1,Y0,Y1)
region -create -name acc_h1 -value (X2,X3,Y2,Y3)
constraint -design_instance {u_soc/g_hart[0].u_core/*/u_pipeline_accel} -region acc_h0
constraint -design_instance {u_soc/g_hart[1].u_core/*/u_pipeline_accel} -region acc_h1
```

（通配符是否支持需在 PCE 里确认；不支持就用 Design Browser 点选后 `constraint`。）

### Stage B：共享 IROM + arbiter + mailbox 收到中间窄条

`u_irom`（32 KiB，8 DRM）+ `u_arb` + `u_mbox`（4.3k LUT）是唯一的跨 hart
通路，放中间一条窄区域，跨区只走这一条走廊。

```tcl
region -create -name shared -value (Xm0,Xm1,0,Ymax)
constraint -design_instance {u_soc/g_shared_irom.u_irom} -region shared
constraint -design_instance {u_soc/g_shared_irom.u_arb}  -region shared
```

### Stage C：整 hart 二分（Stage 0 之后再做）

当前 62.5% 利用率下二分 = 每半 60%，能做但不宽裕；Stage 0 之后每 hart ~11k
（7%），二分几乎无风险。hart0 靠 I/O 侧（引脚 x≈0~16，行 1248~1446）。

```tcl
region -create -name hart0 -value (0, Xm0, 0, Ymax)
region -create -name hart1 -value (Xm1, Xmax, 0, Ymax)
constraint -design_instance {u_soc/g_hart[0].u_core} -region hart0
constraint -design_instance {u_soc/g_hart[1].u_core} -region hart1
```

## 5. 执行步骤

1. PDS 工程 `Tools → 物理约束`，记录 device view 的 Xmax/Ymax 和两个 hart 的
   当前包围盒；
2. 先只做 Stage A/B 中的一个（别一次加满）；
3. `save_constraint` 存 PCF → 重新 `dev_map` + `pnr`（**同 seed**）；
4. 重新出 `report_timing -max_path 200` + 拥塞报告 + 资源报告；
5. 对比下表，再决定下一阶段。

## 6. 验收指标（每阶段都记）

| 指标 | 基线 | 目标 |
| --- | --- | --- |
| LUT / FF / DRM | 99,872 / 51,352 / 157 | Stage 0 后 ~20-25k / ~25k / ~170 |
| WNS / TNS / 失败端点数 | −46.1 / −595k / 130,733（旧网表） | 单调改善 |
| 65 窗口最高 / 平均拥塞度 | 88.1% / ~84% | 下降 |
| route 占关键路径延迟 | 34.5%（DIV）、92.5%（reset） | 下降 |
| Place 错误 | 无 | 无新增 |
| 布线时间 | 旧值 | 不比基线差 |

## 7. 风险

- **BRAM 列**：区域必须覆盖 BRAM 列，否则 32 KiB 私有 DRAM（8 个 BRAM36）+ 16 KiB
  I$（4 个）放不进去 → Place 报错。窄条尤其危险。
- **时钟区域**：本仓库有过 `Place-0089 REGION_CLOCK` 的前车之鉴（区域时钟带不动
  跨 region 的 BRAM），区域不要横跨太多 clock region。
- **利用率**：pblock 降低布局自由度，利用率越高收益越可能为负。
- **PCF/FDC 混淆**：布局约束写在 PCF，写进 FDC 不会生效。

## 7.1 进展（Stage 0）

- `state9_engine`：已在 3febc3d 改为四条 256×8 byte lane，34,650 → **1,163 LUT / 675 FF / 128 DRAM**。
- `mtx9_engine`：已改为 A/B/C 各四条 128×8 byte lane（1 写口 + 1 异步读口），并把
  `ST_VECT` 的 B 读改为复用 `bcol` 缓存。仿真逐拍等价（双核 CoreMark 12,717,309 拍不变），
  等下一次 PDS 报告确认 LUT / DRAM / WNS。
- 复位网络：已按 [pipeline_reset_analysis.md](pipeline_reset_analysis.md) 去掉 **5,248** 个复位端点
  （state9/mtx9 的重复清理、mbox 改 64 拍 INIT 扫描、D$/I$ 的有效位与负载寄存器），
  CoreMark timed ticks 逐拍不变、ISA 36/36。下一次 PDS 报告重点看 `.rtr` 里 `cpu_rst`
  的 fanout（基线 17,585）与 Recovery/Removal。
- 仍待处理：`u_mbox` 的写入阵列（2,048 FF）与 Stage A/B 的区域约束。

## 7.2 进展（mbox 读口打拍）

`top200_timing.rtr`（4-hart、70 MHz、WNS +0.618、13.6677 ns）里 **200/200 条最差
setup 路径全部落在 `u_soc/u_mbox`**：16~17 级逻辑、Route 占 67%~72%、单根
fanout-64 线 2.4~2.5 ns。路径是 CPU `ls2_addr[26]` → `perip_bridge` 译码 →
mbox 的 `(addr[31:8]==TAG) ? slot[addr[7:2]] : 0` 组合读。

已改为读流水：

- `pipeline_coremark_mbox`：读口拆成两拍——`rd_idx_q <= req_addr[7:2]`，
  下一拍把 64:1 拆成 4 个 bank 的 16:1 结果打进 `rd_bank_q`、bank 选择打进
  `rd_sel_q`，最后 4:1 组合出 `rsp_data`。窗口比较（`addr[31:8]==TAG`）彻底
  移出读数据路径（桥在请求拍已经译码过地址）。
- `perip_bridge`：新增 `RESP_SHARED` 标签，在 r2 拍从 `shared_rdata` 取数；
  MMIO 读延迟仍是 2 拍，其它源（DRAM/CNT/ACCEL/MMIO）不受影响。

读路径从"16~17 级 / 13.6677 ns"变成两段：`rd_idx_q` → 16:1（约 3 级）→
`rd_bank_q`，以及 `rd_bank_q/rd_sel_q` → 4:1 → 响应 mux。代价是每 hart
4×32=128 个额外 FF（4-hart 共 512 个，FF 利用率 11% 量级，可忽略）。

验证：4-hart 与 2-hart 全加速 CoreMark MULTITHREAD 全部 `CoreMark PASS`
（`crclist/crcmatrix/crcstate` 全对），2-hart 逐拍数与改动前完全一致
（12,693,533 cycles）；4-hart 6,458,332 cycles 与改动前一致；board-level
`pipeline-amp-board-sim` PASS；ISA 36/36。

下一次 PDS 报告要确认：mbox 最差路径还剩多少、100 MHz 下是否还有别的模块进入
top200。如果 4:1 那一段仍显眼，可以把它也寄存（读延迟 3 拍）；如果 16:1 的
select 扇出成为新瓶颈，就把 `slot` 换成同步读 RAM。

## 8. 还缺的一个输入

器件网格：PCE device view 的 X/Y 范围（或任一条 `CLMA_x_y` 的最大值）。有了它，
上面所有 `(X0,X1,Y0,Y1)` 就能从比例落成确定值。

注意：上传的 `.snr` 里的时序结论（17 MHz 约束、"All Constraints Met"）是**综合阶段
的估算**，single corner、无布局延迟，不能当作 PnR 结果引用。
