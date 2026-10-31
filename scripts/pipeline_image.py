#!/usr/bin/env python3
"""Split an ARES ELF image into the Pango pipeline IROM/DRAM readmemh files.

The pipeline SoC has two local memories with no address decoder between them:

  IROM  0x8000_0000  32 KiB   (8192 x 32-bit, one-cycle fetch)
  DRAM  0x8010_0000 256 KiB   (65536 x 32-bit, byte-enabled writes)

The ARES image is a dense flat binary starting at 0x8000_0000, so it cannot be
loaded as-is by two separate memories.  This script validates that every
initialized byte belongs to exactly one of the two windows and emits one
32-bit word per hex line for each memory.

Any byte outside the two windows (including the 0x8000_8000..0x800F_FFFF gap)
must be zero; otherwise the image would silently lose data on the board.

Usage:
  python3 scripts/pipeline_image.py --elf build/coremark/coremark-riscv32-ares.elf \
      --irom build/pipeline/irom.hex --dram build/pipeline/dram.hex
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from elf_image import ElfImageError, build_image

IROM_BASE = 0x8000_0000
IROM_BYTES = 32 * 1024
DRAM_BASE = 0x8010_0000
DRAM_BYTES = 256 * 1024


@dataclass(frozen=True)
class Region:
    name: str
    base: int
    size: int

    @property
    def end(self) -> int:
        return self.base + self.size

    @property
    def words(self) -> int:
        return self.size // 4


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def split_image(elf: bytes, irom: Region, dram: Region):
    """Return (irom_bytes, dram_bytes, entry) or raise ElfImageError."""
    image = build_image(elf, base=irom.base, limit=dram.end - irom.base)
    regions = [irom, dram]

    for segment in image.segments:
        if segment.mem_end <= segment.paddr:
            continue
        for region in regions:
            if segment.paddr >= region.base and segment.mem_end <= region.end:
                break
        else:
            raise ElfImageError(
                f"segment {segment.index} [0x{segment.paddr:08x}, "
                f"0x{segment.mem_end:08x}) is not contained in IROM or DRAM")

    if not (irom.base <= image.entry < irom.end):
        raise ElfImageError(
            f"entry point 0x{image.entry:08x} is outside IROM "
            f"[0x{irom.base:08x}, 0x{irom.end:08x})")

    buffers = {region.name: bytearray(region.size) for region in regions}
    covered = bytearray(len(image.data))

    for segment in image.segments:
        if segment.filesz == 0:
            continue
        for region in regions:
            if segment.paddr >= region.base and segment.file_end <= region.end:
                source = segment.paddr - image.base
                target = segment.paddr - region.base
                buffers[region.name][target:target + segment.filesz] = \
                    image.data[source:source + segment.filesz]
                covered[source:source + segment.filesz] = b"\x01" * segment.filesz
                break

    for index, (byte, tag) in enumerate(zip(image.data, covered)):
        if tag == 0 and byte != 0:
            raise ElfImageError(
                f"initialized byte at 0x{image.base + index:08x} is outside "
                f"IROM and DRAM; the flat image would lose it on the board")

    return bytes(buffers[irom.name]), bytes(buffers[dram.name]), image.entry


def to_word_hex(data: bytes) -> str:
    if len(data) % 4:
        raise ElfImageError("region size is not a multiple of four")
    return "".join(
        f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n"
        for i in range(0, len(data), 4))


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_bytes(data)
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--elf", type=Path, required=True,
                        help="input ELF32 executable")
    parser.add_argument("--irom", type=Path, default=Path("build/pipeline/irom.hex"),
                        help="IROM readmemh output (default build/pipeline/irom.hex)")
    parser.add_argument("--dram", type=Path, default=Path("build/pipeline/dram.hex"),
                        help="DRAM readmemh output (default build/pipeline/dram.hex)")
    parser.add_argument("--json", type=Path,
                        help="optional build-info JSON output")
    parser.add_argument("--replicate-dram-words", type=int, default=0,
                        help="replicate the first N 32-bit words of DRAM at "
                             "every N-word boundary (per-hart AMP private "
                             "windows; 8192 = 32 KiB)")
    args = parser.parse_args(argv)

    if not args.elf.is_file():
        print(f"error: ELF not found: {args.elf}", file=sys.stderr)
        return 1

    irom = Region("irom", IROM_BASE, IROM_BYTES)
    dram = Region("dram", DRAM_BASE, DRAM_BYTES)

    try:
        data = args.elf.read_bytes()
        irom_data, dram_data, entry = split_image(data, irom, dram)
        if args.replicate_dram_words:
            chunk_bytes = args.replicate_dram_words * 4
            if chunk_bytes <= 0 or chunk_bytes > len(dram_data):
                raise ElfImageError(
                    "--replicate-dram-words is outside the DRAM region")
            chunk = dram_data[:chunk_bytes]
            replicated = bytearray(dram_data)
            for offset in range(chunk_bytes, len(replicated), chunk_bytes):
                take = min(chunk_bytes, len(replicated) - offset)
                replicated[offset:offset + take] = chunk[:take]
            dram_data = bytes(replicated)
        irom_hex = to_word_hex(irom_data)
        dram_hex = to_word_hex(dram_data)
    except (ElfImageError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    atomic_write(args.irom, irom_hex.encode())
    atomic_write(args.dram, dram_hex.encode())

    info = {
        "elf": str(args.elf),
        "elf_sha256": _sha256(data),
        "entry": f"0x{entry:08x}",
        "irom": {
            "path": str(args.irom),
            "base": f"0x{irom.base:08x}",
            "bytes": irom.size,
            "words": irom.words,
            "nonzero_words": sum(
                1 for i in range(0, len(irom_data), 4)
                if irom_data[i:i + 4] != b"\x00\x00\x00\x00"),
            "sha256": _sha256(irom_hex.encode()),
        },
        "dram": {
            "path": str(args.dram),
            "base": f"0x{dram.base:08x}",
            "bytes": dram.size,
            "words": dram.words,
            "nonzero_words": sum(
                1 for i in range(0, len(dram_data), 4)
                if dram_data[i:i + 4] != b"\x00\x00\x00\x00"),
            "replicate_words": args.replicate_dram_words,
            "sha256": _sha256(dram_hex.encode()),
        },
    }
    if args.json is not None:
        atomic_write(args.json, (json.dumps(info, indent=2) + "\n").encode())

    print(f"irom: {info['irom']['nonzero_words']}/{irom.words} nonzero words "
          f"-> {args.irom}")
    print(f"dram: {info['dram']['nonzero_words']}/{dram.words} nonzero words "
          f"-> {args.dram}")
    print(f"entry: {info['entry']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
