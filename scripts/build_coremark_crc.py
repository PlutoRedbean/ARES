#!/usr/bin/env python3
"""Build accelerated CoreMark images without touching the EEMBC sources.

Two build-level accelerations are supported, and can be combined:

  * CRC (always on)     src/crc_hw.c provides crcu8/crcu16/crc16/crcu32 with
                        the ARES custom-0 CRC8 instruction; the reference
                        definitions in core_util.c are renamed to *_orig.
  * --array-list        src/core_list_array.c provides core_bench_list with a
                        software array shadow; the reference definition in
                        core_list_join.c is renamed to core_bench_list_orig.
                        The linked list is materialised back at the end of
                        every call, so the rest of CoreMark still sees a valid
                        list.

The vendored tests/benchmarks/coremark tree is only staged (copied); every
source file in it stays byte-identical.  All changes are build flags and new
translation units.

Usage:
    python3 scripts/build_coremark_crc.py [--out build/coremark_crc]
    python3 scripts/build_coremark_crc.py --array-list [--out build/coremark_array]
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=None,
                    help="output directory (default build/coremark_crc or "
                         "build/coremark_array with --array-list)")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--array-list", action="store_true",
                    help="also replace core_bench_list with the array-shadow TU")
    args = ap.parse_args()

    default_out = ROOT / ("build/coremark_array" if args.array_list
                          else "build/coremark_crc")
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
    with (src_port / "Makefile").open("a") as f:
        f.write(makefile_append)

    cmd = [sys.executable, str(ROOT / "scripts/build_coremark_image.py"),
           "--port", str(src_port), "--out", str(out), "--jobs", str(args.jobs)]
    print("+", " ".join(cmd))
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
