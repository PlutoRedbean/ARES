# CoreMark provenance, frozen parameters and trademark boundary

## Source

The files under `src/` and `include/` are the EEMBC CoreMark 1.0
benchmark sources, imported from the local AbstractMachine benchmark collection
(`am-kernels/benchmarks/coremark`, itself a copy of the EEMBC release), with
the ARES port and an adapted reporting section in core_main.c.  They are vendored into the repository
so the L2 acceptance flow no longer depends on an external benchmark path.

License: see `LICENSE.md` (CoreMark Acceptable Use Agreement and Apache
License 2.0, as published by EEMBC).

## Algorithm provenance and adapted reporting

The list, matrix, state and CRC algorithms and coremark.h retain the imported
bytes. core_main.c retains its benchmark loop and CRC comparisons; its reporting
section now prints actual iteration counts and 100 MHz RTL-cycle measurements
over the RTL UART. Current SHA-256 values:

| file | SHA-256 |
| --- | --- |
| src/core_list_join.c | eced69a19afd3c2f27e690027f5690e7b3c9269cd176196887e82d875b512ea0 |
| src/core_main.c | 0f68c1745f64abc7b12b58c85bad03352daec8159ad08255040cbb34ddde049e |
| src/core_matrix.c | 856502b101bd1e49b5c7edc5c20d455baef96eb0d6e6b88fdf3e88a6b15afc04 |
| src/core_state.c | 9badd1f82f1f6efc8f4e1a65e35b06629a85b6da9b0d48029eea300be500a6d9 |
| src/core_util.c | fdc4e19efd1edff03d919065c2295e30c2eaeada2661f52c847fee56ae534516 |
| include/coremark.h | fa3fbf1b751862683cb436e0c7878c75b1309ee3f93cb6ff7d7f550429b3ff68 |

## ARES port layer

| file | SHA-256 | change |
| --- | --- | --- |
| src/core_portme.c | ff72a0bc6632c590fc4b8b858964e73ad1ed3447f2c707a53b7d905bb6357d79 | 64-bit RTL cycle reads, timing fences, fixed-point report; no host timer |
| include/core_portme.h | 7707ec6102eb54838e58d1d5ff4a378dcf913e922ec3a6c83d80555220b68d74 | 32-bit algorithm types, 64-bit ticks, `MEM_STATIC`, `SEED_VOLATILE`, UART printf, 100 MHz |

The reporting changes remove the inherited relative-i7 Marks conversion and
the disabled/fake timer. Program scores use only the measured iterate() interval;
UART startup/output and EBREAK are outside that interval. core_main.c is
explicitly adapted and is not claimed to be byte-identical to upstream EEMBC.

## Frozen parameters (enforced by `scripts/build_coremark_image.py`)

| parameter | value | where |
| --- | --- | --- |
| ITERATIONS | 100 | include/core_portme.h |
| Clock / timing | 100 MHz, 64-bit RTL cycle counter | core_portme.h / core_portme.c |
| Console | printf enabled, RTL UART 115200 8N1 | core_portme.h / ares_benchmark_io.sv |
| TOTAL_DATA_SIZE | 2000 | include/coremark.h |
| run type | PERFORMANCE_RUN (TOTAL_DATA_SIZE == 2000) | include/core_portme.h |
| performance seeds | 0 / 0 / 0x66 | src/core_portme.c |
| MEM_METHOD | MEM_STATIC | include/core_portme.h |
| MULTITHREAD | 1 (one instance per hart; never EEMBC MULTITHREAD=2) | include/core_portme.h |
| ISA / ABI | RV32IM_Zicsr / ilp32, `-march=rv32im_zicsr -mabi=ilp32` | scripts/riscv32-ares.mk |

The driver rejects a port whose frozen parameters drifted, so a result can no
longer be produced with an unrecorded iteration count, seed set or data size.

Results measured here are simulation regression statistics of this repository's
RTL.  They are not EEMBC-certified CoreMark scores and must not be published as
such; the CoreMark trademark is used only to identify the benchmark program.
Custom-CRC or RTOS-accelerated variants are out of scope and must never be
compared with these numbers.
