#!/usr/bin/env python3
"""Pack a little-endian RV32 binary into 64-bit Vivado COE words."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


BLOCK_BYTES = 8
DEFAULT_CONFIG = Path(__file__).resolve().parents[1] / "configs/build/.config"


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


def pack_blocks(image: bytes, depth: int) -> list[str]:
    capacity = depth * BLOCK_BYTES
    if len(image) > capacity:
        raise ValueError(
            f"image is {len(image)} bytes, exceeds {depth}x64-bit "
            f"IROM capacity ({capacity} bytes)"
        )

    padded = image.ljust(capacity, b"\0")
    return [
        f"{int.from_bytes(padded[offset:offset + BLOCK_BYTES], 'little'):016x}"
        for offset in range(0, capacity, BLOCK_BYTES)
    ]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pack two consecutive RV32 instructions per 64-bit COE entry"
    )
    parser.add_argument("input", type=Path, help="input flat binary")
    parser.add_argument("output", type=Path, help="output .coe file")
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help=f"Kconfig .config containing CONFIG_IROM_DEPTH (default: {DEFAULT_CONFIG})",
    )
    args = parser.parse_args()

    try:
        depth = read_config_int(args.config, "CONFIG_IROM_DEPTH")
        if depth <= 0:
            raise ValueError("CONFIG_IROM_DEPTH must be positive")
        words = pack_blocks(args.input.read_bytes(), depth)
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
