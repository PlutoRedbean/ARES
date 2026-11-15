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
from host.golden.pii_rules import scan  # noqa: E402


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
            mf.write(f"{i}\n")

    print(f"vectors: {args.n} cases, {total_spans} spans -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
