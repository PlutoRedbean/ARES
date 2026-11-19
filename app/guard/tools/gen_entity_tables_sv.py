"""从 host/golden/entities.py 生成 RTL 的实体表（姓氏/锚点/职务/线索）。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.entities import (  # noqa: E402
    ADDR_ANCHORS,
    ADDR_CUES,
    NAME_CUES,
    NAME_TITLES,
    SURNAMES,
)


def hexc(ch: str) -> str:
    b = ch.encode("utf-8")
    assert len(b) == 3, ch
    return "24'h" + b.hex().upper()


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/gen/l2_entity_tables.sv")
    out.parent.mkdir(parents=True, exist_ok=True)
    L = []
    L.append("// 由 tools/gen_entity_tables_sv.py 从 host/golden/entities.py 生成，请勿手改。")
    L.append("`timescale 1ns/1ps")
    L.append("")
    L.append("package l2_entity_tables;")
    L.append("")
    # surname
    L.append("    function automatic logic is_surname(input logic [23:0] c);")
    L.append("        case (c)")
    for ch in SURNAMES:
        L.append("            " + hexc(ch) + ": is_surname = 1'b1;   // " + ch)
    L.append("            default: is_surname = 1'b0;")
    L.append("        endcase")
    L.append("    endfunction")
    L.append("")
    # anchors
    L.append("    function automatic logic is_anchor(input logic [23:0] c);")
    L.append("        case (c)")
    for ch in ADDR_ANCHORS:
        L.append("            " + hexc(ch) + ": is_anchor = 1'b1;   // " + ch)
    L.append("            default: is_anchor = 1'b0;")
    L.append("        endcase")
    L.append("    endfunction")
    L.append("")
    # titles (2 chars)
    L.append("    function automatic logic is_title2(input logic [23:0] a, input logic [23:0] b);")
    L.append("        case ({a, b})")
    for t in NAME_TITLES:
        L.append("            48'h" + (t[0].encode() + t[1].encode()).hex().upper() + ": is_title2 = 1'b1;   // " + t)
    L.append("            default: is_title2 = 1'b0;")
    L.append("        endcase")
    L.append("    endfunction")
    L.append("")
    # cues：按长度分别比较（{c1,c0} 这种拼接，旧的在高位）
    L.append("    function automatic logic [1:0] cue_kind(input logic [23:0] c0,")
    L.append("                                          input logic [23:0] c1,")
    L.append("                                          input logic [23:0] c2,")
    L.append("                                          input logic [23:0] c3);")
    L.append("        cue_kind = 2'd0;")
    seen = set()
    for kind, cues in ((1, NAME_CUES), (2, ADDR_CUES)):
        for cue in cues:
            n = len(cue)
            pat = b"".join(ch.encode() for ch in cue)
            if (n, pat) in seen:
                continue
            seen.add((n, pat))
            val = int.from_bytes(pat, "big")
            if n == 1:
                L.append("        if (c0 == 24'h" + format(val, "06X") + ") cue_kind = 2'd" + str(kind) + ";   // " + cue)
            elif n == 2:
                L.append("        if ({c1, c0} == 48'h" + format(val, "012X") + ") cue_kind = 2'd" + str(kind) + ";   // " + cue)
            elif n == 3:
                L.append("        if ({c2, c1, c0} == 72'h" + format(val, "018X") + ") cue_kind = 2'd" + str(kind) + ";   // " + cue)
            elif n == 4:
                L.append("        if ({c3, c2, c1, c0} == 96'h" + format(val, "024X") + ") cue_kind = 2'd" + str(kind) + ";   // " + cue)
            else:
                raise SystemExit("cue too long: " + cue)
    L.append("    endfunction")
    L.append("")
    L.append("endpackage")
    L.append("")
    out.write_text("\n".join(L), encoding="utf-8")
    print("entity tables: " + str(out) + " (" + str(len(SURNAMES)) + " surnames, " +
          str(len(NAME_CUES) + len(ADDR_CUES)) + " cues)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())