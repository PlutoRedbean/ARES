"""L1 金标命令行：扫描文本，输出 span（默认 JSON）。"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from host.golden.pii_rules import TYPE_NAMES, scan  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="L1 PII 金标扫描器")
    ap.add_argument("file", nargs="?", help="输入文件（缺省读 stdin）")
    ap.add_argument("--redact", action="store_true", help="同时输出脱敏后的文本")
    args = ap.parse_args(argv)

    data = Path(args.file).read_bytes() if args.file else sys.stdin.buffer.read()
    spans = scan(data)

    out = {
        "bytes": len(data),
        "spans": [
            {
                "type": s.name,
                "type_id": s.type,
                "start": s.start,
                "len": s.length,
                "text": data[s.start : s.start + s.length].decode("utf-8", "replace"),
            }
            for s in spans
        ],
    }
    if args.redact:
        buf, cur = bytearray(), 0
        for s in spans:
            buf += data[cur : s.start]
            buf += f"[{s.name.upper()}]".encode()
            cur = s.start + s.length
        buf += data[cur:]
        out["redacted"] = buf.decode("utf-8", "replace")

    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
