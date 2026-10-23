#!/usr/bin/env python3
"""Prepare/replay cache BRAM synthesis and vendor-model contract tests."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

import create_project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="build/vivado/cache-ip")
    args = parser.parse_args()
    options = argparse.Namespace(cpu_mhz=250., jobs=1, profile="core", stage="synth",
        manifest="fpga/vivado/probes/cache_data.json", config="configs/defconfig",
        output=args.output, with_pll=False, allow_version_mismatch=False,
        irom_coe=None, dram_coe=None)
    out = create_project.prepare(options)
    root = create_project.ROOT
    tests = [root/"rtl/frontend/test/tb_icache_way.sv",
             root/"rtl/memory/test/unit/tb_dcache_arrays.sv",
             root/"rtl/memory/test/unit/tb_dcache_top.sv",
             Path(__file__).with_suffix(".tcl")]
    snapshot = out/"verification_inputs"
    snapshot.mkdir()
    (out/"verification_results").mkdir()
    hashes = {}
    for source in tests:
        dest = snapshot/source.name
        shutil.copy2(source, dest)
        hashes[str(dest.relative_to(out))] = hashlib.sha256(dest.read_bytes()).hexdigest()
    (out/"verification_inputs.json").write_text(json.dumps(hashes, indent=2)+"\n")
    (out/"verify.tcl").write_text(
        'set verify_dir [file dirname [file normalize [info script]]]\n'
        'source [file join $verify_dir generate.tcl]\n'
        'source [file join $verify_dir verification_inputs verify_cache_ip.tcl]\n')
    print(f"Prepared {out}; run vivado -mode batch -source {out/'verify.tcl'}")


if __name__ == "__main__":
    main()
