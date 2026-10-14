#!/usr/bin/env python3
"""Generate a call-site-inlined CRC CoreMark translation unit.

The pinned CoreMark sources remain byte-for-byte untouched.  The generated
build input includes the Mundus CRC intrinsic immediately after coremark.h, so
the official declarations are left intact while subsequent direct calls are
mapped to the always-inline custom instruction implementation.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


COREMARK_INCLUDE = '#include "coremark.h"\n'
CRC_INCLUDE = '#include "mundus_hw_crc_inline.h"\n'
CRC_CALL = re.compile(r"\b(?:crc16|crcu16|crcu32)\s*\(")


def rewrite(source: str, source_name: str) -> str:
    if source_name == "core_util.c":
        raise ValueError("core_util.c must retain the official software definitions")
    if source.count(COREMARK_INCLUDE) != 1:
        raise ValueError('expected exactly one #include "coremark.h"')
    if CRC_INCLUDE in source:
        raise ValueError("CRC inline overlay is already present")
    if CRC_CALL.search(source) is None:
        raise ValueError("expected at least one CRC call site")
    return source.replace(
        COREMARK_INCLUDE, COREMARK_INCLUDE + CRC_INCLUDE, 1
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    original = args.source.read_text(encoding="utf-8")
    generated = rewrite(original, args.source.name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    print(f"generated inline-CRC source: {args.output}")


if __name__ == "__main__":
    main()
