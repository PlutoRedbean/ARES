"""Live webcam demo of the trained gesture detector.

Runs the PyTorch model (fast) and the temporal action layer from actions.py.
For the exact board behaviour use evaluate.py --mat, which runs the integer
emulator on held-out frames.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import torch

from common import FRAME_H, FRAME_W, GRID_H, GRID_W, data_dir, load_classes, out_dir, parse_names
from capture_gestures import open_camera
from actions import ActionConfig, GestureActions, EventLog

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ml"))
from model_template import MundusDet  # noqa: E402


def color_for(cls: int) -> tuple[int, int, int]:
    rng = np.random.default_rng(cls * 977 + 13)
    return tuple(int(v) for v in rng.integers(60, 255, size=3))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--names", default=None, help="comma separated gesture names")
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--threshold", type=float, default=None,
                    help="minimum winning logit to report a gesture; defaults to the "
                         "float threshold suggested by out/eval.json")
    ap.add_argument("--events", default=None, help="write action events as JSONL")
    ap.add_argument("--no-actions", action="store_true")
    ap.add_argument("--mirror", action="store_true", default=None,
                    help="flip horizontally (defaults to data/settings.json)")
    args = ap.parse_args()

    if args.mirror is None:
        try:
            args.mirror = bool(json.loads((data_dir() / "settings.json").read_text()).get("mirror", False))
        except Exception:  # noqa: BLE001
            args.mirror = False

    names = parse_names(args.names) if args.names else load_classes()
    k = len(names)
    if args.threshold is None:
        ev = out_dir() / "eval.json"
        if ev.exists():
            try:
                f = json.loads(ev.read_text())["float"]
                if f.get("clean_separation") and f.get("threshold") is not None:
                    args.threshold = float(f["threshold"])
                    print(f"confidence threshold {args.threshold:.2f} (from {ev})")
                else:
                    print("no clean eval threshold; showing every gesture class")
            except Exception:  # noqa: BLE001
                pass
    state = torch.load(args.ckpt, map_location="cpu")
    if isinstance(state, dict) and "model" in state:
        state = state["model"]
    device = "cuda" if torch.cuda.is_available() else "cpu"
    net = MundusDet(num_classes=k).to(device)
    net.load_state_dict(state)
    net.eval()

    cap = open_camera(args.camera, args.width, args.height, 30)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"camera {w}x{h}, model {args.ckpt}, classes {names}")
    cv2.namedWindow("gesture live", cv2.WINDOW_AUTOSIZE)

    saved = {}
    try:
        saved = json.loads((data_dir() / "settings.json").read_text())
    except Exception:  # noqa: BLE001
        saved = {}
    actions = GestureActions(names, ActionConfig(
        hold_seconds=float(saved.get("action_hold", 0.8)),
        swipe_cells=int(saved.get("action_swipe", 6)),
        sequence_window=float(saved.get("action_seq", 1.2)),
    ))
    log = EventLog(args.events) if args.events else None
    recent: list[str] = []
    fps = 0.0
    pause = False
    last_t = time.time()

    while True:
        ok, frame = cap.read()
        if not ok or frame is None:
            break
        if not pause:
            view = letterbox_bgr(frame)
            if args.mirror:
                view = cv2.flip(view, 1)
            rgb = cv2.cvtColor(view, cv2.COLOR_BGR2RGB)
            x = (rgb.astype(np.float32) - 128.0) / 128.0
            xb = torch.from_numpy(np.ascontiguousarray(x.transpose(2, 0, 1)))[None].to(device)
            with torch.inference_mode():
                ha, hb = net(xb)
                hh = torch.cat([ha, hb], dim=1)
                flat = hh.flatten(2)
                val, ch = flat.max(dim=1)
                best = int(val.argmax(dim=1))
                cls = int(ch[0, best].item() % k)
                conf = float(val[0, best].item())
                gx, gy = best % GRID_W, best // GRID_W
                cls_logits = hh.amax(dim=(2, 3))[0]
                prob = float(torch.softmax(cls_logits, dim=0)[cls].item())
            now = time.time()
            inst = 1.0 / max(1e-6, now - last_t)
            last_t = now
            fps = inst if fps == 0 else 0.9 * fps + 0.1 * inst
            if not args.no_actions and (args.threshold is None or conf >= args.threshold):
                for ev in actions.update(cls, gx, gy, int(round(conf)), now):
                    recent.append(ev.to_dict())
                    recent = recent[-4:]
                    print(ev.to_dict(), flush=True)
                    if log:
                        log.write(ev)

            draw = view.copy()
            for gxx in range(0, FRAME_W, 160):
                cv2.line(draw, (gxx, 0), (gxx, FRAME_H), (35, 35, 35), 1)
            for gyy in range(0, FRAME_H, 160):
                cv2.line(draw, (0, gyy), (FRAME_W, gyy), (35, 35, 35), 1)
            show = cls > 0 and (args.threshold is None or conf >= args.threshold)
            if show:
                cx, cy = gx * 16 + 8, gy * 16 + 8
                x0, y0 = max(0, cx - 32), max(0, cy - 20)
                x1, y1 = min(FRAME_W - 1, x0 + 64), min(FRAME_H - 1, y0 + 40)
                col = color_for(cls)
                cv2.rectangle(draw, (x0, y0), (x1, y1), col, 2)
                cv2.putText(draw, f"{names[cls]} {conf:.1f} ({prob * 100:.0f}%)",
                            (x0, max(16, y0 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.65, col, 2)
            label = names[cls] if show else "no gesture"
            cv2.putText(draw, f"{label}   conf {conf:.1f}   cell ({gx},{gy})", (12, 30),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)
            cv2.putText(draw, f"{fps:.1f} fps  {device}  {'PAUSED' if pause else ''}",
                        (12, 62), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (220, 220, 220), 2)
            for i, ev in enumerate(recent):
                cv2.putText(draw, str(ev), (12, FRAME_H - 18 - 24 * i),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 220, 0), 1)
            cv2.imshow("gesture live", draw)

        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        if key == ord("p"):
            pause = not pause
        if key == ord("r"):
            actions.reset()
            recent.clear()
        if key == ord("s"):
            dst = out_dir() / "live"
            dst.mkdir(parents=True, exist_ok=True)
            p = dst / time.strftime("shot_%Y%m%d_%H%M%S.jpg")
            cv2.imwrite(str(p), draw)
            print("saved", p)

    cap.release()
    cv2.destroyAllWindows()
    if log:
        log.close()
    return 0


def letterbox_bgr(frame: np.ndarray) -> np.ndarray:
    from common import letterbox
    return letterbox(frame)


if __name__ == "__main__":
    raise SystemExit(main())
