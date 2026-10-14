#!/usr/bin/env python3
"""Generate a MULBE-enabled CoreMark matrix translation unit.

The checked-in CoreMark source remains byte-for-byte untouched.  This narrow
build-time pass recognizes the bit-extract inner-loop expression and replaces
it with the Mundus custom instruction intrinsic in the generated build file.
It also injects the measured-best N=9 row kernel: i-k-j traversal with nine
independent accumulators.  It deliberately fails if the expected source shape
changes.
"""

from __future__ import annotations

import argparse
from pathlib import Path


INCLUDE = '#include "coremark.h"\n'
INTRINSIC = r'''

/* Generated build input: Mundus custom-0 funct7=1, funct3=0. */
static inline __attribute__((always_inline))
MATRES mundus_matrix_mulbe(MATRES lhs, MATRES rhs)
{
	MATRES result;
	__asm__ volatile (
		".insn r 0x0b, 0, 1, %0, %1, %2"
		: "=r" (result)
		: "r" (lhs), "r" (rhs));
	return result;
}

/* Keep the N=9 software kernel's regular multiply as one schedulable RV32M
 * instruction.  This also prevents GCC's generic matrix-loop recognizer from
 * completely peeling the fixed-size kernel and spilling the B matrix. */
static inline __attribute__((always_inline))
MATRES mundus_matrix_mul(MATRES lhs, MATRES rhs)
{
	MATRES result;
	__asm__ volatile (
		"mul %0, %1, %2"
		: "=r" (result)
		: "r" (lhs), "r" (rhs));
	return result;
}
'''

ORIGINAL_LOOPS = ('''\
\t\t\t\tMATRES tmp=(MATRES)A[i*N+k] * (MATRES)B[k*N+j];
\t\t\t\tC[i*N+j]+=bit_extract(tmp,2,4)*bit_extract(tmp,5,7);''', '''\
                MATRES tmp = (MATRES)A[i * N + k] * (MATRES)B[k * N + j];
                C[i * N + j] += bit_extract(tmp, 2, 4) * bit_extract(tmp, 5, 7);''')

ACCELERATED_LOOPS = ('''\
\t\t\t\tC[i*N+j]+=mundus_matrix_mulbe(
\t\t\t\t\t(MATRES)A[i*N+k], (MATRES)B[k*N+j]);''', '''\
                C[i * N + j] += mundus_matrix_mulbe(
                    (MATRES)A[i * N + k], (MATRES)B[k * N + j]);''')

MATRIX_CALL = "matrix_mul_matrix(N, C, A, B);"
MATRIX_BITEXTRACT_CALL = "matrix_mul_matrix_bitextract(N, C, A, B);"


def make_accumulator_group(first_column: int, count: int, bitextract: bool) -> str:
    declarations = ", ".join(f"c{column} = 0" for column in range(count))
    products = []
    updates = []
    stores = []
    for local_column in range(count):
        if bitextract:
            products.append(
                f"            MATRES p{local_column} = mundus_matrix_mulbe("
                f"a, (MATRES)b[{local_column}]);"
            )
        else:
            products.append(
                f"            MATRES p{local_column} = mundus_matrix_mul("
                f"a, (MATRES)b[{local_column}]);"
            )
        updates.append(
            f"            c{local_column} += p{local_column};"
        )
        stores.append(
            f"        c[{local_column}] = c{local_column};"
        )
    return f'''\
    {{
        MATRES {declarations};
        ee_u32 k;
        for (k = 0; k < limit; k++)
        {{
            MATRES a = (MATRES)A[i * 9 + k];
            MATDAT *b = B + k * 9 + {first_column};
{chr(10).join(products)}
{chr(10).join(updates)}
        }}
        MATRES *c = C + i * 9 + {first_column};
{chr(10).join(stores)}
    }}'''


def make_n9_kernel(name: str, accumulators: int, bitextract: bool) -> str:
    groups = []
    first_column = 0
    while first_column < 9:
        count = min(accumulators, 9 - first_column)
        groups.append(
            make_accumulator_group(first_column, count, bitextract)
        )
        first_column += count
    return f'''\
static __attribute__((noinline,
                      optimize("no-unroll-loops",
                               "no-variable-expansion-in-unroller"))) void
{name}(MATRES *C, MATDAT *A, MATDAT *B)
{{
    ee_u32 i;
    ee_u32 limit = 9;
    __asm__ volatile ("" : "+r" (limit));
    for (i = 0; i < limit; i++)
    {{
{chr(10).join(groups)}
    }}
}}
'''


def make_n9_support(accumulators: int) -> str:
    normal_name = f"mundus_matrix_mul_matrix_n9_acc{accumulators}"
    bitextract_name = (
        f"mundus_matrix_mul_matrix_bitextract_n9_acc{accumulators}"
    )
    return (
        "\n/* Generated measured-best N=9 matrix specialization. */\n"
        + make_n9_kernel(normal_name, accumulators, False)
        + "\n"
        + make_n9_kernel(bitextract_name, accumulators, True)
        + "\n"
    )


def rewrite(source: str) -> str:
    if source.count(INCLUDE) != 1:
        raise ValueError('expected exactly one #include "coremark.h"')
    matches = [index for index, loop in enumerate(ORIGINAL_LOOPS)
               if source.count(loop) == 1]
    if len(matches) != 1:
        raise ValueError("expected exactly one matrix bit-extract inner loop")
    variant = matches[0]
    source = source.replace(
        ORIGINAL_LOOPS[variant], ACCELERATED_LOOPS[variant], 1)
    accumulators = 9
    if source.count(MATRIX_CALL) != 1:
        raise ValueError("expected exactly one matrix_mul_matrix call")
    if source.count(MATRIX_BITEXTRACT_CALL) != 1:
        raise ValueError(
            "expected exactly one matrix_mul_matrix_bitextract call"
        )
    support = INTRINSIC + make_n9_support(accumulators)
    source = source.replace(
        MATRIX_CALL,
        f"if (N == 9)\n"
        f"        mundus_matrix_mul_matrix_n9_acc{accumulators}(C, A, B);\n"
        f"    else\n"
        f"        {MATRIX_CALL}",
        1,
    )
    source = source.replace(
        MATRIX_BITEXTRACT_CALL,
        f"if (N == 9)\n"
        f"        mundus_matrix_mul_matrix_bitextract_n9_acc"
        f"{accumulators}(C, A, B);\n"
        f"    else\n"
        f"        {MATRIX_BITEXTRACT_CALL}",
        1,
    )
    return source.replace(INCLUDE, INCLUDE + support, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    original = args.source.read_text(encoding="utf-8")
    generated = rewrite(original)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    print(f"generated MULBE matrix source: {args.output} (N=9 acc9)")


if __name__ == "__main__":
    main()
