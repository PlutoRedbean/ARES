#!/usr/bin/env python3
"""Check architectural completion and FRP-Lite activity counters."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def metric(report: str, name: str) -> int:
    match = re.search(
        rf"^\|\s*{re.escape(name)}\s*\|\s*([0-9]+)",
        report,
        re.MULTILINE,
    )
    if match is None:
        raise SystemExit(f"missing FRP metric: {name}")
    return int(match.group(1))


def main() -> None:
    log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    report = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
    if "HIT GOOD TRAP" not in log:
        raise SystemExit("FRP-Lite regression did not reach a good trap")

    required = {
        "Candidates": 260,
        "Owned / coverage": 100,
        "Boundary mismatch / issued block": 1,
    }
    values = {name: metric(report, name) for name in required}
    for name, minimum in required.items():
        if values[name] < minimum:
            raise SystemExit(
                f"{name} is {values[name]}, expected at least {minimum}"
            )

    print(
        "FRP-Lite regression passed: "
        f"{values['Candidates']} candidates, "
        f"{values['Owned / coverage']} owned, "
        f"{values['Boundary mismatch / issued block']} boundaries"
    )


if __name__ == "__main__":
    main()
