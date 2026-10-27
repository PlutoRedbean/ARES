# A1 软件镜像链：实施与证据（2026-10-27）

> 范围：`docs/next_steps_implementation_plan.md` §2 A1。决策口径见
> [m1_closure_decisions.md](m1_closure_decisions.md)（D-A1–D-A4）。
> 基线：`base_core` HEAD `f246e1f` 加本轮工作区改动；远端来源 `l2-cache` 至 `1fbe654`。
> 本文只记录 A1 的交付与实测证据，**不表示 L2-M1 已整体关闭**。

## 1. 交付内容

| 位置 | 内容 |
| --- | --- |
| `tests/benchmarks/coremark/` | vendor 的 EEMBC CoreMark 源码（`src/`、`include/`）、`LICENSE.md`、`NOTICE.md`（来源／哈希／冻结参数／商标边界）、`Makefile`、`README.md` |
| `scripts/elf_image.py` | ELF32 → dense bin → 128-bit readmemh，含地址与边界校验（唯一实现） |
| `scripts/build_coremark_image.py` | 构建驱动：frozen 参数闸门、staging、构建、转换、`inputs.json`（哈希／工具版本／git 状态） |
| `scripts/test_coremark_image.py` | 转换器与驱动的正负测试（29 项） |
| `Makefile` | `coremark-image`／`test-coremark-image`；`unit-coremark`／`unit-2core-coremark` 在未给 `DMEM=` 时依赖生成镜像 |
| `rtl/top/test/tb_ares_coremark.sv`、`tb_2core_coremark.sv` | `+MAX_CYCLES`（完成周期界）、`+SHADOW_FAULT`（检查器故障注入，仅双核 TB） |
| `scripts/test_coremark_harness.py` | 13 → 19 项：周期界正／负、shadow 故障注入、干净运行静默 |
| `.gitignore` | 忽略 `tests/benchmarks/coremark/build/` |

`build/coremark/`（镜像、`build.log`、`inputs.json`）与 `build/verification/m1-a1/`（日志）均在忽略目录，不入库。

## 2. 冻结参数与镜像契约

| 项 | 值 |
| --- | --- |
| ITERATIONS／TOTAL_DATA_SIZE | 100／2000（`PERFORMANCE_RUN`） |
| seeds | 0／0／0x66，单实例 `MULTITHREAD=1` |
| ISA／ABI | `rv32im_zicsr`／`ilp32`，`-static` |
| 镜像基址／窗口 | `0x8000_0000`／16 MiB（readmemh 行 i = 基址 + 16i） |
| 代码／数据布局 | IROM 32 KiB `0x8000_0000`；DRAM 256 KiB `0x8010_0000`；栈顶 `0x8014_0000`（`ares-linker.ld`） |
| hart1 私有偏移 | `+0x100000`，**仅诊断**（D-A4），不写入链接脚本／BSP |

驱动在构建前用正则校验上述参数，漂移即拒绝并提示更新 `NOTICE.md` 与决策记录。

## 3. 验证证据

### 3.1 转换器逐字节复现历史镜像

用新转换器处理历史 ELF（`build/verification/l2-integration/coremark-src/build/`），
产物与 [集成记录](l2_integration_results.md) 记录完全一致：

| 产物 | SHA-256 | 与历史记录 |
| --- | --- | --- |
| ELF | `1c1cb8f04fbad8c99813456e12c572dc175b07eadc9069b9a779391d87a268a1` | 一致 |
| bin | `b77bffd438b20b1d41f9d17177012c3d87c2aeed949e72c232269baba460a5b9` | 一致 |
| hex | `ce3ad6ee15c3bd4ec220e557e52e17056b5f96307eb3681308d075c48a85c02c` | 一致（65,726 行） |

这也是选择「解析 ELF program header ＋ 复刻 `objcopy -O binary` 语义」而非手写 `objcopy` 管道的原因：
历史哈希可复核，转换规则只有一处实现。

### 3.2 干净目录重建（无仓库构建状态）

把 `common.mk`、`scripts/`、`tests/benchmarks/`、`tests/abstract-machine/`、`configs/`
复制到空目录 `/tmp/ares-clean`，仅执行：

```
python3 scripts/build_coremark_image.py --out /tmp/ares-clean-out
```

得到与 §3.1 完全相同的 bin／hex 哈希。即镜像链不再依赖任何外部 benchmark 路径或既有构建产物。
（严格意义的「干净 checkout」仍需在提交后复核，见 §5。）

### 3.3 镜像链正负测试：29/29

`make test-coremark-image`（不依赖 RTL）：

| 类别 | 用例 |
| --- | --- |
| 输入拒绝 | 空文件、坏 magic、截断头、64-bit、大端、ET_REL、非 RISC-V、无 program header、无 PT_LOAD、filesz > memsz、段内容截断 |
| 地址边界 | 段低于基址、段超出 16 MiB、自定义 `--limit`、两个文件段重叠、entry 在镜像外（低／高） |
| 正例 | 代码 `0x8000_0000`＋数据 `0x8010_0000` 的 dense 布局、readmemh 编码、单段合法镜像 |
| CLI | 缺 ELF、非法格式、**失败时不写产物** |
| 驱动 | 缺 port、缺已 staging 的 ELF、frozen 参数漂移被拒、frozen 闸门放行、`--out` 在仓库外时记录绝对路径 |

判据是「非零退出 + 具体诊断」，不是打印警告后继续。

### 3.4 完整 CoreMark 回归（仓库内镜像）

命令为 `CCACHE_DISABLE=1 make unit-coremark` 与 `make unit-2core-coremark`，
两者均**未传** `DMEM=`，使用的是 `make coremark-image` 生成的镜像；日志在 `build/verification/m1-a1/`。

| 配置 | retires | cycles | IPC | CoreMark/MHz | 结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| 单核 | 31,349,223 | 48,856,291 | 0.641662 | 2.0468 | PASS，a0=0，hits=8,423／misses=178 |
| 双核 hart0 | 31,349,223 | 48,857,613 | 0.641645 | 2.0468 | PASS，a0=0 |
| 双核 hart1 | 31,349,223 | 48,857,616 | 0.641645 | 2.0468 | PASS，a0=0 |
| 双核聚合 | 62,698,446 | 48,857,616 | 1.283289 | 4.0935 | PASS，9 checks，shadow rsp=17,202 零错 |

单核与双核的 retires／cycles／IPC／CoreMark/MHz 与 [集成记录](l2_integration_results.md) 逐位一致，
shadow 响应数同为 17,202 且零错，说明镜像链替换与 TB 的默认关闭开关都没有改变被测输入。
实测墙钟（本机，单线程 Verilator）：单核约 10 分钟、双核约 36 分钟。

### 3.5 harness：13 → 19 项

新增（A1 第 6 项）：

| 检查 | 期望 | 说明 |
| --- | --- | --- |
| single／dual：`+MAX_CYCLES=100000` | 通过 | 完成周期界不误报 |
| single／dual：`+MAX_CYCLES=1` | 失败，诊断含 MAX_CYCLES | 越界必须非零退出 |
| dual：`+SHADOW_FAULT=1` | 失败，且恰好注入 1 个错误 | 8 条指令／4 次 D 侧读的镜像上 rsp ≥ 3；注入后仍完成后续比对并整体失败，证明错误不会被后续正确响应冲掉 |
| dual：干净运行 | `err_i0=err_i1=err_c0=err_c1=err_wb=0` | 注入开关默认关闭时检查器仍然静默 |

结果：`ALL TESTS PASSED: CoreMark harness 19 checks`。

## 4. 复现命令

```
make coremark-image test-coremark-image   # 镜像 + 转换规则正负测试（秒级）
make unit-coremark                        # 自动使用/构建 build/coremark 镜像（约 10 分钟仿真）
make unit-2core-coremark                  # 双核（约 36 分钟仿真）
make test-coremark-harness                # 短镜像 19 项（需先构建两份 TB）
```

长程序仍然**不在** `make all` 中。

## 5. 仍未关闭

1. **A1 第 5 项后半**：`tb_*_coremark` 的 `addr[23:4]` 低位索引在**运行期**仍会把越界访问折回 backing
   （例如 `0xA000_xxxx` MMIO 会落到低地址）。当前由转换器的加载期边界检查兜住镜像本身；
   运行期守卫与 MMIO 桩的取舍属 A2／SPEC-M7 范围，未在本轮改动。
2. **A1 第 7 项**（自然对齐检查覆盖：取消／有效访问正负用例）未开始。
3. **A2 全部**（默认几何固定 seed 压力、随机反压、复位旧响应隔离、行宽边界、覆盖统计）。
4. 干净 checkout 复核需在提交后重跑 §3.2 的命令。

## 6. 验证中顺带修好的两个问题

| 问题 | 现象 | 处理 |
| --- | --- | --- |
| 并发构建镜像 | 两个长程序目标并行触发 `$(COREMARK_HEX)` 规则，staging 目录被另一方删除，出现 `getcwd() failed` 与半成品镜像 | 驱动对输出目录加 `flock`，bin／hex／inputs.json 改为临时文件 + `os.replace` 原子发布 |
| Verilator 走 ccache | `ccache` 尝试写 `/run/user/1000/ccache-tmp` 被沙箱拒绝，C++ 编译失败 | 长程序回归统一 `CCACHE_DISABLE=1`（与集成记录的既有做法一致）；驱动默认禁用 ccache，可用 `--ccache` 打开 |

## 7. 本轮改动文件

新增：`tests/benchmarks/coremark/`、`scripts/elf_image.py`、`scripts/build_coremark_image.py`、
`scripts/test_coremark_image.py`、`docs/m1_closure_decisions.md`、`docs/m1_a1_image_chain_results.md`。

修改：`Makefile`、`.gitignore`、`scripts/test_coremark_harness.py`、
`rtl/top/test/tb_ares_coremark.sv`、`rtl/top/test/tb_2core_coremark.sv`、
`docs/implementation_plan.md`、`docs/next_steps_implementation_plan.md`、
`docs/l2_integration_results.md`、`docs/multicore_l2_handoff.md`。
