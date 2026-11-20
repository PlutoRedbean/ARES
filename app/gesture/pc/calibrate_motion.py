"""Compare candidate FPGA block thresholds on two unmirrored 720p recordings."""
import argparse

import numpy as np


def reduce_luma(rgb565):
    """Use the sensor channel expansion and both FPGA floor operations."""
    r = (rgb565 >> 11).astype(np.int32)
    g = (rgb565 >> 5) & 63
    b = rgb565 & 31
    y = (77 * (8*r + r//4) + 150 * (4*g + g//16) + 29 * (8*b + b//4)) // 256
    return y.reshape(180, 4, 320, 4).sum(axis=(1, 3)) // 16


def difference(previous, current):
    diff = np.abs(current - previous)
    blocks = diff.reshape(9, 20, 16, 20).sum(axis=(1, 3)) // 400
    return int(diff.sum() // 57600), blocks


def histograms(path):
    import cv2
    cap = cv2.VideoCapture(path)
    peak = np.zeros(256, dtype=np.int64)
    tiles = np.zeros_like(peak)
    previous = None
    try:
        if not cap.isOpened():
            raise ValueError(f"Cannot open video {path}")
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            if frame.shape[:2] != (720, 1280):
                raise ValueError(f"{path}: expected full 1280x720 capture")
            b, g, r = frame.astype(np.uint16).transpose(2, 0, 1)
            current = reduce_luma(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
            if previous is not None:
                _, blocks = difference(previous, current)
                tiles += np.bincount(blocks.ravel(), minlength=256)
                peak[blocks.max()] += 1
            previous = current
    finally:
        cap.release()
    if peak.sum() == 0:
        raise ValueError(f"{path}: need at least two decoded frames")
    return peak, tiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("still", help="fixed camera, stationary scene")
    parser.add_argument("moving", help="same camera, annotated movement clip")
    parser.add_argument("--thresholds", type=int, nargs="+", default=[4, 8, 12, 16, 24])
    args = parser.parse_args()
    if any(t < 0 or t > 255 for t in args.thresholds):
        parser.error("thresholds must be 0..255")
    try:
        recordings = [histograms(path) for path in (args.still, args.moving)]
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    print("T,still_active_frame_pct,still_blocks_per_frame,moving_active_frame_pct,moving_blocks_per_frame")
    for t in args.thresholds:
        fields = [str(t)]
        for peak, tiles in recordings:
            pairs = peak.sum()
            fields.extend([f"{100 * peak[t+1:].sum() / pairs:.2f}",
                           f"{tiles[t+1:].sum() / pairs:.2f}"])
        print(",".join(fields))


if __name__ == "__main__":
    main()
