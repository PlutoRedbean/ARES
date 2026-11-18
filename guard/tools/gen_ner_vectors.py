#!/usr/bin/env python3
"""从留出集生成 200 例 RTL/金标向量：build/ner_vectors/case_XXXX.in / .exp。

    python3 tools/gen_ner_vectors.py --data data/ner --out build/ner_vectors --n 200

.in  = 原始 UTF-8 字节（<=64 字节，一个窗口）
.exp = 每行 "start_byte len_byte type"（只写 1=name / 2=addr；0=其它 PII 不输出，
       因为模型只负责名字和地址）
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(ROOT / "data" / "ner"))
    ap.add_argument("--out", default=str(ROOT / "build" / "ner_vectors"))
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--pos", type=int, default=160)
    ap.add_argument("--seed", type=int, default=20261118)
    args = ap.parse_args()

    rows = load_jsonl(Path(args.data) / "heldout.jsonl")
    rng = random.Random(args.seed)
    rng.shuffle(rows)

    def has_span(r):
        return any(y in (1, 2) for _, _, y in r["spans"])

    pos = [r for r in rows if has_span(r)]
    neg = [r for r in rows if not has_span(r)]
    want_pos = min(args.pos, args.n, len(pos))
    want_neg = min(args.n - want_pos, len(neg))
    chosen = pos[:want_pos] + neg[:want_neg]
    if len(chosen) < args.n:                      # 负样本不够就继续拿正样本
        chosen = (pos + neg)[: args.n]
    rng.shuffle(chosen)

    out = Path(args.out)
    if not out.is_absolute():
        out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("case_*.*"):
        old.unlink()

    n_pos = 0
    for i, r in enumerate(chosen):
        data = r["text"].encode("utf-8")
        (out / f"case_{i:04d}.in").write_bytes(data)
        spans = sorted([s, ln, y] for s, ln, y in r["spans"] if y in (1, 2))
        if spans:
            n_pos += 1
        lines = [f"{s} {ln} {y}" for s, ln, y in spans]
        (out / f"case_{i:04d}.exp").write_text("\n".join(lines) + ("\n" if lines else ""),
                                               encoding="utf-8")

    (out / "manifest.txt").write_text(
        json.dumps({"n": len(chosen), "with_span": n_pos, "seed": args.seed}, ensure_ascii=False) + "\n",
        encoding="utf-8")
    print(f"wrote {len(chosen)} cases ({n_pos} with name/addr spans) -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
