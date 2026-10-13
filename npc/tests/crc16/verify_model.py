#!/usr/bin/env python3
"""Verify the flattened hardware parity network against CoreMark crcu16."""

from __future__ import annotations

import random


MASKS = (
    0xFFFBFFFB, 0x000C000C, 0x00180018, 0x00300030,
    0x00600060, 0x00C000C0, 0x01800180, 0x03000300,
    0x06000600, 0x0C000C00, 0x18001800, 0x30003000,
    0x60016001, 0xC002C002, 0x7FFE7FFE, 0xFFFDFFFD,
)


def crcu8(data: int, crc: int) -> int:
    for _ in range(8):
        x16 = (data ^ crc) & 1
        data >>= 1
        if x16:
            crc ^= 0x4002
        crc = (crc >> 1) | (0x8000 if x16 else 0)
    return crc & 0xFFFF


def reference(new_value: int, crc: int) -> int:
    low = crcu8(new_value & 0xFF, crc)
    return crcu8((new_value >> 8) & 0xFF, low)


def parity_network(new_value: int, crc: int) -> int:
    inputs = (new_value & 0xFFFF) | ((crc & 0xFFFF) << 16)
    return sum(
        ((inputs & mask).bit_count() & 1) << bit
        for bit, mask in enumerate(MASKS)
    )


def main() -> None:
    random.seed(0xC0DE16)
    vectors = [(0, 0), (0xFFFF, 0), (0, 0xFFFF), (0xFFFF, 0xFFFF)]
    vectors.extend(
        (random.randrange(1 << 16), random.randrange(1 << 16))
        for _ in range(100_000)
    )
    for new_value, crc in vectors:
        expected = reference(new_value, crc)
        actual = parity_network(new_value, crc)
        if actual != expected:
            raise SystemExit(
                f"CRC mismatch new=0x{new_value:04x} crc=0x{crc:04x}: "
                f"expected=0x{expected:04x} actual=0x{actual:04x}"
            )
    print(f"CRC parity model passed {len(vectors)} vectors")


if __name__ == "__main__":
    main()
