# ARES 原生 C5／共享 L2 验证交接

> 更新：2026-10-27。验证基线为 `base_core` 的 `ed5b2a4` 加本轮移植，远端相关来源至 `1fbe654`。没有创建 merge／cherry-pick commit。

## 1. 保留的硬件路径

```text
每 hart：真实 FE → 原生 C5 → ares_core_top／私有 L1D
            ICache AXI → axi_l2_bridge → L2 i0/i1
            LSU D-side             → L2 c0/c1
共享：32KiB L2（128 sets × 4 ways × 64B），128-bit backing memory
```

legacy adapter 保留独立测试，不在当前 hart 主路径。hart1 D-side `+0x100000` 只用于当前 AMP CoreMark 私有数据／栈诊断；不能直接用于正式系统共享区、MMIO 或 DMA。

L2 hart 的 MMIO 仍为桩、IRQ 输入为零、FENCE.I 未接 ICache invalidate。CLINT／PLIC 的已有单测不等于完整双核系统接通。

## 2. 已提供的命令

```bash
make lint-l2 unit-l2 unit-l2-frontend
make coremark-image test-coremark-image   # 仓库内镜像链；无外部 benchmark 路径
make unit-coremark
make unit-2core-coremark
make unit-2core-coremark COREMARK_ARGS=+H1EN=0
# 两份 TB 先构建完成；本目标直接复用二进制，运行短镜像正负回归。
make test-coremark-harness
```

`make coremark-image` 产出 `build/coremark/{coremark.bin,coremark_dmem.hex,inputs.json}`；
`unit-coremark`／`unit-2core-coremark` 在未指定 `DMEM=` 时自动使用该镜像（缺失则按需构建），
显式 `DMEM=<path>` 仍然优先。

`+H1EN` 在 TB 启动／释放复位前选择参考模式，不据此宣称在途事务期间任意关核安全。

`COREMARK_ARGS` 透传 simulator plusargs；`+TIMEOUT_NS=<正整数>` 用于有界超时验证，默认 600,000,000ns。测试图像不是完整 CoreMark 时不要引用 TB 打印的 CoreMark/MHz 作为性能结果。

长程序依赖外部镜像，不加入 `make all`。当前本地结果与哈希见 [执行记录](l2_integration_results.md)；仓库内自包含镜像链仍是 M1 待办。

## 3. 本轮软件输入复现

本轮使用现有外部普通软件 CRC CoreMark，未复制其源码进 Git。设置 `COREMARK_SRC` 为已有 benchmark 目录，目录下应有 `src/`、`include/`，其 port 为 `ITERATIONS=100`、2000B、performance seeds `0/0/0x66`、单实例；不得指向硬件 CRC 或 custom 指令版本。

```bash
export ARES_HOME="$(pwd)"
export COREMARK_SRC=/absolute/path/am-kernels/benchmarks/coremark
python3 - <<'PY'
from pathlib import Path
import os, shutil
src = Path(os.environ['COREMARK_SRC'])
out = Path('build/verification/l2-integration/coremark-src')
shutil.copytree(src / 'src', out / 'src', dirs_exist_ok=True)
shutil.copytree(src / 'include', out / 'include', dirs_exist_ok=True)
(out / 'Makefile').write_text('NAME = coremark\nSRCS = $(wildcard src/*.c)\ninclude $(ARES_HOME)/tests/abstract-machine/Makefile\n')
PY
make -C build/verification/l2-integration/coremark-src \
  ARES_HOME="$ARES_HOME" ARCH=riscv32-ares CROSS_COMPILE=riscv64-unknown-elf- image
python3 - <<'PY'
from pathlib import Path
root = Path('build/verification/l2-integration')
b = (root / 'coremark-src/build/coremark-riscv32-ares.bin').read_bytes()
b += bytes(-len(b) % 16)
(root / 'coremark_dmem.hex').write_text(''.join(
    f'{int.from_bytes(b[i:i+16], "little"):032x}\n' for i in range(0, len(b), 16)))
PY
make unit-coremark DMEM="$ARES_HOME/build/verification/l2-integration/coremark_dmem.hex"
make unit-2core-coremark DMEM="$ARES_HOME/build/verification/l2-integration/coremark_dmem.hex"
```

这是当前有外部依赖的复现说明，不能称为干净 checkout 自包含构建。更换源代码／编译器／链接／port 后须记录新哈希，不能要求 cycles 与远端或本轮完全相同。

## 4. 验收与后续

- 保持原生 C5、普通软件 CRC、配置与每 hart／聚合口径；该双核测试是 AMP 两份实例，不是 SMP 或官方 MULTITHREAD=2。
- 旧“44.7ms L2 数据破坏”结论已撤销，见 [根因](coremark_dual_bug_report.md)。若再遇异常，比较首个错误与退休／事务证据，不预设根因。
- M1 剩余：默认几何多 seed 压力、随机反压／复位／行宽边界、运行期越界守卫与覆盖。镜像生产链已由 A1 关闭（`make coremark-image`）；检查器故障注入与完成周期界已由 harness 19 项覆盖，见 [A1 记录](m1_a1_image_chain_results.md)。
- M2 后续：正式 memory map、MMIO xbar、CLINT／PLIC／Mailbox、Boot ROM／双核启动／UART；再推进默认入口、DMA／tensor／BSP、最终板级签核。
- 128KiB／8-bank／多 MSHR／WBQ／QoS／SPM 是后续配置目标；严格 >200MHz 仍为规划要求，没有当前完整 L2 SoC routed／实板签核。
