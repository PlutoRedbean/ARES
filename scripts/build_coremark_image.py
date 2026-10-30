#!/usr/bin/env python3
"""Build the ARES CoreMark image and record every input that produced it.

One command replaces the previous external workflow (copy sources out of
another checkout, build by hand with the AbstractMachine Makefile, then paste
an ad-hoc Python snippet to make a readmemh file).  The result is a
self-contained, hash-stamped image under build/coremark/:

    build/coremark/port/                 staged copy of tests/benchmarks/coremark
    build/coremark/coremark-....elf      linked ELF32 executable (copied)
    build/coremark/coremark.bin          dense flat binary
    build/coremark/coremark_dmem.hex     128-bit little-endian readmemh image
    build/coremark/build.log             compiler output
    build/coremark/inputs.json           hashes, frozen config, tool versions

Frozen parameters are checked before building: if ITERATIONS, TOTAL_DATA_SIZE,
the performance seed set, MEM_METHOD or MULTITHREAD drift, the build is refused
rather than silently producing an incomparable result.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import elf_image  # noqa: E402

ARCH = "riscv32-ares"
DEFAULT_CROSS_COMPILE = "riscv64-unknown-elf-"
ELF_NAME = "coremark-riscv32-ares.elf"

# (file, regex, human description, expected value recorded in inputs.json)
FROZEN_CHECKS = [
    ("include/coremark.h", r"#define\s+TOTAL_DATA_SIZE\s+2\*1000",
     "TOTAL_DATA_SIZE must be 2*1000 (2000 bytes)", "2000"),
    ("include/core_portme.h", r"#define\s+ITERATIONS\s+100\b",
     "ITERATIONS must be 100", "100"),
    ("include/core_portme.h", r"#define\s+COREMARK_CLOCK_HZ\s+100000000u\b",
     "COREMARK_CLOCK_HZ must be 100000000 (100 MHz RTL clock)", "100000000"),
    ("include/core_portme.h", r"#define\s+HAS_PRINTF\s+1\b",
     "HAS_PRINTF must be 1 (CoreMark reports through the RTL UART)", "1"),
    ("include/core_portme.h", r"#define\s+MEM_METHOD\s+MEM_STATIC\b",
     "MEM_METHOD must be MEM_STATIC (no malloc in the ARES runtime)", "MEM_STATIC"),
    ("include/core_portme.h", r"#define\s+MULTITHREAD\s+1\b",
     "MULTITHREAD must be 1 (one CoreMark instance per hart, never EEMBC MULTITHREAD=2)", "1"),
    ("src/core_portme.c", r"#if\s+PERFORMANCE_RUN[\s\S]*?seed1_volatile\s*=\s*0x0\s*;"
     r"[\s\S]*?seed2_volatile\s*=\s*0x0\s*;[\s\S]*?seed3_volatile\s*=\s*0x66\s*;",
     "PERFORMANCE_RUN seeds must be 0 / 0 / 0x66", "0/0/0x66"),
]


def die(message: str) -> "NoReturn":  # noqa: F821 - kept simple for scripts
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


@contextlib.contextmanager
def output_lock(out: Path):
    """Serialize concurrent invocations (make -j, parallel regressions).

    Both the staging directory and the published image are shared state; a
    second build that removed the staging tree under a running make produced
    "getcwd() failed" and a half-written image once already.
    """
    out.mkdir(parents=True, exist_ok=True)
    with (out / ".lock").open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def rel(path: Path, root: Path) -> str:
    """Repository-relative path, or the absolute one for out-of-tree outputs."""
    try:
        return str(Path(path).relative_to(root))
    except ValueError:
        return str(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_version(command: list[str]) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return "unavailable"
    text = (result.stdout + result.stderr).strip()
    return text.splitlines()[0] if text else "unavailable"


def git_info(root: Path) -> dict:
    def git(*args: str) -> str:
        try:
            result = subprocess.run(["git", *args], cwd=root, capture_output=True,
                                    text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return ""
        return result.stdout.strip() if result.returncode == 0 else ""

    status = git("status", "--porcelain")
    return {
        "head": git("rev-parse", "HEAD") or "unknown",
        "branch": git("rev-parse", "--abbrev-ref", "HEAD") or "unknown",
        "dirty": bool(status),
    }


def check_frozen(port: Path) -> dict:
    frozen = {}
    for name, pattern, description, value in FROZEN_CHECKS:
        path = port / name
        if not path.is_file():
            die(f"frozen parameter check: {name} is missing under {port}")
        text = path.read_text()
        if not re.search(pattern, text):
            die(f"frozen parameter changed: {name}: {description}. "
                f"Record the change in tests/benchmarks/coremark/NOTICE.md and "
                f"docs/m1_closure_decisions.md before rebuilding.")
        frozen[description] = value
    # A single instance per hart, and no path that could pull in host stdio.
    return {
        "iterations": 100,
        "total_data_size": 2000,
        "run_type": "PERFORMANCE_RUN",
        "seeds": ["0x0", "0x0", "0x66"],
        "mem_method": "MEM_STATIC",
        "multithread": 1,
        "march": "rv32im_zicsr",
        "mabi": "ilp32",
        "clock_hz": 100000000,
        "timer": "rtl_cycle_counter",
        "console": "rtl_uart_115200_8n1",
    }


def stage_port(port: Path, stage: Path) -> None:
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(port, stage,
                    ignore=shutil.ignore_patterns("build", "__pycache__", "*.pyc"))


MT_OVERLAY = {
    "core_portme.h": "include/core_portme.h",
    "core_portme.c": "src/core_portme.c",
}


def apply_mt_overlay(stage: Path, root: Path) -> dict:
    """Replace the two ARES port files in the *staged* copy only.

    The repository copy under tests/benchmarks/coremark/ is never written, so
    the vendored CoreMark tree (and NOTICE.md's SHA table) stays byte-identical.
    """
    overlay = root / "scripts" / "coremark_mt"
    hashes = {}
    for name, relative in MT_OVERLAY.items():
        source = overlay / name
        target = stage / relative
        if not source.is_file():
            die(f"MT overlay missing: {source}")
        if not target.is_file():
            die(f"MT overlay target missing in staged port: {target}")
        shutil.copyfile(source, target)
        hashes[relative] = sha256(target)
    return hashes


def check_mt_overlay(stage: Path) -> None:
    header = (stage / "include" / "core_portme.h").read_text()
    checks = [
        (r"#define\s+MEM_METHOD\s+MEM_STACK\b",
         "MEM_STACK (core_main.c rejects MEM_STATIC with MULTITHREAD>1)"),
        (r"#define\s+MULTITHREAD\s+2\b", "MULTITHREAD=2"),
        (r"#define\s+PARALLEL_METHOD\s+\"", "PARALLEL_METHOD string"),
    ]
    for pattern, description in checks:
        if not re.search(pattern, header):
            die(f"MT overlay check failed: {description} missing from core_portme.h")
    source = (stage / "src" / "core_portme.c").read_text()
    for hook in ("core_start_parallel", "core_stop_parallel", "MBOX_DONE"):
        if hook not in source:
            die(f"MT overlay check failed: {hook} missing from core_portme.c")


def build(stage: Path, root: Path, cross_compile: str, jobs: int | None,
          ccache: bool, log_path: Path, ldscript: Path | None = None) -> None:
    env = {k: v for k, v in os.environ.items()
           if k not in ("AM_HOME", "MUNDUS_HOME", "NPC_HOME", "ARES_HOME", "CCACHE_DIR")}
    if not ccache:
        # ccache would write outside the workspace and makes the recorded
        # command non-reproducible; keep it off unless explicitly requested.
        env["CCACHE_DISABLE"] = "1"
    command = ["make", "-C", str(stage)]
    if jobs:
        command.append(f"-j{jobs}")
    command += [f"ARES_HOME={root}", f"ARCH={ARCH}",
                f"CROSS_COMPILE={cross_compile}"]
    if ldscript is not None:
        command.append(f"LDSCRIPTS={ldscript}")
    command.append("image")
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        tail = "\n".join((result.stdout + result.stderr).strip().splitlines()[-20:])
        die(f"CoreMark build failed (see {log_path}):\n{tail}")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=None,
                        help="output directory (default build/coremark, "
                             "or build/coremark_mt with --mt)")
    parser.add_argument("--port", type=Path, default=root / "tests/benchmarks/coremark",
                        help="CoreMark port directory to build")
    parser.add_argument("--no-build", action="store_true",
                        help="reuse the ELF already staged under --out")
    parser.add_argument("--mt", action="store_true",
                        help="overlay the 2-hart MULTITHREAD=2 port from "
                             "scripts/coremark_mt/ onto the staged copy")
    parser.add_argument("--cross-compile", default=DEFAULT_CROSS_COMPILE,
                        help=f"toolchain prefix (default {DEFAULT_CROSS_COMPILE})")
    parser.add_argument("--ldscript", type=Path, default=None,
                        help="override the ARES linker script (for example "
                             "tests/abstract-machine/scripts/ares-linker-mc.ld)")
    parser.add_argument("--base", type=lambda v: int(v, 0), default=elf_image.DEFAULT_BASE,
                        help="first address of the image")
    parser.add_argument("--limit", type=lambda v: int(v, 0), default=elf_image.DEFAULT_LIMIT,
                        help="backing window size")
    parser.add_argument("--jobs", type=int, help="parallel make jobs")
    parser.add_argument("--ccache", action="store_true", help="allow ccache")
    parser.add_argument("--expect-hex-sha256", help="fail unless the hex matches this hash")
    parser.add_argument("--json", action="store_true", help="print inputs.json to stdout")
    args = parser.parse_args()

    if args.out is not None:
        out = args.out.resolve()
    elif args.mt:
        out = (root / "build/coremark_mt").resolve()
    else:
        out = (root / "build/coremark").resolve()
    port = args.port.resolve()
    if not port.is_dir():
        die(f"CoreMark port directory not found: {port}")

    frozen = check_frozen(port)
    stage = out / "port"
    mt_hashes = {}
    ldscript = args.ldscript.resolve() if args.ldscript else None
    if ldscript is not None and not ldscript.is_file():
        die(f"linker script not found: {ldscript}")
    if not args.no_build:
        with output_lock(out):
            stage_port(port, stage)
            if args.mt:
                mt_hashes = apply_mt_overlay(stage, root)
                check_mt_overlay(stage)
            build(stage, root, args.cross_compile, args.jobs, args.ccache,
                  out / "build.log", ldscript)
    if args.mt:
        frozen.update({
            "mem_method": "MEM_STACK",
            "multithread": 2,
            "parallel_method": "ares-2hart-mbox",
        })

    elf = stage / "build" / ELF_NAME
    if not elf.is_file():
        die(f"ELF not found: {elf}"
            + ("" if args.no_build else " (the build did not produce it)"))
    kept_elf = out / ELF_NAME
    if elf.resolve() != kept_elf.resolve():
        shutil.copyfile(elf, kept_elf)

    try:
        with output_lock(out):
            image = elf_image.write_outputs(kept_elf, out / "coremark.bin",
                                            out / "coremark_dmem.hex",
                                            base=args.base, limit=args.limit)
    except elf_image.ElfImageError as exc:
        die(f"image conversion failed: {exc}")

    hex_path = out / "coremark_dmem.hex"
    bin_path = out / "coremark.bin"
    hex_sha = sha256(hex_path)
    if args.expect_hex_sha256 and hex_sha != args.expect_hex_sha256:
        die(f"hex SHA-256 mismatch: got {hex_sha}, expected {args.expect_hex_sha256}")

    config = root / "configs/build/.config"
    port_hashes = {str(p.relative_to(port)): sha256(p)
                   for p in sorted(port.rglob("*"))
                   if p.is_file() and "build" not in p.relative_to(port).parts}
    inputs = {
        "schema": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "git": git_info(root),
        "frozen": frozen,
        "image": {
            **image.info(),
            "limit": f"0x{args.limit:08x}",
            "hex_lines": len(image.data + bytes(-len(image.data) % 16)) // 16,
            "sha256": {"bin": sha256(bin_path), "hex": hex_sha, "elf": sha256(kept_elf)},
        },
        "artifacts": {
            "elf": rel(kept_elf, root),
            "bin": rel(bin_path, root),
            "hex": rel(hex_path, root),
            "log": rel(out / "build.log", root),
            "config": {"path": rel(config, root), "sha256": sha256(config)}
            if config.is_file() else None,
        },
        "port_sources_sha256": port_hashes,
        "mt_overlay_sha256": mt_hashes,
        "ldscript": {
            "path": rel(ldscript, root) if ldscript else rel(root / "tests" / "abstract-machine" / "scripts" / "ares-linker.ld", root),
            "sha256": sha256(ldscript) if ldscript else None,
        },
        "tools": {
            "gcc": command_version([f"{args.cross_compile}gcc", "--version"]),
            "make": command_version(["make", "--version"]),
            "python": sys.version.split()[0],
            "verilator": command_version(["verilator", "--version"]),
        },
        "commands": {
            "build": f"make -C {rel(stage, root)} ARES_HOME={root} ARCH={ARCH} "
                     f"CROSS_COMPILE={args.cross_compile} "
                     + (f"LDSCRIPTS={ldscript} " if ldscript else "")
                     + "image",
            "convert": f"python3 scripts/elf_image.py --elf {rel(kept_elf, root)} "
                       f"--bin {rel(bin_path, root)} --hex {rel(hex_path, root)} "
                       f"--base 0x{args.base:08x} --limit 0x{args.limit:08x}",
        },
    }
    elf_image.atomic_write_text(out / "inputs.json", json.dumps(inputs, indent=2) + "\n")

    if not args.json:
        print(f"image:  {image.info()['size_bytes']} bytes "
              f"[0x{image.base:08x}, 0x{image.end:08x}), "
              f"{inputs['image']['hex_lines']} readmemh lines")
        print(f"  elfcopy {rel(kept_elf, root)}")
        print(f"  bin     {rel(bin_path, root)}  sha256 {inputs['image']['sha256']['bin']}")
        print(f"  hex     {rel(hex_path, root)}  sha256 {hex_sha}")
        print(f"  inputs  {rel(out / 'inputs.json', root)}")
        if args.mt:
            print("frozen:  ITERATIONS=100 TOTAL_DATA_SIZE=2000 seeds=0/0/0x66 "
                  "MEM_STACK MULTITHREAD=2 (staged overlay) rv32im_zicsr/ilp32")
        else:
            print("frozen:  ITERATIONS=100 TOTAL_DATA_SIZE=2000 seeds=0/0/0x66 "
                  "MEM_STATIC MULTITHREAD=1 rv32im_zicsr/ilp32")
    else:
        print(json.dumps(inputs, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
