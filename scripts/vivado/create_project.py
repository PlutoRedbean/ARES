#!/usr/bin/env python3
"""Generate a clean ARES Vivado project from the checked-in JYD settings."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "fpga/vivado"


def tcl(value):
    """One Tcl word, including literal $, brackets, quotes and newlines."""
    s = str(value)
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace(
        '$', '\\$').replace('[', '\\[').replace(']', '\\]').replace(
        '\n', '\\n').replace('\r', '\\r') + '"'


def checked_file(path):
    p = Path(path)
    p = (ROOT / p).resolve() if not p.is_absolute() else p.resolve()
    if not p.is_file():
        raise ValueError(f"missing input file: {p}")
    check_vendor_path(p)
    return p


def check_vendor_path(path):
    # Tcl quoting does not remove vendor restrictions on HDL file names.
    if any(c in str(path) for c in "$[]\n\r"):
        raise ValueError(f"Vivado does not support $, [, ], or newline in file paths: {path}")


def prepare(args):
    if not math.isfinite(args.cpu_mhz) or args.cpu_mhz <= 200:
        raise ValueError("--cpu-mhz must be finite and strictly above 200")
    if args.jobs < 1:
        raise ValueError("--jobs must be positive")
    if args.profile != "board" and args.stage == "route":
        raise ValueError("route/sign-off requires the board profile and a complete board top")
    extra = {}
    if args.manifest:
        extra = json.loads(checked_file(args.manifest).read_text())
        unknown = set(extra) - {"sources", "include_dirs", "constraints", "ip_recipes", "top"}
        if unknown:
            raise ValueError(f"unknown manifest keys: {sorted(unknown)}")
    if args.profile == "board" and not args.manifest:
        raise ValueError("board profile requires --manifest (use fpga/board.json for the first board baseline)")
    top = extra.get("top", "ares_core_top" if args.profile == "core" else "student_top")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", top):
        raise ValueError("invalid top module name")
    sources = [ROOT / "rtl/common/fe_pkg.sv", ROOT / "rtl/common/ares_pkg.sv", ROOT / "rtl/common/lsu_pkg.sv"]
    for directory in ["rtl/backend", "rtl/memory"]:
        sources += sorted((ROOT / directory).glob("*.sv"))
    sources.append(ROOT / "rtl/top/ares_core_top.sv")
    if args.profile != "core":
        sources += [ROOT / "rtl/frontend/interface/axi_if.sv", ROOT / "rtl/frontend/interface/miniTensor_if.sv"]
        for directory in ["rtl/frontend", "rtl/frontend/bpu", "rtl/frontend/bpu/direction", "rtl/frontend/bpu/target", "rtl/frontend/ifu"]:
            sources += sorted((ROOT / directory).glob("*.sv"))
        sources.append(ROOT / "rtl/top/ares_cpu_top.sv")
        sources += sorted((ROOT / "rtl/soc/jyd").glob("*.sv"))
        sources.append(ROOT / "rtl/top/student_top.sv")
    sources += [checked_file(p) for p in extra.get("sources", [])]
    sources = list(dict.fromkeys(checked_file(p) for p in sources))
    if not any(re.search(r"\bmodule\s+" + re.escape(top) + r"\b", p.read_text()) for p in sources):
        raise ValueError(f"top module {top} is absent from the selected sources")
    includes = []
    for p in extra.get("include_dirs", []):
        d = (ROOT / p).resolve()
        if not d.is_dir():
            raise ValueError(f"missing include directory: {d}")
        includes.append(d)
    constraints = [checked_file(p) for p in extra.get("constraints", [])]
    if args.profile == "board":
        if top != "top":
            raise ValueError("board profile must retain the physical top module 'top'")
        constraints.insert(0, ASSETS / "constraints/board.xdc")
    recipes = [ASSETS / "ip/cache_data.tcl"]
    if args.profile != "core":
        recipes.append(ASSETS / "ip/memories.tcl")
    if args.with_pll or args.profile == "board":
        recipes.append(ASSETS / "ip/pll.tcl")
    recipes += [checked_file(p) for p in extra.get("ip_recipes", [])]
    config_file = checked_file(args.config)
    irom = checked_file(args.irom_coe) if args.irom_coe else None
    dram = checked_file(args.dram_coe) if args.dram_coe else None
    for image, width, depth in [(irom, 64, 4096), (dram, 32, 65536)]:
        if image:
            validate_coe(image, width, depth)
    if args.profile == "board" and args.stage != "generate" and not (irom and dram):
        raise ValueError("board synth/route requires both --irom-coe and --dram-coe startup images")
    spec = importlib.util.spec_from_file_location("ares_kconfig", ROOT / "scripts/kconfig/ares_kconfig.py")
    kc = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = kc
    spec.loader.exec_module(kc)
    cfg = kc.build_config()
    kc.resolve(cfg, kc.load_dot_config(config_file))
    symbols = kc.emitted_symbols(cfg)
    if args.profile != "core" and (symbols.get("FE_FETCH_WIDTH") != 4 or
            symbols.get("FE_DECODE_WIDTH") != 2 or not symbols.get("IO_USE_AXI")):
        raise ValueError("C5 SoC requires Fetch=4, Decode=2 and IO_USE_AXI=y")
    defines = [f"CONFIG_{name}={kc.sv_value(value)}" for name, value in sorted(symbols.items())]
    out = Path(args.output).resolve()
    check_vendor_path(out)
    if out.exists():
        raise ValueError(f"output already exists: {out}; use a new directory (nothing is overwritten)")
    tree = ET.parse(ASSETS / "baseline.xml")
    project = tree.getroot()
    project.set("Path", str(out / "ares.xpr"))
    ET.SubElement(project.find("Configuration"), "Option", Name="Id", Val=uuid.uuid4().hex)
    for name in ("sources_1", "sim_1"):
        project.find(f"FileSets/FileSet[@Name='{name}']/Config/Option[@Name='TopModule']").set("Val", top)
    out.mkdir(parents=True)
    tree.write(out / "ares.xpr", encoding="UTF-8", xml_declaration=True)
    # Each build has a self-contained input snapshot, independent of later edits
    # in a teammate's checkout. Generated IP and vendor outputs stay in out/.
    copied = {}
    inputs = sources + constraints + recipes + [config_file, ASSETS / "baseline.xml",
        ROOT / "configs/Kconfig", ROOT / "configs/frontend/Kconfig", ROOT / "scripts/kconfig/ares_kconfig.py",
        Path(__file__), Path(__file__).with_name("generate.tcl")]
    if args.manifest:
        inputs.append(checked_file(args.manifest))
    if irom:
        inputs.append(irom)
    if dram:
        inputs.append(dram)
    for p in dict.fromkeys(inputs):
        try:
            relative = p.relative_to(ROOT)
        except ValueError:
            relative = Path("external") / hashlib.sha256(str(p).encode()).hexdigest()[:12] / p.name
        dest = out / "inputs" / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(p, dest)
        copied[p] = dest
    # Include trees can contain nested includes/data. Snapshot complete trees.
    inc_snapshots = []
    for index, p in enumerate(includes):
        dest = out / "includes" / str(index)
        shutil.copytree(p, dest)
        inc_snapshots.append(dest)
    cfg_include = out / "includes/config"
    cfg_include.mkdir(parents=True)
    (cfg_include / "ares_autoconf.vh").write_text("".join(
        f"`ifndef CONFIG_{name}\n`define CONFIG_{name} {kc.sv_value(value)}\n`endif\n"
        for name, value in sorted(symbols.items())))
    inc_snapshots.append(cfg_include)
    values = {
        "ares_project": out / "ares.xpr", "ares_profile": args.profile,
        "ares_top": top, "ares_stage": args.stage, "ares_jobs": args.jobs,
        "ares_cpu_mhz": args.cpu_mhz, "ares_allow_version_mismatch": int(args.allow_version_mismatch),
        "ares_irom_coe": copied[irom] if irom else "",
        "ares_dram_coe": copied[dram] if dram else "",
        "ares_icache_line_bits": symbols["FE_ICACHE_LINE_BYTES"] * 8,
        "ares_icache_sets": symbols["FE_ICACHE_NR_SETS"],
    }
    def word(value):
        if isinstance(value, Path):
            return "[file join $ares_build_dir " + tcl(value.relative_to(out)) + "]"
        return tcl(value)

    lines = ["set ares_build_dir [file dirname [file normalize [info script]]]" ]
    lines += [f"set {key} {word(value)}" for key, value in values.items()]
    for key, values in {
        "ares_sources": [copied[p] for p in sources],
        "ares_constraints": [copied[p] for p in constraints],
        "ares_recipes": [copied[p] for p in recipes],
        "ares_include_dirs": inc_snapshots, "ares_defines": defines,
    }.items():
        lines.append(f"set {key} [list " + " ".join(word(v) for v in values) + "]")
    lines.append("source " + word(copied[Path(__file__).with_name("generate.tcl")]))
    (out / "generate.tcl").write_text("\n".join(lines) + "\n")
    provenance = {
        "profile": args.profile, "top": top, "cpu_mhz_requested": args.cpu_mhz,
        "stage": args.stage, "jobs": args.jobs, "config": symbols,
        "inputs": {str(dest.relative_to(out)): hashlib.sha256(dest.read_bytes()).hexdigest()
                   for dest in copied.values()},
        "include_inputs": {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for d in inc_snapshots for p in sorted(d.rglob("*")) if p.is_file()},
        "expected_vivado": "2025.2", "ppa_verified": False,
    }
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                              text=True, capture_output=True, check=False)
    status = subprocess.run(["git", "status", "--porcelain=v1"], cwd=ROOT,
                            text=True, capture_output=True, check=False)
    provenance["source_revision"] = revision.stdout.strip() if revision.returncode == 0 else None
    provenance["worktree_dirty"] = bool(status.stdout) if status.returncode == 0 else None
    (out / "inputs.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return out


def validate_coe(path, width, depth):
    text = re.sub(r"//[^\n]*", "", path.read_text())
    match = re.fullmatch(r"\s*memory_initialization_radix\s*=\s*(2|10|16)\s*;\s*"
                         r"memory_initialization_vector\s*=\s*(.*?)\s*;\s*", text, re.I | re.S)
    if not match:
        raise ValueError(f"invalid COE syntax: {path}")
    words = [w.strip() for w in match[2].split(",")]
    if not words or len(words) > depth:
        raise ValueError(f"COE exceeds {depth} words: {path}")
    try:
        if any(not w or not 0 <= int(w, int(match[1])) < 2**width for w in words):
            raise ValueError()
    except ValueError:
        raise ValueError(f"invalid or oversized {width}-bit COE word: {path}") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["core", "soc", "board"], default="soc")
    parser.add_argument("--cpu-mhz", type=float, required=True, help="explicit >200MHz CPU target; not an achieved frequency")
    parser.add_argument("--output", default=str(ROOT / "build/vivado/ares"))
    parser.add_argument("--config", default="configs/defconfig")
    parser.add_argument("--manifest", help="additive JSON source/include/constraint/IP manifest, paths relative to repo")
    parser.add_argument("--with-pll", action="store_true", help="also generate board PLL (unused by the OOC top)")
    parser.add_argument("--irom-coe", help="64-bit COE, 4096 words maximum; no image defaults to zero-filled ROM")
    parser.add_argument("--dram-coe", help="32-bit COE, 65536 words maximum; no image defaults to zero-filled RAM")
    parser.add_argument("--stage", choices=["generate", "synth", "route"], default="generate")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--prepare-only", action="store_true", help="write inputs/Tcl/XPR without launching Vivado")
    parser.add_argument("--allow-version-mismatch", action="store_true", help="explicitly permit an unverified vendor-tool version")
    args = parser.parse_args(argv)
    try:
        if not args.prepare_only and shutil.which(args.vivado) is None:
            raise ValueError(f"Vivado executable not found: {args.vivado}")
        out = prepare(args)
        command = [args.vivado, "-mode", "batch", "-nojournal", "-log", str(out / "vivado.log"),
                   "-source", str(out / "generate.tcl")]
        print(f"Project: {out / 'ares.xpr'}", flush=True)
        if args.prepare_only:
            print("Inputs prepared; Vivado/IP generation has not run.")
            return 0
        return subprocess.run(command, cwd=out, check=False).returncode
    except (ValueError, OSError, ET.ParseError) as e:
        parser.exit(2, f"error: {e}\n")


if __name__ == "__main__":
    sys.exit(main())
