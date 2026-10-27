# CoreMark provenance, frozen parameters and trademark boundary

## Source

The files under `src/` and `include/` are the EEMBC CoreMark 1.0
benchmark sources, imported from the local AbstractMachine benchmark collection
(`am-kernels/benchmarks/coremark`, itself a copy of the EEMBC release), with
only the porting layer adapted for ARES.  They are vendored into the repository
so the L2 acceptance flow no longer depends on an external benchmark path.

License: see `LICENSE.md` (CoreMark Acceptable Use Agreement and Apache
License 2.0, as published by EEMBC).

## Unmodified benchmark core

The benchmark proper is these six files.  Their SHA-256 values match the
artefacts recorded in `docs/l2_integration_results.md` and the previous
`build/verification/l2-integration/inputs.json`, byte for byte:

| file | SHA-256 |
| --- | --- |
| src/core_list_join.c | eced69a19afd3c2f27e690027f5690e7b3c9269cd176196887e82d875b512ea0 |
| src/core_main.c | 56dd2c1fb9c3722215f1d0d87df082156755434ff1b1c65cecf262e2b660848c |
| src/core_matrix.c | 856502b101bd1e49b5c7edc5c20d455baef96eb0d6e6b88fdf3e88a6b15afc04 |
| src/core_state.c | 9badd1f82f1f6efc8f4e1a65e35b06629a85b6da9b0d48029eea300be500a6d9 |
| src/core_util.c | fdc4e19efd1edff03d919065c2295e30c2eaeada2661f52c847fee56ae534516 |
| include/coremark.h | fa3fbf1b751862683cb436e0c7878c75b1309ee3f93cb6ff7d7f550429b3ff68 |

## ARES port layer (the only modifications)

| file | SHA-256 | change |
| --- | --- | --- |
| src/core_portme.c | ad20c52270a86726e5f425c08a70b143115910caaa342a94b40a1d03c9988055 | AbstractMachine entry (`_trm_init`, `io_read(AM_TIMER_UPTIME)`), no host stdio/timer |
| include/core_portme.h | 9f57f84dcdc00ad61722fdf79cac6c5f6e25259be9c4fbda1208d305adfb1cdc | 32-bit types, `MEM_STATIC`, `SEED_VOLATILE`, no float/stdio |

This is the intended porting surface documented by EEMBC ("adjust
core_portme.h and possibly core_portme.c").  The benchmark core is untouched.

## Frozen parameters (enforced by `scripts/build_coremark_image.py`)

| parameter | value | where |
| --- | --- | --- |
| ITERATIONS | 100 | include/core_portme.h |
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
