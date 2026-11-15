"""Train the hardware-matched gesture detector (MundusDet).

Loss = per-cell focal loss (CenterNet style) on both heads
     + frame-level cross entropy, because deployment takes the argmax over the
       whole frame, not a per-cell accuracy.

Only conv/ReLU is used, so the checkpoint drops straight into ml/export_mat.py.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

from common import (
    class_counts,
    ensure_dirs,
    load_classes,
    parse_names,
    raw_dir,
    read_labels,
    runs_dir,
    seed_everything,
    split_labels,
    write_json,
)
from dataset import make_loader

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ml"))
from model_template import MundusDet  # noqa: E402


def focal_loss(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """Per-image normalised CenterNet focal loss (averaged over the batch).

    Normalising per image keeps a one-object positive frame from being diluted
    by the thousands of background cells of a negative frame.
    """
    p = torch.sigmoid(logits).flatten(1)
    t = target.flatten(1)
    pos = t >= 0.999
    neg = ~pos
    pos_loss = (1.0 - p) ** 2 * torch.log(p.clamp_min(1e-6)) * pos
    neg_loss = (1.0 - t) ** 4 * p ** 2 * torch.log((1.0 - p).clamp_min(1e-6)) * neg
    per_image = -(pos_loss.sum(1) + neg_loss.sum(1)) / pos.sum(1).clamp_min(1)
    return per_image.mean()


def frame_logits(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """(B,K,H,W) x2 -> (B,K) strongest score per class anywhere in the frame."""
    h = torch.stack([a, b], dim=1)          # B,2,K,H,W
    return h.amax(dim=(1, 3, 4))            # max over head and space, keep class


def batch_loss(ha, hb, target, gt_cls, frame_weight: float):
    cell = 0.5 * (focal_loss(ha, target) + focal_loss(hb, target))
    fl = frame_logits(ha, hb)
    frame = F.cross_entropy(fl, gt_cls)
    return cell + frame_weight * frame, cell.detach(), frame.detach()


@torch.no_grad()
def evaluate(net, loader, device, frame_weight: float):
    net.eval()
    total, cell_sum, frame_sum, seen = 0.0, 0.0, 0.0, 0
    y_true, y_pred = [], []
    for xb, tb in loader:
        xb = xb.to(device, non_blocking=True)
        tb = tb.to(device, non_blocking=True)
        gt_cls = tb[:, 1:].amax(dim=(2, 3)).argmax(dim=1) + 1
        gt_cls = torch.where(tb[:, 0].amin(dim=(1, 2)) > 0.5, torch.zeros_like(gt_cls), gt_cls)
        ha, hb = net(xb)
        loss, cell, frame = batch_loss(ha, hb, tb, gt_cls, frame_weight)
        total += float(loss) * xb.size(0)
        cell_sum += float(cell) * xb.size(0)
        frame_sum += float(frame) * xb.size(0)
        seen += xb.size(0)
        pred = frame_logits(ha, hb).argmax(dim=1)
        y_true.extend(gt_cls.cpu().tolist())
        y_pred.extend(pred.cpu().tolist())
    net.train()
    return {
        "loss": total / max(1, seen),
        "cell_loss": cell_sum / max(1, seen),
        "frame_loss": frame_sum / max(1, seen),
        "frame_acc": float(np.mean(np.array(y_true) == np.array(y_pred))) if seen else 0.0,
        "n": seen,
        "y_true": y_true,
        "y_pred": y_pred,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data", default=str(raw_dir()), help="dataset root (labels.csv + images)")
    ap.add_argument("--out", default=str(runs_dir() / "gesture.pt"))
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--weight-decay", type=float, default=1e-4)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--sigma", type=float, default=2.0)
    ap.add_argument("--hflip", type=float, default=0.0)
    ap.add_argument("--frame-loss", type=float, default=1.0)
    ap.add_argument("--val-frac", type=float, default=0.2)
    ap.add_argument("--split-mode", choices=["auto", "session", "stratified"], default="auto")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--names", default=None, help="comma separated gesture names")
    ap.add_argument("--patience", type=int, default=20)
    args = ap.parse_args()

    ensure_dirs()
    seed_everything(args.seed)
    names = parse_names(args.names) if args.names else load_classes()
    k = len(names)
    if k < 2:
        raise SystemExit("need at least one gesture class plus background")

    labels = read_labels(args.data)
    if not labels:
        raise SystemExit(f"no labels.csv under {args.data}; record first: bash pcvision/gesture/record.sh")

    max_cls = max(l.cls for l in labels)
    if max_cls >= k:
        raise SystemExit(f"labels contain class {max_cls} but only {k} classes configured")
    train_labels, val_labels = split_labels(labels, args.val_frac, args.seed, args.split_mode)
    if not val_labels:
        val_labels = train_labels
        print("warning: no separate validation split (record more sessions)")

    print("classes:", ", ".join(f"{i}={n}" for i, n in enumerate(names)))
    counts = class_counts(train_labels)
    print("train:", len(train_labels), counts)
    val_counts = class_counts(val_labels)
    print("val  :", len(val_labels), val_counts)
    missing = [names[c] for c in range(k) if c not in val_counts]
    if missing:
        print("warning: validation set has no samples for: " + ", ".join(missing))
    if counts.get(0, 0) == 0:
        print("warning: no background (class 0) samples - the model will false-trigger; "
              "record the background stage")
    for c in range(1, k):
        if counts.get(c, 0) < 20:
            print(f"warning: class {c} ({names[c]}) has only {counts.get(c, 0)} train frames")

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print("device:", device, torch.cuda.get_device_name(0) if device == "cuda" else "")

    train_loader = make_loader(train_labels, args.data, names, True, args.batch,
                               args.workers, args.sigma, args.hflip, args.seed)
    val_loader = make_loader(val_labels, args.data, names, False, args.batch,
                             args.workers, args.sigma, 0.0, args.seed)

    net = MundusDet(num_classes=k).to(device)
    # A zero-init head starts at sigmoid(0)=0.5, which makes the focal loss sum
    # over thousands of negative cells explode (~1e3) and drowns the frame CE.
    # Start at p~0.01 like RetinaNet/CenterNet.
    with torch.no_grad():
        net.l7.bias.fill_(-4.595)
        net.l10.bias.fill_(-4.595)
    print("params:", sum(p.numel() for p in net.parameters()))
    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    steps = max(1, len(train_loader))
    warmup = max(1, int(0.05 * steps * args.epochs))
    def lr_at(step: int) -> float:
        if step < warmup:
            return args.lr * (step + 1) / warmup
        t = (step - warmup) / max(1, steps * args.epochs - warmup)
        return args.lr * (0.02 + 0.98 * 0.5 * (1.0 + np.cos(np.pi * t)))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    log_path = out.with_suffix(".csv")
    log_f = log_path.open("w", newline="", encoding="utf-8")
    log_w = csv.writer(log_f)
    log_w.writerow(["epoch", "train_loss", "val_loss", "val_acc", "cell_loss", "lr", "seconds"])

    best_acc, best_epoch, stale = -1.0, -1, 0
    meta = {"names": names, "args": vars(args), "created": time.strftime("%Y-%m-%dT%H:%M:%S")}
    step = 0
    for ep in range(args.epochs):
        t0 = time.time()
        net.train()
        train_loader.dataset.set_epoch(ep)
        running, seen = 0.0, 0
        for bi, (xb, tb) in enumerate(train_loader):
            for g in opt.param_groups:
                g["lr"] = lr_at(step)
            xb = xb.to(device, non_blocking=True)
            tb = tb.to(device, non_blocking=True)
            gt_cls = tb[:, 1:].amax(dim=(2, 3)).argmax(dim=1) + 1
            gt_cls = torch.where(tb[:, 0].amin(dim=(1, 2)) > 0.5, torch.zeros_like(gt_cls), gt_cls)
            ha, hb = net(xb)
            loss, cell, frame = batch_loss(ha, hb, tb, gt_cls, args.frame_loss)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(net.parameters(), 5.0)
            opt.step()
            step += 1
            running += float(loss) * xb.size(0)
            seen += xb.size(0)
            if bi % 20 == 0:
                print(f"  ep {ep:3d} {bi:4d}/{len(train_loader)} loss {float(loss):.4f} "
                      f"cell {float(cell):.4f} frame {float(frame):.4f}", flush=True)
        ev = evaluate(net, val_loader, device, args.frame_loss)
        lr_now = opt.param_groups[0]["lr"]
        log_w.writerow([ep, running / max(1, seen), ev["loss"], ev["frame_acc"],
                        ev["cell_loss"], lr_now, round(time.time() - t0, 1)])
        log_f.flush()
        print(f"epoch {ep:3d}  train {running / max(1, seen):.4f}  val {ev['loss']:.4f}  "
              f"frame-acc {ev['frame_acc'] * 100:.2f}%  {time.time() - t0:.1f}s", flush=True)
        if ev["frame_acc"] > best_acc:
            best_acc, best_epoch, stale = ev["frame_acc"], ep, 0
            torch.save({kk: v.detach().cpu() for kk, v in net.state_dict().items()}, out)
            meta.update(best_acc=best_acc, best_epoch=best_epoch)
            write_json(out.with_suffix(".json"), meta)
        else:
            stale += 1
        torch.save({kk: v.detach().cpu() for kk, v in net.state_dict().items()},
                   out.with_name(out.stem + "_last.pt"))
        if stale >= args.patience:
            print(f"early stop: no improvement in {args.patience} epochs")
            break

    log_f.close()
    if best_epoch < 0:
        torch.save({kk: v.detach().cpu() for kk, v in net.state_dict().items()}, out)
        meta.update(best_acc=0.0, best_epoch=args.epochs - 1)
        write_json(out.with_suffix(".json"), meta)
    print(f"best frame-acc {best_acc * 100:.2f}% @ epoch {best_epoch}")
    print("checkpoint:", out)
    print("meta      :", out.with_suffix(".json"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
