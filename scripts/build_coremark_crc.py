#!/usr/bin/env python3
"""Build an accelerated CoreMark image with the ARES custom CRC8 instruction.

The vendored EEMBC CoreMark sources under tests/benchmarks/coremark are left
untouched.  This script stages a private copy and adds two build-level pieces:

  * src/crc_hw.c         new translation unit with the same crcu8/crcu16/
                         crcu32/crc16 symbols, implemented with the ARES
                         custom-0 CRC8 instruction;
  * a target-specific CFLAGS line that renames the reference definitions in
    core_util.c to *_orig, so the linker resolves all callers to crc_hw.c.

The reference core_util.c itself is byte-identical to the vendored file.

Usage:
    python3 scripts/build_coremark_crc.py [--out build/coremark_crc]
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "tests/benchmarks/coremark"

CRC_HW_C = r'''/* ARES custom-0 CRC8 acceleration.
 *
 * This file is not part of the EEMBC CoreMark sources.  It is added by the
 * accelerated build flow and provides the same external symbols as
 * core_util.c.  The reference definitions in core_util.c are renamed to
 * *_orig by a target-specific -D flag, so all CoreMark callers resolve here.
 *
 * Encoding: .insn r 0x0b, 0, 0x00, rd, rs1, rs2
 *   rd  = crc8_step(rs1[7:0], rs2[15:0])
 * The RTL implements the exact bit-serial recurrence of crcu8() in one
 * combinational ALU operation (latency 1).
 */
#include "coremark.h"

static inline ee_u16 crc8_hw(ee_u8 data, ee_u16 crc)
{
    ee_u32 out;
    __asm__ volatile(".insn r 0x0b, 0, 0x00, %0, %1, %2"
                     : "=r"(out)
                     : "r"((ee_u32)data), "r"((ee_u32)crc));
    return (ee_u16)out;
}

ee_u16 crcu8(ee_u8 data, ee_u16 crc)
{
    return crc8_hw(data, crc);
}

ee_u16 crcu16(ee_u16 newval, ee_u16 crc)
{
    crc = crc8_hw((ee_u8)newval, crc);
    return crc8_hw((ee_u8)(newval >> 8), crc);
}

ee_u16 crc16(ee_s16 newval, ee_u16 crc)
{
    return crcu16((ee_u16)newval, crc);
}

ee_u16 crcu32(ee_u32 newval, ee_u16 crc)
{
    crc = crc16((ee_s16)newval, crc);
    crc = crc16((ee_s16)(newval >> 16), crc);
    return crc;
}
'''

MAKEFILE_APPEND = r'''
#------------------------------------------------------------------------------
# ARES accelerated CRC build (added by scripts/build_coremark_crc.py).
# Rename only the reference definitions in core_util.c; every other
# translation unit keeps calling the canonical crcu8/crcu16/crc16/crcu32
# names, which now resolve to src/crc_hw.c.
#------------------------------------------------------------------------------
$(DST_DIR)/src/core_util.o: CFLAGS += \
    -Dcrcu8=crcu8_orig -Dcrcu16=crcu16_orig \
    -Dcrcu32=crcu32_orig -Dcrc16=crc16_orig
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=ROOT / "build/coremark_crc")
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()

    out = args.out.resolve()
    src_port = out / "src_port"
    if src_port.exists():
        shutil.rmtree(src_port)
    shutil.copytree(SRC, src_port,
                    ignore=shutil.ignore_patterns("build", "__pycache__", "*.pyc"))

    (src_port / "src/crc_hw.c").write_text(CRC_HW_C)
    with (src_port / "Makefile").open("a") as f:
        f.write(MAKEFILE_APPEND)

    cmd = [sys.executable, str(ROOT / "scripts/build_coremark_image.py"),
           "--port", str(src_port), "--out", str(out), "--jobs", str(args.jobs)]
    print("+", " ".join(cmd))
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
