"""Generate RGB565 rasters and independent NumPy expectations for the RTL TB."""
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app/gesture/pc"))
from calibrate_motion import difference, reduce_luma

out = Path("build/gesture_motion")
out.mkdir(parents=True, exist_ok=True)
black = np.zeros((720, 1280), dtype=np.uint16)
white = np.full_like(black, 0xffff)
corner = black.copy()
corner[:80, :80] = 0xf800
separated = corner.copy()
separated[-80:, -80:] = 0x07e0
# Blue level 14 expands to 115, yielding luma 13.
# Tune each 4x4 cell's sum around the strict floor(mean) > 12 cutoff.
threshold = black.copy()
threshold[:80, :80] = 0x000e
threshold[0, 0] = 0  # one reduced sample falls below 13: tile mean becomes 12
threshold[:80, 80:160] = 0x000e
rng = np.random.default_rng(214)
texture = rng.integers(0, 65536, size=black.shape, dtype=np.uint16)
# Removing exactly one source column per 4x4 cell exercises all 16 contributions.
stripes = texture.copy()
stripes[:, 1::4] = 0
# (pixels, line count, width of line 17, reset before frame)
cases = [(black, 720, 1280, 0), (black, 720, 1280, 0), (corner, 720, 1280, 0),
         (separated, 720, 1280, 0), (black, 720, 1280, 0), (threshold, 720, 1280, 0),
         (black, 720, 1280, 0), (white, 720, 1280, 0), (texture, 720, 1280, 0),
         (stripes, 720, 1280, 0), (white, 100, 1280, 0), (white, 720, 1280, 0),
         (black, 720, 1280, 0), (white, 720, 1279, 0), (white, 720, 1280, 0),
         (white, 720, 1281, 0), (black, 721, 1280, 0), (white, 720, 1280, 0),
         (white, 720, 1280, 1), (black, 720, 1280, 0)]


previous = None
seq = 0
with (out / "frames.bin").open("wb") as images, (out / "expected.txt").open("w") as expects:
    for pixels, rows, width, reset in cases:
        if reset:
            previous = None
            seq = 0
        seq += 1
        pixels.astype(">u2").tofile(images)
        current = reduce_luma(pixels) if (rows, width) == (720, 1280) else None
        valid = previous is not None and current is not None
        mean = count = mask = 0
        if valid:
            mean, strengths = difference(previous, current)
            bits = strengths.ravel() > 12
            count = int(bits.sum())
            mask = int.from_bytes(np.packbits(bits, bitorder="little").tobytes(), "little")
        print(rows, width, reset, seq, int(valid), mean, count, f"{mask:036x}", file=expects)
        previous = current
