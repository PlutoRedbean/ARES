"""Evaluate a gesture checkpoint in float and bit-exact integer arithmetic.

Float numbers say whether the network learned the task.  The bit-exact pass
runs pcvision/gesture/hw_emulate.py on the exported .mat files and says whether the
quantised model that goes to the board still does.  Both are reported together
because a model can be accurate in float and collapse after quantisation.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import cv2
import numpy as np
import torch

from common import (
    GRID_W,
    accuracy_report,
    cell_of,
    format_report,
    letterbox,
    class_counts,
    load_classes,
    out_dir,
    raw_dir,
    read_labels,
    split_labels,
    write_json,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ml"))
from model_template import MundusDet  # noqa: E402
from hw_emulate import HWModel, detect  # noqa: E402


def load_checkpoint(ckpt: str) -> dict:
    return torch.load(ckpt, map_location="cpu")


def apply_threshold(preds, thresh):
    """Below-threshold gesture detections become background.

    thresh=None means "no threshold" and must stay that way: a trained model can
    have all-negative logits, so threshold 0 would hide every detection.
    """
    if thresh is None:
        return list(preds)
    return [p if (p[0] == 0 or p[3] >= thresh) else (0, p[1], p[2], p[3]) for p in preds]


def suggest_threshold(y_true, preds):
    """Midpoint between the strongest negative and the weakest true positive.

    Returns (threshold, clean_separation).  The board applies the same idea in
    frame_argmax (CONF_THRESH) or in the RV/PC post-process.
    """
    neg = [p[3] for t, p in zip(y_true, preds) if t == 0]
    pos = [p[3] for t, p in zip(y_true, preds) if t > 0]
    if not neg or not pos:
        # No way to calibrate a threshold on this split.  Do not invent 0.0:
        # a model with negative logits would then hide every detection.
        return None, False
    hi_neg, lo_pos = max(neg), min(pos)
    if hi_neg < lo_pos:
        return (hi_neg + lo_pos) / 2.0, True
    # overlapping confidences: pick the threshold with the best accuracy,
    # including "no threshold" as a candidate.
    best_t, best = None, -1.0
    for t in [None] + sorted(set(neg + pos)):
        acc = sum(1 for y, p in zip(y_true, preds)
                  if (0 if (p[0] > 0 and t is not None and p[3] < t) else p[0]) == y) / len(y_true)
        if acc > best:
            best_t, best = t, acc
    return (None if best_t is None else float(best_t)), False


def float_predict(net, files, batch, device):
    out = []
    with torch.no_grad():
        for i in range(0, len(files), batch):
            imgs = []
            for p in files[i:i + batch]:
                bgr = cv2.imread(str(p), cv2.IMREAD_COLOR)
                if bgr is None:
                    raise FileNotFoundError(p)
                if bgr.shape[1] != 1280 or bgr.shape[0] != 720:
                    bgr = letterbox(bgr)
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                x = (rgb.astype(np.float32) - 128.0) / 128.0
                imgs.append(torch.from_numpy(np.ascontiguousarray(x.transpose(2, 0, 1))))
            xb = torch.stack(imgs).to(device)
            ha, hb = net(xb)
            h = torch.cat([ha, hb], dim=1)                    # B,2K,45,80
            b, c = h.shape[:2]
            flat = h.reshape(b, c, -1)
            val, ch = flat.max(dim=1)                          # B,N
            best = val.argmax(dim=1)
            ar = torch.arange(b, device=device)
            cls = ch[ar, best] % (c // 2)
            conf = val[ar, best]
            for j in range(b):
                idx = int(best[j])
                out.append((int(cls[j]), idx % GRID_W, idx // GRID_W, float(conf[j])))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--data", default=str(raw_dir()))
    ap.add_argument("--mat", default=None, help="exported .mat directory for bit-exact eval")
    ap.add_argument("--split", choices=["val", "train", "all"], default="val")
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--max-samples", type=int, default=0, help="0 = all")
    ap.add_argument("--names", default=None)
    ap.add_argument("--val-frac", type=float, default=0.2)
    ap.add_argument("--split-mode", choices=["auto", "session", "stratified"], default=None,
                    help="defaults to the mode used for training (gesture.json)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default=str(out_dir() / "eval.json"))
    ap.add_argument("--no-float", action="store_true")
    ap.add_argument("--thresh", type=float, default=None,
                    help="force the confidence threshold used for bit-exact metrics")
    args = ap.parse_args()

    names = load_classes()
    if args.names:
        names = ["background"] + [s.strip() for s in args.names.split(",") if s.strip()]
    k = len(names)

    labels = read_labels(args.data)
    if not labels:
        raise SystemExit("no labels.csv")

    split_mode = args.split_mode
    if split_mode is None:
        meta_path = Path(args.ckpt).with_suffix(".json")
        split_mode = "auto"
        if meta_path.exists():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                split_mode = (meta.get("args") or {}).get("split_mode") or "auto"
            except Exception:  # noqa: BLE001
                split_mode = "auto"
    train_l, val_l = split_labels(labels, args.val_frac, args.seed, split_mode)
    if args.split == "val":
        eval_labels = val_l
    elif args.split == "train":
        eval_labels = train_l
    else:
        eval_labels = labels
    if args.max_samples and args.max_samples < len(eval_labels):
        rng = np.random.default_rng(args.seed)
        idx = sorted(rng.choice(len(eval_labels), args.max_samples, replace=False).tolist())
        eval_labels = [eval_labels[i] for i in idx]
    root = Path(args.data)
    files = [root / l.file for l in eval_labels]
    y_true = [l.cls for l in eval_labels]
    print(f"evaluating {len(eval_labels)} frames on split={args.split} "
          f"(mode={split_mode})")
    print("  classes:", class_counts(eval_labels))
    missing = [names[c] for c in range(k) if c not in {l.cls for l in eval_labels}]
    if missing:
        print("  warning: eval set has no samples for: " + ", ".join(missing))

    result = {"split": args.split, "split_mode": split_mode,
              "n": len(eval_labels), "names": names}
    if not args.no_float:
        device = "cuda" if torch.cuda.is_available() else "cpu"
        state = load_checkpoint(args.ckpt)
        if isinstance(state, dict) and "model" in state:
            state = state["model"]
        net = MundusDet(num_classes=k).to(device)
        net.load_state_dict(state)
        net.eval()
        preds = float_predict(net, files, args.batch, device)
        t_float, clean = suggest_threshold(y_true, preds)
        preds_t = apply_threshold(preds, t_float)
        y_pred = [p[0] for p in preds_t]
        rep = accuracy_report(y_true, y_pred, names)
        loc = [
            abs(p[1] - cell_of(l.x, l.y)[0]) <= 2 and abs(p[2] - cell_of(l.x, l.y)[1]) <= 2
            for p, l in zip(preds, eval_labels) if l.cls > 0
        ]
        rep["localisation_acc"] = float(np.mean(loc)) if loc else None
        rep["threshold"] = t_float
        rep["clean_separation"] = clean
        result["float"] = rep
        tstr = "none" if t_float is None else f"{t_float:.2f}"
        print(f"\n== float (PyTorch), threshold {tstr}"
              f"{' (clean gap)' if clean else ' (best-effort)'} ==")
        print(format_report(rep))
        if rep["localisation_acc"] is not None:
            print(f"  localisation within 2 cells: {rep['localisation_acc'] * 100:.2f}%")

    if args.mat:
        model = HWModel(args.mat)
        preds_int = []
        for i, (p, l) in enumerate(zip(files, eval_labels)):
            bgr = cv2.imread(str(p), cv2.IMREAD_COLOR)
            if bgr is None:
                raise FileNotFoundError(p)
            if bgr.shape[1] != 1280 or bgr.shape[0] != 720:
                bgr = letterbox(bgr)
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            preds_int.append(detect(model, rgb))
            if i % 25 == 0:
                print(f"  bit-exact {i}/{len(files)}", flush=True)
        t_int, clean_int = suggest_threshold(y_true, preds_int)
        if args.thresh is not None:
            t_int, clean_int = float(args.thresh), False
        preds_int_t = apply_threshold(preds_int, t_int)
        y_pred = [p[0] for p in preds_int_t]
        rep = accuracy_report(y_true, y_pred, names)
        loc = [
            abs(p[1] - cell_of(l.x, l.y)[0]) <= 2 and abs(p[2] - cell_of(l.x, l.y)[1]) <= 2
            for p, l in zip(preds_int, eval_labels) if l.cls > 0
        ]
        rep["localisation_acc"] = float(np.mean(loc)) if loc else None
        rep["threshold"] = t_int
        rep["clean_separation"] = clean_int
        result["bit_exact"] = rep
        tstr = "none" if t_int is None else f"{t_int:.1f}"
        print(f"\n== bit-exact (hw_emulate, what the board shows), threshold {tstr}"
              f"{' (clean gap)' if clean_int else ' (best-effort)'} ==")
        print(format_report(rep))
        if rep["localisation_acc"] is not None:
            print(f"  localisation within 2 cells: {rep['localisation_acc'] * 100:.2f}%")
        if "float" in result and y_pred:
            same = sum(1 for a, b in zip([p[0] for p in preds_t], y_pred) if a == b)
            result["float_int_agreement"] = same / len(y_pred)
            print(f"  float/int prediction agreement: {same / len(y_pred) * 100:.2f}%")

        # per-frame dump helps debug specific confusions
        dump = Path(args.out).with_suffix(".csv")
        with dump.open("w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["file", "true", "float", "int", "gx", "gy", "conf"])
            for i, (l, pi) in enumerate(zip(eval_labels, preds_int_t)):
                pf = preds_t[i][0] if not args.no_float else ""
                w.writerow([l.file, l.cls, pf, pi[0], pi[1], pi[2], pi[3]])
        print("  per-frame:", dump)

    write_json(args.out, result)
    print("\nresults ->", args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
