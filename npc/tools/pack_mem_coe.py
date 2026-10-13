#!/usr/bin/env python3
"""Pack a little-endian binary image into a 32-bit Vivado COE file."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


WORD_BYTES = 4


def read_config_int(config: Path, key: str) -> int:
    pattern = re.compile(rf"^{re.escape(key)}=(0[xX][0-9a-fA-F]+|[0-9]+)$")

    try:
        lines = config.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ValueError(f"cannot read configuration {config}: {error}") from error

    for line in lines:
        match = pattern.fullmatch(line.strip())
        if match:
            return int(match.group(1), 0)

    raise ValueError(f"{key} is missing from configuration {config}")


def resolve_capacity(args: argparse.Namespace) -> int:
    if args.capacity_bytes is not None:
        capacity = args.capacity_bytes
    else:
        capacity = read_config_int(args.config, args.capacity_config_key)

    if capacity <= 0:
        raise ValueError("memory capacity must be positive")
    if capacity % WORD_BYTES != 0:
        raise ValueError("memory capacity must be a multiple of 4 bytes")
    return capacity


def pack_words(image: bytes, capacity: int) -> list[str]:
    if len(image) > capacity:
        raise ValueError(
            f"image is {len(image)} bytes, exceeds 32-bit memory capacity "
            f"({capacity} bytes)"
        )

    padded = image.ljust(capacity, b"\0")
    return [
        f"{int.from_bytes(padded[offset:offset + WORD_BYTES], 'little'):08x}"
        for offset in range(0, capacity, WORD_BYTES)
    ]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pack a binary into little-endian 32-bit Vivado COE words"
    )
    parser.add_argument("input", type=Path, help="input flat binary")
    parser.add_argument("output", type=Path, help="output .coe file")
    capacity = parser.add_mutually_exclusive_group(required=True)
    capacity.add_argument(
        "--capacity-bytes",
        type=lambda value: int(value, 0),
        help="memory capacity in bytes",
    )
    capacity.add_argument(
        "--capacity-config-key",
        help="configuration key whose value is the memory capacity in bytes",
    )
    parser.add_argument(
        "--config",
        type=Path,
        help="Kconfig .config used with --capacity-config-key",
    )
    args = parser.parse_args()

    if args.capacity_config_key is not None and args.config is None:
        parser.error("--config is required with --capacity-config-key")

    try:
        memory_capacity = resolve_capacity(args)
        words = pack_words(args.input.read_bytes(), memory_capacity)
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
