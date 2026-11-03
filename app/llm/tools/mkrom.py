#!/usr/bin/env python3
"""Generate rtl/board/boot_rom.v from build/fw/loader.bin.

The boot ROM is a combinational 16-byte-line table: it holds the UART loader
that receives a firmware image into 0x8000_0000 and jumps there.  Paths are
relative to the project root (the parent of this tools/ directory), so the
script works from any checkout location.

    python3 tools/mkrom.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "build" / "fw" / "loader.bin"
OUT = ROOT / "rtl" / "board" / "boot_rom.v"

b = SRC.read_bytes()
lines = [
    "// ---------------------------------------------------------------------------",
    "// boot_rom.v - GENERATED from build/fw/loader.bin.  Do not edit.",
    f"// Size   : {len(b)} bytes ({((len(b)+15)//16)} x 16-byte blocks)",
    "// ---------------------------------------------------------------------------",
    "module boot_rom (",
    "    input  wire [11:0]  idx,",
    "    output reg  [127:0] data",
    ");",
    "    always @(*) begin",
    "        case (idx)",
]
for idx in range((len(b) + 15) // 16):
    chunk = b[idx * 16:(idx + 1) * 16]
    chunk = chunk + b"\0" * (16 - len(chunk))
    ws = [int.from_bytes(chunk[i:i + 4], "little") for i in range(0, 16, 4)]
    hx = "".join(f"{w:08X}" for w in reversed(ws))
    lines.append(f"            12'd{idx}: data = 128'h{hx};")
lines += ["            default: data = 128'd0;", "        endcase", "    end", "endmodule", ""]
OUT.write_text("\n".join(lines), encoding="utf-8")
print(len(b), (len(b) + 15) // 16, OUT)
