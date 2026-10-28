#!/usr/bin/env python3
"""Build the minimal hello image for the Pango board flow.

Stages tests/benchmarks/hello into build/hello/port, builds it with
ARES_BOARD=1 (compact ares-board-linker.ld), then writes the 48 KiB board
RAM image (ELF image + hart1 data copy) with elf_image.board_image.

Usage:
  python3 scripts/build_hello_image.py
  python3 scripts/build_hello_image.py --no-build   # reconvert only
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import elf_image  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "tests" / "benchmarks" / "hello"
OUT = ROOT / "build" / "hello"
ELF_NAME = "hello-riscv32-ares.elf"
CROSS = "riscv64-unknown-elf-"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--cross-compile", default=CROSS)
    ap.add_argument("--jobs", type=int)
    args = ap.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    stage = OUT / "port"
    if not args.no_build:
        if stage.exists():
            shutil.rmtree(stage)
        shutil.copytree(SRC, stage,
                        ignore=shutil.ignore_patterns("build", "__pycache__"))
        cmd = ["make", "-C", str(stage), f"ARES_HOME={ROOT}",
               "ARCH=riscv32-ares", f"CROSS_COMPILE={args.cross_compile}",
               "ARES_BOARD=1"]
        if args.jobs:
            cmd.append(f"-j{args.jobs}")
        cmd.append("image")
        result = subprocess.run(cmd, capture_output=True, text=True)
        (OUT / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode != 0:
            print((result.stdout + result.stderr)[-2000:], file=sys.stderr)
            return 1

    elf = stage / "build" / ELF_NAME
    if not elf.is_file():
        print(f"error: {elf} not found", file=sys.stderr)
        return 1

    kept = OUT / ELF_NAME
    shutil.copyfile(elf, kept)
    image = elf_image.write_outputs(kept, OUT / "hello.bin", OUT / "hello.hex",
                                    base=elf_image.DEFAULT_BASE,
                                    limit=elf_image.DEFAULT_LIMIT)
    board = elf_image.board_image(image)
    elf_image.atomic_write_text(OUT / "hello_board.hex", elf_image.to_readmemh(board))

    print(f"hello: {len(image.data)} bytes [0x{image.base:08x}, 0x{image.end:08x})")
    print(f"  elfcopy {kept.relative_to(ROOT)}")
    print(f"  board   build/hello/hello_board.hex "
          f"({elf_image.BOARD_RAM_BYTES // 1024} KiB window)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
