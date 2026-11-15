"""手工边界用例：形状固定、期望由金标给出（与 test_rules.py 的手写断言互补）。

输出格式与 gen_vectors 一致（.in/.exp/manifest.txt），可以直接用
`Vtb_l1_engine +dir=build/edges` 回放。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.pii_rules import scan  # noqa: E402

CASES: list[bytes] = [
    b"",
    b"   \t\n",
    b"- - -",
    # 身份证
    b"11010519491231002X",
    b"x11010519491231002Xy",
    b"1101 0519 4912 3100 2X",
    b"110105194913310020",          # 月份 13
    b"110105491231002",             # 15 位
    b"110105491332002",             # 15 位、月份 13
    # 银行卡 / 超长
    b"4111111111111111",
    b"4111 1111 1111 1111",
    b"4111111111111112",
    b"1234567890123456789",
    b"123456789012345678901",       # 21 位 -> 作废
    b"1380013800041111111111111111",  # 30 位纯数字 -> 作废
    # 手机
    b"13800138000",
    b"12800138000",
    # 邮箱
    b"a@b.co",
    b"user.name+tag@sub.example.com",
    b"a..b@example.com",
    b"a@b",
    b"a@b.com.",
    b"@example.com",
    b"a@-bad.com",
    b"a@" + b"x" * 64 + b".com",
    # IPv4
    b"255.255.255.255",
    b"256.1.1.1",
    b"01.2.3.4",
    b"1.2.3",
    b"1.2.3.4.",
    b"1.2.3.4@example.com",
    # USCC
    b"91350100M000100Y43",
    b"91350100M000100Y44",
    b"91350100M000100Y4",
    b"11010519491231002X",          # 全数字 18 位不应报 USCC
    # 车牌
    "京A12345".encode(),
    "沪B67890".encode(),
    "京A1234I".encode(),
    "京A12345的快递".encode(),
    "京A12345沪B67890".encode(),
    "粤Z1234港".encode(),
    # 混合
    "联系人张三，手机 138 0013 8000，邮箱 zs@example.com，车牌 京A12345。".encode(),
    b"id=11010519491231002X&ip=10.0.0.1&email=a@b.com",
]


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/edges")
    out.mkdir(parents=True, exist_ok=True)
    with (out / "manifest.txt").open("w", encoding="utf-8") as mf:
        for i, data in enumerate(CASES):
            (out / f"case_{i:04d}.in").write_bytes(data)
            spans = scan(data)
            with (out / f"case_{i:04d}.exp").open("w", encoding="utf-8") as ef:
                for s in spans:
                    ef.write(f"{s.start} {s.length} {s.type}\n")
            mf.write(f"{i}\n")
    total = sum(len(scan(c)) for c in CASES)
    print(f"edges: {len(CASES)} cases, {total} spans -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
