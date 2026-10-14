# RT-Thread Nano 外部工程

本目录保存用户提供的 RT-Thread Nano 源码快照，作为普通目录纳入 ARES，
不使用 Git 子模块。保留内核、FinSH、各架构端口、BSP、许可证及原有项目配置。
随包 `rtdef.h` 声明的内核版本为 **3.1.5**。

| 路径 | 内容 |
| --- | --- |
| `rt-thread/src/`、`include/` | RT-Thread 内核和公共头文件 |
| `rt-thread/components/finsh/` | MSH/FinSH 控制台 |
| `rt-thread/libcpu/` | 各架构 CPU 端口，含 RISC-V |
| `rt-thread/bsp/MundusJyd/` | 提供的 JYD BSP、启动/中断/链接脚本及 CoreMark 构建入口 |
| `rt-thread/bsp/MundusJyd/coremark/eembc/` | 带版本和 SHA-256 清单的 CoreMark 源码快照 |
| 其他 `rt-thread/bsp/` | 原外部工程的 BSP 示例和平台依赖 |

本次是源码导入。`MundusJyd` 仍使用旧 `MUNDUS_HOME`/`NPC_HOME` 配置与打包工具，
并带有 Mundus 专用 CoreMark 指令选项；导入不代表 ARES 已完成 RTOS 启动或硬件加速验证。
ARES 后续需完成 BSP、Timer/中断、控制台、链接地址、固件打包和构建入口适配。

原始软件说明见 [RT-Thread README](rt-thread/README.md)；
JYD 旧平台说明见 [BSP README](rt-thread/bsp/MundusJyd/README.md)。
许可证见本目录及各子目录中的 LICENSE；旧平台的功能/性能记录保持原样，不转作 ARES 验收证据。

构建目录、ELF/BIN/HEX/AXF、对象文件、日志、缓存和 IDE 用户状态由 [.gitignore](.gitignore)
排除。共享 `.uvprojx`、`.ewp`、`.eww`、Eclipse 项目、链接/启动文件和供应商设备资源保留。
