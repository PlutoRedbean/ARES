#!/usr/bin/env python3
"""Pack a little-endian binary into 32-bit Vivado DRAM COE words."""

from __future__ import annotations

import argparse
from pathlib import Path


WORD_BYTES = 4


def pack_words(image: bytes, depth: int) -> list[str]:
    capacity = depth * WORD_BYTES
    if len(image) > capacity:
        raise ValueError(
            f"image is {len(image)} bytes, exceeds {depth}x32-bit "
            f"DRAM capacity ({capacity} bytes)"
        )

    padded = image.ljust(capacity, b"\0")
    return [
        f"{int.from_bytes(padded[offset:offset + WORD_BYTES], 'little'):08x}"
        for offset in range(0, capacity, WORD_BYTES)
    ]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pack a little-endian binary into 32-bit Vivado COE words"
    )
    parser.add_argument("input", type=Path, help="input flat binary")
    parser.add_argument("output", type=Path, help="output .coe file")
    parser.add_argument(
        "--depth",
        type=int,
        default=65536,
        help="number of 32-bit DRAM entries (default: 65536)",
    )
    args = parser.parse_args()

    if args.depth <= 0:
        parser.error("--depth must be positive")

    try:
        words = pack_words(args.input.read_bytes(), args.depth)
    except (OSError, ValueError) as error:
        parser.error(str(error))

    lines = [
        "memory_initialization_radix=16;",
        "memory_initialization_vector=",
    ]
    lines.extend(
        f"{word}{';' if index == len(words) - 1 else ','}"
        for index, word in enumerate(words)
    )
    args.output.write_text("\n".join(lines) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
