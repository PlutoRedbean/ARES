# Pinned EEMBC CoreMark integration and acceleration results

## Source identity

The default BSP build uses the unmodified EEMBC CoreMark snapshot under
`eembc/`, pinned to commit
`1f483d5b8316753a742cbf5590caf5bd0a4e4777` (2025-05-01).  The exact file
hashes and the upstream `coremark.h` MD5 caveat are recorded in
`eembc/UPSTREAM_VERSION.md`.

The port, RT-Thread command, build-time instruction wrappers, and generated
files live outside the vendored source.  `scripts/generate_matrix_accel.py` reads the official
`core_matrix.c` and creates `cm_core_matrix_mulbe.c` only in the build object
directory; it never writes back to `eembc/`.

## Final A/B result

Both measurements used GCC 15.2.0, `COREMARK_ITERATIONS=100`, a 300 MHz
cycle-accurate Verilator model, `JYD_FAST_TIMER=0`, the same official sources,
the same performance seeds, and the same final RT-Thread configuration.

| Build | CoreMark ticks | Simulator cycles | Guest instructions | IPC | Iterations/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Reference: screenshot-style `-O2`, software CRC/matrix | 17,878,826 | 17,928,072 | 24,794,612 | 1.383005 | 1,677.962524 |
| Retained default: `-O3`/LTO plus CRC16 and MULBE | 16,565,566 | 16,611,532 | 22,452,660 | 1.351631 | 1,810.985511 |

The retained default reduces measured CoreMark ticks by 1,313,260 (7.3453%)
and guest instructions by 2,341,952 (9.4454%).  Iterations/s rises by 7.9276%.
IPC alone is lower and is therefore not the score: the accelerated build
finishes with fewer instructions and fewer total cycles.

Both runs produced the competition screenshot's validation values:

```text
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x988c
CoreMark finished with result 0
HIT GOOD TRAP
```

The 100-iteration simulation deliberately runs for less than CoreMark's
required 10 seconds, so upstream prints `ERROR! Must execute for at least 10
secs` and `Errors detected` even though all CRCs match.  This is a short
performance regression, not a reportable CoreMark score.  At 300 MHz the
formal run should use at least about 18,100 iterations; use 20,000 for margin.

## Reproduction

The retained default is simply:

```sh
JYD_CONSOLE_CMDS='coremark;quit' make run COREMARK_ITERATIONS=100
```

The reference build uses a separate directory so it cannot contaminate the
retained default:

```sh
JYD_CONSOLE_CMDS='coremark;quit' make run \
  BUILD_DIR=/tmp/mundus-eembc-ref \
  COREMARK_HW_CRC=0 COREMARK_HW_MATRIX=0 \
  COREMARK_MATRIX_LINK_BOUNDARY=0 \
  LTO_FLAGS= COREMARK_REPORT_MODE=0 COREMARK_ITERATIONS=100 \
  COREMARK_MATRIX_EXTRA_CFLAGS= \
  COREMARK_OPT_FLAGS='-O2 -funroll-loops -finline-functions --param=max-inline-insns-auto=300 -falign-functions=4 -falign-jumps=4 -falign-loops=4 -specs=nano.specs'
```

For a formal-duration run on the 300 MHz target:

```sh
JYD_CONSOLE_CMDS='coremark;quit' make run COREMARK_ITERATIONS=20000
```

The generated RTL still needs FPGA synthesis and post-route timing analysis;
cycle-accurate simulation validates behavior and architectural cycle counts,
not physical 300 MHz timing closure.
