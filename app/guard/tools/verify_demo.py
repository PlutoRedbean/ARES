"""端到端校验：用 Verilator 的 Vdetect 跑一批用例，与金标逐条比对。

检查三件事：
  1. RTL 报的 PII span 集合 == 金标（按 (start,type,len) 排序后比）；
  2. RTL 报的关键词命中 == 金标；
  3. 用 RTL 的 span 做脱敏，结果与金标脱敏逐字节相同。
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.keywords import find_keywords  # noqa: E402
from host.golden.pii_rules import Span, scan  # noqa: E402
from host.golden.redact import redact  # noqa: E402

BIN = ROOT / "build" / "obj_detect" / "Vdetect"
RED_BIN = ROOT / "build" / "obj_redtop" / "Vredact"


def parse(out: str) -> tuple[list[Span], list[tuple[int, int, int]]]:
    spans, kws = [], []
    for line in out.splitlines():
        p = line.split()
        if len(p) != 4:
            continue
        tag, a, b, c = p[0], int(p[1]), int(p[2]), int(p[3])
        if tag == "P":
            spans.append(Span(c, a, b))
        else:
            kws.append((c, a, b))
    return spans, kws


def key(s: Span) -> tuple[int, int, int]:
    return (s.start, s.type, s.length)


def main() -> int:
    vdir = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build" / "vectors")
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    if not BIN.exists():
        print(f"missing {BIN}; run make harness", file=sys.stderr)
        return 2

    errors = 0
    cases = 0
    for line in (vdir / "manifest.txt").read_text().split():
        if cases >= limit:
            break
        idx = int(line)
        path = vdir / f"case_{idx:04d}.in"
        data = path.read_bytes()
        proc = subprocess.run([str(BIN), str(path)], capture_output=True, text=True)
        rtl_spans, rtl_kws = parse(proc.stdout)

        gold_spans = sorted(scan(data), key=key)
        rtl_sorted = sorted(rtl_spans, key=key)
        gold_kws = sorted(((h.kid, h.start, h.length) for h in find_keywords(data)))

        if [key(s) for s in gold_spans] != [key(s) for s in rtl_sorted]:
            errors += 1
            if errors <= 3:
                print(f"FAIL case {idx}: spans differ")
                print(f"  gold: {[key(s) for s in gold_spans]}")
                print(f"  rtl : {[key(s) for s in rtl_sorted]}")
        if sorted(rtl_kws) != gold_kws:
            errors += 1
            if errors <= 3:
                print(f"FAIL case {idx}: keywords differ gold={gold_kws} rtl={sorted(rtl_kws)}")

        gold_out, _ = redact(data, keep_spans=gold_spans)
        rtl_out, _ = redact(data, keep_spans=rtl_sorted)
        if gold_out != rtl_out:
            errors += 1
            if errors <= 3:
                print(f"FAIL case {idx}: redacted bytes differ")
        # 全 RTL 脱敏：字节与审计都要与金标一致
        mask_path = vdir / f"case_{idx:04d}.mask"
        tmp_out = vdir / f"case_{idx:04d}.rtlmask"
        proc2 = subprocess.run([str(RED_BIN), str(path), str(tmp_out)], capture_output=True, text=True)
        rtl_mask = tmp_out.read_bytes()
        gold_mask = mask_path.read_bytes()
        if rtl_mask != gold_mask:
            errors += 1
            if errors <= 3:
                print(f"FAIL case {idx}: RTL mask differs ({len(rtl_mask)} vs {len(gold_mask)} B)")
        rtl_audit = [tuple(int(x) for x in line.split()) for line in proc2.stdout.splitlines() if line.strip()]
        gold_audit = [tuple(int(x) for x in line.split()) for line in (vdir / f"case_{idx:04d}.audit").read_text().splitlines() if line.strip()]
        if rtl_audit != gold_audit:
            errors += 1
            if errors <= 3:
                print(f"FAIL case {idx}: RTL audit differs")
        cases += 1

    print(f"demo-check: cases={cases} errors={errors}")
    if errors:
        return 1
    print("PASS: RTL detection + golden redaction agree end to end")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
