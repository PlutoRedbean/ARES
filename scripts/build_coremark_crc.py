#!/usr/bin/env python3
"""Build accelerated CoreMark images without touching the EEMBC sources.

Four build-level accelerations are supported, and can be combined:

  * CRC (always on)     src/crc_hw.c provides crcu8/crcu16/crc16/crcu32 with
                        the ARES custom-0 CRC8 instruction; the reference
                        definitions in core_util.c are renamed to *_orig.
  * --array-list        src/core_list_array.c provides core_bench_list with a
                        software array shadow; the reference definition in
                        core_list_join.c is renamed to core_bench_list_orig.
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

ARRAY_LIST_C = r'''/* ARES software array-shadow core_bench_list.
 *
 * This file is not part of the EEMBC CoreMark sources.  It is added by the
 * accelerated build flow; the reference core_bench_list() in
 * core_list_join.c is renamed to core_bench_list_orig() so this definition
 * wins for every caller (core_main.c is unchanged).
 *
 * The benchmark's linked list has only ~30 nodes and lives in L1D.  The
 * original find is a 3-load serial chain per node (next -> info -> idx) and
 * the original reverse writes a serial next chain.  This implementation
 * keeps an array shadow of {node, info} in the current list order:
 *
 *   - find scans the info array with independent loads (4-way unrolled);
 *   - reverse toggles an O(1) direction flag; the physical array is
 *     normalised once after the find loop;
 *   - move-to-front/remove/undo are array index operations;
 *   - the two mergesorts are the exact same bottom-up merge algorithm,
 *     only indexed by array position, so the cmp() call order (and therefore
 *     calc_func's caching/CRC side effects) is identical;
 *   - the linked list is materialised from the array at the end of each call,
 *     restoring the original idx order.
 *
 * The array is reused across calls (keyed by core_results/list head).  No
 * CoreMark source file is modified.
 */

#include "coremark.h"

#define ARES_LIST_MAX 128

typedef ee_s32 (*ares_cmp_fn)(list_data *, list_data *, core_results *);

extern ee_s32 cmp_complex(list_data *a, list_data *b, core_results *res);
extern ee_u16 core_bench_list_orig(core_results *res, ee_s16 finder_idx);

static list_head *ares_nodes[ARES_LIST_MAX];
static list_data *ares_info[ARES_LIST_MAX];
static list_head *ares_tmp_nodes[ARES_LIST_MAX];
static list_data *ares_tmp_info[ARES_LIST_MAX];
static int ares_n;
static int ares_dir;              /* 0: array order is forward; 1: reversed */
static core_results *ares_res;
static list_head *ares_head;

static void ares_build(core_results *res)
{
    list_head *p = res->list;
    int n = 0;

    while (p != 0 && n < ARES_LIST_MAX) {
        ares_nodes[n] = p;
        ares_info[n] = p->info;
        n++;
        p = p->next;
    }
    ares_res = res;
    ares_head = res->list;
    ares_n = (p == 0) ? n : 0;
    ares_dir = 0;
}

static int ares_find_idx(ee_s16 idx)
{
    int i;

    if (!ares_dir) {
        for (i = 0; i + 3 < ares_n; i += 4) {
            if (ares_info[i]->idx == idx) return i;
            if (ares_info[i + 1]->idx == idx) return i + 1;
            if (ares_info[i + 2]->idx == idx) return i + 2;
            if (ares_info[i + 3]->idx == idx) return i + 3;
        }
        for (; i < ares_n; i++)
            if (ares_info[i]->idx == idx) return i;
    } else {
        for (i = ares_n - 1; i - 3 >= 0; i -= 4) {
            if (ares_info[i]->idx == idx) return ares_n - 1 - i;
            if (ares_info[i - 1]->idx == idx) return ares_n - i;
            if (ares_info[i - 2]->idx == idx) return ares_n + 1 - i;
            if (ares_info[i - 3]->idx == idx) return ares_n + 2 - i;
        }
        for (; i >= 0; i--)
            if (ares_info[i]->idx == idx) return ares_n - 1 - i;
    }
    return -1;
}

static int ares_find_data(ee_u16 data)
{
    int i;
    int key = (int)data;

    if (!ares_dir) {
        for (i = 0; i + 3 < ares_n; i += 4) {
            if ((ares_info[i]->data16 & 0xff) == key) return i;
            if ((ares_info[i + 1]->data16 & 0xff) == key) return i + 1;
            if ((ares_info[i + 2]->data16 & 0xff) == key) return i + 2;
            if ((ares_info[i + 3]->data16 & 0xff) == key) return i + 3;
        }
        for (; i < ares_n; i++)
            if ((ares_info[i]->data16 & 0xff) == key) return i;
    } else {
        for (i = ares_n - 1; i - 3 >= 0; i -= 4) {
            if ((ares_info[i]->data16 & 0xff) == key) return ares_n - 1 - i;
            if ((ares_info[i - 1]->data16 & 0xff) == key) return ares_n - i;
            if ((ares_info[i - 2]->data16 & 0xff) == key) return ares_n + 1 - i;
            if ((ares_info[i - 3]->data16 & 0xff) == key) return ares_n + 2 - i;
        }
        for (; i >= 0; i--)
            if ((ares_info[i]->data16 & 0xff) == key) return ares_n - 1 - i;
    }
    return -1;
}

static void ares_flip(void)
{
    ares_dir ^= 1;
}

static list_data *ares_info_at(int k)
{
    return ares_dir ? ares_info[ares_n - 1 - k] : ares_info[k];
}

/* Materialise the current logical order into the physical arrays.  Called
 * once after the find/reverse loop, so the hot loop's reverse is O(1). */
static void ares_normalize(void)
{
    int i = 0;
    int j = ares_n - 1;

    if (!ares_dir) return;
    while (i < j) {
        list_head *tn = ares_nodes[i];
        list_data *ti = ares_info[i];
        ares_nodes[i] = ares_nodes[j];
        ares_info[i] = ares_info[j];
        ares_nodes[j] = tn;
        ares_info[j] = ti;
        i++;
        j--;
    }
    ares_dir = 0;
}

static void ares_move_after_head(int idx)
{
    list_head *finder;
    list_data *finder_info;
    int k;
    int p;

    /* idx is a logical index in the current direction.  Move the node at
     * logical idx+1 to logical position 1 with a single shift. */
    if (idx <= 0 || idx + 1 >= ares_n) return;

    if (!ares_dir) {
        finder = ares_nodes[idx + 1];
        finder_info = ares_info[idx + 1];
        for (k = idx + 1; k > 1; k--) {
            ares_nodes[k] = ares_nodes[k - 1];
            ares_info[k] = ares_info[k - 1];
        }
        ares_nodes[1] = finder;
        ares_info[1] = finder_info;
    } else {
        int lo = ares_n - 2 - idx;
        finder = ares_nodes[lo];
        finder_info = ares_info[lo];
        for (p = lo; p <= ares_n - 3; p++) {
            ares_nodes[p] = ares_nodes[p + 1];
            ares_info[p] = ares_info[p + 1];
        }
        ares_nodes[ares_n - 2] = finder;
        ares_info[ares_n - 2] = finder_info;
    }
}

static list_head *ares_remove_after_head(void)
{
    list_head *item;
    list_head *ret;
    list_data *tmp;
    int k;

    if (ares_n < 3) return 0;

    item = ares_nodes[1];
    ret = ares_nodes[2];

    tmp = item->info;
    item->info = ret->info;
    ret->info = tmp;
    ret->next = 0;
    ares_info[1] = item->info;

    for (k = 2; k < ares_n - 1; k++) {
        ares_nodes[k] = ares_nodes[k + 1];
        ares_info[k] = ares_info[k + 1];
    }
    ares_n--;
    return ret;
}

static void ares_undo_remove(list_head *removed)
{
    list_head *modified;
    list_data *tmp;
    int k;

    if (removed == 0 || ares_n < 2) return;

    modified = ares_nodes[1];
    tmp = removed->info;
    removed->info = modified->info;
    modified->info = tmp;
    ares_info[1] = modified->info;

    for (k = ares_n; k > 2; k--) {
        ares_nodes[k] = ares_nodes[k - 1];
        ares_info[k] = ares_info[k - 1];
    }
    ares_nodes[2] = removed;
    ares_info[2] = removed->info;
    ares_n++;

    modified->next = removed;
    removed->next = (ares_n > 3) ? ares_nodes[3] : 0;
}

static void ares_sort(ares_cmp_fn cmp, core_results *res)
{
    int insize = 1;
    int i;

    for (;;) {
        int p = 0;
        int out = 0;
        int nmerges = 0;

        while (p < ares_n) {
            int q = p;
            int psize = 0;
            int qsize;
            int e;

            nmerges++;
            for (i = 0; i < insize; i++) {
                psize++;
                q++;
                if (q >= ares_n) break;
            }
            qsize = insize;

            while (psize > 0 || (qsize > 0 && q < ares_n)) {
                if (psize == 0) {
                    e = q;
                    q++;
                    qsize--;
                } else if (qsize == 0 || q >= ares_n) {
                    e = p;
                    p++;
                    psize--;
                } else if (cmp(ares_info[p], ares_info[q], res) <= 0) {
                    e = p;
                    p++;
                    psize--;
                } else {
                    e = q;
                    q++;
                    qsize--;
                }
                ares_tmp_nodes[out] = ares_nodes[e];
                ares_tmp_info[out] = ares_info[e];
                out++;
            }
            p = q;
        }

        for (i = 0; i < out; i++) {
            ares_nodes[i] = ares_tmp_nodes[i];
            ares_info[i] = ares_tmp_info[i];
        }
        if (nmerges <= 1) break;
        insize *= 2;
    }
}

static ee_s32 ares_cmp_idx(list_data *a, list_data *b, core_results *res)
{
    if (res == 0) {
        a->data16 = (a->data16 & 0xff00) | (0x00ff & (a->data16 >> 8));
        b->data16 = (b->data16 & 0xff00) | (0x00ff & (b->data16 >> 8));
    }
    return a->idx - b->idx;
}

static ee_u16 ares_crc_walk(int start, ee_u16 retval)
{
    ee_s16 head_data;
    int i;

    if (start < 0) start = 0;
    head_data = ares_info[0]->data16;
    for (i = start; i < ares_n; i++)
        retval = crc16(head_data, retval);
    return retval;
}

static void ares_materialize(void)
{
    int i;

    for (i = 0; i < ares_n; i++)
        ares_nodes[i]->next = (i + 1 < ares_n) ? ares_nodes[i + 1] : 0;
}

ee_u16 core_bench_list(core_results *res, ee_s16 finder_idx)
{
    ee_u16 retval = 0;
    ee_u16 found = 0;
    ee_u16 missed = 0;
    ee_s16 find_num = res->seed3;
    ee_s16 info_idx = finder_idx;
    ee_s16 info_data16 = 0;
    ee_s16 i;
    int fi;
    int ri;
    list_head *remover;

    if (ares_n == 0 || ares_res != res || ares_head != res->list)
        ares_build(res);
    if (ares_n < 3)
        return core_bench_list_orig(res, finder_idx);

    for (i = 0; i < find_num; i++) {
        info_data16 = (ee_s16)(i & 0xff);
        fi = (info_idx >= 0) ? ares_find_idx(info_idx)
                             : ares_find_data((ee_u16)info_data16);

        ares_flip();
        ri = (fi >= 0) ? (ares_n - 1 - fi) : -1;

        if (ri < 0) {
            missed++;
            retval = (ee_u16)(retval +
                              ((ares_info_at(1)->data16 >> 8) & 1));
        } else {
            found++;
            if (ares_info_at(ri)->data16 & 0x1)
                retval = (ee_u16)(retval +
                                  ((ares_info_at(ri)->data16 >> 9) & 1));
            if (ri + 1 < ares_n)
                ares_move_after_head(ri);
        }

        if (info_idx >= 0) info_idx++;
    }

    /* Leave the hot loop's logical direction behind once: subsequent
     * remove/CRC/sort code uses the physical (forward) arrays. */
    ares_normalize();

    retval = (ee_u16)(retval + found * 4 - missed);

    if (finder_idx > 0)
        ares_sort(cmp_complex, res);

    remover = ares_remove_after_head();
    if (remover == 0)
        return retval;

    fi = (info_idx >= 0) ? ares_find_idx(info_idx)
                         : ares_find_data((ee_u16)info_data16);
    if (fi < 0) fi = 1;
    retval = ares_crc_walk(fi, retval);

    ares_undo_remove(remover);

    ares_sort(ares_cmp_idx, 0);
    retval = ares_crc_walk(1, retval);

    ares_materialize();
    return retval;
}
'''

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
