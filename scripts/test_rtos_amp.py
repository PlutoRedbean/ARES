#!/usr/bin/env python3
"""Check DVP-to-UART gestures, four-hart CoreMark, and AI resume."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / "build/rtos_amp"
# Invert the model input quantization and choose the closest neutral RGB565
# pixel in the OV5640's BGR byte order. Use the same fixture as ai selftest.
weights = root / "app/gesture/firmware/app/rps_weights.h"
packed = re.search(r"rps_imgs\[\d+\] = \{([^}]+)", weights.read_text())[1]
quantized = [int(value) for value in packed.split(",")[:4096:4]]
grays = []
for value in range(256):
    r, g, b = value >> 3, value >> 2, value >> 3
    luma = (77 * ((r << 3) | (r >> 2)) +
            150 * ((g << 2) | (g >> 4)) +
            29 * ((b << 3) | (b >> 2))) >> 8
    grays.append((luma, (b << 11) | (g << 5) | r))
patch = [min(grays, key=lambda pair: abs((pair[0] * 194 >> 8) - q))[1]
         for q in quantized]
(out / "camera_patch.hex").write_text("".join(f"{pixel:04x}\n" for pixel in patch))

commands = (
    "ps\necall\nsleep 3\nai selftest\n"
    "ai start\nsleep 140\ncoremark start 1\ncoremark start 2 validation\n"
    "sleep 140\nai stop\nai status\n"
    "ai selftest\nirq\nquit\n"
)
result = subprocess.run(
    [str(out / "model/run"), "--max-ms", "650", "+camera"],
    input=commands, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    cwd=root, timeout=360,
)
log = result.stdout
path = out / "acceptance.log"
path.write_text(log)


def require(condition, message):
    if not condition:
        raise SystemExit(f"{message}. UART log: {path}")


require(result.returncode == 0, f"Simulator exited with {result.returncode}")
require("FAIL" not in log and "ERROR!" not in log, "Firmware reported a failure")
for line in ("Camera crop corners PASS", "ecall PASS", "slept 3 ms", "ARES SHELL EXIT"):
    require(line in log, f"Missing {line}")
for name in ("tshell", "coremark", "ai"):
    require(re.search(rf"^{name}\s+\d+\s+\d+\s+\d+$", log, re.M),
            f"Missing RT-Thread thread {name}")
require(re.search(r"timer_irq=[1-9]\d*", log), "RTOS tick interrupt never fired")

reports = log.split("AMP CoreMark PASS")
require(len(reports) == 3, "Expected two successful CoreMark reports")
ai = r"^AI selftest PASS: scores (-?\d+,-?\d+,-?\d+), golden diff 0$"
first_ai = re.findall(ai, reports[0], re.M)
require(len(first_ai) == 1 and first_ai == re.findall(ai, reports[2], re.M),
        "AI golden results differ before and after CoreMark")
require(reports[0].index("AI selftest PASS") < reports[0].index("Running CoreMark"),
        "AI did not run before CoreMark")
require("AI selftest PASS" not in reports[1], "Unexpected selftest between the benchmarks")
gesture = r"^hand: scissors margin (?:[4-9]|[1-9]\d+)$"
require(re.search(gesture, reports[0], re.M), "Missing live gesture before CoreMark")
require(re.search(gesture, reports[2], re.M), "Missing live gesture after CoreMark")
require("hand: none" in reports[0].split("coremark start 1")[-1],
        "AI did not clear the held gesture before the benchmark")
for report in reports[:2]:
    timed = report.split("Running CoreMark", 1)[1]
    require("hand:" not in timed, "Gesture UART output during CoreMark")
require("AI stopped" in reports[2], "AI did not stop")

for report, iterations, seed, expected in zip(
    reports[:2], (4, 8), ("e9f5", "18f2"),
    (("e714", "1fd7", "8e3a"), ("e3c1", "0747", "8d84")),
):
    require(re.search(rf"^Iterations\s*:\s*{iterations}$", report, re.M),
            f"Wrong aggregate iteration count for seed {seed}")
    require("Parallel ares-mt-mbox : 4" in report, "Missing four-hart aggregate report")
    require(re.search(rf"^seedcrc\s*:\s*0x{seed}$", report, re.M),
            f"Wrong seeds for run {seed}")
    require("CoreMark short run: CRC check only" in report, "Short run is not labeled")
    for field, crc in zip(("crclist", "crcmatrix", "crcstate"), expected):
        values = re.findall(rf"^\[(\d)\]{field}\s*:\s*0x([0-9a-f]{{4}})$", report, re.M)
        require(values == [(str(hart), crc) for hart in range(4)],
                f"Wrong {field} values for seed {seed}: {values}")
    final = re.findall(r"^\[(\d)\]crcfinal\s*:\s*0x([0-9a-f]{4})$", report, re.M)
    require([hart for hart, _ in final] == ["0", "1", "2", "3"] and
            len({crc for _, crc in final}) == 1, f"Final CRC mismatch for seed {seed}")

print(f"RTOS AMP PASS: DVP gestures -> two four-hart CoreMark runs -> DVP gestures. UART log: {path}")
