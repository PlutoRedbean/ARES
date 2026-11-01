#!/usr/bin/env python3
"""Generate directed/random vectors for tb_list9_engine.

The model is the C reference semantics (core_bench_list's hot loop) on a
Python list; the RTL is the array-shadow version with a direction bit, so a
match exercises both the find/MTF order and the final direction mapping.
"""
from __future__ import annotations

import argparse
import random
from pathlib import Path


def run_case(n, vals, finder, find_num):
    idx = [(v >> 16) & 0xFFFF for v in vals]
    d16 = [v & 0xFFFF for v in vals]
    seq = list(range(n))
    retval = 0
    found = 0
    missed = 0
    fkey = finder

    for i in range(find_num):
        key = fkey if finder >= 0 else (i & 0xFF)
        f = -1
        fi = -1
        for k, ph in enumerate(seq):
            v = idx[ph] if finder >= 0 else (d16[ph] & 0xFF)
            if v == key:
                f = ph
                fi = k
                break
        seq.reverse()
        if f < 0:
            missed += 1
            retval += (d16[seq[1]] >> 8) & 1
        else:
            found += 1
            if d16[f] & 1:
                retval += (d16[f] >> 9) & 1
            ri = n - 1 - fi
            if ri > 0 and ri + 1 < n:
                x = seq[ri + 1]
                seq.pop(ri + 1)
                seq.insert(1, x)
        if finder >= 0:
            fkey += 1

    retval = (retval + found * 4 - missed) & 0xFFFF
    return retval, found, missed, seq, (find_num & 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path("build/unit/list9_vectors.hex"))
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--seed", type=int, default=12345)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = []

    # Directed: minimum size, odd/even iteration count, both key modes.
    for n in (3, 4, 31, 32):
        for finder in (1, -1):
            for iters in (1, 2, 3, 102):
                vals = [((rng.randrange(-32768, 32768) & 0xFFFF) << 16) |
                        (rng.randrange(0, 65536) & 0xFFFF) for _ in range(n)]
                cases.append((n, vals, finder, iters))

    # Random: duplicate idx values, all sizes.
    for _ in range(args.count):
        n = rng.randrange(3, 33)
        vals = []
        for i in range(n):
            # small idx range so finds hit duplicates/negative-zero cases
            idx = rng.randrange(0, max(4, n))
            d16 = rng.randrange(0, 65536)
            vals.append(((idx & 0xFFFF) << 16) | (d16 & 0xFFFF))
        finder = 1 if rng.random() < 0.5 else -1
        iters = rng.choice([1, 2, 3, 5, 17, 102, 128, 255])
        cases.append((n, vals, finder, iters))

    words = [len(cases)]
    for n, vals, finder, iters in cases:
        retval, found, missed, seq, direction = run_case(n, vals, finder, iters)
        words += [n, finder & 0xFFFFFFFF, iters & 0xFFFFFFFF]
        words += [0x1000_0000 + 4 * i for i in range(n)]  # node addresses
        words += vals
        words += [retval, found, missed, direction]
        words += [0x1000_0000 + 4 * seq[i] for i in range(n)]

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(f"{w & 0xFFFFFFFF:08x}" for w in words) + "\n")
    print(f"wrote {len(cases)} cases / {len(words)} words to {args.out}")


if __name__ == "__main__":
    main()
