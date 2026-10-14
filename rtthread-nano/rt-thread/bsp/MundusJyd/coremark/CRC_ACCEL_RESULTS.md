# Mundus CoreMark CRC16 acceleration results

Measured with GCC 15.2.0, `COREMARK_ITERATIONS=100`, a 300 MHz simulated
core, `JYD_FAST_TIMER=0`, and identical performance-run seeds.

## Call-site inline integration

The final build emits the custom CRC instruction directly at every CoreMark
call site.  An A/B run with matrix acceleration and all other build options
held constant produced:

| CRC integration | CoreMark cycles | Simulator cycles | Guest instructions | IPC | Iterations/Sec |
| --- | ---: | ---: | ---: | ---: | ---: |
| Software CRC (`COREMARK_HW_CRC=0`) | 18,755,689 | 18,780,136 | 26,336,226 | 1.402345 | 1,599.514686 |
| Linker wrapper (`jal` + CRC + `ret`) | 16,565,566 | 16,589,488 | 22,426,301 | 1.351838 | 1,810.985511 |
| Call-site inline (final) | 16,542,072 | 16,565,823 | 22,656,735 | 1.367679 | 1,813.557576 |

Call-site inline reduced CoreMark cycles by 23,494 (0.1418%) and simulator
cycles by 23,665 (0.1427%).  It increased the dynamic instruction count by
1.0275% because removing the call boundary changed GCC's LTO layout, but the
higher IPC still produced the lower total cycle count.  The legacy wrapper
implementation and linker flags were therefore removed.

Against the current software fallback, the final inline implementation reduced
CoreMark cycles by 11.8024%, simulator cycles by 11.7907%, and guest
instructions by 13.9712%.

`COREMARK_HW_CRC` is the only CRC selection switch: `1` enables call-site
inline acceleration and `0` selects the official software implementation.

## Original CRC hardware benefit

| Build | CoreMark cycles | Simulator cycles | Guest instructions | IPC | Marks |
| --- | ---: | ---: | ---: | ---: | ---: |
| Default software CRC, full LTO | 22,344,307 | 22,395,941 | 29,955,073 | 1.337522 | 3,947.837838 |
| Software CRC, non-LTO `core_util.c` control | 22,355,087 | 22,406,679 | 29,549,719 | 1.318791 | 3,947.837838 |
| Hardware CRC16 | 20,394,345 | 20,445,741 | 25,640,276 | 1.254064 | 4,296.176471 |

Against the strict non-LTO control, hardware CRC16 reduced CoreMark cycles
by 8.7709% (1.0961x speedup).  Against the original default build, it reduced
cycles by 8.7269% and guest instructions by 14.4042%.  The non-LTO boundary
itself changed simulator cycles by only 0.0479%.

All three runs produced:

```text
seedcrc     = 0xe9f5
crclist     = 0xe714
crcmatrix   = 0x1fd7
crcstate    = 0x8e3a
crcfinal    = 0x988c
CoreMark finished with result 0
HIT GOOD TRAP
```

Reproduce the software and final accelerated runs with:

```sh
JYD_CONSOLE_CMDS='coremark;quit' \
  make run COREMARK_HW_CRC=0 \
  COREMARK_HW_MATRIX=0 COREMARK_MATRIX_LINK_BOUNDARY=0 \
  COREMARK_ITERATIONS=100

JYD_CONSOLE_CMDS='coremark;quit' \
  make run COREMARK_HW_CRC=1 \
  COREMARK_HW_MATRIX=0 COREMARK_MATRIX_LINK_BOUNDARY=0 \
  COREMARK_ITERATIONS=100
```

Run the standalone instruction and model regression with:

```sh
CCACHE_DISABLE=1 make -C ../../../../npc/tests/crc16 run
```

The performance result is cycle-accurate simulation data.  FPGA timing and
area have not yet been measured; the parity network must still pass the final
implementation timing constraint before using the same 300 MHz frequency on
hardware.
