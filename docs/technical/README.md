# ARES 技术文档（单文件合并版）

本目录只保留一个大的 LaTeX 报告：`technical_report.tex`。core 原稿、应用片段、TikZ 子文件都已内联，不再有 `application/`、`build_full.py` 和 `figures/tikz/`。

## 文件

| 路径 | 说明 |
| --- | --- |
| `technical_report.tex` | 唯一的报告源文件（core + 应用/加速器，TikZ 图全部内联） |
| `technical_report.pdf` | 合并报告 PDF（74 页） |
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

- 摘要、1.1--1.6：miniTensor、两个应用、指标表、创新点、流程。
- 2.1：平台与口径、应用与加速器总体架构。
- 2.2.3：自研 miniTensor 全节。
- 2.3.1：两个应用共用的软件栈。
- 2.3.3：语言模型部署。
- 2.3.4：手势识别。
- 2.3.5：演示层（串口桥接、SSE、Three.js）。
- 3.4：应用与加速器特性成果。
- 4.1/4.2：应用侧扩展方向、五个 bug 与优化心得。
- 附录 C：应用与加速器复现信息（原附录 B 旧版 Mundus 资料已删除）。

所有 TikZ 图（core 原有 13 张 + 新增 12 张，以及正文内联小图，共 27 个 `tikzpicture`）都在 `technical_report.tex` 里，图片素材仍从 `figures/` 读取。

## 口径

- 应用数据在 ARES-L 五级应用基线上实测；Mundus 九级主线的 512 KiB 数据窗口是后续移植项。
- H112 152,056 B 用 512 KiB 窗口；H88 118,168 B 用 128 KB loader。
- 20 token/s 是输出节流；QA 的 5 tok/s 是 4 字符/token 的显示口径。
- 103 char/s 是 INT8 miniTensor 路径，文本质量低于 CPU int16 的 17 char/s。
- b5 的 CLMA/FF 与 `video_fb_top` 的 LUT/IO 不混比；相机整机 WNS -3.83 ns、3 条时钟未约束。
- core 稿第 3.3.5 节的 PDS/实板证据 TODO 仍原样保留。

## 和 core 原稿的关系

主报告是在 core 原稿上插入应用/加速器内容得到的；插入前正文没有被删除或改写。新增图表会让 core 原有图表号整体后移，正文引用都走 `\label/\ref`。