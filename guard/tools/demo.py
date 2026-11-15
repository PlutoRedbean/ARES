"""端到端 demo：文本进 → 脱敏文本 + 审计 JSON 出。

默认用 Python 金标做检测；`--rtl` 时改为调用 Verilator 构建的 `Vdetect`，
把 RTL 的检测结果送进同一套合并/替换/审计流程（这样 demo 与 RTL 一致）。

用法：
    python3 tools/demo.py --in examples/sample.txt --policy token --json audit.json
    python3 tools/demo.py --in examples/sample.txt --rtl --out redacted.txt
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.keywords import KEYWORDS, find_keywords  # noqa: E402
from host.golden.pii_rules import TYPE_NAMES, Span, scan  # noqa: E402
from host.golden.redact import audit_json, redact  # noqa: E402

RTL_BIN = ROOT / "build" / "obj_detect" / "Vdetect"


def detect_rtl(path: Path) -> tuple[list[Span], list[tuple[int, int, int]]]:
    if not RTL_BIN.exists():
        raise SystemExit(f"RTL harness not built: {RTL_BIN}\nrun: make harness")
    proc = subprocess.run([str(RTL_BIN), str(path)], capture_output=True, text=True, check=True)
    spans: list[Span] = []
    kws: list[tuple[int, int, int]] = []
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        tag, start, ln, kind = parts[0], int(parts[1]), int(parts[2]), int(parts[3])
        if tag == "P":
            spans.append(Span(kind, start, ln))
        elif tag == "K":
            kws.append((kind, start, ln))
    return spans, kws


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="guard 端到端 demo")
    ap.add_argument("--in", dest="inp", required=True, help="输入文本文件")
    ap.add_argument("--out", help="脱敏文本输出文件（缺省打印到 stdout）")
    ap.add_argument("--json", help="审计 JSON 输出文件")
    ap.add_argument("--policy", choices=["token", "mask"], default="token")
    ap.add_argument("--rtl", action="store_true", help="用 RTL 检测（需要 make harness）")
    args = ap.parse_args(argv)

    path = Path(args.inp)
    data = path.read_bytes()

    if args.rtl:
        spans, kws = detect_rtl(path)
        hit_kids = {k[0] for k in kws}
    else:
        spans = scan(data)
        kws = [(h.kid, h.start, h.length) for h in find_keywords(data)]
        hit_kids = {h.kid for h in find_keywords(data)}

    out, audits = redact(data, policy=args.policy, keep_spans=spans)

    if args.out:
        Path(args.out).write_bytes(out)
    else:
        sys.stdout.buffer.write(out)
        sys.stdout.buffer.write(b"\n")

    if args.json:
        Path(args.json).write_text(audit_json(audits) + "\n", encoding="utf-8")

    mode = "rtl" if args.rtl else "golden"
    kinds = sorted({a.type for a in audits})
    print(
        f"[demo:{mode}] in={len(data)}B out={len(out)}B spans={len(audits)} "
        f"types={','.join(kinds) if kinds else '-'} "
        f"keywords={','.join(KEYWORDS[k] for k in sorted(hit_kids)) if hit_kids else '-'}",
        file=sys.stderr,
    )
    if args.json:
        print(f"[demo] audit -> {args.json}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
