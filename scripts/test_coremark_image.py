#!/usr/bin/env python3
"""Negative and positive tests for the CoreMark image chain (no RTL needed).

The point of these tests is that a bad input fails loudly instead of producing
a plausible-looking image: empty files, non-RISC-V ELFs, segments outside the
backing window, overlapping segments and frozen-parameter drift must all be
refused with a specific diagnostic.  This is the A1 exit condition "empty
image / illegal format / out of backing range fail explicitly".

Run with: make test-coremark-image
"""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import elf_image  # noqa: E402

PT_LOAD = 1
checks = 0
failures: list[str] = []


def ok(name: str) -> None:
    global checks
    checks += 1
    print(f"PASS: {name}")


def fail(name: str, detail: str) -> None:
    global checks
    checks += 1
    failures.append(f"{name}: {detail}")
    print(f"FAIL: {name}: {detail}")


def make_elf(segments: list[dict], entry: int = 0x8000_0000, machine: int = 243,
             etype: int = 2, elfclass: int = 1, elfdata: int = 1,
             with_phdrs: bool = True) -> bytes:
    """Build a minimal ELF32 file.  Each segment dict accepts paddr/data/... overrides."""
    count = len(segments) if with_phdrs else 0
    phoff = 52 if count else 0
    data_off = max(52, (phoff + 32 * count) if count else 52)
    blob = bytearray(b"\x00" * data_off)
    phdrs = bytearray()
    for segment in segments:
        body = segment.get("data", b"")
        offset = segment.get("offset", len(blob))
        if offset == len(blob):
            blob += body
        else:
            end = offset + len(body)
            if end > len(blob):
                blob += b"\x00" * (end - len(blob))
            blob[offset:end] = body
        paddr = segment.get("paddr", 0x8000_0000)
        filesz = segment.get("filesz", len(body))
        memsz = segment.get("memsz", max(filesz, len(body)))
        phdrs += struct.pack("<8I", segment.get("type", PT_LOAD), offset, paddr,
                             segment.get("vaddr", paddr), filesz, memsz,
                             5, 0x1000)
    blob[0:4] = b"\x7fELF"
    blob[4] = elfclass
    blob[5] = elfdata
    blob[6] = 1
    struct.pack_into("<HHIIIIIHHHHHH", blob, 16,
                     etype, machine, 1, entry, phoff, 0, 0, 52, 32, count, 0, 0, 0)
    if with_phdrs:
        blob[phoff:phoff + len(phdrs)] = phdrs
    return bytes(blob)


def expect_error(name: str, blob: bytes, substring: str, **kwargs) -> None:
    try:
        elf_image.build_image(blob, **kwargs)
    except elf_image.ElfImageError as exc:
        if substring.lower() in str(exc).lower():
            ok(name)
        else:
            fail(name, f"message {str(exc)!r} does not contain {substring!r}")
    except AssertionError:
        raise
    else:
        fail(name, "image was accepted but should have been refused")


def expect_ok(name: str, blob: bytes, condition: bool, detail: str = "") -> None:
    try:
        elf_image.build_image(blob)
    except elf_image.ElfImageError as exc:
        fail(name, f"unexpected refusal: {exc}")
        return
    if condition:
        ok(name)
    else:
        fail(name, detail)


def test_converter() -> None:
    base = elf_image.DEFAULT_BASE
    code = bytes(range(16))

    expect_error("empty file", b"", "empty image file")
    expect_error("truncated header", b"\x7fELF\x01\x01", "truncated ELF header")
    expect_error("bad magic", b"NOTELF" + b"\x00" * 64, "bad ELF magic")
    expect_error("64-bit ELF", make_elf([{"data": code}], elfclass=2), "not a 32-bit ELF")
    expect_error("big-endian ELF", make_elf([{"data": code}], elfdata=2),
                 "not a little-endian ELF")
    expect_error("relocatable ELF", make_elf([{"data": code}], etype=1), "ET_EXEC")
    expect_error("non-RISC-V machine", make_elf([{"data": code}], machine=3),
                 "expected RISC-V")
    expect_error("no program headers", make_elf([{"data": code}], with_phdrs=False),
                 "no program headers")
    expect_error("no loadable segment", make_elf([{"type": 4, "data": code}]),
                 "no loadable segments")
    expect_error("filesz exceeds memsz",
                 make_elf([{"data": code, "paddr": base, "memsz": 4}]), "exceeds memory size")
    expect_error("segment contents truncated",
                 make_elf([{"data": code, "paddr": base, "filesz": len(code) + 64,
                            "memsz": len(code) + 64}]), "truncated")
    expect_error("segment below base",
                 make_elf([{"data": code, "paddr": base - 0x1000}]), "below the image base")
    expect_error("segment past backing window",
                 make_elf([{"data": code, "paddr": base + elf_image.DEFAULT_LIMIT - 8}]),
                 "outside the backing window")
    expect_error("custom limit respected",
                 make_elf([{"data": code, "paddr": base + 0x2000}]),
                 "outside the backing window", limit=0x1000)
    expect_error("overlapping file segments",
                 make_elf([{"data": b"A" * 32, "paddr": base},
                           {"data": b"B" * 32, "paddr": base + 16}]),
                 "overlap")
    expect_error("entry outside image",
                 make_elf([{"data": code, "paddr": base + 0x1000},
                           ], entry=base),
                 "outside the image")
    expect_error("entry above image", make_elf([{"data": code, "paddr": base}],
                                               entry=base + 0x400), "outside the image")

    # Positive: code at 0x8000_0000 and data at 0x8010_0000, dense image.
    elf = make_elf([
        {"data": bytes(range(16)), "paddr": base},
        {"data": b"\xde\xad\xbe\xef" * 4, "paddr": base + 0x10_0000},
    ])
    try:
        image = elf_image.build_image(elf)
    except elf_image.ElfImageError as exc:
        fail("dense image layout", f"unexpected refusal: {exc}")
        return
    expected_size = 0x10_0000 + 16
    ok_condition = (
        len(image.data) == expected_size
        and image.data[:16] == bytes(range(16))
        and image.data[16:0x10_0000] == bytes(0x10_0000 - 16)
        and image.data[0x10_0000:] == b"\xde\xad\xbe\xef" * 4
        and image.info()["end"] == f"0x{base + expected_size:08x}"
    )
    if ok_condition:
        ok("dense image layout")
    else:
        fail("dense image layout", f"size={len(image.data)} end={image.info()['end']}")

    lines = elf_image.to_readmemh(image.data).splitlines()
    if (len(lines) == expected_size // 16
            and lines[0] == "0f0e0d0c0b0a09080706050403020100"
            and lines[0x10_0000 // 16] == "efbeadde" * 4
            and all(len(line) == 32 for line in lines)):
        ok("readmemh encoding")
    else:
        fail("readmemh encoding", f"lines={len(lines)} first={lines[0] if lines else ''}")

    expect_ok("valid single segment", make_elf([{"data": code}]), True)


def test_cli(tmp: Path) -> None:
    def run(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(ROOT / "scripts/elf_image.py"), *args],
                              capture_output=True, text=True)

    result = run("--elf", str(tmp / "missing.elf"))
    if result.returncode != 0 and "ELF not found" in result.stderr:
        ok("cli: missing ELF")
    else:
        fail("cli: missing ELF", f"exit={result.returncode} err={result.stderr.strip()}")

    good = tmp / "good.elf"
    good.write_bytes(make_elf([{"data": bytes(range(16))}]))
    result = run("--elf", str(good), "--bin", str(tmp / "good.bin"),
                 "--hex", str(tmp / "good.hex"))
    produced = (tmp / "good.bin").is_file() and (tmp / "good.hex").is_file()
    if result.returncode == 0 and produced and (tmp / "good.bin").stat().st_size == 16:
        ok("cli: valid image")
    else:
        fail("cli: valid image", f"exit={result.returncode} err={result.stderr.strip()}")

    bad = tmp / "bad.elf"
    bad.write_bytes(b"\x00" * 128)
    result = run("--elf", str(bad), "--hex", str(tmp / "bad.hex"))
    if result.returncode != 0 and "bad ELF magic" in result.stderr:
        ok("cli: invalid format fails")
    else:
        fail("cli: invalid format fails", f"exit={result.returncode} err={result.stderr.strip()}")
    if not (tmp / "bad.hex").exists():
        ok("cli: no output on failure")
    else:
        fail("cli: no output on failure", "bad.hex was written anyway")


def test_driver(tmp: Path) -> None:
    driver = ROOT / "scripts/build_coremark_image.py"
    port = ROOT / "tests/benchmarks/coremark"

    def run(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(driver), *args],
                              capture_output=True, text=True)

    result = run("--port", str(tmp / "absent"), "--out", str(tmp / "o1"), "--no-build")
    if result.returncode != 0 and "port directory not found" in result.stderr:
        ok("driver: missing port")
    else:
        fail("driver: missing port", f"exit={result.returncode} err={result.stderr.strip()}")

    result = run("--out", str(tmp / "o2"), "--no-build")
    if result.returncode != 0 and "ELF not found" in result.stderr:
        ok("driver: no staged ELF")
    else:
        fail("driver: no staged ELF", f"exit={result.returncode} err={result.stderr.strip()}")

    # Frozen-parameter drift must be refused before any build starts.
    import shutil
    mutated = tmp / "mutated-port"
    shutil.copytree(port, mutated)
    header = mutated / "include/core_portme.h"
    header.write_text(header.read_text().replace("#define ITERATIONS 100",
                                                 "#define ITERATIONS 1000"))
    result = run("--port", str(mutated), "--out", str(tmp / "o3"))
    if result.returncode != 0 and "frozen parameter changed" in result.stderr:
        ok("driver: frozen parameter drift refused")
    else:
        fail("driver: frozen parameter drift refused",
             f"exit={result.returncode} err={result.stderr.strip()}")

    # An unmodified port must still stage cleanly when only checking the gate.
    result = run("--port", str(port), "--out", str(tmp / "o4"), "--no-build")
    if result.returncode != 0 and "ELF not found" in result.stderr:
        ok("driver: frozen gate passes on the repo port")
    else:
        fail("driver: frozen gate passes on the repo port",
             f"exit={result.returncode} err={result.stderr.strip()}")

    # An --out outside the repository must record absolute paths instead of
    # crashing on relative_to(), which it did once during a clean-room check.
    import json
    out = tmp / "outside-out"
    staged = out / "port" / "build"
    staged.mkdir(parents=True)
    (staged / "coremark-riscv32-ares.elf").write_bytes(
        make_elf([{"data": bytes(range(16))}]))
    result = run("--port", str(port), "--out", str(out), "--no-build")
    inputs = out / "inputs.json"
    if result.returncode == 0 and inputs.is_file() and (out / "coremark_dmem.hex").is_file():
        recorded = json.loads(inputs.read_text())["artifacts"]["elf"]
        if recorded.startswith(str(out)):
            ok("driver: out-of-tree output")
        else:
            fail("driver: out-of-tree output", f"elf path recorded as {recorded!r}")
    else:
        fail("driver: out-of-tree output",
             f"exit={result.returncode} err={result.stderr.strip()[:300]}")


def main() -> int:
    test_converter()
    with tempfile.TemporaryDirectory(prefix="ares-coremark-image-") as directory:
        tmp = Path(directory)
        test_cli(tmp)
        test_driver(tmp)
    print(f"\n{checks - len(failures)}/{checks} checks passed")
    if failures:
        for failure in failures:
            print(f"  {failure}")
        return 1
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
