# CoreMark `core_bench_list` 软件数组化（链接层替换）

> 状态：已实现；主机等价 200/200，4-iteration 与 100-iteration RTL CoreMark 均通过 9 checks + L2 shadow。
> 约束：只改构建脚本/新增 TU；`tests/benchmarks/coremark/src/*.c` 一个字节不改。

## 1. 做什么

原始的 `core_bench_list` 对 30 个节点做 102 次 `core_list_find`，每次 find 是
`next → info → idx` 的三级串行 load；每次 find 后还对整条链表做一次
`core_list_reverse`，每节点一次 `next` 写。100 次 iteration 中，find+reverse
占 26.0% 动态指令、约 75% 的链表周期。

这个变体在**链接层**把 `core_bench_list` 换成一个数组影子实现：

- 进入时（或 `core_results`/head 变化时）把链表展开成
  `{node, info}` 数组，按当前顺序保存；
- find 在 `info` 数组上顺序扫描（4-way 展开），每条节点只有一次独立 load；
- reverse 只翻转一个 `dir` 位（O(1)），不再每次写 30 个 `next`；
- move-to-front/remove/undo 用数组索引移动；
- 两次 mergesort 逐句照搬原来的 bottom-up 链表归并算法，只是用数组下标代替
  `next`，因此 `cmp()` 的调用顺序与 `calc_func` 的缓存/CRC 副作用完全一致；
- find 循环结束后把逻辑方向归一化，再做 remove/CRC/按 idx 排序；
- 函数返回前把数组顺序写回 `next`，链表始终保持合法，外部代码无感。

## 2. 构建（不改 CoreMark 源文件）

```bash
make coremark-array-image
# 等价于：
python3 scripts/build_coremark_crc.py --array-list --out build/coremark_array --jobs 4
```

构建脚本只做三件事：

1. 把 `tests/benchmarks/coremark` 复制到 `build/coremark_array/src_port`；
2. 写入 `src/crc_hw.c`（CRC8 指令）和 `src/core_list_array.c`（本变体）；
3. 在复制出来的 Makefile 末尾加 target-specific 标志：

```make
$(DST_DIR)/src/core_util.o: CFLAGS += -Dcrcu8=crcu8_orig ...
$(DST_DIR)/src/core_list_join.o: CFLAGS += -Dcore_bench_list=core_bench_list_orig
CFLAGS += -O3 -funroll-loops
```

`core_list_join.c` 里的 `core_bench_list` 只被重命名为
`core_bench_list_orig`，文件内容不变；`core_main.c` 的调用方仍调用
`core_bench_list`，链接器解析到新 TU。

## 3. 正确性验证

### 3.1 主机等价测试（推荐先跑）

```bash
make test-coremark-array
# 或 python3 scripts/test_coremark_array.py
```

测试把原始 `core_bench_list` 与数组版编译进同一个 x86 可执行文件，用相同的
2000 B 工作集、seed1=seed2=0x3415、seed3=0x66、每算法 666 B，跑完整的
100 iteration × 2 次调用，每次比较：

- 返回值；
- 链表遍历的 `(idx, data16)` 序列 hash；
- 矩阵/state 区域的字节 hash；
- `res->crc / crclist / crcmatrix / crcstate`。

当前结果：

```
ALL 200 CALLS MATCH
```

### 3.2 RTL

4-iteration 数组镜像（CRC + O3 + 32 KiB ICache）在 `tb_phase`/双核 TB 上：

```
L2 shadow check: rsp=4820 err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0
ALL TESTS PASSED: 9 checks - 2 harts + shared L2, two CoreMark instances
```

100-iteration（`build/analysis/array_100iter.out`）同样通过 9 checks + L2 shadow
（rsp=38,844，err_i0/i1/c0/c1/wb=0），最终分数见 4.2：
**3.3756 CM/MHz 单核 / 6.7512 双核聚合，相对基线 1.198×**。

## 4. 性能

### 4.1 4-iteration（同一 RTL/ICache 配置）

| 配置 | cycles | retires/hart | IPC | 4-iter CM/MHz 单核 | 双核聚合 | 相对基线 |
|---|---:|---:|---:|---:|---:|---:|
| CRC + probe + O3 + 32 KiB ICache（基线） | 1,463,597 | 973,650 | 0.6652 | 2.733 | 5.466 | 1.000× |
| **+ 数组化 `core_bench_list`** | **1,237,385** | **894,812** | **0.7231** | **3.233** | **6.465** | **1.183×** |

### 4.2 100-iteration（最终）

| 配置 | cycles | retires/hart | IPC | CM/MHz 单核 | 双核聚合 | 相对基线 |
|---|---:|---:|---:|---:|---:|---:|
| CRC + probe + O3 + 32 KiB ICache（基线） | 35,493,729 | 24,055,220 | 0.6777 | 2.8174 | 5.6348 | 1.000× |
| **+ 数组化 `core_bench_list`** | **29,624,227** | **22,067,156** | **0.7449** | **3.3756** | **6.7512** | **1.198×** |

100-iter 的相位/停顿时钟：

| 指标 | 基线 | 数组化 |
|---|---:|---:|
| no-issue | 62.2% | 58.7% |
| dep_load（占总周期） | 16,212,653（45.7%） | 10,935,027（36.9%） |
| dep_alu | 4,719,575（13.3%） | 4,714,960（15.9%） |
| LSU credit/port | 732,727（2.1%） | 1,095,869（3.7%） |
| ICache refill | 410 | 9,543 |
| L2 hits/misses | 1,723 / 325 | 38,323 / 521 |

数组化把 load 依赖砍掉 **32.6%**，但数组移动/物化增加了 store/LSU 压力和代码体积；
100-iter 的 ICache refill 从 410 涨到 9,543（仍是总周期的 0.03% 量级，但说明
25 KiB 代码在 32 KiB 4-way ICache 上已有冲突）。下一步若继续抠，优先做
**索引直接映射（idx→node）** 和 **64 KiB ICache/代码布局**，而不是再加数组操作。

### 4.3 相位变化（4-iteration，按 no-issue + issue 总周期）

| 相位 | 基线 cycles | 数组化 cycles | 变化 |
|---|---:|---:|---:|
| list（find + reverse + sort/flags） | 652,341（44.6%） | 410,712（33.2%） | **1.59× 更快** |
| matrix | 294,213 | 294,399 | ~0 |
| state | 352,239 | 352,021 | ~0 |
| bench_state | 70,046 | 69,768 | ~0 |
| crc | 16,798 | 14,944 | ~0 |
| other | 77,960 | 95,541 | +17.6k |
| **total** | **1,463,597** | **1,237,385** | **1.183×** |

链表相位的 `dep_load` 从 426,522 降到 217,296（-49%）；全核 no-issue 从
62.7% 降到 59.6%。

### 4.4 指令数（100 iterations，ISS）

| 配置 | 总指令 | list 组 | list 占比 | 相对基线 |
|---|---:|---:|---:|---:|
| CRC + O3（基线） | 24,055,220 | 7,632,439 | 31.7% | 1.000× |
| **数组化** | **22,067,156** | **5,643,826** | **25.6%** | **-8.3%** |

链表组本身减少 **26.1%** 指令；总指令减少 8.3%，但周期减少 18.3%，因为
find 的串行 load 链被打断，IPC 从 0.665 升到 0.723。

## 5. 限制与注意事项

- **单 context 假设**：数组缓存是文件级 static，按 `res` 和 `res->list`
  失效。当前 CoreMark 是 `MULTITHREAD=1`，每个 hart 独立地址空间，满足；
  如果未来做同地址空间多 context，需要把数组放进 `core_results` 或按 context
  分槽。
- **节点数上限** `ARES_LIST_MAX=128`；当前 list 31 个节点。超过上限会回退到
  `core_bench_list_orig`（该符号被刻意保留）。
- 数组化只改 `core_bench_list` 的**数据组织**，不改变 CoreMark 的种子、数据
  大小、迭代次数或 CRC 校验；输出与原始实现逐 call 一致。
- 代码从 16,980 B 增到约 25.3 KiB（仍 < 32 KiB ICache）；100-iter 的
  `icache_refill` 从 410 增到 9,543，说明 25 KiB 代码在 256-set 4-way ICache 上
  已出现冲突。仍建议保留 32 KiB ICache；若继续优化，64 KiB 或代码布局比
  再加数组操作更值得。
- 该变体与 CRC 变体一样属于 **accelerated variant**，不能与官方 EEMBC 分数
  直接比较（见 `tests/benchmarks/coremark/NOTICE.md`）。

## 6. 相关文件

| 文件 | 内容 |
|---|---|
| `scripts/build_coremark_crc.py` | `--array-list` 构建入口；内嵌 `core_list_array.c` |
| `scripts/test_coremark_array.py` | 主机等价测试 |
| `Makefile` | `coremark-array-image`、`test-coremark-array` |
| `build/coremark_array/` | 生成镜像（ELF/bin/dmem hex/inputs.json） |
| `build/analysis/array_4iter.out` | 4-iter RTL 结果 |
| `build/analysis/array_100iter.out` | 100-iter RTL 结果 |
| `build/analysis/array_phase_4iter.out` | 数组版相位归因 |
| `build/analysis/iss_array.out` | 数组版 ISS 指令流 |
