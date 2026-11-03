# ARES-L 应用工程：语言模型（llm）与手势识别（gesture）

技术报告《ARES：面向 FPGA 的 RISC-V 单发射流水线 SoC》（`technical_report.pdf`）
第二部分的两个应用，各自作为一个**自包含工程**：同一颗 ARES 九级顺序核
（Mundus，源码取自 `/home/ccy/Documents/qs/ARES/rtl/pipeline/core`）、同一片
miniTensor INT8 协处理器、同一套 SoC 与裸机运行时，应用差异只在固件、模型与
后处理。

| 目录 | 应用 | 硬件 | 软件 |
| --- | --- | --- | --- |
| `llm/` | 语言模型：H112 词级 seq2seq GRU、A0 char-GRU（CPU / miniTensor 两条路径）、QA 检索 | CPU + miniTensor + UART | 裸机 `mt` 驱动、量化/打包工具、PDS |
| `gesture/` | 手势识别：OV5640 → 32×32 → 4 层 INT8 CNN → UART 10 Hz | CPU + miniTensor + OV5640 采集 | 固件 + Three.js 全息页 + gesture-bridge |

两个工程的 `rtl/` 逐字节相同（`gesture/rtl/cam` 与 `board_gesture.v` 除外）：

```bash
bash llm/tools/check_core_sync.sh        # 校验两边 rtl/ 一致、且与 ARES 核一致
bash llm/tools/sync_ares_core.sh /path/to/ARES   # 从 ARES 重新同步核
```

## 统一口径

* **CPU**：ARES 核（IF1/IF2、ID、ISS、EX1–EX4、WB 九级），16 项 Bimodal+BTB、
  8 项 RAS、四路 ICache、写直达 L1 D-cache；应用侧复位入口 0x0；
* **数据视图**：uncached。所有应用地址都在核内 0x8010_0000–0x8013_FFFF 可缓存
  窗口之外，load/store 以单拍 32 bit 事务经 PERIP 出核；
* **miniTensor**：4×4 INT8 阵列、128 bit 行式 UB、向量单元（ADD8/MAX8/RELU8）、
  定点 epilogue；CV-X-IF 兼容 shim + 64 项命令队列 + DMA 桥；GEMV 映射为
  1×1 卷积；
* **加速器窗口**：0xE000_0000，8 个 32 bit 寄存器；
* **公共软件栈**：裸机运行时（`start.S`/`runtime`/UART printf）、`mt.c` 驱动、
  量化/打包/golden 工具链。

## 快速开始

```bash
cd llm && make lint && make sim && make fw-h112 && make run-h112
cd gesture && make lint && make lint-board && make sim && make fw-sim && make run-sim
cd gesture && make track-test && make web-build
```

## 与文档的关系

技术报告的应用章节按“ARES-L 五级应用基线”叙述；本次重构按统一要求把两个应用
的核替换为 ARES 主线的 Mundus 九级核，应用侧契约（uncached 视图、CV-X-IF shim、
0xE000_0000 八寄存器窗口、命令流、模型与精度口径）保持不变。每个工程的
`README.md` 与 `rtl/core/README.md` 记录了核的来源、唯一改动（复位入口）与
同步/校验方法。
