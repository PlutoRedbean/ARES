#!/usr/bin/env python3
"""Build the ARES L2 board flow for Pango ADS 2022.2-SP6.4.

Steps
  1. scripts/pango_prep.py        interfaces expanded, sv2v -> build/pango/syn/design.v
  2. build_coremark_image.py --board   compact 48 KiB image
  3. copy design.v / coremark_board.hex / ares_2core.fdc / flow_cpu.tcl
     into a Windows-visible working directory (PDS cannot read the WSL repo)
  4. run pds_shell -file flow_cpu.tcl (unless --no-run)
  5. copy logs / reports / bitstream back into build/pango/reports/<project>

Usage
  python3 scripts/pango_build.py                 # prep + image + PDS
  python3 scripts/pango_build.py --no-run        # prep + image + sync only
  python3 scripts/pango_build.py --no-image      # reuse the existing image
  python3 scripts/pango_build.py --work /mnt/c/ares_pango/cpu
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / "build" / "pango" / "syn" / "design.v"
IMAGE = ROOT / "build" / "coremark-board" / "coremark_board.hex"
REPORTS = ROOT / "build" / "pango" / "reports"

SYNC_FILES = (
    "design.v",
    "coremark_board.hex",
    "ares_2core.fdc",
    "flow_cpu.tcl",
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", type=Path, default=Path("/mnt/d/ares_pango/cpu"),
                    help="PDS working directory on a Windows-visible drive "
                         "(default /mnt/d/ares_pango/cpu = D:\\ares_pango\\cpu)")
    ap.add_argument("--pds", type=Path,
                    default=Path("/mnt/d/PDS_2022.2-SP6.4/bin/pds_shell.exe"))
    ap.add_argument("--project", default="ares_cpu")
    ap.add_argument("--no-image", action="store_true", help="reuse the existing board image")
    ap.add_argument("--no-run", action="store_true", help="prepare and sync only")
    args = ap.parse_args()

    print("== pango_prep ==")
    subprocess.run([sys.executable, str(ROOT / "scripts" / "pango_prep.py")], check=True)

    if not args.no_image:
        print("== board image ==")
        subprocess.run([sys.executable, str(ROOT / "scripts" / "build_coremark_image.py"),
                        "--board"], check=True)

    if not DESIGN.is_file() or not IMAGE.is_file():
        print("error: design.v or coremark_board.hex missing", file=sys.stderr)
        return 1

    work = args.work
    work.mkdir(parents=True, exist_ok=True)
    for name in SYNC_FILES:
        src = (ROOT / "build" / "pango" / "syn" / name
               if name == "design.v" else
               IMAGE if name == "coremark_board.hex" else
               ROOT / "fpga" / "pango" / name)
        shutil.copy2(src, work / name)
    print(f"== synced to {work} ==")

    if args.no_run:
        print(f"run manually: cd {work} && {args.pds} -file flow_cpu.tcl "
              f"-project_name {args.project}")
        return 0

    print("== PDS ==")
    subprocess.run([str(args.pds), "-file", "flow_cpu.tcl",
                    "-project_name", args.project], cwd=work)

    dest = REPORTS / args.project
    dest.mkdir(parents=True, exist_ok=True)
    copied = 0
    for pattern in ("*.log", "*.rpt", "*.sbit", "*.txt", "*.prr", "*.pcf"):
        for f in work.rglob(pattern):
            if f.is_file():
                target = dest / f.name
                shutil.copy2(f, target)
                copied += 1
    print(f"== {copied} artefacts copied to {dest} ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
