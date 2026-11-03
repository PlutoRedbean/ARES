# ARES-L 应用二：手势识别（gesture）

OV5640 实时手势识别 + 全息网页演示工程：**一颗 ARES 九级顺序核 + 一片 miniTensor
INT8 协处理器**跑 4 层 INT8 CNN，串口以 10 Hz 输出手势，由 `web/` 里的
gesture-bridge 转成指令驱动 Three.js 全息页面。语言模型工程（`../llm`）与本工程
共用同一份 `rtl/`。

## 平台与口径

| 项目 | 本工程实现 |
| --- | --- |
| CPU | ARES 核（Mundus 九级），源码取自 ARES 仓库 `rtl/pipeline/core`，见 `rtl/core/README.md` |
| 数据视图 | uncached；CPU 与 miniTensor DMA 共享同一物理视图 |
| 加速器 | miniTensor：4×4 INT8、128 bit 行式 UB、向量单元、定点 epilogue；CV-X-IF shim + 64 项命令队列 |
| 采集 | OV5640 720p → 640×480 → 320×240，`cam_cap` 抽 32×32 缩略图写入 0xD000_2000 窗口 |
| 判决 | 13×11 固定取景框 letterbox 到 32×32 → 量化 → CNN → argmax + 裕度门限 4 + 3 帧确认 |
| 输出 | UART 115200 8N1，`hand: rock/paper/scissors`，10 Hz |
| 复位入口 | 0x0000_0000（仿真跳板 / 上板 UART loader） |

> 技术报告的应用章节把 CPU 记作“ARES-L 五级应用基线”。本次重构按要求把两个应用
> 统一到 ARES 仓库的 Mundus 九级核；应用侧契约（uncached 数据视图、CV-X-IF shim、
> 0xE000_0000 八寄存器窗口、命令流、255 帧 INT8 golden 口径）保持不变。

## 目录

```
gesture/
├── rtl/
│   ├── core/          ARES 核（与 llm 工程逐字节相同）
│   ├── minitensor/    统一 miniTensor（与 llm 工程逐字节相同）
│   ├── common/ soc/   SoC、L2/MMIO、UART、CLINT、miniTensor 包装
│   ├── cam/           OV5640 DVP 解码、32×32 缩略图、跨时钟 FIFO、帧缓存
│   └── board/         CPU + miniTensor + UART 顶层
├── board/             board_gesture.v：OV5640 + ares_soc 板级顶层
├── firmware/
│   ├── boot/ common/  启动、链接、runtime
│   └── app/           mt 驱动、mt_net、4 层 CNN、跟踪器、相机主程序
├── web/               Three.js 全息页 + gesture-bridge（COM9 → SSE）+ 单测
├── fpga/pango/        PDS 流程与引脚约束
├── tests/             跟踪器宿主单测
├── sim/ tools/ docs/
```

## 快速开始

```bash
make lint          # SoC lint
make lint-board    # 相机板级顶层 lint
make sim           # Verilator SoC 模型
make fw-sim        # 检测器自检镜像（仿真入口）
make run-sim       # 跑一段并打印 UART
make fw-cam        # 相机 + 手势镜像（上板入口，3 类头）
make track-test    # 跟踪器 5 项单测
make web-build     # 构建全息页（pnpm）
```

网页端：

```bash
cd web && pnpm install && pnpm dev       # http://127.0.0.1:5173
python web/tools/gesture-bridge/gesture_bridge.py   # COM9 -> SSE :8765
```

## 网络与判决

conv3×3 4→8、8→16、16→16，接 1×1 head 16→8；3,920 参数、约 745K MAC，
每帧约 1,936 条命令、1.31 M 周期（100 MHz 仿真 13.1 ms / 27 MHz 板级 48.5 ms）。
判决用裕度门限 4、连续 3 帧一致；无对比度直接报 none。

## 上位机

页面按 LineParser → CommandBus → StateMachine → EffectDirector → Three.js 组织，
手势经 gesture-bridge 映射为 FIST/START/MODE，经 SSE 推给页面；单测在
`web/tests`，协议见 `web/docs/PROTOCOL.md`、`web/docs/GESTURE-BRIDGE.md`。
