"""从 host/golden/keywords.py 生成 RTL 关键词表（SV package）。

输出：build/gen/l1_keywords_pkg.sv，按 kid 顺序给出每个关键词的字节和长度，
`rtl/l1/l1_keyword_match.sv` 直接 import 这个 package。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.keywords import KEYWORDS, MAX_KEYWORD_BYTES  # noqa: E402


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/gen/l1_keywords_pkg.sv")
    out.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        "// 由 tools/gen_keywords.py 生成，勿手改",
        "`ifndef L1_KEYWORDS_PKG_SV",
        "`define L1_KEYWORDS_PKG_SV",
        "package l1_keywords_pkg;",
        f"    localparam int NKW   = {len(KEYWORDS)};",
        f"    localparam int KWMAX = {MAX_KEYWORD_BYTES};",
    ]
    for i, kw in enumerate(KEYWORDS):
        bs = kw.encode("utf-8")
        val = 0
        for j, b in enumerate(bs):
            val |= b << (j * 8)
        lines.append(f"    // {i}: {kw} ({len(bs)} B)")
        lines.append(f"    localparam logic [{MAX_KEYWORD_BYTES * 8 - 1}:0] KW{i} = {MAX_KEYWORD_BYTES * 8}'h{val:0{MAX_KEYWORD_BYTES * 2}x};")
        lines.append(f"    localparam int KW{i}_LEN = {len(bs)};")
    lines += [
        "    function automatic logic [7:0] kw_byte(input int k, input int i);",
        "        logic [KWMAX*8-1:0] v;",
        "        v = '0;",
        "        case (k)",
    ]
    for i in range(len(KEYWORDS)):
        lines.append(f"            {i}: v = KW{i};")
    lines += [
        "            default: v = '0;",
        "        endcase",
        "        kw_byte = v[i*8 +: 8];",
        "    endfunction",
        "",
        "    function automatic int kw_len(input int k);",
        "        case (k)",
    ]
    for i in range(len(KEYWORDS)):
        lines.append(f"            {i}: kw_len = KW{i}_LEN;")
    lines += [
        "            default: kw_len = 0;",
        "        endcase",
        "    endfunction",
        "endpackage",
        "`endif",
    ]
    out.write_text("\n".join(lines) + "\n")
    print(f"keywords pkg: {len(KEYWORDS)} keywords -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
