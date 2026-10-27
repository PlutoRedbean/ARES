#!/usr/bin/env python3
"""Prove that the L2 reference-model testbench detects real corruption.

Each mutation below is one plausible RTL defect in l2_top.sv.  The testbench
must fail for every one of them: a mutant that still passes means the checker
is not discriminating (the failure mode SPEC-D13 records for the old frontend
testbench).  The unmodified RTL must pass first, so a failing mutant can only
be caused by the injected defect.

Usage: make test-l2-ref-faults    (or python3 scripts/test_l2_ref_faults.py)
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

# name, exact text in l2_top.sv, replacement, expected diagnostic
MUTATIONS = [
    ("writeback goes to the next set",
     "wire [31:0] mem_wb_addr = {victim_tag, req_set, wb_beat, 4'b0000};",
     "wire [31:0] mem_wb_addr = {victim_tag, req_set, wb_beat, 4'b0000} ^ 32'h40;",
     "L2 REF"),
    ("read miss returns the wrong beat",
     "if (!req_write && (rf_beat == req_beat))",
     "if (!req_write && (rf_beat != req_beat))",
     "L2 REF"),
    ("dirty bit never installed",
     "dirty_mem[req_set][victim_way] <= req_write;",
     "dirty_mem[req_set][victim_way] <= 1'b0;",
     "L2 REF"),
    ("byte enables inverted on merge",
     "if (be[i]) v[8*i +: 8] = new_data[8*i +: 8];",
     "if (!be[i]) v[8*i +: 8] = new_data[8*i +: 8];",
     "L2 REF"),
    ("corrupted victim tag leaves the window",
     "wire [31:0] mem_wb_addr = {victim_tag, req_set, wb_beat, 4'b0000};",
     "wire [31:0] mem_wb_addr = {victim_tag | {TAG_W{1'b1}}, req_set, wb_beat, 4'b0000};",
     "outside"),
]


def run_build(root: Path, l2_top: Path, mdir: Path) -> tuple[bool, str]:
    sources = [
        root / "rtl/l2/l2_pkg.sv",
        l2_top,
        root / "rtl/l2/test/l2_ref_model.sv",
        root / "rtl/l2/test/tb_l2_ref.sv",
    ]
    cmd = [
        os.environ.get("VERILATOR", "verilator"), "--binary", "--timing", "-sv",
        "--assert", "-Wall", "-Wno-DECLFILENAME", "-Wno-TIMESCALEMOD",
        "-Wno-SIDEEFFECT", "-Wno-BLKSEQ", "-Wno-PINCONNECTEMPTY",
        "-DCONFIG_SIMULATION", "--top-module", "tb_l2_ref",
        "--Mdir", str(mdir), "-o", str(mdir / "tb_l2_ref"),
        *[str(source) for source in sources],
    ]
    env = {k: v for k, v in os.environ.items() if k != "CCACHE_DIR"}
    env["CCACHE_DISABLE"] = "1"
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    log = result.stdout + result.stderr
    (mdir / "build.log").write_text(log)
    return result.returncode == 0, log


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", type=Path, default=root / "build/verification/l2-ref-faults",
                        help="work directory (git-ignored)")
    args = parser.parse_args()

    work = args.work.resolve()
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    original = (root / "rtl/l2/l2_top.sv").read_text()
    rtl_copy = work / "l2_top_base.sv"
    rtl_copy.write_text(original)

    print("[baseline] unmodified l2_top")
    ok, log = run_build(root, rtl_copy, work / "base")
    if not ok:
        print(log[-2000:])
        print("error: baseline build failed")
        return 1
    run = subprocess.run([str(work / "base/tb_l2_ref")], capture_output=True, text=True)
    if run.returncode != 0 or "ALL TESTS PASSED" not in run.stdout:
        print(run.stdout[-2000:] + run.stderr[-2000:])
        print("error: baseline testbench failed on unmodified RTL")
        return 1
    print("PASS: baseline")

    failures = 0
    for name, old, new, marker in MUTATIONS:
        if original.count(old) != 1:
            print(f"FAIL: mutation {name!r}: anchor text appears {original.count(old)} times")
            failures += 1
            continue
        mutant_dir = work / name.replace(" ", "-")
        mutant = mutant_dir / "l2_top.sv"
        mutant_dir.mkdir(parents=True)
        mutant.write_text(original.replace(old, new))
        built, log = run_build(root, mutant, mutant_dir / "obj")
        if not built:
            print(f"FAIL: mutation {name!r} did not compile")
            print(log[-1500:])
            failures += 1
            continue
        run = subprocess.run([str(mutant_dir / "obj/tb_l2_ref")],
                             capture_output=True, text=True)
        output = run.stdout + run.stderr
        detected = run.returncode != 0 and marker in output
        if detected:
            first = next((line for line in output.splitlines() if marker in line or "FAIL:" in line), "")
            print(f"PASS: {name} -> {first.strip()[:110]}")
        else:
            print(f"FAIL: {name} was NOT detected (exit={run.returncode})")
            failures += 1

    if failures:
        print(f"\n{failures} mutation(s) not detected")
        return 1
    print(f"\nALL MUTANTS DETECTED: {len(MUTATIONS)} defects caught by the reference model")
    return 0


if __name__ == "__main__":
    sys.exit(main())
