#!/usr/bin/env python3
"""Validate the architectural and accounting results of the directed run."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def require_section(text: str, title: str) -> str:
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


def require_metric(section: str, label: str, minimum: int = 0) -> int:
    match = re.search(
        rf"^\|\s*{re.escape(label)}\s*\|\s*(\d+)(?:\s|$)",
        section,
        re.MULTILINE,
    )
    if match is None:
        raise SystemExit(f"missing statistic: {label}")
    value = int(match.group(1))
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
    args = parser.parse_args()
    text = args.log.read_text(encoding="utf-8", errors="replace")
    pipeline_text = args.pipeline_report.read_text(
        encoding="utf-8", errors="replace"
    )
    memory_text = args.memory_report.read_text(
        encoding="utf-8", errors="replace"
    )

    if "HIT GOOD TRAP" not in text:
        raise SystemExit("dual-issue regression did not reach a good trap")

    summary = require_section(text, "Simulation Summary")
    require_metric(summary, "Clock cycles", 1)
    require_metric(summary, "Guest instructions", 1)
    if "Execution time" not in summary:
        raise SystemExit("execution time is missing from simulation summary")
    performance_report = text[text.find("[Simulation Summary]") :]
    if re.search(r"\[[^\]\n]*sim\.cpp:\d+\s+performance\]", performance_report):
        raise SystemExit("performance report still contains source prefixes")
    for title in (
        "Pipeline Throughput",
        "Pair Decisions",
        "WAW Breakdown",
        "Pipeline Stall Summary",
        "Pipeline Stall Accounting",
        "Pipeline Stall Causes",
        "Issue Operand Breakdown",
        "Issue Operand Cross-dimension Detail",
        "Top Issue-Operand Stall PCs",
        "D-cache",
        "Store Buffer",
    ):
        if f"[{title}]" in text:
            raise SystemExit(f"statistics section leaked into main log: {title}")

    throughput = require_section(pipeline_text, "Pipeline Throughput")
    width1 = require_metric(throughput, "Retire width 1 cycles")
    width2 = require_metric(throughput, "Retire width 2 cycles", 1)
    retired_count = require_metric(throughput, "Retired instructions", 1)
    flat = require_metric(
        throughput, "Same-group ALU0 -> ALU1 bypasses", 1
    )
    load_pair_hits = require_metric(
        throughput, "Same-group load -> slot1 hits"
    )
    load_pair_replays = require_metric(
        throughput, "Same-group load -> slot1 replays"
    )
    if load_pair_hits != 0 or load_pair_replays != 0:
        raise SystemExit("dependent same-group loads must serialize")
    require_metric(throughput, "Load replays", 1)
    if retired_count != width1 + 2 * width2:
        raise SystemExit("retirement width identity failed")

    pair_decisions = require_section(pipeline_text, "Pair Decisions")
    for outcome in (
        "success",
        "slot0-serial",
        "slot1-unsupported",
        "shared-resource",
        "WAW",
        "RAW",
    ):
        require_metric(pair_decisions, outcome, 1)
    # Advancing the registered producer snapshot across decode and the
    # synchronous GPR read can eliminate the conservative slot1-late case.
    # Keep checking that the accounting row exists without requiring the
    # optimized pipeline to manufacture a rejection.
    require_metric(pair_decisions, "slot1-late")

    waw_breakdown = require_section(pipeline_text, "WAW Breakdown")
    for waw_class in (
        "WAW-only",
        "WAW + ALU0 flat RAW",
        "WAW + load RAW",
        "WAW + MUL RAW",
    ):
        require_metric(waw_breakdown, waw_class, 1)

    stall_accounting = require_section(
        pipeline_text, "Pipeline Stall Accounting"
    )
    frozen = require_metric(stall_accounting, "Frozen cycles")
    accounted = require_metric(stall_accounting, "Accounted primary cycles")
    raw_sum = require_metric(stall_accounting, "Raw overlap sum")
    if frozen != accounted:
        raise SystemExit("primary stall cause identity failed")
    if raw_sum <= frozen:
        raise SystemExit("overlapping raw stall causes were not observed")

    stall_causes = require_section(pipeline_text, "Pipeline Stall Causes")
    for cause in ("wb-div", "issue-operand"):
        match = re.search(
            rf"^\|\s*{re.escape(cause)}\s*\|\s*(\d+)",
            stall_causes,
            re.MULTILINE,
        )
        if match is None or int(match.group(1)) == 0:
            raise SystemExit(f"primary stall cause {cause} was not observed")

    breakdown = require_section(pipeline_text, "Issue Operand Breakdown")
    lane_source_total = 0
    for lane in range(2):
        for source in range(1, 3):
            match = re.search(
                rf"^\|\s*lane/source\s*\|\s*lane{lane}/rs{source}\s*"
                rf"\|\s*(\d+)",
                breakdown,
                re.MULTILINE,
            )
            if match is None:
                raise SystemExit(
                    f"issue operand lane{lane}/rs{source} statistic is missing"
                )
            lane_source_total += int(match.group(1))
    if lane_source_total == 0:
        raise SystemExit("issue operand lane/source statistics are missing")

    dimensions = (
        ("producer stage", ("Ex1", "Ex2", "Ex3", "Ex4", "WB")),
        (
            "producer type",
            ("ALU", "load", "MUL", "load-pair ALU"),
        ),
        ("consumer type", ("ALU", "branch", "AGU", "store-data")),
    )
    for dimension, values in dimensions:
        for value in values:
            if re.search(
                rf"^\|\s*{re.escape(dimension)}\s*\|\s*"
                rf"{re.escape(value)}\s*\|\s*\d+",
                breakdown,
                re.MULTILINE,
            ) is None:
                raise SystemExit(
                    f"issue operand {dimension}/{value} statistic is missing"
                )

    detail = require_section(
        pipeline_text, "Issue Operand Cross-dimension Detail"
    )
    if re.search(
        r"^\|\s*[01]\s*\|\s*rs[12]\s*\|\s*"
        r"(?:Ex[1-4]|WB)\s*\|",
        detail,
        re.MULTILINE,
    ) is None:
        raise SystemExit("issue operand cross-dimension statistics are missing")

    top_pc = require_section(pipeline_text, "Top Issue-Operand Stall PCs")
    top_stall_pc = re.search(
        r"^\|\s*1\s*\|\s*0x[0-9a-fA-F]+\s*\|\s*(\d+)\s*\|\s*(\d+)",
        top_pc,
        re.MULTILINE,
    )
    if (
        top_stall_pc is None
        or int(top_stall_pc.group(1)) == 0
        or int(top_stall_pc.group(2)) == 0
    ):
        raise SystemExit("top issue-operand stall PC statistics are missing")

    dcache = require_section(memory_text, "D-cache")
    if re.search(
        r"^\|\s*all\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+",
        dcache,
        re.MULTILINE,
    ) is None:
        raise SystemExit("D-cache statistics are missing")
    store_buffer = require_section(memory_text, "Store Buffer")
    require_metric(store_buffer, "Depth", 1)

    print(
        "dual-issue regression passed: "
        f"{width2} dual-retire cycle(s), {flat} flat bypass(es), "
        "dependent same-group loads serialized"
    )


if __name__ == "__main__":
    main()
