# ARES 9-PE INT16 矩阵引擎（CoreMark matrix_test）

> 状态：RTL 引擎 + 单元测试 + 双核 CoreMark 集成已实现；4-iteration 双核
> CoreMark 通过 9 checks + L2 shadow。100-iteration 双核聚合
> 4.4492 / 8.8985 CM/MHz（相对原基线 1.579x）。
> 约束：tests/benchmarks/coremark/src/*.c 不修改；软件替换通过新增 TU 和
> 链接层符号重命名完成。

## 1. 做什么

CoreMark 的 matrix_test(9, C, A, B, val) 被 core_bench_matrix() 调用，
每 iteration 4 次。原实现约 19,214 条指令 / 18.4k cycle 每次调用，包含：

1. matrix_add_const(A, val)
2. C = A * val -> matrix_sum -> crc16
3. C[0..8] = A * B[0..8] -> matrix_sum（C[9..80] 保留上一步的值）
4. C = A * B -> matrix_sum -> crc16
5. C = bitextract(A * B) -> matrix_sum -> crc16
6. matrix_add_const(A, -val) 复原

matrix_test 是纯函数：A 复原、B 不变、C 不被调用方使用。因此引擎只需要
A/B 拷入、返回 CRC，不需要拷回数据，也不需要 cache maintenance。

## 2. RTL

文件：rtl/accel/mtx9_engine.sv

- 9 个 INT16 PE（16x16 -> 32 MAC），每个 PE 负责一个输出列 j；
- B 的 9x9 列缓存在 81 个 16-bit 寄存器中，matmul 每行 9 MAC cycle；
- 一个共享乘法器做 mul_const / mul_vect；
- 串行 matrix_sum 单元（C 的 recurrence 本身串行），精确实现 s16 ret
  回绕、clipval = 0xf000 | val、tmp > clipval 的语义；
- bit_extract 使用与 C 宏完全相同的 >>> from & mask；
- CRC16 使用 crcu16 的低字节->高字节顺序；
- A 在引擎本地 SRAM 中加/减 val，最后复原。

### 2.1 MMIO 地址窗口

窗口 4 KiB，默认 0xA000_1000：

| 偏移 | 内容 |
|---|---|
| 0x000..0x143 | A[0..80]，每个 32-bit word 放一个 s16 |
| 0x200..0x343 | B[0..80]，每个 32-bit word 放一个 s16 |
| 0x400..0x543 | C[0..80]，s32（调试/读回） |
| 0x700 | CTRL：bit0 = start |
| 0x704 | N（必须 9；软件对其它 N 回退） |
| 0x708 | VAL（s16） |
| 0x70C | STATUS：bit0 = busy，bit1 = done |
| 0x710 | CRC（matrix_test 返回值，s16） |
| 0x720..0x72C | SUM0..3（调试） |

时序：host 写/读在时钟沿接受，host_rsp_valid 下一 cycle 返回；引擎忙时
仍可读 STATUS/CRC。软件在 START 后轮询 done bit。

## 3. 软件接入

scripts/build_coremark_crc.py --matrix-engine 会：

1. 复制 EEMBC 源到 build/.../src_port；
2. 写入 src/matrix_hw.c；
3. 只对 core_matrix.o 加 -Dcore_bench_matrix=core_bench_matrix_orig；
4. 让 core_list_join.c 的 calc_func 继续调用 canonical core_bench_matrix，
   链接到 matrix_hw.c。

matrix_hw.c 的行为：

- 对 p->N == 9：把 A/B 各 81 个 s16 写入引擎窗口，写 N/VAL/START，
  轮询 done，读 CRC，返回 crc16((ee_s16)ret, crc)；
- 对其它 N：调用 core_bench_matrix_orig() 回退；
- 不修改 CoreMark 源文件；A/B 在 CoreMark 内存中保持原值（原函数最终也会
  复原 A、B 不变）。

## 4. 双核集成

rtl/top/ares_2core_frontend_l2_top.sv 为每个 hart 例化一个 mtx9_engine：

- 两个引擎使用同一虚拟地址 0xA000_1000，但分别接 hart0/hart1 的 MMIO
  通道，因此不需要地址偏移，也不会串扰；
- 非引擎 MMIO 地址仍返回 1-cycle 0 响应（保留原 stub 行为）；
- 每个引擎有独立 SRAM/状态；两 hart 同时发命令时并行执行，不互相串行化。

rtl/top/ares_frontend_hart.sv 现在暴露真实 MMIO 端口，不再内部 tie-off。

## 5. 验证

### 5.1 引擎单元测试

    make lint-mtx9
    make unit-mtx9

tb_mtx9_engine 用 bit-exact SV 模型对比 CRC / C[0..80] / SUM0..3 /
复原后的 A；16 组随机 + 5 组 directed（0、0x7fff/0x8000、bitextract 边界、
与主机 C 参考一致的确定性向量），共 3507 checks。

### 5.2 双核 CoreMark

4-iteration（CRC + matrix engine，32 KiB ICache）：

    make coremark-matrix-image
    python3 - <<'EOF'
    from pathlib import Path
    src = Path('build/coremark_matrix/coremark_dmem.hex').read_text().splitlines()
    hits = [i for i, line in enumerate(src) if line.endswith('00000066'+'00000064')]
    assert len(hits) == 1
    src[hits[0]] = src[hits[0]][:-8] + '00000004'
    Path('build/analysis/coremark_matrix_4iter.hex').write_text('\n'.join(src)+'\n')
    EOF
    make unit-2core-coremark DMEM=$PWD/build/analysis/coremark_matrix_4iter.hex \
         ARES_CFG_INC=+incdir+$PWD/build/coremark_32k/include

结果：

    ALL TESTS PASSED: 9 checks - 2 harts + shared L2
    hart0: retires=677325 cycles=1182272 IPC=0.572901 CM/MHz=84.5829
    hart1: retires=677325 cycles=1182170 IPC=0.572951 CM/MHz=84.5902
    aggregate: retires=1354650 max_cycles=1182272 IPC=1.145802 CM/MHz=169.1658
    L2: hits=1256 misses=248

TB 的 CM/MHz 按 100 iteration 打印；4-iter 值除以 25：
3.383 / 6.767 CM/MHz。对比 CRC+probe 4-iter 基线 1,463,597 cycle
（2.733 / 5.466），1.238x。

## 6. 结果

### 6.1 4-iteration

| 配置 | cycles | retires/hart | IPC | 4-iter CM/MHz 单核 | 双核聚合 | 相对基线 |
|---|---:|---:|---:|---:|---:|---:|
| CRC + probe + O3 + 32K（基线） | 1,463,597 | 973,650 | 0.6652 | 2.733 | 5.466 | 1.000x |
| + matrix engine | 1,182,272 | 677,325 | 0.5729 | 3.383 | 6.767 | 1.238x |
| + matrix engine + array list | 947,551 | 598,475 | 0.6316 | 4.221 | 8.443 | 1.545x |

矩阵引擎单独去掉约 20.7% 的相位周期；与数组化链表叠加后，4-iter 达到
1.545x（相对 CRC 基线）。

### 6.2 100-iteration

| 配置 | cycles | retires/hart | IPC | CM/MHz 单核 | 双核聚合 | 相对基线 |
|---|---:|---:|---:|---:|---:|---:|
| CRC + probe + O3 + 32K（基线） | 35,493,729 | 24,055,220 | 0.6777 | 2.8174 | 5.6348 | 1.000x |
| + array list | 29,624,227 | 22,067,156 | 0.7449 | 3.3756 | 6.7512 | 1.198x |
| **+ matrix engine + array list** | **22,475,821** | **14,660,672** | **0.6523** | **4.4492** | **8.8985** | **1.579x** |

原始输出：build/analysis/matrix_array_100iter.out。9 checks + L2 shadow
全过（rsp=9332，err_i0/i1/c0/c1/wb=0）。

矩阵引擎单独（未加数组化）4-iter 为 1,182,272 cycle / 3.383 / 6.767
（1.238x）；与数组化链表叠加后 100-iter 达到 4.4492 / 8.8985
（1.579x）。

## 7. 限制与后续

- 引擎只支持 N=9；其它 N 由软件回退到原始 core_bench_matrix_orig。
- 引擎当前通过 MMIO word store 拷贝 A/B；81x2 个 store 约 300 cycle，
  相对 18k cycle 的软件矩阵可忽略。后续可改成 L1D 让渡/DMA，但不影响
  当前正确性。
- matrix_sum 仍是串行 81 cycle/次；若继续优化，可把 sum 与 matmul 的
  行输出流水化，但当前引擎已不是瓶颈。
- 引擎未做时钟门控/独立时钟域；上板 PPA 需在综合后评估。
- 该变体属于 accelerated variant，不能与官方 EEMBC 分数直接比较。
