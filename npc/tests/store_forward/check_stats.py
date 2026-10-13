#!/usr/bin/env python3
"""Validate the transient store-forwarding directed regression."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def section(text: str, title: str) -> str:
    marker = f"[{title}]"
    start = text.find(marker)
    if start == -1:
        raise SystemExit(f"missing statistics section: {title}")
    following = re.search(r"\n\[[^\n]+\]\n", text[start + len(marker) :])
    end = (
        len(text)
        if following is None
        else start + len(marker) + following.start()
    )
    return text[start:end]


def metric(text: str, label: str) -> int:
    match = re.search(
        rf"^\|\s*{re.escape(label)}\s*\|\s*(\d+)(?:\s|$)",
        text,
        re.MULTILINE,
    )
    if match is None:
        raise SystemExit(f"missing statistic: {label}")
    return int(match.group(1))


def require_minimum(text: str, label: str, minimum: int = 1) -> int:
    value = metric(text, label)
    if value < minimum:
        raise SystemExit(
            f"statistic {label} is {value}, expected at least {minimum}"
        )
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("pipeline_report", type=Path)
    parser.add_argument("memory_report", type=Path)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()

    log = args.log.read_text(encoding="utf-8", errors="replace")
    pipeline = args.pipeline_report.read_text(
        encoding="utf-8", errors="replace"
    )
    memory = args.memory_report.read_text(
        encoding="utf-8", errors="replace"
    )
    config = args.config.read_text(encoding="utf-8", errors="replace")
    ex2_replay = "CONFIG_LSU_EX2_STORE_REPLAY=y" in config

    if "HIT GOOD TRAP" not in log:
        raise SystemExit("store-forward regression did not reach a good trap")

    forwarding = section(pipeline, "Transient Store Forwarding")
    ex1 = metric(forwarding, "Ex1 store overlap cycles")
    ex2 = require_minimum(forwarding, "Ex2 store overlap cycles")
    ready = require_minimum(forwarding, "Final producers ready cycles")
    not_ready = require_minimum(
        forwarding, "Final producer not-ready cycles"
    )
    if metric(forwarding, "Unknown-address stall cycles") != 0:
        raise SystemExit("known-address pipeline produced an unknown stall")

    bridge = section(memory, "Store Buffer")
    concurrent = require_minimum(bridge, "Concurrent BRAM reads + writes")
    require_minimum(bridge, "Same-word BRAM reads + writes")
    require_minimum(bridge, "Staged-write forwarded reads")
    require_minimum(bridge, "Staged-write forwarded bytes")
    if metric(bridge, "Reads blocked by staged writes") != 0:
        raise SystemExit("dual-port BRAM still blocked a read by staged write")

    refill = section(memory, "Transient Refill")
    if ex2_replay:
        if ex1 != 0:
            raise SystemExit(
                "Ex2 replay still elaborated the Issue-side overlap path"
            )
        loads = require_minimum(bridge, "Forwarded reads")
        byte_count = require_minimum(bridge, "Forwarded bytes", loads)
        merges = ex2
        refill_candidates = require_minimum(refill, "Refill candidates")
        direct_refills = require_minimum(refill, "Direct refills")
        deferred_refills = metric(refill, "Deferred refills")
        if metric(forwarding, "Forwarded loads") != 0:
            raise SystemExit("Issue-side transient forwarding was not removed")
    else:
        if ex1 < 1:
            raise SystemExit("Issue-side store overlap was not exercised")
        loads = require_minimum(forwarding, "Forwarded loads")
        byte_count = require_minimum(forwarding, "Forwarded bytes", loads)
        require_minimum(forwarding, "Not-ready-data stall cycles")
        merges = require_minimum(forwarding, "Multi-store merges")
        require_minimum(forwarding, "Shadowed not-ready producer loads")
        refill_candidates = require_minimum(refill, "Transient candidates")
        direct_refills = metric(refill, "Direct transient refills")
        deferred_refills = metric(refill, "Deferred transient refills")
        if direct_refills + deferred_refills < 1:
            raise SystemExit(
                "no transient miss reached a precise D-cache refill"
            )
    if metric(refill, "Dropped refill candidates") != 0:
        raise SystemExit("transient refill queue dropped a candidate")

    print(
        "store-forward regression passed: "
        f"{loads} loads/{byte_count} bytes, "
        f"Ex1={ex1}, Ex2={ex2}, ready={ready}, "
        f"not-ready={not_ready}, merges={merges}, "
        f"BRAM read+write={concurrent}, "
        f"refills={direct_refills}+{deferred_refills}/"
        f"{refill_candidates} transient candidates"
    )


if __name__ == "__main__":
    main()
