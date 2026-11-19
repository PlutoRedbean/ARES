"""Generate raw MMIO frames and their expected pre-UART bytes from the Guard oracle."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "app/guard"))
from host.golden.board_proto import frame_stream

cases = [
    b"\n", b"13800138000", "手机 13800138000，邮箱 a@b.co\n".encode(),
    b"a\r\n", b"\xff / \x00\n", b"bank 123 456 789 4321 7788",
    b"x " * 400 + b"13800138000\n",
]
for length in (56, 63, 64, 65, 127, 128, 255, 256, 257):
    cases.append(b"." * (length - 12) + b"13800138000\n")

cases.append(b"last frame with a UART overrun\n")

out = root / "build/rtos_amp/guard_mmio_cases.txt"
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w") as f:
    for index, data in enumerate(cases):
        fault = int(index == len(cases) - 1)
        expected = frame_stream(data, at_line_start=data.endswith(b"\n")).replace(b"\r\n", b"\n")
        if fault:
            expected = expected.replace(b" ovf=000 ", b" ovf=001 ")
        print(len(data), len(expected), fault, file=f)
        print(data.hex(" "), expected.hex(" "), file=f)
