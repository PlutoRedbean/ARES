#!/usr/bin/env python3
"""Generate a cycle-instrumented CoreMark translation unit.

This pass is only for profiling builds.  It times the inclusive list calls in
core_main.c, the nested matrix/state calls in core_list_join.c, and the matrix
kernel calls in core_matrix.c with mcycle.  The pinned benchmark sources and
the normal performance binary are untouched.
"""

from __future__ import annotations

import argparse
from pathlib import Path


COREMARK_INCLUDE = '#include "coremark.h"\n'

LIST_SUPPORT = r'''

/* Generated profiling input; counters are valid for short (< 2^32 cycle) runs. */
ee_u32 mundus_profile_matrix_cycles;
ee_u32 mundus_profile_state_cycles;
ee_u32 mundus_profile_matrix_calls;
ee_u32 mundus_profile_state_calls;

static inline __attribute__((always_inline)) ee_u32
mundus_profile_read_mcycle(void)
{
    ee_u32 cycle;
    __asm__ volatile ("csrr %0, mcycle" : "=r" (cycle) : : "memory");
    return cycle;
}

static inline __attribute__((always_inline)) ee_u16
mundus_profile_core_bench_state(ee_u32 blksize,
                                ee_u8 *memblock,
                                ee_s16 seed1,
                                ee_s16 seed2,
                                ee_s16 step,
                                ee_u16 crc)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    ee_u16 result = core_bench_state(
        blksize, memblock, seed1, seed2, step, crc);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_state_cycles += end - begin;
    mundus_profile_state_calls++;
    return result;
}

static inline __attribute__((always_inline)) ee_u16
mundus_profile_core_bench_matrix(mat_params *params, ee_s16 seed, ee_u16 crc)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    ee_u16 result = core_bench_matrix(params, seed, crc);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_cycles += end - begin;
    mundus_profile_matrix_calls++;
    return result;
}
'''

MATRIX_GLOBALS = r'''

/* Generated profiling input; counters are valid for short (< 2^32 cycle) runs. */
ee_u32 mundus_profile_matrix_add_cycles;
ee_u32 mundus_profile_matrix_mul_const_cycles;
ee_u32 mundus_profile_matrix_sum_cycles;
ee_u32 mundus_profile_matrix_mul_vect_cycles;
ee_u32 mundus_profile_matrix_mul_matrix_cycles;
ee_u32 mundus_profile_matrix_mul_bitextract_cycles;
ee_u32 mundus_profile_matrix_add_calls;
ee_u32 mundus_profile_matrix_mul_const_calls;
ee_u32 mundus_profile_matrix_sum_calls;
ee_u32 mundus_profile_matrix_mul_vect_calls;
ee_u32 mundus_profile_matrix_mul_matrix_calls;
ee_u32 mundus_profile_matrix_mul_bitextract_calls;

static inline __attribute__((always_inline)) ee_u32
mundus_profile_read_mcycle(void)
{
    ee_u32 cycle;
    __asm__ volatile ("csrr %0, mcycle" : "=r" (cycle) : : "memory");
    return cycle;
}
'''

MATRIX_WRAPPERS = r'''

static inline __attribute__((always_inline)) void
mundus_profile_matrix_add_const(ee_u32 N, MATDAT *A, MATDAT val)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    matrix_add_const(N, A, val);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_add_cycles += end - begin;
    mundus_profile_matrix_add_calls++;
}

static inline __attribute__((always_inline)) void
mundus_profile_matrix_mul_const(ee_u32 N,
                                MATRES *C,
                                MATDAT *A,
                                MATDAT val)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    matrix_mul_const(N, C, A, val);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_mul_const_cycles += end - begin;
    mundus_profile_matrix_mul_const_calls++;
}

static inline __attribute__((always_inline)) ee_s16
mundus_profile_matrix_sum(ee_u32 N, MATRES *C, MATDAT clipval)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    ee_s16 result = matrix_sum(N, C, clipval);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_sum_cycles += end - begin;
    mundus_profile_matrix_sum_calls++;
    return result;
}

static inline __attribute__((always_inline)) void
mundus_profile_matrix_mul_vect(ee_u32 N, MATRES *C, MATDAT *A, MATDAT *B)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    matrix_mul_vect(N, C, A, B);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_mul_vect_cycles += end - begin;
    mundus_profile_matrix_mul_vect_calls++;
}

static inline __attribute__((always_inline)) void
mundus_profile_matrix_mul_matrix(ee_u32 N,
                                 MATRES *C,
                                 MATDAT *A,
                                 MATDAT *B)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    matrix_mul_matrix(N, C, A, B);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_mul_matrix_cycles += end - begin;
    mundus_profile_matrix_mul_matrix_calls++;
}

static inline __attribute__((always_inline)) void
mundus_profile_matrix_mul_matrix_bitextract(ee_u32 N,
                                            MATRES *C,
                                            MATDAT *A,
                                            MATDAT *B)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    matrix_mul_matrix_bitextract(N, C, A, B);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_mul_bitextract_cycles += end - begin;
    mundus_profile_matrix_mul_bitextract_calls++;
}

static inline __attribute__((always_inline)) void
mundus_profile_matrix_mul_matrix_n9(MATRES *C, MATDAT *A, MATDAT *B)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    mundus_matrix_mul_matrix_n9_acc9(C, A, B);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_mul_matrix_cycles += end - begin;
    mundus_profile_matrix_mul_matrix_calls++;
}

static inline __attribute__((always_inline)) void
mundus_profile_matrix_mul_matrix_bitextract_n9(MATRES *C,
                                               MATDAT *A,
                                               MATDAT *B)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    mundus_matrix_mul_matrix_bitextract_n9_acc9(C, A, B);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_matrix_mul_bitextract_cycles += end - begin;
    mundus_profile_matrix_mul_bitextract_calls++;
}
'''

MAIN_SUPPORT = r'''

extern ee_u32 mundus_profile_matrix_cycles;
extern ee_u32 mundus_profile_state_cycles;
extern ee_u32 mundus_profile_matrix_calls;
extern ee_u32 mundus_profile_state_calls;
extern ee_u32 mundus_profile_matrix_add_cycles;
extern ee_u32 mundus_profile_matrix_mul_const_cycles;
extern ee_u32 mundus_profile_matrix_sum_cycles;
extern ee_u32 mundus_profile_matrix_mul_vect_cycles;
extern ee_u32 mundus_profile_matrix_mul_matrix_cycles;
extern ee_u32 mundus_profile_matrix_mul_bitextract_cycles;
extern ee_u32 mundus_profile_matrix_add_calls;
extern ee_u32 mundus_profile_matrix_mul_const_calls;
extern ee_u32 mundus_profile_matrix_sum_calls;
extern ee_u32 mundus_profile_matrix_mul_vect_calls;
extern ee_u32 mundus_profile_matrix_mul_matrix_calls;
extern ee_u32 mundus_profile_matrix_mul_bitextract_calls;

ee_u32 mundus_profile_list_cycles;
ee_u32 mundus_profile_list_calls;

static inline __attribute__((always_inline)) ee_u32
mundus_profile_read_mcycle(void)
{
    ee_u32 cycle;
    __asm__ volatile ("csrr %0, mcycle" : "=r" (cycle) : : "memory");
    return cycle;
}

static inline __attribute__((always_inline)) ee_u16
mundus_profile_core_bench_list(core_results *results, ee_s16 finder_idx)
{
    ee_u32 begin = mundus_profile_read_mcycle();
    ee_u16 result = core_bench_list(results, finder_idx);
    ee_u32 end = mundus_profile_read_mcycle();
    mundus_profile_list_cycles += end - begin;
    mundus_profile_list_calls++;
    return result;
}
'''

PROFILE_REPORT = r'''
    ee_printf("MUNDUS_PROFILE cycles total=%lu list=%lu matrix=%lu state=%lu\n",
              (long unsigned)total_time,
              (long unsigned)mundus_profile_list_cycles,
              (long unsigned)mundus_profile_matrix_cycles,
              (long unsigned)mundus_profile_state_cycles);
    ee_printf("MUNDUS_PROFILE calls list=%lu matrix=%lu state=%lu\n",
              (long unsigned)mundus_profile_list_calls,
              (long unsigned)mundus_profile_matrix_calls,
              (long unsigned)mundus_profile_state_calls);
    ee_printf("MUNDUS_PROFILE matrix_cycles add=%lu mul_const=%lu sum=%lu "
              "mul_vect=%lu mul_matrix=%lu mul_bitextract=%lu\n",
              (long unsigned)mundus_profile_matrix_add_cycles,
              (long unsigned)mundus_profile_matrix_mul_const_cycles,
              (long unsigned)mundus_profile_matrix_sum_cycles,
              (long unsigned)mundus_profile_matrix_mul_vect_cycles,
              (long unsigned)mundus_profile_matrix_mul_matrix_cycles,
              (long unsigned)mundus_profile_matrix_mul_bitextract_cycles);
    ee_printf("MUNDUS_PROFILE matrix_calls add=%lu mul_const=%lu sum=%lu "
              "mul_vect=%lu mul_matrix=%lu mul_bitextract=%lu\n",
              (long unsigned)mundus_profile_matrix_add_calls,
              (long unsigned)mundus_profile_matrix_mul_const_calls,
              (long unsigned)mundus_profile_matrix_sum_calls,
              (long unsigned)mundus_profile_matrix_mul_vect_calls,
              (long unsigned)mundus_profile_matrix_mul_matrix_calls,
              (long unsigned)mundus_profile_matrix_mul_bitextract_calls);

'''


def inject_after_coremark_include(source: str, support: str) -> str:
    if source.count(COREMARK_INCLUDE) != 1:
        raise ValueError('expected exactly one #include "coremark.h"')
    return source.replace(COREMARK_INCLUDE, COREMARK_INCLUDE + support, 1)


def rewrite_list(source: str) -> str:
    state_call = "retval = core_bench_state("
    matrix_call = "retval = core_bench_matrix("
    if source.count(state_call) != 1 or source.count(matrix_call) != 1:
        raise ValueError("expected one nested state call and one nested matrix call")
    source = source.replace(
        state_call, "retval = mundus_profile_core_bench_state(", 1
    )
    source = source.replace(
        matrix_call, "retval = mundus_profile_core_bench_matrix(", 1
    )
    return inject_after_coremark_include(source, LIST_SUPPORT)


def rewrite_main(source: str) -> str:
    positive_call = "core_bench_list(res, 1)"
    negative_call = "core_bench_list(res, -1)"
    report_anchor = "#if (MEM_METHOD == MEM_MALLOC)\n"
    if source.count(positive_call) != 1 or source.count(negative_call) != 1:
        raise ValueError("expected the two top-level list calls")
    if source.count(report_anchor) != 1:
        raise ValueError("expected exactly one finalization anchor")
    source = source.replace(
        positive_call, "mundus_profile_core_bench_list(res, 1)", 1
    )
    source = source.replace(
        negative_call, "mundus_profile_core_bench_list(res, -1)", 1
    )
    source = source.replace(report_anchor, PROFILE_REPORT + report_anchor, 1)
    return inject_after_coremark_include(source, MAIN_SUPPORT)


def rewrite_matrix(source: str) -> str:
    replacements = {
        "matrix_add_const(N, A, val);":
            "mundus_profile_matrix_add_const(N, A, val);",
        "matrix_add_const(N, A, -val);":
            "mundus_profile_matrix_add_const(N, A, -val);",
        "matrix_mul_const(N, C, A, val);":
            "mundus_profile_matrix_mul_const(N, C, A, val);",
        "matrix_mul_vect(N, C, A, B);":
            "mundus_profile_matrix_mul_vect(N, C, A, B);",
        "matrix_mul_matrix(N, C, A, B);":
            "mundus_profile_matrix_mul_matrix(N, C, A, B);",
        "matrix_mul_matrix_bitextract(N, C, A, B);":
            "mundus_profile_matrix_mul_matrix_bitextract(N, C, A, B);",
        "mundus_matrix_mul_matrix_n9_acc9(C, A, B);":
            "mundus_profile_matrix_mul_matrix_n9(C, A, B);",
        "mundus_matrix_mul_matrix_bitextract_n9_acc9(C, A, B);":
            "mundus_profile_matrix_mul_matrix_bitextract_n9(C, A, B);",
        "matrix_sum(N, C, clipval)":
            "mundus_profile_matrix_sum(N, C, clipval)",
    }
    expected = {
        "matrix_add_const(N, A, val);": 1,
        "matrix_add_const(N, A, -val);": 1,
        "matrix_mul_const(N, C, A, val);": 1,
        "matrix_mul_vect(N, C, A, B);": 1,
        "matrix_mul_matrix(N, C, A, B);": 1,
        "matrix_mul_matrix_bitextract(N, C, A, B);": 1,
        "mundus_matrix_mul_matrix_n9_acc9(C, A, B);": 1,
        "mundus_matrix_mul_matrix_bitextract_n9_acc9(C, A, B);": 1,
        "matrix_sum(N, C, clipval)": 4,
    }
    for original, replacement in replacements.items():
        if source.count(original) != expected[original]:
            raise ValueError(
                f"expected {expected[original]} occurrences of {original!r}"
            )
        source = source.replace(original, replacement)

    definition_anchor = "ee_s16\nmatrix_test(ee_u32 N,"
    if source.count(definition_anchor) != 1:
        raise ValueError("expected exactly one matrix_test definition")
    source = source.replace(
        definition_anchor, MATRIX_WRAPPERS + "\n" + definition_anchor, 1
    )
    return inject_after_coremark_include(source, MATRIX_GLOBALS)


def rewrite(source: str, source_name: str) -> str:
    if "core_list_join" in source_name:
        return rewrite_list(source)
    if "core_main" in source_name:
        return rewrite_main(source)
    if "core_matrix" in source_name:
        return rewrite_matrix(source)
    raise ValueError(
        "profiling pass only supports core_list_join.c, core_matrix.c, "
        "and core_main.c"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    original = args.source.read_text(encoding="utf-8")
    generated = rewrite(original, args.source.name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    print(f"generated CoreMark profiling source: {args.output}")


if __name__ == "__main__":
    main()
