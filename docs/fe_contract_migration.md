# C5：真实 FE／BE 契约迁移与 IROM 接入

> 状态：2026-10-18 功能验收完成。此前迁移请求中的旧接口、工作量估算及 Q1–Q6 不再作为当前待办。
> 权威接口：[frontend_backend_contract.md](microarch/frontend_backend_contract.md) v1.1。

## 已批准的行为

- 未知目标 JALR 继续推测执行，`pred_npc=pc+4`；BRU 仅在目标不等时恢复，不再使用 `need_redirect`。
- `fe_pkg` 为唯一 FE/BE 类型来源；有效 `pred_npc` 与原始训练 metadata 分开保存。
- metadata 固定布局，包含预测目标／方向／类型、完整逐槽 `ghr_before` 和原始查表 metadata；停用预测器不删字段。
- 块内保留多个预测不跳转 CFI，首个预测跳转后截断。BPU 在 FTQ 前生成完整历史；不再传递 `cfi_prefix`。
- Branch Recovery 使用独立 PC/kind/GHR/actual_taken 通道；ARCH 恢复使用同沿双 Commit 更新后的历史。
- 双路提交输入、深度 8 训练 FIFO、单路表训练；credit 不借用同拍出队空间。提交历史及 RAS/Loop 恢复状态在接受沿推进，训练 FIFO 不被普通 Redirect 清除。
- 保持当前 Kconfig 默认值，包含 HEAD=2/BODY=8 的 IQ；首版只从 32KiB IROM 取指。

## 实际连接

`ares_cpu_top = frontend + ares_core_top (Backend/LSU) + ares_irom_bridge`。
桥将只读 AXI-Lite 单 outstanding 请求接到 64-bit、1-cycle 同步 IROM，选择 bit2 指定的字，持有响应直到接受。
`student_top` 内部实例化真实 CPU 和 IROM；`ares_soc_top` 沿用该平台并保留 miniTensor MMIO 控制适配，DMA 仍外露。

Predecode 修正只在有效前缀成功进入 IQ 后发出；未知条件分支不猜实际方向。
取消＋排空阻止旧路径响应再次进入 IQ；IROM 末端屏蔽越界槽，越界推测 PC 停发直至 Redirect。
无新增 illegal/misaligned/取指访问 Trap，原有 v1 支持边界不变。

## 验收与复现

```bash
make lint-all lint-backend lint-lsu lint-soc lint-mt
make tb-ares-pkg tb-fe-stub tb-mem-model unit unit-lsu
make unit-frontend unit-frontend-modes unit-soc
make isa          # 默认真实 FE，36/36
make isa-stub     # 保留 FE 桩，36/36
make test-vivado test-images
```

本轮证据：Backend 4/4 TB、LSU 11/11 TB、基础 3/3 TB；默认 FE 5 个 TB、
关闭 Tournament/RAS/Loop 的 2 个历史／协议 TB；真实 FE 与桩各 36/36。
FIFO TB 1821 checks；历史 TB 默认 8 checks／关闭可选预测器 6 checks；IQ 535 checks；
真实 FE 契约 601 条指令、154 次局部修正、32 次延迟读响应，含最终 ROM 窗口和旧响应隔离；
IROM 桥 36 checks。真实 CPU ISA 顶层另逐周期检查 FE→CIQ 的 metadata/pred_npc/PC
保存、Commit metadata 原样回传和 BRU 完整历史恢复。
SoC 总线 TB 2864 checks；自主取指程序退休 25 条，验证 DRAM miss/hit、uncached、
UART/LED、分支／调用／JALR（包括 target=pc+4）。Vivado 生成器 8/8、镜像分割 3/3。

## 保留边界

MC5 为真实 FE 功能集成门禁；不代表目标深预测器／吞吐或 FPGA PPA 完成。
板级物理 top、PLL/复位/CDC、完整约束和 post-route >200MHz（MC4）仍待实现验收。
正式 Timer、ARES RT-Thread、miniTensor 内核 XIF／共享内存 DMA（MC6）仍未闭环。
独立 DCache TB、部分覆盖率与性能比较等原有验证债务继续保留。
