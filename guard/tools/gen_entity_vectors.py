"""L2b 实体层向量：字节流 -> 期望的 (type, start, len)（金标给出）。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.entities import scan_entities  # noqa: E402

CASES: list[bytes] = [
    "联系人张三，电话 13800138000".encode(),
    "姓名：李四".encode(),
    "王经理您好".encode(),
    "李老师来了".encode(),
    "地址：北京市朝阳区建国路88号".encode(),
    "住址：广东省深圳市南山区科技园1栋".encode(),
    "我住在杭州市西湖区文三路100号".encode(),
    "身份证 11010519491231002X".encode(),
    "订单号 330203300422240391".encode(),
    "联系人：李娜。".encode(),
    "联系人张三，地址：北京市朝阳区建国路88号；王经理的身份证 11010519491231002X。".encode(),
    "收件人王小明，电话 13900139000".encode(),
    "户名：赵六，账号 6222020000000000001".encode(),
    "张三丰和欧阳锋".encode(),
    "地址是上海市浦东新区世纪大道1号".encode(),
    "".encode(),
]


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/ent")
    out.mkdir(parents=True, exist_ok=True)
    total = 0
    with (out / "manifest.txt").open("w", encoding="utf-8") as mf:
        for i, data in enumerate(CASES):
            (out / f"case_{i:04d}.in").write_bytes(data)
            spans = scan_entities(data)
            with (out / f"case_{i:04d}.exp").open("w", encoding="utf-8") as ef:
                for ty, s, ln in spans:
                    ef.write(f"{s} {ln} {ty}\n")
            mf.write(f"{i}\n")
            total += len(spans)
    print(f"entity: {len(CASES)} cases, {total} spans -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
