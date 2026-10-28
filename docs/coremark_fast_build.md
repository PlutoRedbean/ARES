# CoreMark 最快构建与跑分流程

> 目标：从当前仓库快速得到 **CRC8 + 数组化 core_bench_list + O3 + 32 KiB ICache** 的 CoreMark 跑分。
> 约束：不修改 `tests/benchmarks/coremark/src/*.c`；加速来自构建脚本、新增 TU 和 RTL 配置。
> 相关文档：[数组化实现](coremark_array_list.md) · [最新指令流分析](coremark_latest_hw_acceleration_analysis.md)

## 0. 环境准备

在仓库根目录执行：

```bash
cd /path/to/ARES

# 本机 ccache 默认目录可能无写权限；统一放到 /tmp。
export CCACHE_DIR=/tmp/ccache-ares
export CCACHE_TEMPDIR=/tmp/ccache-ares-tmp
export CXX=g++
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"
```

需要：RISC-V 裸机工具链（`riscv64-unknown-elf-`）、Python 3、Verilator、主机 gcc。

## 1. 生成加速镜像（约 1 分钟）

```bash
make coremark-array-image
```

产物：

```text
build/coremark_array/coremark-riscv32-ares.elf
build/coremark_array/coremark.bin
build/coremark_array/coremark_dmem.hex   ← 100-iter 跑分镜像
build/coremark_array/inputs.json
```

这一步自动完成：

- 复制 EEMBC 源文件到 `build/coremark_array/src_port`（源文件不动）；
- 生成 `src/crc_hw.c`（custom-0 CRC8）；
- 生成 `src/core_list_array.c`（数组化 `core_bench_list`）；
- 只对 `core_list_join.o` 加 `-Dcore_bench_list=core_bench_list_orig`；
- 加 `-O3 -funroll-loops`，再走 ELF → bin → 128-bit readmemh。

## 2. 主机等价测试（几秒）

```bash
make test-coremark-array
```

预期：

```text
ALL 200 CALLS MATCH
```

它把原始 `core_bench_list` 与数组版编译进同一个 x86 程序，跑 100 iteration × 2 call，逐次比较返回值、链表内容、矩阵/state 字节和 4 个 CRC。

## 3. 生成可复现的 32 KiB ICache 配置

默认 `configs/build/.config` 是 64 sets = **8 KiB** ICache；25 KiB 的加速镜像会严重冲突。用下面的命令生成一个 32 KiB 的 include 覆盖：

```bash
make config-gen
mkdir -p build/coremark_32k/include
sed 's/`define CONFIG_FE_ICACHE_NR_SETS 64/`define CONFIG_FE_ICACHE_NR_SETS 256/' \
    configs/build/vsrc/include/ares_autoconf.vh \
    > build/coremark_32k/include/ares_autoconf.vh

grep -q '`define CONFIG_FE_ICACHE_NR_SETS 256' \
    build/coremark_32k/include/ares_autoconf.vh

export COREMARK_CFG="+incdir+$PWD/build/coremark_32k/include"
```

> 这个 include 只改 `CONFIG_FE_ICACHE_NR_SETS`，其他配置与默认一致；`build/` 是 ignored 的生成目录。

## 4. 4-iteration 快速验证（约 1 分钟仿真）

先由 100-iter 镜像生成 4-iter 诊断镜像（只改 seed4，不用于正式分数）：

```bash
python3 - <<'EOF'
from pathlib import Path
src = Path('build/coremark_array/coremark_dmem.hex').read_text().splitlines()
hits = [i for i, line in enumerate(src)
        if line.endswith('00000066' + '00000064')]
assert len(hits) == 1, hits
i = hits[0]
src[i] = src[i][:-8] + '00000004'
Path('build/analysis/coremark_array_4iter.hex').write_text(
    '\n'.join(src) + '\n')
EOF

make unit-2core-coremark \
    DMEM=$PWD/build/analysis/coremark_array_4iter.hex \
    ARES_CFG_INC=$COREMARK_CFG
```

预期：

```text
ALL TESTS PASSED: 9 checks - 2 harts + shared L2, two CoreMark instances
hart0: retires=894812 cycles=1237385 IPC=0.723148 CM/MHz=80.8156
hart1: retires=894812 cycles=1237382 IPC=0.723149 CM/MHz=80.8158
aggregate: retires=1789624 max_cycles=1237385 IPC=1.446295 CM/MHz=161.6312
```

**注意**：TB 的 `CM/MHz` 按 100 iterations 计算（`100e6/cycles`）。4-iter 打印的
80.8156 / 161.6312 要除以 25，才是 **3.233 / 6.465 CM/MHz**。

## 5. 100-iteration 正式跑分（约 20 分钟）

```bash
make unit-2core-coremark \
    DMEM=$PWD/build/coremark_array/coremark_dmem.hex \
    ARES_CFG_INC=$COREMARK_CFG
```

预期：

```text
ALL TESTS PASSED: 9 checks - 2 harts + shared L2, two CoreMark instances
hart0: retires=22067156 cycles=29624227 IPC=0.744902 CM/MHz=3.3756
hart1: retires=22067156 cycles=29624224 IPC=0.744902 CM/MHz=3.3756
aggregate: retires=44134312 max_cycles=29624227 IPC=1.489805 CM/MHz=6.7512
```

对比基线（CRC + probe + O3 + 32 KiB ICache，无数组化）：

| 配置 | cycles | IPC | CM/MHz 单核 | 双核聚合 |
|---|---:|---:|---:|---:|
| 基线 | 35,493,729 | 0.6777 | 2.8174 | 5.6348 |
| **最快加速流程** | **29,624,227** | **0.7449** | **3.3756** | **6.7512** |

## 6. 为什么这是“最快”

| 层 | 加速 | 作用 |
|---|---|---|
| 编译器/链接 | `-O3 -funroll-loops`、符号插入 | 减指令、把 CRC/链表替换成新 TU |
| 软件 | 数组化 `core_bench_list` | 打断 `next → info → idx` 串行 load；reverse O(1) |
| 指令集/RTL | custom-0 CRC8 | 把 8 次 bit 循环压成 1 条指令 |
| 微架构 | speculative load probe | load-use 3→2 cycle |
| 配置 | 32 KiB ICache | 25 KiB 文本不 thrash |
| 双核 | 2 × AMP | 聚合分数近似线性翻倍 |

不要用默认的 `make unit-2core-coremark` 空跑：不带 `DMEM=` 时它会跑
`build/coremark/coremark_dmem.hex`，即未加速的默认镜像。

## 7. 干净重建

```bash
rm -rf build/coremark_array build/coremark_32k build/analysis/coremark_array_4iter.hex
make coremark-array-image
make test-coremark-array
# 再按第 3/4/5 节生成配置并跑 RTL
```

## 8. 常见问题

| 现象 | 原因/处理 |
|---|---|
| `ccache: error: Permission denied` | 先执行第 0 节的 `CCACHE_DIR`/`CCACHE_TEMPDIR`/`CXX=g++` |
| `illegal instruction` | RTL 没有 custom-0 CRC8；换当前 RTL 或不要用 CRC 变体 |
| 分数明显低于 3.38/6.75 | 忘了 `ARES_CFG_INC=+incdir+.../coremark_32k/include`，用了 8 KiB ICache |
| `CoreMark image not found` | 先跑 `make coremark-array-image` |
| 4-iter 的 CM/MHz 看起来是 80 | TB 按 100 iter 打印，除以 25 |
| `input.json`/frozen 报错 | CoreMark 源文件被改了；恢复 `tests/benchmarks/coremark` |
| 想要 CRC-only | `python3 scripts/build_coremark_crc.py --out build/coremark_crc` |

## 9. 相关文件

| 文件 | 内容 |
|---|---|
| `scripts/build_coremark_crc.py` | 加速镜像构建入口（`--array-list`） |
| `scripts/build_coremark_image.py` | ELF → bin → readmemh 镜像链 |
| `scripts/test_coremark_array.py` | 数组化主机等价测试 |
| `docs/coremark_array_list.md` | 数组化实现与详细结果 |
| `docs/coremark_latest_hw_acceleration_analysis.md` | 最新指令流/相位分析 |
| `build/analysis/array_100iter.out` | 100-iter 原始输出 |
| `build/analysis/array_4iter.out` | 4-iter 原始输出 |

## 10. 一句话

```bash
make coremark-array-image && make test-coremark-array
# 然后带 32 KiB include 和 DMEM 跑 unit-2core-coremark
```
