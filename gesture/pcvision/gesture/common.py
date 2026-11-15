"""Shared constants and helpers for the ScreenSense gesture pipeline.

The hardware only accepts 1280x720 RGB and produces an 80x45 per-cell class
heatmap (see docs/MODEL.md), so every tool in this package works in that
geometry.  Data and checkpoints live in the isolated workspace
($QS_GESTURE_HOME), never in the git repo.
"""

from __future__ import annotations

import csv
import itertools
import json
import os
import random
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
for _p in (str(REPO), str(REPO / "ml"), str(REPO / "pcvision")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

FRAME_W, FRAME_H = 1280, 720
GRID_W, GRID_H = 80, 45
CELL = 16                       # one grid cell covers 16x16 input pixels

DEFAULT_NAMES = [
    "background",
    "fist",
    "open_palm",
    "point",
    "victory",
    "thumbs_up",
    "ok",
]


def workspace() -> Path:
    """Training workspace: $QS_GESTURE_HOME, else <repo>/../gesture-env,
    else <repo>/../../gesture-env (rule: docs/GESTURE.md §2)."""
    env = os.environ.get("QS_GESTURE_HOME")
    if env:
        return Path(env)
    primary = REPO.parent / "gesture-env"
    if not primary.exists():
        legacy = REPO.parent.parent / "gesture-env"
        if legacy.exists():
            return legacy
    return primary


def data_dir() -> Path:
    return Path(os.environ.get("QS_GESTURE_DATA", workspace() / "data"))


def runs_dir() -> Path:
    return Path(os.environ.get("QS_GESTURE_RUNS", workspace() / "runs"))


def out_dir() -> Path:
    return Path(os.environ.get("QS_GESTURE_OUT", workspace() / "out"))


def raw_dir() -> Path:
    return data_dir() / "raw"


def ensure_dirs() -> None:
    for p in (raw_dir(), runs_dir(), out_dir(), workspace() / "tmp"):
        p.mkdir(parents=True, exist_ok=True)


def seed_everything(seed: int = 0) -> None:
    random.seed(seed)
    np.random.seed(seed)
    os.environ["PYTHONHASHSEED"] = str(seed)
    try:
        import torch
        torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)
    except ImportError:
        pass


# --------------------------------------------------------------------------- #
# classes
# --------------------------------------------------------------------------- #

def classes_path() -> Path:
    return data_dir() / "classes.json"


def load_classes(path: str | os.PathLike | None = None) -> list[str]:
    p = Path(path) if path else classes_path()
    if p.exists():
        d = json.loads(p.read_text(encoding="utf-8"))
        names = d["names"] if isinstance(d, dict) else d
    else:
        names = list(DEFAULT_NAMES)
    if not names or names[0] != "background":
        names = ["background"] + [str(n) for n in names if n != "background"]
    return [str(n) for n in names]


def save_classes(names: list[str], path: str | os.PathLike | None = None) -> Path:
    p = Path(path) if path else classes_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "names": names,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "note": "index 0 is background; keys 1..N-1 are gestures",
    }
    p.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return p


def parse_names(spec: str | None) -> list[str]:
    """'fist,open_palm,point' -> ['background','fist','open_palm','point']."""
    if not spec:
        return load_classes()
    names = ["background"] + [s.strip() for s in spec.split(",") if s.strip()]
    seen = set()
    for n in names:
        if n in seen:
            raise SystemExit(f"duplicate class name: {n}")
        seen.add(n)
    return names


# --------------------------------------------------------------------------- #
# geometry
# --------------------------------------------------------------------------- #

def letterbox(frame: np.ndarray, width: int = FRAME_W, height: int = FRAME_H) -> np.ndarray:
    """Resize preserving aspect ratio and pad with black to exactly WxH."""
    h, w = frame.shape[:2]
    scale = min(width / w, height / h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    cv2 = _cv2()
    interp = cv2.INTER_AREA if scale <= 1.0 else cv2.INTER_LINEAR
    resized = cv2.resize(frame, (nw, nh), interpolation=interp)
    canvas = np.zeros((height, width, 3), dtype=np.uint8)
    x0, y0 = (width - nw) // 2, (height - nh) // 2
    canvas[y0:y0 + nh, x0:x0 + nw] = resized
    return canvas


def _cv2():
    import cv2
    return cv2


def cv2_interp():
    import cv2
    return cv2.INTER_AREA


def cell_of(x: float, y: float) -> tuple[int, int]:
    gx = min(GRID_W - 1, max(0, int(x) * GRID_W // FRAME_W))
    gy = min(GRID_H - 1, max(0, int(y) * GRID_H // FRAME_H))
    return gx, gy


def gaussian_target(cls: int, x: float, y: float, num_classes: int,
                    sigma: float = 2.0) -> np.ndarray:
    """(K,45,80) target: gaussian on the gesture class.

    Negative frames set background=1 everywhere.  Positive frames leave the
    background channel at 0, so the global argmax cannot pick background where
    a gesture is present.
    """
    t = np.zeros((num_classes, GRID_H, GRID_W), dtype=np.float32)
    if cls <= 0:
        t[0] = 1.0
        return t
    gx, gy = cell_of(x, y)
    if sigma <= 0:
        t[cls, gy, gx] = 1.0
        return t
    yy, xx = np.mgrid[0:GRID_H, 0:GRID_W]
    d2 = (xx - gx) ** 2 + (yy - gy) ** 2
    g = np.exp(-d2 / (2.0 * sigma * sigma)).astype(np.float32)
    g[g < 1e-3] = 0.0
    t[cls] = g
    # On a positive frame the background class must lose everywhere; only
    # negative frames teach the background channel to be high.
    return t


# --------------------------------------------------------------------------- #
# labels
# --------------------------------------------------------------------------- #

@dataclass
class Label:
    file: str
    cls: int
    x: int
    y: int
    session: str = ""

    @property
    def is_negative(self) -> bool:
        return self.cls == 0


LABEL_COLUMNS = ["file", "cls", "x", "y", "session"]


def labels_path(root: str | os.PathLike | None = None) -> Path:
    return Path(root or raw_dir()) / "labels.csv"


def read_labels(root: str | os.PathLike | None = None) -> list[Label]:
    path = labels_path(root)
    if not path.exists():
        return []
    out: list[Label] = []
    with path.open(encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            try:
                cls = int(row.get("cls", 0) or 0)
                x = int(float(row.get("x", -1) or -1))
                y = int(float(row.get("y", -1) or -1))
            except (TypeError, ValueError):
                continue
            out.append(Label(row.get("file", ""), cls, x, y, row.get("session", "") or ""))
    return out


def write_labels(labels: list[Label], root: str | os.PathLike | None = None) -> None:
    path = labels_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(LABEL_COLUMNS)
        for l in labels:
            w.writerow([l.file, l.cls, l.x, l.y, l.session])


def append_label(label: Label, root: str | os.PathLike | None = None) -> None:
    path = labels_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    fresh = not path.exists() or path.stat().st_size == 0
    with path.open("a", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        if fresh:
            w.writerow(LABEL_COLUMNS)
        w.writerow([label.file, label.cls, label.x, label.y, label.session])
        f.flush()


def _split_by_session(labels: list[Label], val_frac: float) -> tuple[list[Label], list[Label]]:
    """Choose whole sessions for val, preferring class coverage then size."""
    sessions = sorted({l.session or "legacy" for l in labels})
    if len(sessions) < 2:
        return [], []
    n_val = max(1, int(round(len(sessions) * val_frac)))
    n_val = min(n_val, len(sessions) - 1)
    total = max(1, len(labels))
    best = None
    for combo in itertools.combinations(sessions, n_val):
        chosen = set(combo)
        val = [l for l in labels if (l.session or "legacy") in chosen]
        train = [l for l in labels if (l.session or "legacy") not in chosen]
        cover = len({l.cls for l in val})
        score = (cover, -abs(len(val) / total - val_frac), len(val))
        if best is None or score > best[0]:
            best = (score, train, val)
    return best[1], best[2]


def _split_stratified(labels: list[Label], val_frac: float, seed: int) -> tuple[list[Label], list[Label]]:
    """Per-class random split.  Use when session split cannot cover all classes."""
    rng = random.Random(seed)
    by_cls: dict[int, list[Label]] = {}
    for l in labels:
        by_cls.setdefault(l.cls, []).append(l)
    train, val = [], []
    for cls in sorted(by_cls):
        items = by_cls[cls]
        rng.shuffle(items)
        if len(items) > 1:
            n = max(1, int(round(len(items) * val_frac)))
            n = min(n, len(items) - 1)
        else:
            n = 0
        val.extend(items[:n])
        train.extend(items[n:])
    rng.shuffle(val)
    rng.shuffle(train)
    return train, val


def split_labels(labels: list[Label], val_frac: float = 0.2, seed: int = 0,
                 mode: str = "auto") -> tuple[list[Label], list[Label]]:
    """Split train/val.

    mode="session"    whole sessions only (no near-duplicate leakage, but a
                      partial session can leave val without some classes);
    mode="stratified" per-class random split (always covers classes, small
                      leakage risk between adjacent recorded frames);
    mode="auto"       prefer a session split that covers all classes and keeps
                      at least half the data for training, else stratified.
    """
    if mode not in ("auto", "session", "stratified"):
        raise ValueError("split mode must be auto/session/stratified")
    if not labels:
        return [], []
    if mode == "session":
        return _split_by_session(labels, val_frac)
    if mode == "stratified":
        return _split_stratified(labels, val_frac, seed)
    train, val = _split_by_session(labels, val_frac)
    need = {l.cls for l in labels}
    got = {l.cls for l in val}
    if (val and need <= got and len(train) >= 0.5 * len(labels)
            and len(val) <= 0.5 * len(labels)):
        return train, val
    return _split_stratified(labels, val_frac, seed)


def class_counts(labels: list[Label]) -> dict[int, int]:
    counts: dict[int, int] = {}
    for l in labels:
        counts[l.cls] = counts.get(l.cls, 0) + 1
    return dict(sorted(counts.items()))


# --------------------------------------------------------------------------- #
# metrics
# --------------------------------------------------------------------------- #

def confusion_matrix(y_true: list[int], y_pred: list[int], k: int) -> np.ndarray:
    cm = np.zeros((k, k), dtype=np.int64)
    for t, p in zip(y_true, y_pred):
        if 0 <= t < k and 0 <= p < k:
            cm[t, p] += 1
    return cm


def accuracy_report(y_true: list[int], y_pred: list[int], names: list[str]) -> dict:
    k = len(names)
    cm = confusion_matrix(y_true, y_pred, k)
    total = int(cm.sum())
    correct = int(np.trace(cm))
    per_class = {}
    for c in range(k):
        n = int(cm[c].sum())
        rec = float(cm[c, c] / n) if n else None
        per_class[names[c]] = {"n": n, "recall": rec}
    negatives = [p for t, p in zip(y_true, y_pred) if t == 0]
    fpr = float(sum(1 for p in negatives if p != 0) / len(negatives)) if negatives else None
    return {
        "n": total,
        "accuracy": correct / total if total else 0.0,
        "per_class": per_class,
        "negative_false_positive_rate": fpr,
        "confusion": cm.tolist(),
        "names": names,
    }


def format_report(rep: dict) -> str:
    lines = [f"samples {rep['n']}  frame-accuracy {rep['accuracy'] * 100:.2f}%"]
    lines.append("  per class: " + "  ".join(
        f"{n}:{v['n']}" + (f"/{v['recall'] * 100:.0f}%" if v['recall'] is not None else "")
        for n, v in rep["per_class"].items()))
    if rep["negative_false_positive_rate"] is not None:
        lines.append(f"  negative FPR {rep['negative_false_positive_rate'] * 100:.2f}%")
    cm = rep["confusion"]
    names = rep["names"]
    width = max(len(n) for n in names) + 1
    lines.append("  confusion (rows=true, cols=pred):")
    header = " " * width + " ".join(f"{n[:7]:>7}" for n in names)
    lines.append(header)
    for i, row in enumerate(cm):
        lines.append(f"  {names[i]:<{width}}" + " ".join(f"{v:>7d}" for v in row))
    return "\n".join(lines)


def write_json(path: str | os.PathLike, payload) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
