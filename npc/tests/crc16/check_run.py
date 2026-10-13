#!/usr/bin/env python3
"""Check the directed CRC16 instruction simulation result."""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_run.py LOG")
    text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    if "HIT GOOD TRAP" not in text:
        raise SystemExit("CRC16 directed regression did not reach a good trap")
    print("CRC16 directed regression passed")


if __name__ == "__main__":
    main()
