# vendor 来源

本目录是**只读拷贝**，不要在这里改代码；上游改了再重新拷贝。

| 目录 | 上游 | 分支 | commit | 拷贝时间 | 说明 |
|---|---|---|---|---|---|
| `ares-core/` | `git@github.com:ccycyc6/ARES.git` | `origin/pipeline-single-issue` | `98d24270a517d418c7baaf1856a81804641956df` | 2026-11-15 | 单发射 8 级（9 功能单元）流水核 + jyd SoC + 板级/Pango 层 + 自带 TB 与 filelist；`core/vsrc/build/Mundus.sv` 是已生成的核 |
| `minitensor/rtl/` | 同上 | 同上 | 同上 | 2026-11-15 | `app/gesture/rtl/minitensor/`：CV-X-IF、UB、DMA、VPU、4×4 INT8 GEMM、epilogue（为 Pango ADS 改成扁平 struct） |
| `minitensor/sw/` | 同上 | 同上 | 同上 | 2026-11-15 | `app/gesture/firmware/app/mt.c` / `mt.h`：裸机驱动参考 |

重新拷贝：

```bash
cd /home/ccy/Documents/qs/ARES
git fetch origin
git archive origin/pipeline-single-issue rtl/pipeline | tar -x -C /tmp/ares-core
git archive origin/pipeline-single-issue app/gesture/rtl/minitensor app/gesture/firmware/app/mt.c app/gesture/firmware/app/mt.h | tar -x -C /tmp/ares-mt
```

## 已知差异与注意事项

- `ares-core/core/vsrc/build/Mundus.sv` 是 Chisel 生成物，上游改 core 时需要重新生成（`gen/` 里有 mill 配置），本仓库不负责重新生成。
- `minitensor/rtl/` 用的是 `minitensor_pkg.sv` 扁平 struct；上游 `main` 分支的 `miniTensor/` 目录是旧的 SV interface 版本（115 个文件，含 docs/tb），**不要混用**。
- 两个上游目录都带 `MANIFEST.sha256` / `.gitignore` 之类的文件，拷贝时原样带过来了。

## 我们的改造计划（见 `../TODO.md` M3）

在 `minitensor/rtl/` 的副本基础上改，**不在 vendor 里直接改**：新增 `rtl/l2/` 放 16×16 W4A8 GEMM、双缓冲 DMA、transformer 算子，
复用 vendor 里的 UB/VPU/接口。M3 开始前先把要复用的 3–4 个模块拷到 `rtl/l2/` 再改，保持 vendor 可对照。
