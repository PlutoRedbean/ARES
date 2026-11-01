#!/usr/bin/env python3
"""Build accelerated CoreMark images without touching the EEMBC sources.

Four build-level accelerations are supported, and can be combined:

  * CRC (always on)     src/crc_hw.c provides crcu8/crcu16/crc16/crcu32 with
                        the ARES custom-0 CRC8 instruction; the reference
                        definitions in core_util.c are renamed to *_orig.
  * --array-list        src/core_list_array.c provides core_bench_list with a
                        software array shadow; the reference definition in
                        core_list_join.c is renamed to core_bench_list_orig.
  * --list-engine       use list9_engine (0xA000_3000) for the 102-iteration
                        find/reverse/move-to-front loop; implies --array-list.
                        The array tail (sort/remove/CRC) stays in software.
                        The linked list is materialised back at the end of
                        every call, so the rest of CoreMark still sees a valid
                        list.
  * --matrix-engine     src/matrix_hw.c provides core_bench_matrix by driving
                        the mtx9_engine MMIO window at 0xA000_1000; the
                        reference definition in core_matrix.c is renamed to
                        core_bench_matrix_orig.  The engine computes the exact
                        matrix_test() result for N=9; other N fall back.
  * --state-engine      src/state_hw.c provides core_bench_state by driving
                        the state9_engine MMIO window at 0xA000_2000; the
                        reference definition in core_state.c is renamed to
                        core_bench_state_orig.  The scanner is exact for
                        blksize<=1024, step>0 and seed1==seed2.

The vendored tests/benchmarks/coremark tree is only staged (copied); every
source file in it stays byte-identical.  All changes are build flags and new
translation units.

Usage:
    python3 scripts/build_coremark_crc.py [--out build/coremark_crc]
    python3 scripts/build_coremark_crc.py --array-list [--out build/coremark_array]
    python3 scripts/build_coremark_crc.py --array-list --matrix-engine \
        --state-engine --mt [--out build/coremark_full_mt]

--mt stages scripts/coremark_mt/ through build_coremark_image.py --mt, so the
accelerated TUs are combined with MEM_STACK / MULTITHREAD=2 / the shared MMIO
mailbox and hart0 prints one aggregate report.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "tests/benchmarks/coremark"

CRC_HW_C = r'''/* ARES custom-0 CRC8 acceleration.
 *
 * This file is not part of the EEMBC CoreMark sources.  It is added by the
 * accelerated build flow and provides the same external symbols as
 * core_util.c.  The reference definitions in core_util.c are renamed to
 * *_orig by a target-specific -D flag, so all CoreMark callers resolve here.
 *
 * Encoding: .insn r 0x0b, 0, 0x00, rd, rs1, rs2
 *   rd  = crc8_step(rs1[7:0], rs2[15:0])
 * The RTL implements the exact bit-serial recurrence of crcu8() in one
 * combinational ALU operation (latency 1).
 */
#include "coremark.h"

static inline ee_u16 crc8_hw(ee_u8 data, ee_u16 crc)
{
    ee_u32 out;
    __asm__ volatile(".insn r 0x0b, 0, 0x00, %0, %1, %2"
                     : "=r"(out)
                     : "r"((ee_u32)data), "r"((ee_u32)crc));
    return (ee_u16)out;
}

ee_u16 crcu8(ee_u8 data, ee_u16 crc)
{
    return crc8_hw(data, crc);
}

ee_u16 crcu16(ee_u16 newval, ee_u16 crc)
{
    crc = crc8_hw((ee_u8)newval, crc);
    return crc8_hw((ee_u8)(newval >> 8), crc);
}

ee_u16 crc16(ee_s16 newval, ee_u16 crc)
{
    return crcu16((ee_u16)newval, crc);
}

ee_u16 crcu32(ee_u32 newval, ee_u16 crc)
{
    crc = crc16((ee_s16)newval, crc);
    crc = crc16((ee_s16)(newval >> 16), crc);
    return crc;
}
'''

ARRAY_LIST_C = (ROOT / "scripts/coremark_array_list.c").read_text()

MATRIX_HW_C = r'''/* ARES 9-PE INT16 matrix engine driver.
 *
 * This file is not part of the EEMBC CoreMark sources.  It is added by the
 * accelerated build flow; core_matrix.c's core_bench_matrix definition is
 * renamed to core_bench_matrix_orig so this definition wins for callers in
 * core_list_join.c.
 *
 * matrix_test() is a pure function: A is restored, B is unchanged, C is not
 * used by the caller.  The engine therefore only needs A/B copied in and the
 * final CRC read back.  Both harts use the same virtual address; the 2-core
 * top gives each hart a private engine instance.
 */
#include "coremark.h"

#define MTX_BASE   0xA0001000u
#define MTX_A      (MTX_BASE + 0x000u)
#define MTX_B      (MTX_BASE + 0x200u)
#define MTX_CTRL   (MTX_BASE + 0x700u)
#define MTX_N      (MTX_BASE + 0x704u)
#define MTX_VAL    (MTX_BASE + 0x708u)
#define MTX_STATUS (MTX_BASE + 0x70Cu)
#define MTX_CRC    (MTX_BASE + 0x710u)

static inline void mtx_wr(ee_u32 a, ee_u32 v)
{
    *(volatile ee_u32 *)a = v;
}

static inline ee_u32 mtx_rd(ee_u32 a)
{
    return *(volatile ee_u32 *)a;
}

extern ee_u16 core_bench_matrix_orig(mat_params *p, ee_s16 seed, ee_u16 crc);

ee_u16 core_bench_matrix(mat_params *p, ee_s16 seed, ee_u16 crc)
{
    ee_u32 n = p->N;
    ee_u32 i;
    ee_u16 ret;

    if (n != 9u)
        return core_bench_matrix_orig(p, seed, crc);

    for (i = 0; i < 81u; i++) {
        mtx_wr(MTX_A + 4u * i, (ee_u16)p->A[i]);
        mtx_wr(MTX_B + 4u * i, (ee_u16)p->B[i]);
    }
    __asm__ volatile("" ::: "memory");

    mtx_wr(MTX_N, 9u);
    mtx_wr(MTX_VAL, (ee_u16)seed);
    mtx_wr(MTX_CTRL, 1u);
    while ((mtx_rd(MTX_STATUS) & 2u) == 0u)
        ;
    __asm__ volatile("" ::: "memory");

    ret = (ee_u16)mtx_rd(MTX_CRC);
    return crc16((ee_s16)ret, crc);
}
'''

STATE_HW_C = r'''/* ARES state-machine token scanner driver.
 *
 * This file is not part of the EEMBC CoreMark sources.  It is added by the
 * accelerated build flow; core_state.c's core_bench_state definition is
 * renamed to core_bench_state_orig so this definition wins for callers in
 * core_list_join.c.
 *
 * core_bench_state() is a pure function when seed1 == seed2: the block is
 * restored after the corruption/undo passes.  The engine keeps a private
 * 1 KiB copy, so the core's memblock is never written.
 */
#include "coremark.h"

#define ST_BASE   0xA0002000u
#define ST_DATA   (ST_BASE + 0x000u)
#define ST_CTRL   (ST_BASE + 0x700u)
#define ST_BLKSZ  (ST_BASE + 0x704u)
#define ST_SEED1  (ST_BASE + 0x708u)
#define ST_SEED2  (ST_BASE + 0x70Cu)
#define ST_STEP   (ST_BASE + 0x710u)
#define ST_CRCIN  (ST_BASE + 0x714u)
#define ST_STATUS (ST_BASE + 0x718u)
#define ST_CRCOUT (ST_BASE + 0x71Cu)

static inline void st_wr(ee_u32 a, ee_u32 v)
{
    *(volatile ee_u32 *)a = v;
}

static inline ee_u32 st_rd(ee_u32 a)
{
    return *(volatile ee_u32 *)a;
}

extern ee_u16 core_bench_state_orig(ee_u32 blksize, ee_u8 *memblock,
                                    ee_s16 seed1, ee_s16 seed2,
                                    ee_s16 step, ee_u16 crc);

ee_u16 core_bench_state(ee_u32 blksize, ee_u8 *memblock,
                        ee_s16 seed1, ee_s16 seed2,
                        ee_s16 step, ee_u16 crc)
{
    ee_u32 i, j, w;

    if (blksize > 1024u || blksize == 0u || step <= 0 || seed1 != seed2)
        return core_bench_state_orig(blksize, memblock, seed1, seed2, step, crc);

    for (i = 0; i < blksize; i += 4u) {
        w = 0u;
        for (j = 0; j < 4u && (i + j) < blksize; j++)
            w |= ((ee_u32)memblock[i + j]) << (8u * j);
        st_wr(ST_DATA + i, w);
    }
    __asm__ volatile("" ::: "memory");

    st_wr(ST_BLKSZ, blksize);
    st_wr(ST_SEED1, (ee_u16)seed1);
    st_wr(ST_SEED2, (ee_u16)seed2);
    st_wr(ST_STEP, (ee_u16)step);
    st_wr(ST_CRCIN, crc);
    st_wr(ST_CTRL, 1u);
    while ((st_rd(ST_STATUS) & 2u) == 0u)
        ;
    __asm__ volatile("" ::: "memory");

    return (ee_u16)st_rd(ST_CRCOUT);
}
'''

MAKEFILE_APPEND_CRC = r'''
#------------------------------------------------------------------------------
# ARES accelerated CRC build (added by scripts/build_coremark_crc.py).
# Rename only the reference definitions in core_util.c; every other
# translation unit keeps calling the canonical crcu8/crcu16/crc16/crcu32
# names, which now resolve to src/crc_hw.c.
#------------------------------------------------------------------------------
$(DST_DIR)/src/core_util.o: CFLAGS += \
    -Dcrcu8=crcu8_orig -Dcrcu16=crcu16_orig \
    -Dcrcu32=crcu32_orig -Dcrc16=crc16_orig
'''

MAKEFILE_APPEND_ARRAY = r'''
#------------------------------------------------------------------------------
# ARES software array-shadow core_bench_list (added by
# scripts/build_coremark_crc.py --array-list).  Only the definition in
# core_list_join.c is renamed; callers in core_main.c still call
# core_bench_list, which now resolves to src/core_list_array.c.
#------------------------------------------------------------------------------
$(DST_DIR)/src/core_list_join.o: CFLAGS += -Dcore_bench_list=core_bench_list_orig
CFLAGS += -O3 -funroll-loops
'''

MAKEFILE_APPEND_LIST_ENGINE = r'''
#------------------------------------------------------------------------------
# list9_engine hot loop (added by scripts/build_coremark_crc.py --list-engine).
# The array-shadow TU keeps the sort/remove/CRC tail in software; only the
# 102-iteration find/reverse/move-to-front loop runs on the engine.
#------------------------------------------------------------------------------
$(DST_DIR)/src/core_list_array.o: CFLAGS += -DARES_LIST_ENGINE
'''

MAKEFILE_APPEND_MATRIX = r'''
#------------------------------------------------------------------------------
# ARES 9-PE INT16 matrix engine (added by
# scripts/build_coremark_crc.py --matrix-engine).  Only the definition in
# core_matrix.c is renamed; core_list_join.c's calc_func still calls
# core_bench_matrix, which now resolves to src/matrix_hw.c.
#------------------------------------------------------------------------------
$(DST_DIR)/src/core_matrix.o: CFLAGS += -Dcore_bench_matrix=core_bench_matrix_orig
CFLAGS += -O3 -funroll-loops
'''

MAKEFILE_APPEND_STATE = r'''
#------------------------------------------------------------------------------
# ARES state-machine token scanner (added by
# scripts/build_coremark_crc.py --state-engine).  Only the definition in
# core_state.c is renamed; core_list_join.c's calc_func still calls
# core_bench_state, which now resolves to src/state_hw.c.
#------------------------------------------------------------------------------
$(DST_DIR)/src/core_state.o: CFLAGS += -Dcore_bench_state=core_bench_state_orig
CFLAGS += -O3 -funroll-loops
'''

MAKEFILE_APPEND_SMALL_CODE = r'''
#------------------------------------------------------------------------------
# Smaller cold objects for the 32 KiB pipeline/AMP IROM (added by
# scripts/build_coremark_crc.py --small-code).  The hot benchmark TUs keep the
# global -O3 -funroll-loops; only startup, reporting and unused reference
# helpers are shrunk.
#------------------------------------------------------------------------------
$(DST_DIR)/src/core_util.o: CFLAGS += -Os -fno-unroll-loops
$(DST_DIR)/src/core_portme.o: CFLAGS += -Os -fno-unroll-loops
$(DST_DIR)/src/core_main.o: CFLAGS += -O2 -fno-unroll-loops
# The matrix/state engines replace these TUs at run time; the originals are
# only kept as fallbacks for non-standard shapes and are never executed by
# CoreMark.  Shrinking them recovers ~5 KiB of IROM without touching the
# accelerated hot path.
$(DST_DIR)/src/core_matrix.o: CFLAGS += -Os -fno-unroll-loops -fno-tree-vectorize
$(DST_DIR)/src/core_state.o: CFLAGS += -Os -fno-unroll-loops -fno-tree-vectorize
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=None,
                    help="output directory (default build/coremark_crc or "
                         "build/coremark_array with --array-list)")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--array-list", action="store_true",
                    help="also replace core_bench_list with the array-shadow TU")
    ap.add_argument("--list-engine", action="store_true",
                    help="run the core_bench_list hot loop on list9_engine; "
                         "implies --array-list")
    ap.add_argument("--matrix-engine", action="store_true",
                    help="also replace core_bench_matrix with the mtx9 engine driver")
    ap.add_argument("--state-engine", action="store_true",
                    help="also replace core_bench_state with the state9 scanner driver")
    ap.add_argument("--small-code", action="store_true",
                    help="shrink cold objects so the accelerated image fits the "
                         "pipeline 32 KiB IROM")
    ap.add_argument("--mt", action="store_true",
                    help="also build the 2-hart MULTITHREAD=2 single-report image "
                         "(overlay is applied by build_coremark_image.py --mt)")
    ap.add_argument("--mt-pipe", action="store_true",
                    help="also build the parameterized 2/4-hart pipeline MULTITHREAD "
                         "image (requires --cores; overlay applied by "
                         "build_coremark_image.py --mt-pipe)")
    ap.add_argument("--cores", type=int, default=None,
                    help="harts / CoreMark contexts for --mt-pipe (2 or 4)")
    # Cores=1 is accepted by build_coremark_image.py for single-context
    # reference images only; this accelerated flow targets the 2/4-hart runs.
    ap.add_argument("--total-iterations", type=int, default=None,
                    help="total iterations across all contexts for --mt-pipe "
                         "(default 10000, each context runs total/cores)")
    ap.add_argument("--ldscript", type=Path, default=None,
                    help="override the ARES linker script (for example "
                         "tests/abstract-machine/scripts/ares-linker-mc.ld)")
    args = ap.parse_args()
    if args.list_engine:
        args.array_list = True

    if args.state_engine and args.matrix_engine and args.array_list:
        default_out = ROOT / "build/coremark_full"
    elif args.state_engine and args.matrix_engine:
        default_out = ROOT / "build/coremark_state_matrix"
    elif args.state_engine and args.array_list:
        default_out = ROOT / "build/coremark_state_array"
    elif args.state_engine:
        default_out = ROOT / "build/coremark_state"
    elif args.matrix_engine and args.array_list:
        default_out = ROOT / "build/coremark_matrix_array"
    elif args.matrix_engine:
        default_out = ROOT / "build/coremark_matrix"
    elif args.array_list:
        default_out = ROOT / "build/coremark_array"
    else:
        default_out = ROOT / "build/coremark_crc"
    if args.mt and args.mt_pipe:
        raise SystemExit("error: --mt and --mt-pipe are mutually exclusive")
    if args.mt:
        default_out = default_out.with_name(default_out.name + "_mt")
    elif args.mt_pipe:
        if args.cores not in (2, 4):
            raise SystemExit("error: --mt-pipe requires --cores 2 or 4")
        default_out = default_out.with_name(default_out.name + f"_mt{args.cores}")
    out = (args.out or default_out).resolve()
    src_port = out / "src_port"
    if src_port.exists():
        shutil.rmtree(src_port)
    shutil.copytree(SRC, src_port,
                    ignore=shutil.ignore_patterns("build", "__pycache__", "*.pyc"))

    (src_port / "src/crc_hw.c").write_text(CRC_HW_C)
    makefile_append = MAKEFILE_APPEND_CRC
    if args.array_list:
        (src_port / "src/core_list_array.c").write_text(ARRAY_LIST_C)
        makefile_append += MAKEFILE_APPEND_ARRAY
    if args.list_engine:
        makefile_append += MAKEFILE_APPEND_LIST_ENGINE
    if args.matrix_engine:
        (src_port / "src/matrix_hw.c").write_text(MATRIX_HW_C)
        makefile_append += MAKEFILE_APPEND_MATRIX
    if args.state_engine:
        (src_port / "src/state_hw.c").write_text(STATE_HW_C)
        makefile_append += MAKEFILE_APPEND_STATE
    if args.small_code:
        makefile_append += MAKEFILE_APPEND_SMALL_CODE
    with (src_port / "Makefile").open("a") as f:
        f.write(makefile_append)

    cmd = [sys.executable, str(ROOT / "scripts/build_coremark_image.py"),
           "--port", str(src_port), "--out", str(out), "--jobs", str(args.jobs)]
    if args.mt:
        cmd.append("--mt")
    elif args.mt_pipe:
        cmd += ["--mt-pipe", "--cores", str(args.cores)]
        if args.total_iterations is not None:
            cmd += ["--total-iterations", str(args.total_iterations)]
    if args.ldscript is not None:
        cmd += ["--ldscript", str(args.ldscript.resolve())]
    print("+", " ".join(cmd))
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
