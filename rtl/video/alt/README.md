# rtl/video/alt — `video_dpram`（推断 RAM，仅仿真/对照）

`video_dpram.v` 用 8 个 512×32 的推断 bank 实现与 vendor
`wr_fram_buf`/`rd_fram_buf` 同名的模块（32-bit 写、256-bit 读）。它**不**被当前
S2 综合流程使用：`fpga/pango/flow_video_fb.tcl` 使用 vendor
`legacy/wr_fram_buf.v` + `legacy/rd_fram_buf.v` + `GTP_DRM36K_E1` SDPRAM。

保留它的原因：

- `rtl/video/test/tb_fram_buf.sv` 使用它做 Verilator 仿真（不依赖 Pango DRM 模型）；
- 仿真已经证明 framebuf 的地址/多 burst/行缓冲映射正确，可作为 vendor DRM 的对照。

复现仿真：

```bash
verilator --binary --timing -Irtl/video \
  --top-module tb_fram_buf_pat rtl/video/test/tb_fram_buf.sv \
  rtl/video/alt/video_dpram.v \
  rtl/video/legacy/{fram_buf,wr_buf,rd_buf,wr_ctrl,rd_ctrl,wr_cmd_trans,wr_rd_ctrl_top}.v
./obj_dir/tb_fram_buf_pat
```

**不要**把 `alt/video_dpram.v` 和 `legacy/wr_fram_buf.v`/`legacy/rd_fram_buf.v` 同时加进
一个 PDS 工程：它们定义同名模块。
