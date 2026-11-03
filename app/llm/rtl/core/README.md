# rtl/core —— ARES 核（应用侧统一版本）

本目录是 **ARES 仓库 `rtl/pipeline/core` 的 RTL 子集**，两个应用工程
（`llm` 与 `gesture`）各自携带一份**逐字节相同**的副本。应用侧只用到综合
RTL，因此没有复制 Chisel 源（`scsrc/`）、DPI 钩子（`vsrc/DPIC/`）和
`Makefile`/mill 构建目录。

## 文件来源

| 本目录文件 | ARES 源路径 |
| --- | --- |
| `Mundus.sv` | `rtl/pipeline/core/vsrc/build/Mundus.sv`（firtool 生成） |
| `myCPU.v` | `rtl/pipeline/core/vsrc/Mundus/myCPU.v` |
| `Mundus_PC.v` | `rtl/pipeline/core/vsrc/Mundus/Mundus_PC.v`（见下方唯一改动） |
| `RegisterFile.v` `BimodalRas.v` `ReturnAddressStack.v` | `rtl/pipeline/core/vsrc/Mundus/` |
| `Divider.v` `Multplier.v` | `rtl/pipeline/core/vsrc/Mundus/` |
| `div.v` `mult.v` | `rtl/pipeline/soc/ip/` |
| `DCacheData_BRAM.v` `DCacheTag_BRAM.v` `DCacheLru_BRAM.v` | `rtl/pipeline/soc/ip/` |
| `icache/pipeline_icache.v` | `rtl/pipeline/core/vsrc/icache/` |
| `include/*.vh` | `rtl/pipeline/core/vsrc/include/` |
| `include/autoconf.vh` `include/pipeline_autoconf.vh` | `rtl/pipeline/include/` |

## 唯一改动：复位入口

`Mundus_PC.v` 的 `PC_BASE` 从 ARES 主线的 `32'h8000_0000` 改为
`32'h0000_0000`，原因见文件内注释：

* 仿真：ROM 跳板在 0x0，`lui x1,0x80000; jalr` 跳到 0x8000_0000 的镜像；
* 上板：UART loader 在 ROM 0x0，收完镜像后跳到 0x8000_0000。

如果定义 `CORE_ENTRY`，仍可按 autoconf 的口径覆盖。核的其余逻辑、
`IO` 端口、参数与 ARES 主线完全一致（IFU/IDU/ISS/EXU/LSU/WBU、16 项
Bimodal+BTB、8 项 RAS、`CONFIG_DCACHE_*` 的写直达 L1 D-cache、
custom-0 CRC8）。

## 与应用 SoC 的接口

`myCPU` 使用 ARES 的 IROM 请求/响应握手与 PERIP 数据口：

* `irom.req_valid/req_addr/req_ready` + `irom.rsp_valid/rsp_data/rsp_ready/flush`
  —— 由 `rtl/soc/ares_core_complex.sv` 接到四路 ICache；
* `perip.valid/ready/addr/wen/mask/wdata/rvalid/rdata/idle` —— 由
  `rtl/soc/ares_perip_bridge.sv` 接到 128 bit L2（读响应固定两拍，符合
  `lsu.scala` 在 LS3 取数的约定）；
* `retire.*` —— 顺序提交观察口，测试台用它判断 EBREAK 停机。

数据地址全部落在 0x8010_0000–0x8013_FFFF 可缓存窗口之外，因此应用侧是
uncached 视图；核内的 L1 D-cache 在该配置下不参与数据通路。

## 与 ARES 同步

```bash
tools/sync_ares_core.sh /path/to/ARES     # 重新拷贝并重放入口改动
tools/check_core_sync.sh /path/to/ARES    # 只检查差异
```
