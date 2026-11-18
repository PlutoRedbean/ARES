"""把合成语料固化成 RTL 一致性向量。

每个用例生成两个文件：
  case_XXXX.in   —— 原始字节流（UTF-8）
  case_XXXX.exp  —— 期望命中，每行 "start len type"
外加 manifest.txt：每行一个用例序号（TB 用 --dir 拼路径）。

RTL 侧 `sim/tb_l1_digit_engine.sv` 按 manifest 逐条回放并逐条比对。
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.corpus.synth import build_case  # noqa: E402
from host.golden.entities import scan_with_entities  # noqa: E402
from host.golden.pii_rules import Span, scan  # noqa: E402
from host.golden.redact import merge, redact  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/vectors")
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--seed", type=int, default=20261115)
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)

    manifest = out / "manifest.txt"
    bench = out / "bench.txt"
    bench_chunks: list[bytes] = []
    total_spans = 0
    with manifest.open("w", encoding="utf-8") as mf:
        for i in range(args.n):
            name = f"case_{i:04d}"
            data = build_case(rng)
            spans = scan(data)
            total_spans += len(spans)
            (out / f"{name}.in").write_bytes(data)
            with (out / f"{name}.exp").open("w", encoding="utf-8") as ef:
                for s in spans:
                    ef.write(f"{s.start} {s.length} {s.type}\n")
            # .audit/.mask 是"脱敏后的样子"，要把 L2b 实体层算进去；.exp 仍只放 L1
            _l1, ents = scan_with_entities(data)
            merged = merge([Span(t, s, ln) for t, s, ln in _l1]
                           + [Span(t, s, ln) for t, s, ln in ents])
            masked, _ = redact(data, policy="mask", keep_spans=merged)
            (out / f"{name}.mask").write_bytes(masked)
            with (out / f"{name}.audit").open("w", encoding="utf-8") as af:
                for s2 in merged:
                    af.write(f"{s2.start} {s2.length} {s2.type}\n")
            mf.write(f"{i}\n")
            bench_chunks.append(data + b"\n")

    bench.write_bytes(b"".join(bench_chunks))
    print(f"vectors: {args.n} cases, {total_spans} spans, bench {bench.stat().st_size} B -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())