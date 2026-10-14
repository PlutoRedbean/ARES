# 模型输入与生成物

| 文件 | Git 策略 | 用途/生成方式 |
| --- | --- | --- |
| `tiny-yolov3.onnx` | 跟踪 | 完整模型和三层模型的预训练输入，不可由当前打包脚本重建 |
| `ym_weights.bin` | 忽略 | 完整 21-stage 模型 blob，由 `pack_full.py` 生成 |
| `yc_weights.bin` | 忽略 | 三层卷积回归 blob，由 `pack_real.py` 生成 |

`integration/tools/detector_float.npz` 是小型检测器打包工具的校准/训练输入，继续跟踪。
`integration/bsp/*_weights.h` 保留为固件可直接使用的 golden 夹具。
不要把 ONNX/NPZ 输入与生成的 blob 一起全局忽略。

从 ARES 根目录准备工具环境，再在 miniTensor 目录内运行：

```bash
cd miniTensor
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python integration/tools/pack_full.py  # ym_weights.bin + 完整模型层表
.venv/bin/python integration/tools/pack_real.py  # yc_weights.bin + 三层模型夹具
```

打包器同时会更新受跟踪的 golden 头；提交前应检查这些夹具差异。
`pack_model.py` 是旧的部分模型打包器，也会覆盖 `ym_weights.bin` 和同名层表，
完整模型部署应使用 `pack_full.py`。
