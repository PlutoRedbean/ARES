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

from host.golden.entities import (  # noqa: E402
    ENTITY_NAMES,
    mask_entities,
    scan_with_entities,
)
from host.golden.keywords import KEYWORDS, find_keywords  # noqa: E402
from host.golden.pii_rules import TYPE_NAMES, Span, scan  # noqa: E402
from host.golden.redact import Audit, RULE_IDS, audit_json, redact  # noqa: E402

RTL_BIN = ROOT / "build" / "obj_detect" / "Vdetect"
RED_BIN = ROOT / "build" / "obj_redtop" / "Vredact"


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
    ap.add_argument("--rtl-full", action="store_true", help="全 RTL：检测+合并+mask 替换（需要 make redact-harness）")
    ap.add_argument("--entities", action="store_true",
                    help="额外用 L2b 实体层遮人名/地址（金标路径，整段遮）")
    args = ap.parse_args(argv)

    path = Path(args.inp)
    data = path.read_bytes()

    if args.rtl_full:
        if not RED_BIN.exists():
            raise SystemExit(f"RTL redactor not built: {RED_BIN}\nrun: make redact-harness")
        tmp = path.with_suffix(path.suffix + ".rtl")
        proc = subprocess.run([str(RED_BIN), str(path), str(tmp)], capture_output=True, text=True, check=True)
        out = tmp.read_bytes()
        tmp.unlink(missing_ok=True)
        audits = []
        for i, line in enumerate((l for l in proc.stdout.splitlines() if l.strip()), 1):
            st, ln, ty = (int(x) for x in line.split())
            seg = data[st : st + ln]
            keep = min(4, ln)
            repl = b"*" * (ln - keep) + seg[ln - keep :]
            audits.append(
                Audit(index=i, type=TYPE_NAMES[ty], type_id=ty, rule=RULE_IDS[ty],
                      start=st, length=ln, action="mask", replacement=repl.decode("utf-8", "replace"))
            )
        if args.out:
            Path(args.out).write_bytes(out)
        else:
            sys.stdout.buffer.write(out)
            sys.stdout.buffer.write(b"\n")
        if args.json:
            Path(args.json).write_text(audit_json(audits) + "\n", encoding="utf-8")
        kinds = sorted({a.type for a in audits})
        print(f"[demo:rtl-full] in={len(data)}B out={len(out)}B spans={len(audits)} "
              f"types={','.join(kinds) if kinds else '-'}", file=sys.stderr)
        return 0

    if args.rtl:
        spans, kws = detect_rtl(path)
        hit_kids = {k[0] for k in kws}
    else:
        spans = scan(data)
        kws = [(h.kid, h.start, h.length) for h in find_keywords(data)]
        hit_kids = {h.kid for h in find_keywords(data)}

    out, audits = redact(data, policy=args.policy, keep_spans=spans)

    if args.entities:
        if args.policy != "mask":
            raise SystemExit("--entities 需要 --policy mask（保持字节 1:1）")
        _l1, ents = scan_with_entities(data)
        ents = [e for e in ents if not any(
            sp.start < e[1] + e[2] and e[1] < sp.start + sp.length for sp in spans)]
        if ents:
            out = mask_entities(out, ents)
            base = len(audits)
            for k, (ty, st, ln) in enumerate(sorted(ents, key=lambda e: e[1]), start=1):
                audits.append(Audit(
                    index=base + k, type=ENTITY_NAMES[ty], type_id=ty,
                    rule="lexicon." + ENTITY_NAMES[ty], start=st, length=ln,
                    action="mask", replacement="*" * ln))

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