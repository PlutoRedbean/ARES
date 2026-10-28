#!/usr/bin/env python3
"""Host-side equivalence test for the array-shadow core_bench_list.

Builds the original CoreMark list benchmark and the generated array version
into one native executable, then runs 100 iterations x 2 calls and compares
the return value, list contents, matrix/state bytes and all output CRCs after
every call.

The script only consumes the vendored sources; it does not modify them.  The
array TU is the exact string that scripts/build_coremark_crc.py stages for
--array-list, so this test covers the shipping implementation.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import build_coremark_crc  # noqa: E402

OUT = ROOT / "build/test-coremark-array"
SRC = ROOT / "tests/benchmarks/coremark/src"
INC = ROOT / "tests/benchmarks/coremark/include"

HOST_PORTME = r"""#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stddef.h>
#include <stdint.h>
#define ITERATIONS 100
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
typedef uint32_t CORE_TICKS;
typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef double ee_f32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
#define align_mem(x) (void *)(4 + (((uintptr_t)(x) - 1) & ~(uintptr_t)3))
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define COMPILER_VERSION "host"
#define COMPILER_FLAGS ""
#define MEM_LOCATION "STATIC"
typedef struct CORE_PORTABLE_S { ee_u8 portable_id; } core_portable;
extern ee_u32 default_num_contexts;
#endif
"""

HARNESS = r"""#include "coremark.h"
#include <stdio.h>
#include <string.h>

volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = 100;
volatile ee_s32 seed5_volatile = 0;

extern ee_u16 core_bench_list_orig(core_results *res, ee_s16 finder_idx);
extern ee_u16 core_bench_list_array(core_results *res, ee_s16 finder_idx);

static unsigned long hash_list(list_head *l)
{
    unsigned long h = 1469598103934665603UL;
    int n = 0;
    while (l != 0 && n < 4096) {
        h ^= (unsigned short)l->info->idx;
        h *= 1099511628211UL;
        h ^= (unsigned short)l->info->data16;
        h *= 1099511628211UL;
        n++;
        l = l->next;
    }
    return h ^ ((unsigned long)n << 48);
}

static unsigned long hash_bytes(const ee_u8 *p, int n)
{
    unsigned long h = 1469598103934665603UL;
    int i;
    for (i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211UL;
    }
    return h;
}

static void setup(core_results *r, ee_u8 *mem)
{
    memset(r, 0, sizeof(*r));
    memset(mem, 0, 2000);
    r->size = 666;
    r->memblock[0] = mem;
    r->memblock[1] = mem;
    r->memblock[2] = mem + 666;
    r->memblock[3] = mem + 1332;
    r->seed1 = 0x3415;
    r->seed2 = 0x3415;
    r->seed3 = 0x66;
    r->iterations = 100;
    r->execs = ALL_ALGORITHMS_MASK;
    r->list = core_list_init(666, (list_head *)mem, 0x3415);
    core_init_matrix(666, mem + 666, (ee_s32)0x34153415, &r->mat);
    core_init_state(666, 0x3415, mem + 1332);
}

int main(void)
{
    static ee_u8 mem_orig[2000] __attribute__((aligned(16)));
    static ee_u8 mem_arr[2000] __attribute__((aligned(16)));
    core_results r1, r2;
    int iter, call;
    int bad = 0;

    setup(&r1, mem_orig);
    setup(&r2, mem_arr);

    for (iter = 0; iter < 100 && !bad; iter++) {
        for (call = 0; call < 2 && !bad; call++) {
            ee_s16 finder = (call == 0) ? 1 : -1;
            ee_u16 a = core_bench_list_orig(&r1, finder);
            ee_u16 b = core_bench_list_array(&r2, finder);
            unsigned long l1 = hash_list(r1.list);
            unsigned long l2 = hash_list(r2.list);
            unsigned long m1 = hash_bytes(mem_orig + 666, 1334);
            unsigned long m2 = hash_bytes(mem_arr + 666, 1334);

            if (a != b || l1 != l2 || m1 != m2 ||
                r1.crc != r2.crc || r1.crclist != r2.crclist ||
                r1.crcmatrix != r2.crcmatrix || r1.crcstate != r2.crcstate) {
                printf("MISMATCH iter=%d call=%d finder=%d\n", iter, call, (int)finder);
                printf("  retval %04x vs %04x\n", a, b);
                printf("  list   %016lx vs %016lx\n", l1, l2);
                printf("  matst  %016lx vs %016lx\n", m1, m2);
                printf("  crc    %04x %04x %04x %04x vs %04x %04x %04x %04x\n",
                       r1.crc, r1.crclist, r1.crcmatrix, r1.crcstate,
                       r2.crc, r2.crclist, r2.crcmatrix, r2.crcstate);
                bad = 1;
            }
        }
    }
    if (!bad)
        printf("ALL 200 CALLS MATCH\n");
    return bad;
}
"""


def run(cmd: list[str]) -> None:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"command failed: {' '.join(cmd)}")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "core_portme.h").write_text(HOST_PORTME)
    (OUT / "core_list_array.c").write_text(build_coremark_crc.ARRAY_LIST_C)
    (OUT / "harness.c").write_text(HARNESS)

    common = [
        "gcc", "-O2", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
        "-include", str(OUT / "core_portme.h"),
        "-I", str(INC), "-I", str(OUT),
    ]
    objects = {
        "clj.o": [str(SRC / "core_list_join.c"),
                  "-Dcore_bench_list=core_bench_list_orig"],
        "state.o": [str(SRC / "core_state.c")],
        "matrix.o": [str(SRC / "core_matrix.c")],
        "util.o": [str(SRC / "core_util.c")],
        "array.o": [str(OUT / "core_list_array.c"),
                    "-Dcore_bench_list=core_bench_list_array"],
        "harness.o": [str(OUT / "harness.c")],
    }
    for obj, args in objects.items():
        run(common + ["-c"] + args + ["-o", str(OUT / obj)])
    run(["gcc"] + [str(OUT / o) for o in objects] + ["-o", str(OUT / "harness")])

    result = subprocess.run([str(OUT / "harness")], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    if result.returncode != 0 or "ALL 200 CALLS MATCH" not in result.stdout:
        sys.stderr.write(result.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
