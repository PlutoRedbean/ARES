# ARES 技术文档（单文件合并版）

本目录只保留一个大的 LaTeX 报告：`technical_report.tex`。core 原稿、应用片段、TikZ 子文件都已内联，不再有 `application/`、`build_full.py` 和 `figures/tikz/`。

## 文件

| 路径 | 说明 |
| --- | --- |
| `technical_report.tex` | 唯一的报告源文件（core + 应用/加速器，TikZ 图全部内联） |
| `technical_report.pdf` | 合并报告 PDF（69 页） |
| `results.json` | core 组原有结果，未改动 |
| `application_results.json` | 应用与加速器结果（本部分新增） |
| `figures/` | 只放图片/PDF 素材，不再放 `.tex` |
| `figures/architecture_sheet.pdf` | 新增 10 张架构/数据流图，单独成页 |
| `figures/diagrams/*.png` | 上述图纸导出的 PNG，可直接插 PPT |
| `figures/app_web_*.png` | 上位机实拍截图 |

PDF 均未纳入 git，只在本地保留；需要时按上面的命令重新生成。

core 原稿与替换前目录在 `/home/ccy/Documents/qs/ARES-technical-backup-2026-11-03.tar.gz`，需要 diff 时从备份取。

## 构建

本机若没有 SimSun / Times New Roman，报告会自动回退到 Noto Serif CJK SC / TeX Gyre Termes；有模板字体的机器仍使用原字体。

~~~bash
cd ARES/docs/technical
xelatex -interaction=nonstopmode -halt-on-error technical_report.tex
xelatex -interaction=nonstopmode -halt-on-error technical_report.tex
~~~

## 单文件里有什么

- 摘要、1.1--1.5：miniTensor、两个应用、指标表、创新点。
- 2.1：平台与口径、应用与加速器总体架构。
- 2.2.3：自研 miniTensor 全节。
- 2.3.3：语言模型部署。
- 2.3.4：手势识别。
- 2.3.5：演示层（串口桥接、SSE、Three.js）。
- 3.4：应用与加速器特性成果。
- 4.1/4.2：实际应用、五个 bug 与优化心得。
- 附录 C：应用与加速器复现信息（原附录 B 旧版 Mundus 九级核资料已删除）。

报告正文保留 5 张新增核心图（总体架构、miniTensor 架构、GEMV 映射、LLM 路径、手势链路）和 1 组网页截图；core 原有 13 张图与正文内联小图也在同一个文件里，共 21 个 `tikzpicture`。`figures/architecture_sheet.pdf` 是 10 张图的扩展集合，部分图未放进正文。

正文中的手势应用按 8 类词表设计，可识别石头、布、剪刀、OK、点赞、指向、停止、捏合 8 种手势，其中石头、布、剪刀已完成板端演示，识别速度为 10 fps。

## 口径

- 应用数据统一按 Mundus 九级核口径记录；512 KiB 数据窗口为应用侧配置。
- H112 152,056 B 用 512 KiB 窗口；H88 118,168 B 用 128 KB loader。
- H112 语言模型输出速度约为 3 token/s（3 tps）；手势识别速度为 10 fps。
- 103 char/s 是 INT8 miniTensor 路径，文本质量低于 CPU int16 的 17 char/s。
- b5 的 CLMA/FF 与 `video_fb_top` 的 LUT/IO 不混比。

## 和 core 原稿的关系

主报告是在 core 原稿上插入应用/加速器内容得到的；插入前正文没有被删除或改写。新增图表会让 core 原有图表号整体后移，正文引用都走 `\label/\ref`。
## 图纸索引

`figures/diagrams/` 里是 10 张图的 PNG；正文只放了其中 5 张核心图，其余留在扩展图纸里。

| PNG | 内容 | 正文位置 |
| --- | --- | --- |
| `01_app_overview.png` | 应用与加速器总体架构 | 图 6 |
| `02_mt_arch.png` | miniTensor 架构 | 图 18 |
| `03_mt_dataflow.png` | 行式 UB 与 4×4 数据通路 | 扩展 |
| `04_mt_cmd_timing.png` | 命令 issue/commit/result | 扩展 |
| `05_mt_gemv.png` | GEMV 映射为 1×1 卷积 | 图 19 |
| `06_app_stack.png` | 两个应用共用软件栈 | 扩展 |
| `07_llm_flow.png` | H112 CPU 部署、A0 定点路径对照及独立 QA 检索 | 图 21 |
| `08_gesture_flow.png` | 手势识别链路 | 图 22 |
| `09_gesture_fsm.png` | 手势判决状态机 | 扩展 |
| `10_gesture_tile.png` | 手势 UB 分配与 tile 调度 | 扩展 |


## 本次勘误与待补验证（2026-11-04）

- H112 rank-24：126,006 个参数（124,464 个权重 + 1,542 个偏置）。
- A0：57,121 个参数（56,480 个权重 + 641 个偏置）。参数统计不包含量化比例、LUT 和对齐填充；镜像大小沿用原记录。
- 图 21 将 H112 的 CPU 部署、A0 的 CPU/miniTensor 两种量化路径和 QA 检索分别表示。H112 激活 LUT 按 127 缩放。
- 两个应用的 GEMM 核均由 8 步改为 10 步，覆盖完整 4×4×4 tile 的末端乘积。运行 `python3 scripts/test_minitensor_gemm.py`，两份 RTL 各通过 134 个用例、2,144 个输出检查；含有符号边界、累加、输入锁存与结果背压。

| 需要补充的实验或材料 | 要记录的内容 |
| --- | --- |
| 修复后的应用级仿真 | 手势各层及完整输出与整数 golden 对拍；A0 INT8 序列与各自 golden 对拍；固定输入、权重、RTL 哈希与随机种子 |
| 修复后的性能复测 | 手势命令数、完整帧周期与 busy 占比；A0 字符吞吐；明确计时是否包含 DMA、量化、后处理和串口延时 |
| 新位流与板端验证 | 重新综合/PnR，归档资源、setup/hold 时序及位流哈希；复测手势板端一致性和实际延迟 |
| 异常机制覆盖 | 实现标准 EBREAK 断点异常及其他拟声明支持的异常；用例检查 mcause、mepc、mtval（适用时）、mstatus、返回 PC 与错误路径副作用。FENCE.I 的取指同步需单独实现和验证 |
| 模型来源 | 最终 H112 checkpoint、训练语料配比和训练配置；H88 的实际权重与含偏置参数统计 |

正文及 JSON 中原有的 17/103 char/s、1.31 M 周期、精度和 FPGA 资源/时序仍是历史记录。10 步版本的应用性能与板级结果尚未重新测量。
