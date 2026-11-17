"""从 host/golden/l2_weights.py 生成 RTL 权重包（与关键词包同一套做法）。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.l2_int4 import L2_CLASSES, L2_FEATURES  # noqa: E402
from host.golden.l2_weights import W_INT4  # noqa: E402


def lit(v: int) -> str:
    return "-8'sd" + str(-v) if v < 0 else "8'sd" + str(v)


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/gen/l2_weights_pkg.sv")
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "// 由 tools/gen_l2_weights_sv.py 从 host/golden/l2_weights.py 生成，请勿手改。",
        "// 权重是 INT4（-8..7），在 l2_int4_gemm 里符号扩展到 INT8 后进 miniTensor 的阵列。",
        "`timescale 1ns/1ps",
        "",
        "package l2_weights_pkg;",
        "",
        "    function automatic logic signed [7:0] w4(input logic [1:0] c, input logic [2:0] f);",
        "        case ({c, f})",
    ]
    for c in range(L2_CLASSES):
        for row_start in (0, 4):
            parts = []
            for f in range(row_start, row_start + 4):
                w = W_INT4[c][f]
                assert -8 <= w <= 7
                parts.append("5'd" + str(c * 8 + f) + ": w4 = " + lit(w) + ";")
            lines.append("            " + "  ".join(parts))
    lines += [
        "            default: w4 = 8'sd0;",
        "        endcase",
        "    endfunction",
        "",
        "endpackage",
        "",
    ]
    out.write_text("\n".join(lines), encoding="utf-8")
    print("l2 weights pkg: " + str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
