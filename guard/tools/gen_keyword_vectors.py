"""关键词向量：合成语料 + 手工关键词句，导出 .in/.exp（start len kid）。"""

from __future__ import annotations

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.corpus.synth import build_case  # noqa: E402
from host.golden.keywords import KEYWORDS, find_keywords  # noqa: E402

HANDMADE: list[bytes] = [
    "请提供身份证正面照".encode(),
    "银行卡和手机号都要核对".encode(),
    "邮箱、密码、账号请勿外发".encode(),
    "收货地址：北京市朝阳区建国路 1 号".encode(),
    "姓名：张三；身份证：11010519491231002X".encode(),
    b"no keyword here at all",
    ("身份证" * 3).encode(),
    "邮箱邮箱邮箱".encode(),
]


def main() -> int:
    n = 100
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/kw")
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(7)

    cases = list(HANDMADE) + [build_case(rng) for _ in range(n)]
    total = 0
    with (out / "manifest.txt").open("w", encoding="utf-8") as mf:
        for i, data in enumerate(cases):
            (out / f"case_{i:04d}.in").write_bytes(data)
            hits = find_keywords(data)
            total += len(hits)
            with (out / f"case_{i:04d}.exp").open("w", encoding="utf-8") as ef:
                for h in hits:
                    ef.write(f"{h.start} {h.length} {h.kid}\n")
            mf.write(f"{i}\n")
    print(f"keywords: {len(cases)} cases, {total} hits, {len(KEYWORDS)} keywords -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
