"""Check production firmware, real DVP decoder, MMIO and M1 wire byte order."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "app/gesture/pc"))
from motion import parse

out = root / "build/rtos_amp"
log = out / "motion_uart.log"
with subprocess.Popen([out / "model/run", "+motion", "--max-ms", "180"], cwd=root,
                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.STDOUT) as sim, log.open("wb") as transcript:
    try:
        sim.stdin.write(b"motion\n")
        sim.stdin.flush()
        seen = False
        for line in sim.stdout:
            transcript.write(line)
            summary = parse(line)
            if summary and summary.valid and not seen:
                if (summary.mean, summary.count, summary.mask) != (
                        3, 2, bytes([1]) + bytes(16) + bytes([128])):
                    raise ValueError(f"unexpected M1 report: {line!r}")
                seen = True
                sim.stdin.write(b"\x1dquit\n")
                sim.stdin.flush()
        if sim.wait() or not seen:
            raise RuntimeError(f"Missing M1 report or shell exit: {log}")
    finally:
        if sim.poll() is None:
            sim.terminate()
if b"MOTION EXIT" not in log.read_bytes():
    raise RuntimeError(f"Shell did not exit the motion session: {log}")
print(f"DVP -> hart0 -> UART -> PC parser PASS: {log}")
