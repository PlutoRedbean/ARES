#!/usr/bin/env python3
"""Core-only Pango timing run (ares_core_top: Backend + LSU).

PDS cannot read the WSL repository, so design.v and the constraints are copied
to a Windows-visible directory (default D:\\ares_pango\\core), PDS is run there,
and logs/reports are copied back to build/pango/reports/<project>.

Usage:
  python3 scripts/pango_core_timing.py              # full flow in background
  python3 scripts/pango_core_timing.py --no-run     # sync only
  python3 scripts/pango_core_timing.py --period 20  # 50 MHz constraint
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / "build" / "pango" / "syn" / "design.v"
REPORTS = ROOT / "build" / "pango" / "reports"
FDC = ROOT / "fpga" / "pango" / "ares_core.fdc"
TCL = ROOT / "fpga" / "pango" / "flow_core.tcl"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", type=Path, default=Path("/mnt/d/ares_pango/core"))
    ap.add_argument("--pds", type=Path,
                    default=Path("/mnt/d/PDS_2022.2-SP6.4/bin/pds_shell.exe"))
    ap.add_argument("--project", default="ares_core")
    ap.add_argument("--period", type=float, default=None,
                    help="clock period in ns written into the synced fdc")
    ap.add_argument("--no-run", action="store_true")
    args = ap.parse_args()

    if not DESIGN.is_file():
        print("error: design.v missing; run scripts/pango_prep.py first",
              file=sys.stderr)
        return 1

    args.work.mkdir(parents=True, exist_ok=True)
    shutil.copy2(DESIGN, args.work / "design.v")

    fdc_text = FDC.read_text()
    if args.period is not None:
        fdc_text = re.sub(r"create_clock -name sys_clk -period [\d.]+",
                          f"create_clock -name sys_clk -period {args.period:.3f}",
                          fdc_text)
        fdc_text = re.sub(r"-waveform \{[^}]*\}",
                          f"-waveform {{0.000 {args.period / 2:.3f}}}", fdc_text)
    (args.work / "ares_core.fdc").write_text(fdc_text)
    shutil.copy2(TCL, args.work / "flow_core.tcl")
    print(f"== synced to {args.work} (period "
          f"{args.period if args.period else 'from file'} ns) ==")

    if args.no_run:
        return 0

    print("== PDS: compile -> synthesize -> dev_map -> pnr -> report_timing ==")
    subprocess.run([str(args.pds), "-file", "flow_core.tcl",
                    "-project_name", args.project], cwd=args.work)

    dest = REPORTS / args.project
    dest.mkdir(parents=True, exist_ok=True)
    copied = 0
    for pattern in ("*.log", "*.rpt", "*.txt", "*.prr", "*.pcf"):
        for f in args.work.rglob(pattern):
            if f.is_file():
                shutil.copy2(f, dest / f.name)
                copied += 1
    print(f"== {copied} artefacts copied to {dest} ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
