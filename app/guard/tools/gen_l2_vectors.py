"""生成 L2 语义层的向量：字节流 -> 每个数字游程的分类（金标给出期望）。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.l2_int4 import CLASS_NAMES, semantic_scan  # noqa: E402

CASES: list[bytes] = [
    "身份证 330203300422240391".encode(),
    "银行卡 6222020000000000001".encode(),
    "手机号 13800138000".encode(),
    "号码 330203300422240391".encode(),
    "身份证号：11010519491231002X".encode(),
    "身份证 330203300422240391 和 手机号 13800138000".encode(),
    "订单 2024 年，手机号 13800138000。".encode(),
    "卡号 6222020000000000001，邮箱 a@b.co，手机号 13900139000".encode(),
    "身份证 11010519491231002X".encode(),
    "没有数字的一段话".encode(),
    "手机号13800138000999".encode(),
    "身份证 330203300422240391".encode() + bytes([0x0A]),
]


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/l2")
    out.mkdir(parents=True, exist_ok=True)
    total = 0
    with (out / "manifest.txt").open("w", encoding="utf-8") as mf:
        for i, data in enumerate(CASES):
            (out / f"case_{i:04d}.in").write_bytes(data)
            rows = semantic_scan(data)
            with (out / f"case_{i:04d}.exp").open("w", encoding="utf-8") as ef:
                for start, ln, cls, sc in rows:
                    ef.write(f"{start} {ln} {cls} {sc[0]} {sc[1]} {sc[2]} {sc[3]}\n")
            mf.write(f"{i}\n")
            total += len(rows)
    print(f"l2: {len(CASES)} cases, {total} runs -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
