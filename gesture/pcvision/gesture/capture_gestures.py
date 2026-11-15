"""Record gesture frames from the local webcam.

Two modes:

  manual (default)  preview; press 1..9 to choose a gesture, Space to save,
                    0 for a background/negative frame, b toggles auto-save.
  --guided          one key per class: Space starts a 3 s countdown then
                    records --seconds at --save-fps, then moves to the next
                    class.  Much easier for a first dataset.

Frames are letterboxed to the hardware geometry (1280x720) and saved *without*
any overlay.  Labels go to <out>/labels.csv with the hand centre, so training
can build the per-cell heatmap target.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path

import cv2
import numpy as np

from common import (
    FRAME_H,
    FRAME_W,
    Label,
    append_label,
    class_counts,
    data_dir,
    ensure_dirs,
    letterbox,
    load_classes,
    parse_names,
    raw_dir,
    read_labels,
    save_classes,
    write_labels,
)


def open_camera(index: int, width: int, height: int, fps: int) -> cv2.VideoCapture:
    cap = cv2.VideoCapture(index, cv2.CAP_V4L2)
    if not cap.isOpened():
        cap = cv2.VideoCapture(index)
    if not cap.isOpened():
        raise SystemExit(
            f"cannot open camera {index}.  Is it in use?  Check: ls -l /dev/video*")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    for _ in range(8):
        cap.read()
    return cap


class HandTracker:
    """Optional MediaPipe hand centre; falls back to a fixed crosshair."""

    def __init__(self, wanted: str):
        self.hands = None
        self.wanted = wanted
        if wanted == "fixed":
            return
        try:
            import mediapipe as mp
            self._mp = mp
            self.hands = mp.solutions.hands.Hands(
                static_image_mode=False,
                max_num_hands=1,
                min_detection_confidence=0.5,
                min_tracking_confidence=0.5,
            )
            print("tracker: mediapipe hands")
        except Exception as exc:  # noqa: BLE001
            if wanted == "mediapipe":
                print(f"mediapipe unavailable ({exc}); falling back to fixed centre")
            else:
                print("tracker: fixed centre (install mediapipe for hand tracking)")
            self.hands = None

    def center(self, bgr: np.ndarray) -> tuple[int, int] | None:
        if self.hands is None:
            return None
        res = self.hands.process(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        if not res.multi_hand_landmarks:
            return None
        lm = res.multi_hand_landmarks[0].landmark
        xs = [p.x for p in lm]
        ys = [p.y for p in lm]
        return int((min(xs) + max(xs)) * 0.5 * FRAME_W), int((min(ys) + max(ys)) * 0.5 * FRAME_H)

    def close(self) -> None:
        if self.hands is not None:
            self.hands.close()


class Recorder:
    def __init__(self, args, names: list[str]):
        ensure_dirs()
        self.args = args
        self.names = names
        self.out = Path(args.out)
        self.out.mkdir(parents=True, exist_ok=True)
        if not (data_dir() / "classes.json").exists():
            save_classes(names)
        self.session = time.strftime("s%Y%m%d_%H%M%S")
        self.labels = read_labels(self.out)
        self.counts = class_counts(self.labels)
        self.start = time.time()
        self.saved = 0
        self.center_mode = args.tracker
        self.tracker = HandTracker(args.tracker)
        self.last_center: tuple[int, int] | None = None
        self.last_tracked = False
        self._mouse_center: tuple[int, int] | None = None
        self.cap = open_camera(args.camera, args.width, args.height, args.fps)
        w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        f = self.cap.get(cv2.CAP_PROP_FPS)
        print(f"camera {args.camera}: {w}x{h} @ {f:.1f} fps -> letterbox {FRAME_W}x{FRAME_H}")
        self.camera_info = {"index": args.camera, "width": w, "height": h, "fps": f}
        self.clean = np.zeros((FRAME_H, FRAME_W, 3), np.uint8)
        cv2.namedWindow("gesture capture", cv2.WINDOW_AUTOSIZE)
        cv2.setMouseCallback("gesture capture", self._on_mouse)

    def _on_mouse(self, event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            self._mouse_center = (int(x), int(y))

    def read(self) -> np.ndarray:
        ok, frame = self.cap.read()
        if not ok or frame is None:
            raise SystemExit("camera read failed")
        self.clean = letterbox(frame)
        if self.args.mirror:
            self.clean = cv2.flip(self.clean, 1)
        return self.clean

    def center_for(self, cls: int) -> tuple[int, int]:
        """Best available hand centre for the frame just read."""
        if self._mouse_center is not None:
            self.last_center = self._mouse_center
        tracked = self.tracker.center(self.clean)
        self.last_tracked = tracked is not None
        if tracked is not None:
            self.last_center = tracked
        elif self.last_center is None:
            self.last_center = (FRAME_W // 2, FRAME_H // 2)
        return self.last_center

    def save(self, cls: int, center: tuple[int, int] | None) -> bool:
        x, y = (-1, -1) if cls == 0 or center is None else (int(center[0]), int(center[1]))
        name = f"g_{self.session}_{int(time.time() * 1000):013d}_c{cls}.jpg"
        path = self.out / name
        ok = cv2.imwrite(str(path), self.clean, [cv2.IMWRITE_JPEG_QUALITY, self.args.quality])
        if not ok:
            print("warning: failed to write", path)
            return False
        append_label(Label(name, cls, x, y, self.session), self.out)
        self.labels.append(Label(name, cls, x, y, self.session))
        self.counts[cls] = self.counts.get(cls, 0) + 1
        self.saved += 1
        return True

    def undo(self) -> None:
        if not self.labels:
            return
        last = self.labels[-1]
        if last.session != self.session:
            print("undo: last frame belongs to an older session, ignored")
            return
        self.labels.pop()
        p = self.out / last.file
        if p.exists():
            p.unlink()
        self.counts[last.cls] = max(0, self.counts.get(last.cls, 1) - 1)
        # rewrite the csv without the removed row
        from common import write_labels
        write_labels(self.labels, self.out)
        print("undo", last.file)

    def overlay(self, view: np.ndarray, cls: int, center: tuple[int, int] | None,
                text: str) -> np.ndarray:
        img = view.copy()
        for gx in range(0, FRAME_W, 160):
            cv2.line(img, (gx, 0), (gx, FRAME_H), (40, 40, 40), 1)
        for gy in range(0, FRAME_H, 160):
            cv2.line(img, (0, gy), (FRAME_W, gy), (40, 40, 40), 1)
        r = self.args.roi // 2
        bx, by = (center or (FRAME_W // 2, FRAME_H // 2))
        cv2.rectangle(img, (max(0, bx - r), max(0, by - r)),
                      (min(FRAME_W - 1, bx + r), min(FRAME_H - 1, by + r)), (0, 200, 0), 1)
        if center:
            cv2.drawMarker(img, center, (0, 255, 0), cv2.MARKER_CROSS, 26, 2)
        counts = "  ".join(f"{i}:{self.counts.get(i, 0)}" for i in range(len(self.names)))
        lines = [
            f"{self.names[cls] if cls < len(self.names) else cls}  (class {cls})   session {self.session}",
            text,
            counts,
        ]
        for i, s in enumerate(lines):
            cv2.putText(img, s, (12, 30 + 28 * i), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                        (0, 255, 255) if i == 0 else (230, 230, 230), 2)
        return img

    def finish(self) -> None:
        self.tracker.close()
        self.cap.release()
        cv2.destroyAllWindows()
        info = {
            "session": self.session,
            "started": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(self.start)),
            "seconds": round(time.time() - self.start, 1),
            "mode": "guided" if self.args.guided else "manual",
            "camera": self.camera_info,
            "classes": self.names,
            "saved": self.counts,
            "host": socket.gethostname(),
        }
        with (self.out / "sessions.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(info, ensure_ascii=False) + "\n")
        print(f"saved {self.saved} frames this run -> {self.out}")
        print("class counts:", self.counts)


def run_manual(rec: Recorder, args) -> None:
    cls = 1 if len(rec.names) > 1 else 0
    burst = False
    next_burst = 0.0
    while True:
        rec.read()
        center = rec.center_for(cls)
        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        if ord("0") <= key <= ord("9"):
            cls = min(key - ord("0"), len(rec.names) - 1)
        elif key == ord("["):
            cls = max(0, cls - 1)
        elif key == ord("]"):
            cls = min(len(rec.names) - 1, cls + 1)
        elif key == 32:
            rec.save(cls, center if cls else None)
        elif key == ord("b"):
            burst = not burst
            print("burst", "on" if burst else "off")
        elif key == ord("u"):
            rec.undo()
        elif key == ord("c"):
            rec._mouse_center = None
            rec.last_center = None

        if burst and time.time() >= next_burst:
            rec.save(cls, center if cls else None)
            next_burst = time.time() + args.burst_interval

        text = ("SPACE save  b burst  u undo  0-9 class  [/] cycle  click=centre  q quit"
                + ("   BURST" if burst else ""))
        cv2.imshow("gesture capture", rec.overlay(rec.clean, cls, center, text))


def run_guided(rec: Recorder, args) -> bool:
    order = list(range(1, len(rec.names))) + [0]
    save_dt = 1.0 / max(0.5, args.save_fps)

    def wait_key(ms: int = 1) -> int:
        return cv2.waitKey(ms) & 0xFF

    def preview(cls: int, text: str) -> int:
        rec.read()
        center = rec.center_for(cls) if cls else None
        cv2.imshow("gesture capture", rec.overlay(rec.clean, cls, center, text))
        return wait_key(1)

    for cls in order:
        name = rec.names[cls]
        hint = ("SPACE start   s skip class   q quit   (empty scene, or hand with no gesture)"
                if cls == 0 else
                "SPACE start   s skip class   q quit   (keep hand in green box)")
        # 1) wait for space
        while True:
            k = preview(cls, hint)
            if k == 32:
                break
            if k == ord("q"):
                return False
            if k == ord("s"):
                break
        if k == ord("s"):
            continue
        # 2) countdown
        t0 = time.time()
        while True:
            left = 3.0 - (time.time() - t0)
            if left <= 0:
                break
            rec.read()
            center = rec.center_for(cls) if cls else None
            cv2.imshow("gesture capture", rec.overlay(
                rec.clean, cls, center, f"starting {name} in {left:.1f}s"))
            if wait_key(10) == ord("q"):
                return False
        # 3) record
        rec.read()
        t0 = time.time()
        n_saved = 0
        next_save = t0
        while time.time() - t0 < args.seconds:
            rec.read()
            center = rec.center_for(cls) if cls else None
            if time.time() >= next_save:
                # with mediapipe, skip frames where no hand was found
                if cls == 0 or rec.tracker.hands is None or rec.last_tracked:
                    rec.save(cls, center)
                    n_saved += 1
                next_save += save_dt
            left = max(0.0, args.seconds - (time.time() - t0))
            cv2.imshow("gesture capture", rec.overlay(
                rec.clean, cls, center, f"recording {name}: {n_saved} frames, {left:.1f}s left"))
            if wait_key(1) == ord("q"):
                return False
        print(f"  {name}: +{n_saved}")
    print("guided recording complete")
    return True


def selftest(args, names: list[str]) -> int:
    """Open the camera, save N background frames, exit. No GUI, no labels of value."""
    out = Path(args.out) / "selftest"
    out.mkdir(parents=True, exist_ok=True)
    cap = open_camera(args.camera, args.width, args.height, args.fps)
    labels = []
    for i in range(args.selftest):
        ok, frame = cap.read()
        if not ok or frame is None:
            raise SystemExit("camera read failed")
        img = letterbox(frame)
        if args.mirror:
            img = cv2.flip(img, 1)
        name = f"selftest_{i:02d}.jpg"
        cv2.imwrite(str(out / name), img, [cv2.IMWRITE_JPEG_QUALITY, args.quality])
        labels.append(Label(name, 0, -1, -1, "selftest"))
    cap.release()
    write_labels(labels, out)
    print(f"selftest: wrote {len(labels)} frames to {out} (class 0)")
    print(f"delete after checking: rm -rf {out}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--out", default=str(raw_dir()))
    ap.add_argument("--names", default=None, help="comma separated gesture names")
    ap.add_argument("--tracker", choices=["auto", "mediapipe", "fixed"], default="auto")
    ap.add_argument("--roi", type=int, default=440, help="guide box size in pixels")
    ap.add_argument("--quality", type=int, default=95)
    ap.add_argument("--mirror", action="store_true", default=None,
                    help="flip horizontally (defaults to data/settings.json)")
    ap.add_argument("--guided", action="store_true")
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--save-fps", type=float, default=5.0)
    ap.add_argument("--burst-interval", type=float, default=0.25)
    ap.add_argument("--selftest", type=int, default=0,
                    help="save N frames without GUI then exit (camera check)")
    args = ap.parse_args()

    if args.mirror is None:
        try:
            args.mirror = bool(json.loads((data_dir() / "settings.json").read_text()).get("mirror", False))
        except Exception:  # noqa: BLE001
            args.mirror = False
    print("mirror:", "on" if args.mirror else "off")

    names = parse_names(args.names) if args.names else load_classes()
    if args.names and (data_dir() / "classes.json").exists():
        existing = load_classes()
        if existing != names:
            raise SystemExit(
                f"classes.json already has {existing}; drop --names or delete {data_dir() / 'classes.json'}")
    if len(names) < 2:
        raise SystemExit("need at least background + one gesture")
    if args.selftest:
        return selftest(args, names)
    print("classes:", "  ".join(f"{i}={n}" for i, n in enumerate(names)))
    rec = Recorder(args, names)
    completed = True
    try:
        if args.guided:
            completed = run_guided(rec, args)
        else:
            run_manual(rec, args)
    finally:
        rec.finish()
    return 0 if completed else 1


if __name__ == "__main__":
    raise SystemExit(main())
