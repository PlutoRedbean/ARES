# llm

QS 工程里的 LLM 线，与 `gesture/` 并列，共用同一个 git 仓库（仓库根在 `QS/`）。

目前是占位目录，尚无代码。加入内容时沿用 `gesture/` 的约定：

- 代码、脚本、文档放本目录并入库；大文件不进仓库。
- 模型权重、数据集、venv、下载/编译缓存放仓库外的工作区，
  并用一个 `$QS_LLM_HOME`（或同名环境变量）指过去。
- 入口脚本自带 `doctor` / `status` 之类的自检，别让日常命令依赖具体机器的绝对路径。

参考同级的 `gesture/README.md` 与 `gesture/docs/GESTURE.md`。
