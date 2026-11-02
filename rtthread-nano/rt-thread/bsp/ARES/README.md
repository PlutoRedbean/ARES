# ARES 单核最小 BSP

基于导入的 MundusJyd BSP 和 RT-Thread RISC-V common 端口，目标是当前 ARES 单核流水线。
启动、trap 汇编保留原有栈帧约定；本地 cpuport 使用 16 字节栈对齐和仅 M 模式初始状态。
内核与 common/context_gcc.S 直接复用 vendored 源码，不修改旧 BSP。

从仓库根运行 `make rtos-image`、`make pipeline-rtos` 或 `make pipeline-rtos-board-sim`。
交互式 MSH 使用 `make pipeline-rtos-shell`；`PROFILE=shell` 输出到独立的 `build/rtos_shell/`，
支持 `help`、`ps`、`tick`、`irq`、`led`、`echo`、`sleep`、`ecall` 和模拟器退出命令 `quit`。
完整内存/中断契约、测试结果和 PDS 入口见 [单核 RTOS 文档](../../../../docs/pipeline_rtos.md)。
