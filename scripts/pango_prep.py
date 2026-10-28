#!/usr/bin/env python3
"""Mechanical SystemVerilog -> Verilog-2005 preparer for the Pango ADS flow.

WHY
---
Pango Design Suite 2022.2-SP6.4 (ADS) rejects SystemVerilog interfaces
("Verilog-4204: SystemVerilog Interface is not supported yet") and enumerations
("Verilog-4203"), and it cannot resolve references into generate/named-block
scopes.  sv2v converts the rest of the language cleanly, but it implements
interfaces by inlining every interface-using module into its parent and
connecting through hierarchical names such as `ares_cpu_top.ifetch_bus.araddr`.
ADS rejects exactly those ("Verilog-4123: Could not resolve hierarchical name"),
and stripping the module prefix does not help.

So interfaces are expanded BEFORE sv2v runs: every `axi_if.master foo` port
becomes one explicit port per interface signal (`foo_araddr`, `foo_arvalid`, ...)
with the direction taken from the modport, every interface instance becomes a
flat wire bundle, and every `.port(iface)` connection becomes one connection per
signal.  sv2v then sees a design with no interfaces, so it never inlines
anything and the module hierarchy is preserved.

The originals under rtl/ are never modified.  The output tree is regenerated
from scratch on every run (idempotent).

PIPELINE
--------
  rtl/**/*.sv (synthesis set)
      -> build/pango/syn/sv/rtl/**/*.sv   interface expansion + ADS fixups
      -> sv2v                             Verilog-2005
      -> build/pango/syn/design.v         one file for `add_design`

ADS fixups applied to the expanded copies (each one is reported):
  * SV functions with `output` arguments   -> packed {found, value} return
  * behavioural cache RAMs                 -> -D ARES_ICACHE_BEHAVIORAL,
                                              -D ARES_DCACHE_BEHAVIORAL for sv2v
    (ADS infers the memories; the Vivado IPs do not exist in this flow)

Usage:
  python3 scripts/pango_prep.py [--check]
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
OUT = ROOT / "build" / "pango" / "syn"
SV_OUT = OUT / "sv" / "rtl"
V_OUT = OUT / "design.v"
NOTES = OUT / "PORT_NOTES.md"
AUTOCONF = ROOT / "configs" / "build" / "vsrc" / "include"

INTERFACE_DIR = RTL / "frontend" / "interface"

# Synthesis set for ares_pango_board (ares_2core_frontend_l2_top + board top).
SOURCE_DIRS = ("common", "frontend", "backend", "memory", "l2", "board")
SOURCE_FILES = (
    "top/ares_core_top.sv",
    "top/ares_frontend_hart.sv",
    "top/ares_2core_frontend_l2_top.sv",
)
EXCLUDED_DIRS = ("frontend/report",)
EXCLUDED_FILES = (
    "top/ares_cpu_top.sv",
    "top/ares_soc_top.sv",
    "top/student_top.sv",
    "top/ares_frontend_l2_top.sv",
    "top/ares_2core_l2_top.sv",
)

# sv2v defines: behavioural cache arrays instead of the Vivado BMG IPs.
SV2V_DEFINES = ("ARES_ICACHE_BEHAVIORAL", "ARES_DCACHE_BEHAVIORAL")


# --------------------------------------------------------------------------- #
# interface model
# --------------------------------------------------------------------------- #
class Interface:
    def __init__(self, name: str, widths: dict[str, tuple[int, int] | None],
                 modports: dict[str, dict[str, str]]):
        self.name = name
        self.widths = widths          # signal -> (msb, lsb), or None for scalar
        self.modports = modports      # modport -> signal -> direction

    def port_decl(self, signal: str, direction: str, prefix: str) -> str:
        rng = self.widths[signal]
        span = "" if rng is None else f"[{rng[0]}:{rng[1]}] "
        return f"{direction} wire {span}{prefix}_{signal}"


def parse_interface(path: Path) -> Interface:
    text = path.read_text()
    name = re.search(r"interface\s+(\w+)", text).group(1)
    params = {m.group(1): int(m.group(2))
              for m in re.finditer(r"parameter\s+int\s+unsigned\s+(\w+)\s*=\s*(\d+)", text)}

    def evaluate(expr: str) -> int:
        def repl(m: re.Match) -> str:
            key = m.group(0)
            if key in params:
                return str(params[key])
            raise SystemExit(f"{path}: unsupported identifier {key!r} in range {expr!r}")
        return int(eval(re.sub(r"[A-Za-z_]\w*", repl, expr), {"__builtins__": {}}))  # noqa: S307

    body = text[text.index(");") + 2:] if ");" in text else text
    widths: dict[str, tuple[int, int] | None] = {}
    for m in re.finditer(r"logic\s*(\[[^\]]*\])?\s*(\w+)\s*;", body):
        rng, sig = m.group(1), m.group(2)
        if rng is None:
            widths[sig] = None
            continue
        parts = [p.strip() for p in rng.strip()[1:-1].split(":")]
        if len(parts) != 2:
            raise SystemExit(f"{path}: cannot parse range {rng}")
        widths[sig] = (evaluate(parts[0]), evaluate(parts[1]))

    modports: dict[str, dict[str, str]] = {}
    for m in re.finditer(r"modport\s+(\w+)\s*\((.*?)\)\s*;", text, re.S):
        mp, mp_body = m.group(1), m.group(2)
        directions: dict[str, str] = {}
        for item in mp_body.split(","):
            bits = item.split()
            if len(bits) >= 2 and bits[0] in ("input", "output", "inout"):
                directions[bits[1]] = bits[0]
        missing = set(widths) - set(directions)
        if missing:
            raise SystemExit(f"{path}: modport {mp} misses {sorted(missing)}")
        modports[mp] = directions
    return Interface(name, widths, modports)


def load_interfaces() -> dict[str, Interface]:
    ifaces = {}
    for f in ("axi_if.sv", "miniTensor_if.sv"):
        iface = parse_interface(INTERFACE_DIR / f)
        ifaces[iface.name] = iface
    return ifaces


# --------------------------------------------------------------------------- #
# source selection
# --------------------------------------------------------------------------- #
def sources(extra_dirs: tuple[str, ...] = (), extra_files: tuple[str, ...] = (),
            everything: bool = False) -> list[Path]:
    dirs = tuple(dict.fromkeys(SOURCE_DIRS + extra_dirs))
    if everything:
        dirs = tuple(sorted({p.name for p in RTL.iterdir() if p.is_dir()}))
    files: list[Path] = []
    for d in dirs:
        files += [p for p in sorted((RTL / d).rglob("*.sv")) if "/test/" not in p.as_posix()]
    explicit = {f for f in tuple(dict.fromkeys(SOURCE_FILES + extra_files))}
    files += [RTL / f for f in explicit]
    keep = []
    for p in files:
        rel = p.relative_to(RTL).as_posix()
        if any(rel.startswith(d) for d in EXCLUDED_DIRS):
            continue
        if rel in EXCLUDED_FILES and rel not in explicit:
            continue
        # Interface definition files are parsed by load_interfaces(); sv2v does
        # not need them once every port has been expanded.
        if re.search(r"(?m)^\s*interface\s+\w+", p.read_text(errors="replace")):
            continue
        keep.append(p)
    return keep


# --------------------------------------------------------------------------- #
# interface expansion
# --------------------------------------------------------------------------- #
def expand_interfaces(text: str, ifaces: dict[str, Interface], report: list[str],
                      relpath: str) -> str:
    for name, iface in ifaces.items():
        # Names of this interface type in the file (ports and instances),
        # collected before any rewrite.
        port_decls = re.findall(rf"^\s*{name}(?:\.(\w+))?\s+(\w+)\s*,?\s*$", text, re.M)
        inst_decls = re.findall(rf"^\s*{name}\s+(\w+)\s*\(\s*\)\s*;", text, re.M)
        if not port_decls and not inst_decls:
            continue
        names = {p[1] for p in port_decls} | set(inst_decls)
        exprs = "|".join(sorted(names, key=len, reverse=True))

        # 1. module ports: `<iface>.<modport> <name>,`
        def port_sub(m: re.Match) -> str:
            modport, pname, comma = m.group(1), m.group(2), m.group(3)
            if modport is None:
                raise SystemExit(f"{relpath}: interface port without modport: {m.group(0)!r}")
            decls = [iface.port_decl(sig, iface.modports[modport][sig], pname)
                     for sig in iface.modports[modport]]
            report.append(f"{relpath}: port {name}.{modport} {pname} -> "
                          f"{len(decls)} explicit ports")
            return "    " + ",\n    ".join(decls) + comma
        text = re.sub(rf"^\s*{name}(?:\.(\w+))?\s+(\w+)\s*(,?)\s*$",
                      port_sub, text, flags=re.M)

        # 2. interface instances: `<iface> name ();` -> flat wires
        def inst_sub(m: re.Match) -> str:
            pname = m.group(1)
            decls = []
            for sig, rng in iface.widths.items():
                span = "" if rng is None else f"[{rng[0]}:{rng[1]}] "
                decls.append(f"wire {span}{pname}_{sig};")
            report.append(f"{relpath}: instance {name} {pname} -> {len(decls)} wires")
            return "    " + "\n    ".join(decls)
        text = re.sub(rf"^\s*{name}\s+(\w+)\s*\(\s*\)\s*;\s*$", inst_sub, text, flags=re.M)

        # 3. `.port(iface_expr)` -> one connection per interface signal
        def conn_sub(m: re.Match) -> str:
            port, expr = m.group(1), m.group(2)
            parts = [f".{port}_{sig}({expr}_{sig})" for sig in iface.widths]
            report.append(f"{relpath}: connection .{port}({expr}) -> {len(parts)} signals")
            return ", ".join(parts)
        text = re.sub(rf"\.(\w+)\s*\(\s*({exprs})\s*\)", conn_sub, text)

        # 4. `iface.sig` -> `iface_sig`
        def member_sub(m: re.Match) -> str:
            whole, sig = m.group(0), m.group(1)
            if sig not in iface.widths:
                return whole
            return f"{whole.rsplit('.', 1)[0]}_{sig}"
        text = re.sub(rf"\b(?:{exprs})\.(\w+)\b", member_sub, text)
    return text


# --------------------------------------------------------------------------- #
# ADS fixups
# --------------------------------------------------------------------------- #
PICK_PORT_OLD = """    function automatic logic pick_port(input fu_type_t ft, input logic smul_eligible,
                                       input logic credit_ok, input logic [7:0] rem,
                                       output logic [2:0] port);"""
PICK_PORT_NEW = """    // ADS rejects functions with output arguments (Verilog-4017); return
    // {found, port} instead and unpack at the single call site.
    function automatic logic [3:0] pick_port(input fu_type_t ft, input logic smul_eligible,
                                             input logic credit_ok, input logic [7:0] rem);"""


def fix_functions(text: str, report: list[str], relpath: str) -> str:
    if PICK_PORT_OLD in text:
        text = text.replace(PICK_PORT_OLD, PICK_PORT_NEW)
        text = text.replace("            pick_port = 1'b1;\n            port      = P_ALU0;",
                            "            pick_port = {1'b1, P_ALU0};")
        text = re.sub(r"\bport(\s*)= (P_\w+);", r"pick_port[2:0]\1= \2;", text)
        text = text.replace("pick_port = 1'b0;", "pick_port[3] = 1'b0;")
        text = text.replace(
            "c_found = pick_port(cand[i].fu_type, smul_ok[i], c_credit_ok, remaining, c_port);",
            "{c_found, c_port} = pick_port(cand[i].fu_type, smul_ok[i], c_credit_ok, remaining);")
        report.append(f"{relpath}: pick_port output argument -> packed {{found, port}} return")

    # bpu.sv loop_sel_index: with ADDR_WIDTH=32 and LOOP_SEL_WIDTH=8 the last
    # iteration selects pc[33:26], which is past the vector (ADS: Verilog-4088,
    # "Index 33 of pc is out of range").  Simulators read the missing bits as
    # zero, so shifting reproduces the intended value exactly.
    old = ("        for (int b = 2; b < ADDR_WIDTH; b += LOOP_SEL_WIDTH)\n"
           "        loop_sel_index = loop_sel_index ^ pc[b+:LOOP_SEL_WIDTH];")
    new = ("        // ADS-compatible: pc[33:26] is out of range for a 32-bit pc;\n"
           "        // the shift reads the missing high bits as zero (simulator value).\n"
           "        for (int b = 2; b < ADDR_WIDTH; b += LOOP_SEL_WIDTH)\n"
           "        loop_sel_index = loop_sel_index ^ ((pc >> b) & ((1 << LOOP_SEL_WIDTH) - 1));")
    if old in text:
        text = text.replace(old, new)
        report.append(f"{relpath}: loop_sel_index part-select past pc[31:0] -> masked shift")

    # $countones is not synthesizable in ADS (Verilog-4037).  The two live uses
    # are the debug/assertion paths over 2-bit valid vectors (DECODE_WIDTH=2).
    def countones_sub(m: re.Match) -> str:
        sig = m.group(1)
        report.append(f"{relpath}: $countones({sig}) -> {sig}[0]+{sig}[1] (2 bits)")
        return f"({sig}[0] + {sig}[1])"
    text = re.sub(r"\$countones\s*\(\s*(\w+)\s*\)", countones_sub, text)
    return text


# --------------------------------------------------------------------------- #
# unreachable-module pruning
# --------------------------------------------------------------------------- #
def split_modules(text: str) -> list[tuple[str, str]]:
    blocks = []
    for m in re.finditer(r"(?m)^module\s+(\w+)", text):
        end = text.find("endmodule", m.start())
        if end < 0:
            raise SystemExit(f"unterminated module {m.group(1)}")
        end = text.find("\n", end)
        blocks.append((m.group(1), text[m.start():end + 1]))
    return blocks


def prune_unreachable(text: str, top: str, report: list[str]) -> str:
    """Keep only modules reachable from `top` through instantiation.

    ADS optimises every module in the library, including ones the top never
    instantiates.  An unreachable module can still break the flow (for example
    the utage RAM output that ADS ties to its global GND net when
    CONFIG_FE_UTAGE is off), and it wastes compile time.
    """
    blocks = split_modules(text)
    names = [n for n, _ in blocks]
    if top not in names:
        raise SystemExit(f"top module {top} not found in the converted design")
    pattern = {n: re.compile(rf"(?m)^\s*{n}\s*(?:#\s*\(|\w+\s*\()") for n in names}
    deps = {n: {o for o in names if o != n and pattern[o].search(b)}
            for n, b in blocks}
    keep, stack = {top}, [top]
    while stack:
        for d in deps[stack.pop()]:
            if d not in keep:
                keep.add(d)
                stack.append(d)
    dropped = [n for n in names if n not in keep]
    if dropped:
        report.append(f"pruned {len(dropped)} unreachable modules: "
                      + ", ".join(sorted(dropped)[:8])
                      + (" ..." if len(dropped) > 8 else ""))
    return "".join(b for n, b in blocks if n in keep)


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report only, write nothing")
    ap.add_argument("--top", default="ares_pango_board",
                    help="top MODULE name, or a source path such as "
                         "rtl/top/ares_core_top.sv (default ares_pango_board)")
    ap.add_argument("--v-out", type=Path, default=None,
                    help="Verilog-2005 output file (default build/pango/syn/design.v "
                         "for the board top, build/pango/syn/design_<top>.v otherwise)")
    ap.add_argument("--no-prune", action="store_true",
                    help="keep modules the top does not instantiate")
    ap.add_argument("--src-dir", action="append", default=[],
                    help="extra RTL directory under rtl/ (repeatable, e.g. soc/jyd)")
    ap.add_argument("--src-file", action="append", default=[],
                    help="extra RTL file under rtl/ (repeatable, e.g. top/student_top.sv)")
    ap.add_argument("--all", action="store_true",
                    help="convert every module under rtl/ (test/report dirs excluded)")
    args = ap.parse_args()
    # Accept both a module name and a source path (rtl/top/ares_core_top.sv).
    args.top = Path(args.top).name
    if args.top.endswith(".sv"):
        args.top = args.top[:-3]

    if args.v_out is None:
        # Never let a non-default top overwrite the board/core artifact that
        # scripts/pango_build.py and scripts/pango_core_timing.py consume.
        args.v_out = (V_OUT if args.top == "ares_pango_board"
                      else OUT / f"design_{args.top}.v")

    # Accept both a module name and a source path (rtl/top/ares_core_top.sv).
    args.top = Path(args.top).name
    if args.top.endswith(".sv"):
        args.top = args.top[:-3]

    if args.v_out is None:
        args.v_out = (V_OUT if args.top == "ares_pango_board"
                      else OUT / f"design_{args.top}.v")

    ifaces = load_interfaces()
    files = sources(tuple(args.src_dir), tuple(args.src_file), args.all)
    if not files:
        raise SystemExit("no synthesis sources found")

    report: list[str] = []
    expanded: dict[str, str] = {}
    for f in files:
        rel = f.relative_to(RTL).as_posix()
        text = f.read_text(encoding="utf-8", errors="replace")
        text = fix_functions(text, report, rel)
        text = expand_interfaces(text, ifaces, report, rel)
        expanded[rel] = text

    # Fail loudly if a source still uses an interface this script cannot
    # expand; sv2v would inline it and ADS would reject the hierarchical names.
    leftover = sorted(rel for rel, txt in expanded.items()
                      if re.search(r"(?m)^\s*interface\s+\w+", txt)
                      or re.search(r"(?m)^\s*(axi_if|miniTensor_if|core_v_xif)\b", txt))
    if leftover:
        raise SystemExit(
            "unexpanded interface in: " + ", ".join(leftover)
            + "\nadd it to INTERFACE_DIR / load_interfaces() in scripts/pango_prep.py")

    print(f"pango_prep: {len(files)} files; interfaces {', '.join(sorted(ifaces))}; "
          f"{len(report)} rewrites")
    for line in report[:10]:
        print(f"  {line}")
    if len(report) > 10:
        print(f"  ... {len(report) - 10} more (see PORT_NOTES.md)")

    if args.check:
        return 0

    if SV_OUT.exists():
        shutil.rmtree(SV_OUT)
    for rel, text in expanded.items():
        dst = SV_OUT / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(text)

    # sv2v: one Verilog-2005 file, no interfaces left.
    cmd = ["sv2v", f"-I{AUTOCONF}"]
    cmd += [f"-D{d}" for d in SV2V_DEFINES]
    cmd += [str(SV_OUT / rel) for rel in sorted(expanded)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr[-4000:], file=sys.stderr)
        raise SystemExit("sv2v failed")
    OUT.mkdir(parents=True, exist_ok=True)
    verilog = result.stdout
    if not args.no_prune:
        verilog = prune_unreachable(verilog, args.top, report)
    args.v_out.write_text(verilog)
    if result.stderr.strip():
        (OUT / "sv2v.log").write_text(result.stderr)

    notes = ["# Pango ADS port notes", "",
             f"Generated by `scripts/pango_prep.py` from `rtl/` ({len(files)} files).", "",
             "sv2v defines: " + ", ".join(SV2V_DEFINES), "",
             "## Rewrites", ""]
    notes += [f"- {line}" for line in report] or ["- none"]
    NOTES.write_text("\n".join(notes) + "\n")
    try:
        shown = args.v_out.resolve().relative_to(ROOT)
    except ValueError:
        shown = args.v_out
    print(f"  -> {shown} ({len(verilog.splitlines())} lines, top {args.top})")
    print(f"  -> {NOTES.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
