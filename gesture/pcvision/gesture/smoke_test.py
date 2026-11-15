"""End-to-end smoke test on a synthetic dataset (no camera, no gestures).

Builds a tiny labelled dataset in $QS_GESTURE_OUT/smoke, then runs the real
CLIs: train -> export with calibration -> bit-exact verify -> float/int eval ->
hardware pack -> action unit tests.  This proves the chain is wired correctly
without touching the real dataset or the board.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np

from common import FRAME_H, FRAME_W, out_dir

NAMES = ["red_bar", "blue_circle", "green_cross"]
CLASSES = ["background"] + NAMES


def draw_hand(img, cls, cx, cy, rng):
    col = {1: (40, 40, 220), 2: (220, 80, 40), 3: (40, 200, 40)}[cls]
    axes = (int(rng.integers(70, 95)), int(rng.integers(50, 65)))
    cv2.ellipse(img, (cx, cy), axes, int(rng.integers(-15, 15)), 0, 360, col, -1)
    if cls == 1:      # vertical bars
        for i in range(4):
            x = cx - 60 + i * 40
            cv2.rectangle(img, (x, cy - 150), (x + 14, cy - 40), col, -1)
    elif cls == 2:    # circle
        cv2.circle(img, (cx, cy - 90), 46, col, -1)
    else:             # cross
        cv2.line(img, (cx - 55, cy - 95), (cx + 55, cy - 95), col, 22)
        cv2.line(img, (cx, cy - 150), (cx, cy - 40), col, 22)


def make_scene(cls, rng):
    img = np.full((FRAME_H, FRAME_W, 3), 30, np.uint8)
    g = np.linspace(0, 25, FRAME_W, dtype=np.float32)[None, :]
    for c in range(3):
        img[..., c] = np.clip(img[..., c].astype(np.float32) + g * (c + 1), 0, 255).astype(np.uint8)
    for _ in range(6):
        x, y = int(rng.integers(0, FRAME_W)), int(rng.integers(0, FRAME_H))
        cv2.rectangle(img, (x, y), (x + int(rng.integers(20, 120)),
                                    y + int(rng.integers(20, 90))),
                      tuple(int(v) for v in rng.integers(20, 120, 3)), -1)
    if cls == 0:
        return img, -1, -1
    cx = int(rng.integers(320, FRAME_W - 320))
    cy = int(rng.integers(280, FRAME_H - 240))
    draw_hand(img, cls, cx, cy, rng)
    noise = rng.normal(0, 4, img.shape)
    return np.clip(img.astype(np.float32) + noise, 0, 255).astype(np.uint8), cx, cy


def build_dataset(root: Path, sessions: int, per_class: int) -> None:
    root.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(7)
    rows = []
    for s in range(sessions):
        sid = f"smoke{s:02d}"
        for cls in range(len(CLASSES)):
            for i in range(per_class):
                img, cx, cy = make_scene(cls, rng)
                name = f"{sid}_c{cls}_{i:03d}.jpg"
                cv2.imwrite(str(root / name), img, [cv2.IMWRITE_JPEG_QUALITY, 90])
                rows.append([name, cls, cx, cy, sid])
    with (root / "labels.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "cls", "x", "y", "session"])
        w.writerows(rows)
    print(f"dataset: {len(rows)} frames, {sessions} sessions -> {root}")


def run(cmd, **kw):
    print("\n$", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run([str(c) for c in cmd], **kw)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sessions", type=int, default=3)
    ap.add_argument("--per-class", type=int, default=8)
    ap.add_argument("--epochs", type=int, default=4)
    ap.add_argument("--skip-pack", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the previous smoke dir")
    args = ap.parse_args()

    py = sys.executable
    repo = Path(__file__).resolve().parents[2]
    root = out_dir() / "smoke"
    if root.exists() and not args.keep:
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    raw = root / "raw"
    if not args.keep:
        build_dataset(raw, args.sessions, args.per_class)

    ckpt = root / "model.pt"
    mats = root / "mats"
    if run([py, repo / "pcvision/gesture/train_gestures.py", "--data", raw,
            "--out", ckpt, "--epochs", args.epochs, "--batch", 4, "--workers", 0,
            "--names", ",".join(NAMES), "--patience", 50]).returncode != 0:
        raise SystemExit("train failed")

    if run([py, repo / "ml/export_mat.py", "--ckpt", ckpt, "--out", mats,
            "--classes", len(CLASSES), "--calib-dir", raw, "--calib-count", 6]).returncode != 0:
        raise SystemExit("export failed")

    r = run([py, repo / "pcvision/gesture/hw_emulate.py", "--mat", mats, "--verify"])
    if r.returncode != 0:
        raise SystemExit("bit-exact verification failed")

    ev = root / "eval.json"
    if run([py, repo / "pcvision/gesture/evaluate.py", "--ckpt", ckpt, "--data", raw,
            "--mat", mats, "--split", "all", "--max-samples", 12,
            "--names", ",".join(NAMES), "--out", ev]).returncode != 0:
        raise SystemExit("evaluate failed")
    report = json.loads(ev.read_text(encoding="utf-8"))
    print("\nfloat acc:", report.get("float", {}).get("accuracy"),
          "| bit-exact acc:", report.get("bit_exact", {}).get("accuracy"))

    if not args.skip_pack:
        pack = root / "pack"
        if run([py, repo / "ml/pack_model.py", "--mat", mats,
                "--gen", repo / "fpga/python_script/CnnHardwareGenerator_pds.py",
                "--out-mem", pack / "mem_data", "--out-vh", pack / "header"]).returncode != 0:
            raise SystemExit("pack failed")
        n_vh = len(list((pack / "header").glob("*.vh")))
        n_mem = len(list((pack / "mem_data").glob("*.mem")))
        print(f"packed: {n_vh} .vh headers, {n_mem} .mem files")
        if n_vh == 0 or n_mem == 0:
            raise SystemExit("pack produced no files")

    r = run([py, repo / "pcvision/gesture/test_actions.py"])
    if r.returncode != 0:
        raise SystemExit("action tests failed")

    print("\nSMOKE OK - full PC chain works (synthetic data).")
    print("note: 4 epochs validates wiring only; accuracy is not a quality claim.")
    print("next: record real gestures with  bash pcvision/gesture/gesture.sh record")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
