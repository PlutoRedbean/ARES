# ARES 状态机 token scanner（CoreMark core_bench_state）

> 状态：RTL 扫描器 + 单元测试 + 双核 CoreMark 集成已实现；4/100-iteration
> 全加速变体（array + matrix + state）通过 9 checks + L2 shadow。
> 100-iteration：14,263,577 cycles / 7.0109 单核 / 14.0217 双核聚合（2.488x）。
> 约束：tests/benchmarks/coremark/src/*.c 不修改；软件替换通过新增 TU 和
> 链接层符号重命名完成。

## 1. 做什么

CoreMark 的 core_bench_state() 每 iteration 4 次，每次：

1. 对 666 B 块扫描一遍：反复调用 core_state_transition()，直到 NUL；
2. 以 step 为间隔，对非 ',' 字节 XOR (ee_u8)seed1；
3. 再扫描一遍；
4. 以 step 为间隔 XOR (ee_u8)seed2（CoreMark 中 seed1==seed2，复原）；
5. 对 final_counts[0..7] / track_counts[0..7] 做 16 次 crcu32。

core_bench_state() 在 seed1==seed2 时是纯函数：块被复原，调用方只使用返回
CRC。引擎因此保留一份 1 KiB 私有拷贝，不回写核心内存。

## 2. RTL

文件：rtl/accel/state9_engine.sv

- 8 状态 DFA：START、INVALID、S1、S2、INT、FLOAT、EXPONENT、SCIENTIFIC；
- 每字节 1 cycle；精确复现 core_state_transition() 的：
  - 逗号提前结束、指针后移；
  - invalid 字符后指针 +1、状态 INVALID、track/final 计数；
  - START/S1/S2/EXPONENT 的 track 计数规则；
  - INT/FLOAT/SCIENTIFIC 只在特定字符上增加 track；
- corruption/undo 每 cycle 处理一个 step 字节，跳过 ','；
- CRC 单元按 final[0], track[0], final[1], track[1], ... 的顺序，
  每个 u32 低字节到高字节做 crcu32；
- 扫描在 p >= blksize 时把当前 token 视为遇到 NUL 并收尾（CoreMark 状态块
  之后是 0，和原函数读到的内存一致）。

### 2.1 MMIO 地址窗口

窗口 4 KiB，默认 0xA000_2000：

| 偏移 | 内容 |
|---|---|
| 0x000..0x3FF | data[0..1023]，32-bit word store 写 4 字节 |
| 0x700 | CTRL：bit0 = start |
| 0x704 | BLKSIZE（<=1024） |
| 0x708 | SEED1（s16） |
| 0x70C | SEED2（s16） |
| 0x710 | STEP（s16，1..255） |
| 0x714 | CRC_IN（u16） |
| 0x718 | STATUS：bit0 busy，bit1 done |
| 0x71C | CRC_OUT（u16） |
| 0x720..0x73C | FINAL0..7（u32，调试） |
| 0x740..0x75C | TRACK0..7（u32，调试） |

## 3. 软件接入

scripts/build_coremark_crc.py --state-engine：

1. 复制 EEMBC 源到 build/.../src_port；
2. 写入 src/state_hw.c；
3. 只对 core_state.o 加 -Dcore_bench_state=core_bench_state_orig；
4. core_list_join.c 的 calc_func 继续调用 canonical core_bench_state，
   链接到 state_hw.c。

state_hw.c：

- 对 blksize <= 1024、blksize != 0、step > 0、seed1 == seed2：
  把 blksize 字节打包成 32-bit word 写入引擎，写参数，START，轮询 done，
  读 CRC_OUT；
- 其它情况回退 core_bench_state_orig()；
- 不回写 memblock（seed1==seed2 时原函数也会复原）。

## 4. 双核集成

rtl/top/ares_2core_frontend_l2_top.sv 为每个 hart 例化：

- mtx9_engine 在 0xA000_1000（矩阵）；
- state9_engine 在 0xA000_2000（状态机）；
- 非加速器 MMIO 地址返回 1-cycle 0 响应；
- 两个 hart 使用同一组虚拟地址，但各自有私有引擎实例，互不串扰。

rtl/top/ares_frontend_l2_top.sv（单核）也例化两个引擎。

## 5. 验证

### 5.1 单元测试

    make lint-state9
    make unit-state9

tb_state9_engine 用 bit-exact SV 模型对比 CRC、FINAL0..7、TRACK0..7 和
corruption/undo 后的 666 B 数据；12 组随机块 + 4 组 directed（全 token
路径、首尾逗号、提前 NUL、step=1/0x22/0xff），共 10928 checks。

### 5.2 双核 CoreMark

全加速镜像（CRC + array list + matrix engine + state scanner）：

    make coremark-full-image

4-iteration：

    ALL TESTS PASSED: 9 checks - 2 harts + shared L2
    hart0: retires=332597 cycles=615472 IPC=0.540393 CM/MHz=162.4769
    hart1: retires=332597 cycles=615469 IPC=0.540396 CM/MHz=162.4777
    aggregate: retires=665194 max_cycles=615472 IPC=1.080787 CM/MHz=324.9539
    L2 shadow check: rsp=3104 err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0

TB 的 CM/MHz 按 100 iteration 打印；4-iter 除以 25：
6.499 / 12.998 CM/MHz。

## 6. 结果

### 6.1 4-iteration

| 配置 | cycles | retires/hart | IPC | 4-iter CM/MHz 单核 | 双核聚合 | 相对基线 |
|---|---:|---:|---:|---:|---:|---:|
| CRC + probe + O3 + 32K（基线） | 1,463,597 | 973,650 | 0.6652 | 2.733 | 5.466 | 1.000x |
| + matrix engine + array list | 947,551 | 598,475 | 0.6316 | 4.221 | 8.443 | 1.545x |
| **+ state scanner（全加速）** | **615,472** | **332,597** | **0.5404** | **6.499** | **12.998** | **2.378x** |

### 6.2 100-iteration

| 配置 | cycles | retires/hart | IPC | CM/MHz 单核 | 双核聚合 | 相对基线 |
|---|---:|---:|---:|---:|---:|---:|
| CRC + probe + O3 + 32K（基线） | 35,493,729 | 24,055,220 | 0.6777 | 2.8174 | 5.6348 | 1.000x |
| + array list | 29,624,227 | 22,067,156 | 0.7449 | 3.3756 | 6.7512 | 1.198x |
| + matrix engine | 22,475,821 | 14,660,672 | 0.6523 | 4.4492 | 8.8985 | 1.579x |
| **+ state scanner（全加速）** | **14,263,577** | **8,014,097** | **0.5619** | **7.0109** | **14.0217** | **2.488x** |

原始输出：build/analysis/full_100iter.out。9 checks + L2 shadow 全过
（rsp=10784，err_i0/i1/c0/c1/wb=0）。

## 7. 限制与后续

- 只支持 blksize <= 1024、step > 0、seed1 == seed2；其它情况回退原函数。
- 扫描在 blksize 边界把当前 token 收尾；CoreMark 状态块之后的字节为 0，
  与原函数读到的内存一致。如果未来把引擎用于非 CoreMark 数据、且块后
  存在非零字节，需要扩展为“拷贝块 + 一个 NUL 哨兵”的语义。
- 数据拷贝 666 B 约 167 个 word store/次，4 次/iteration；相对原状态机
  80k+ cycle 可忽略。
- CRC 目前字节串行 64 cycle/次，可进一步流水化，但已不是瓶颈。
- 该变体属于 accelerated variant，不能与官方 EEMBC 分数直接比较。
