#!/usr/bin/env python3
"""Run the board-level power-on check on the converted RTL.

Two modes:
  --sv      (default) build from build/pango/syn/sv (expanded SystemVerilog);
            this checks that interface expansion + fixups preserve behaviour.
  --design  build from build/pango/syn/design.v (the exact file PDS compiles).

The bench runs at 27 MHz, releases reset after 200 us, decodes uart_tx at
115200 8N1 and prints the console output.  PASS means both harts retired an
EBREAK and the UART produced a CoreMark result block.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TB = ROOT / "sim" / "tb_pango_board.sv"
SV_ROOT = ROOT / "build" / "pango" / "syn" / "sv" / "rtl"
DESIGN = ROOT / "build" / "pango" / "syn" / "design.v"
IMAGE_DIR = ROOT / "build" / "coremark-board"
OUT = ROOT / "build" / "sim" / "board"

# Packages and interfaces must be seen before their users.
ORDER = (
    "common/fe_pkg.sv",
    "common/ares_pkg.sv",
    "common/lsu_pkg.sv",
    "frontend/bpu/direction/tage_pkg.sv",
    "l2/l2_pkg.sv",
    "frontend/interface/axi_if.sv",
    "frontend/interface/miniTensor_if.sv",
    "frontend/interface/axi_l2_bridge.sv",
)


def sv_sources() -> list[Path]:
    ordered = [SV_ROOT / p for p in ORDER]
    rest = sorted(p for p in SV_ROOT.rglob("*.sv")
                  if p not in ordered and "/test/" not in p.as_posix())
    return ordered + rest


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--design", action="store_true",
                    help="simulate design.v (the sv2v output PDS consumes)")
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()

    if not IMAGE_DIR.joinpath("coremark_board.hex").is_file():
        print("error: build/coremark-board/coremark_board.hex missing; run "
              "scripts/build_coremark_image.py --board", file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    if args.design:
        sources = [str(TB), str(DESIGN)]
        extra: list[str] = []
    else:
        sources = [str(TB)] + [str(p) for p in sv_sources()]
        extra = ["-DCONFIG_SIMULATION",
                 "-DARES_ICACHE_BEHAVIORAL", "-DARES_DCACHE_BEHAVIORAL",
                 f"-I{ROOT / 'configs/build/vsrc/include'}"]

    build = ["verilator", "--binary", f"-j{args.jobs}", "-Wno-fatal", "-Wno-lint",
             "--top-module", "tb_pango_board", *sources,
             "--Mdir", str(OUT), "-o", "ares-board-sim", *extra]
    print("[sim] " + " ".join(build[:6]) + " ...")
    if subprocess.run(build).returncode != 0:
        return 1

    log = OUT / "board_sim.log"
    with log.open("w") as f:
        rc = subprocess.run([str(OUT / "ares-board-sim")], cwd=IMAGE_DIR,
                            stdout=f, stderr=subprocess.STDOUT).returncode
    text = log.read_text(errors="replace")
    sys.stdout.write(text[-4000:])
    return 0 if ("[board] PASS" in text and rc == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
