# miniTensor

ARES 仓库中的 miniTensor 加速器源码、独立验证和软件集成资料。
当前批准的架构见 [ARES miniTensor 微架构](../docs/microarch/miniTensor.md)。
ARES 尚未完成真实 Core＋RT-Thread＋miniTensor 集成；RT-Thread 工程将后续加入。

## 目录与入口

| 路径 | 用途 |
| --- | --- |
| `rtl/` | 加速器 RTL、CV-X-IF 接口、Tensor/VPU/UB/DMA 模块 |
| `tb/` | 独立单元和闭环验证；`tb/npc/` 是行为模型，不依赖旧根目录 NPC 工程 |
| `Makefile` | 独立仿真、回归及清理入口 |
| `integration/bsp/` | 保留的 RT-Thread 驱动、应用、兼容头及自校验 golden 夹具 |
| `integration/npc/` | MMIO→CV-X-IF 适配器、仿真 DPI DMA 和适配器测试 |
| `integration/tools/` | 模型训练、量化、打包与布局检查工具 |
| `integration/patches/` | 旧 Mundus/RT-Thread BSP 补丁，供后续移植参考 |
| `integration/run_jyd_sim.sh` | 显式使用外部 Mundus 工程的旧集成入口 |
| `models/` | 模型输入与生成物策略，见 [models README](models/README.md) |
| `docs/` | 旧部署手册和微架构快照 |
| `handoff/archive/design/` | 保留的历史设计记录 |

## 独立验证

从 ARES 根目录运行，依赖 Verilator 和 C++ 编译器：

```bash
make -C miniTensor regress   # 九个独立测试目标
make -C miniTensor top-sim   # 加速器顶层测试
make -C miniTensor npc-sim   # CPU 行为模型＋DMA＋Tensor 闭环
make -C miniTensor clean    # 清理独立仿真构建目录
```

`npc-sim` 使用本目录的测试行为模型，不执行 ARES 或 Mundus CPU RTL。
默认构建产物位于忽略的 `obj_dir/`。

## RT-Thread 与旧平台资料

- [集成说明](integration/README.md)：旧平台 MMIO/数据通路及适配器验证。
- [集成清单](integration/MANIFEST.md)：驱动、补丁和历史结果地图。
- [旧 Mundus 部署手册](docs/legacy_mundus_deployment.md)：原有完整构建步骤。
- [旧微架构快照](docs/legacy_microarch.md)：保留版本差异，供维护者核对。
- [历史设计索引](handoff/README.md)。

复现旧平台时需要已配置好的外部 Mundus CPU 和 RT-Thread BSP：

```bash
MUNDUS_HOME=/absolute/path/to/Mundus \
  miniTensor/integration/run_jyd_sim.sh
```

脚本默认使用本仓库的 miniTensor 作为 `MT_HOME`。其中 DPI DMA 是仿真设施；
后续 FPGA 接入需完成实际内存仲裁和数据可见性设计。

## Git 跟踪范围

保留 RTL、测试、驱动、工具、补丁、文档、ONNX 模型和校准输入。
`integration/bsp/*_weights.h` 是固件直接使用的自校验夹具，继续跟踪。

忽略构建目录、Python 环境/缓存、波形、运行日志、生成权重 blob，以及已经被完整模型
替代的 `handoff/archive/9stage/` 本地备份。取消跟踪的文件仍保留在本地；
它们不再随新克隆分发。忽略规则见 [.gitignore](.gitignore)。
