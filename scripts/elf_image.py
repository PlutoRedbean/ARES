#!/usr/bin/env python3
"""Convert a RISC-V ELF32 executable into the flat image the ARES L2 TBs load.

The ARES L2 testbenches load a 128-bit-wide $readmemh file where line i is the
16-byte word at BASE + 16*i (rtl/top/test/tb_ares_coremark.sv documents the
format).  This module owns that conversion and every rule that decides whether
an ELF is a legal input, so the image chain has one implementation instead of a
hand-written objcopy + readmemh snippet.

Dense layout (deliberate): the linker script places code in IROM
(0x8000_0000) and writable data in DRAM (0x8010_0000), so the flat image is
~1 MiB with zero fill between the regions.  The readmemh format has no address
field, which is exactly why the span must be checked here: an image that runs
past the backing window would otherwise be truncated silently by the
testbench's addr[23:4] index.

Usage:
  python3 scripts/elf_image.py --elf build/coremark/coremark-riscv32-ares.elf \
      --bin build/coremark/coremark.bin --hex build/coremark/coremark_dmem.hex
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

PT_LOAD = 1
ET_EXEC = 2
EM_RISCV = 243
ELFCLASS32 = 1
ELFDATA2LSB = 1
EHDR_SIZE = 52
PHDR_SIZE = 32

DEFAULT_BASE = 0x8000_0000
DEFAULT_LIMIT = 0x0100_0000  # 16 MiB backing memory of the L2 testbenches


class ElfImageError(Exception):
    """A refused input.  The message is part of the tool's contract."""


@dataclass(frozen=True)
class Segment:
    index: int
    offset: int
    vaddr: int
    paddr: int
    filesz: int
    memsz: int

    @property
    def file_end(self) -> int:
        return self.paddr + self.filesz

    @property
    def mem_end(self) -> int:
        return self.paddr + self.memsz


@dataclass(frozen=True)
class Image:
    base: int
    data: bytes
    entry: int
    segments: list[Segment]

    @property
    def end(self) -> int:
        return self.base + len(self.data)

    def info(self) -> dict:
        return {
            "base": f"0x{self.base:08x}",
            "end": f"0x{self.end:08x}",
            "size_bytes": len(self.data),
            "entry": f"0x{self.entry:08x}",
            "segments": [
                {
                    "index": segment.index,
                    "paddr": f"0x{segment.paddr:08x}",
                    "vaddr": f"0x{segment.vaddr:08x}",
                    "filesz": segment.filesz,
                    "memsz": segment.memsz,
                }
                for segment in self.segments
            ],
        }


def _u16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset:offset + 2], "little")


def _u32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset:offset + 4], "little")


def parse_segments(data: bytes) -> tuple[list[Segment], int]:
    """Validate the ELF32/RISC-V envelope and return (loadable segments, entry)."""
    if len(data) == 0:
        raise ElfImageError("empty image file (0 bytes)")
    if len(data) < EHDR_SIZE:
        raise ElfImageError(
            f"truncated ELF header: {len(data)} bytes, need at least {EHDR_SIZE}")
    if data[:4] != b"\x7fELF":
        raise ElfImageError("not an ELF file (bad ELF magic)")
    elf_class = data[4]
    elf_data = data[5]
    if elf_class != ELFCLASS32:
        raise ElfImageError(
            f"not a 32-bit ELF (EI_CLASS={elf_class}); ARES images are ELF32")
    if elf_data != ELFDATA2LSB:
        raise ElfImageError(
            f"not a little-endian ELF (EI_DATA={elf_data}); readmemh words are LE")

    e_type = _u16(data, 16)
    e_machine = _u16(data, 18)
    e_entry = _u32(data, 24)
    e_phoff = _u32(data, 28)
    e_phentsize = _u16(data, 42)
    e_phnum = _u16(data, 44)

    if e_type != ET_EXEC:
        raise ElfImageError(
            f"ELF type is {e_type}, expected ET_EXEC(2); link with -static")
    if e_machine != EM_RISCV:
        raise ElfImageError(
            f"ELF machine is {e_machine}, expected RISC-V({EM_RISCV})")
    if e_phnum == 0:
        raise ElfImageError("no program headers")
    if e_phentsize != PHDR_SIZE:
        raise ElfImageError(
            f"unexpected program-header size {e_phentsize}, expected {PHDR_SIZE}")
    if e_phoff + e_phnum * e_phentsize > len(data):
        raise ElfImageError("program-header table runs past the end of the ELF")

    segments: list[Segment] = []
    for index in range(e_phnum):
        off = e_phoff + index * e_phentsize
        p_type = _u32(data, off)
        p_offset = _u32(data, off + 4)
        p_vaddr = _u32(data, off + 8)
        p_paddr = _u32(data, off + 12)
        p_filesz = _u32(data, off + 16)
        p_memsz = _u32(data, off + 20)
        if p_type != PT_LOAD or p_memsz == 0:
            continue
        if p_filesz > p_memsz:
            raise ElfImageError(
                f"segment {index}: file size {p_filesz} exceeds memory size {p_memsz}")
        if p_offset + p_filesz > len(data):
            raise ElfImageError(
                f"segment {index}: file range ends at {p_offset + p_filesz} "
                f"past the {len(data)}-byte ELF (truncated)")
        segments.append(Segment(index, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz))

    if not segments:
        raise ElfImageError("no loadable segments with non-zero memory size")
    return segments, e_entry


def build_image(data: bytes, base: int = DEFAULT_BASE,
                limit: int = DEFAULT_LIMIT) -> Image:
    """Return the dense [base, base+size) image encoded by an ELF32 executable."""
    if base < 0:
        raise ElfImageError(f"negative base address 0x{base:x}")
    if limit <= 0:
        raise ElfImageError(f"backing window must be positive, got 0x{limit:x}")

    segments, entry = parse_segments(data)

    for segment in segments:
        if segment.paddr < base:
            raise ElfImageError(
                f"segment {segment.index}: start 0x{segment.paddr:08x} is below the "
                f"image base 0x{base:08x}")
        if segment.mem_end > base + limit:
            raise ElfImageError(
                f"segment {segment.index}: end 0x{segment.mem_end:08x} is outside the "
                f"backing window [0x{base:08x}, 0x{base + limit:08x})")
        if segment.filesz and segment.offset + segment.filesz > len(data):
            raise ElfImageError(
                f"segment {segment.index}: truncated file contents")

    # File-backed ranges must not overlap; a silent overlap would make the image
    # depend on segment order instead of the linker script.
    backed = sorted((s for s in segments if s.filesz), key=lambda s: s.paddr)
    for previous, current in zip(backed, backed[1:]):
        if current.paddr < previous.file_end:
            raise ElfImageError(
                f"segments {previous.index} and {current.index} overlap: "
                f"[0x{previous.paddr:08x}, 0x{previous.file_end:08x}) vs "
                f"[0x{current.paddr:08x}, 0x{current.file_end:08x})")

    start = min(segment.paddr for segment in segments)
    end = max(segment.mem_end for segment in segments)
    span = end - start
    if span > limit:
        raise ElfImageError(
            f"image spans {span} bytes from 0x{start:08x}, larger than the "
            f"{limit}-byte backing window")
    if not (start <= entry < end):
        raise ElfImageError(
            f"entry point 0x{entry:08x} is outside the image "
            f"[0x{start:08x}, 0x{end:08x})")

    image = bytearray(span)
    for segment in segments:
        if not segment.filesz:
            continue
        begin = segment.paddr - start
        image[begin:begin + segment.filesz] = data[segment.offset:segment.offset + segment.filesz]

    # Zero-fill from base to start keeps the readmemh line index equal to
    # (address - base) / 16 even if the linker ever moves the first section.
    lead = start - base
    if lead:
        image = bytearray(lead) + image
    return Image(base=base, data=bytes(image), entry=entry, segments=segments)


def pad16(data: bytes) -> bytes:
    return data + bytes(-len(data) % 16)


def to_readmemh(image: bytes) -> str:
    """128-bit little-endian lines, 32 hex digits each (testbench format)."""
    padded = pad16(image)
    return "".join(
        f"{int.from_bytes(padded[i:i + 16], 'little'):032x}" + "\n"
        for i in range(0, len(padded), 16))


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """Publish a fully formed file; readers never observe a partial image."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp{os.getpid()}")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_write_text(path: Path, text: str) -> None:
    atomic_write_bytes(path, text.encode())


def write_outputs(elf_path: Path, bin_path: Path | None, hex_path: Path | None,
                  base: int, limit: int) -> Image:
    data = Path(elf_path).read_bytes()
    image = build_image(data, base=base, limit=limit)
    if bin_path is not None:
        atomic_write_bytes(bin_path, image.data)
    if hex_path is not None:
        atomic_write_text(hex_path, to_readmemh(image.data))
    return image


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--elf", type=Path, required=True, help="input ELF32 executable")
    parser.add_argument("--bin", type=Path, help="optional dense flat binary output")
    parser.add_argument("--hex", type=Path, help="optional 128-bit readmemh output")
    parser.add_argument("--base", type=lambda v: int(v, 0), default=DEFAULT_BASE,
                        help=f"first address of the image (default 0x{DEFAULT_BASE:08x})")
    parser.add_argument("--limit", type=lambda v: int(v, 0), default=DEFAULT_LIMIT,
                        help=f"backing window size (default 0x{DEFAULT_LIMIT:x})")
    parser.add_argument("--json", action="store_true", help="print image info as JSON")
    args = parser.parse_args(argv)

    if not args.elf.is_file():
        print(f"error: ELF not found: {args.elf}", file=sys.stderr)
        return 1

    try:
        image = write_outputs(args.elf, args.bin, args.hex, args.base, args.limit)
    except (ElfImageError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(image.info(), indent=2))
    else:
        print(f"image: {image.info()['size_bytes']} bytes "
              f"[0x{image.base:08x}, 0x{image.end:08x}), entry 0x{image.entry:08x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
