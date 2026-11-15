"""ScreenSense gesture workbench - one local web page for the whole flow.

Buttons drive the same scripts the CLI uses:
    camera preview -> guided/manual recording -> training -> quantise+eval ->
    real-time monitor, with a live log.

Run it with pcvision/gesture/app.sh and open http://127.0.0.1:8765 .
Only stdlib HTTP + OpenCV/torch are used; no OpenCV window, so the old
highgui sizing/focus problems disappear.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from collections import Counter, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import cv2
import numpy as np

from actions import ActionConfig, GestureActions
from capture_gestures import open_camera
from common import (
    FRAME_H,
    FRAME_W,
    GRID_H,
    GRID_W,
    Label,
    append_label,
    cell_of,
    class_counts,
    classes_path,
    data_dir,
    ensure_dirs,
    letterbox,
    load_classes,
    out_dir,
    raw_dir,
    read_labels,
    runs_dir,
    save_classes,
)

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "ml"))
from model_template import MundusDet  # noqa: E402

try:
    import torch
except Exception as exc:  # noqa: BLE001
    torch = None
    TORCH_ERROR = repr(exc)
else:
    TORCH_ERROR = ""


class ApiError(Exception):
    def __init__(self, message: str, code: int = 400):
        super().__init__(message)
        self.code = code


def encode_jpeg(img: np.ndarray, quality: int = 80) -> bytes:
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
    return buf.tobytes() if ok else b""


def safe_name(name: str, idx: int) -> str:
    try:
        name.encode("ascii")
        return name
    except UnicodeEncodeError:
        return "class " + str(idx)


class Workbench:
    def __init__(self, args):
        self.args = args
        ensure_dirs()
        self.lock = threading.RLock()
        self.classes = load_classes()
        self.counts = class_counts(read_labels())
        self.n_labels = sum(self.counts.values())
        self.selected_class = 1 if len(self.classes) > 1 else 0
        self.center = [FRAME_W // 2, FRAME_H // 2]
        self.frame = np.zeros((FRAME_H, FRAME_W, 3), np.uint8)
        self.annotated = self.frame.copy()
        self.jpeg = encode_jpeg(self.annotated)
        self.camera_info: dict = {}
        self.error = ""
        self.mode = "idle"                 # idle | guided | monitor
        self.guided = None
        self.monitor = None                # (net, device)
        self.actions = None
        self.threshold = None
        self.events = deque(maxlen=40)
        self.event_seq = 0
        self.action_cfg = None
        self.last_det = None
        self.vote = deque(maxlen=7)
        self.stable = None
        _saved = load_settings()
        self.mirror = bool(_saved.get("mirror", False))
        self.action_cfg = {
            "hold": float(_saved.get("action_hold", 0.8)),
            "swipe": int(_saved.get("action_swipe", 6)),
            "seq": float(_saved.get("action_seq", 1.2)),
        }
        self.job = None
        self.logs = deque(maxlen=4000)
        self.log_seq = 0
        self.metrics = load_metrics()
        self.train_meta = load_train_meta()
        self.stop_event = threading.Event()
        self.cap = None
        self.camera_error = ""
        self._session_no = 0
        self.session = self.new_session()
        self._last_jpeg = 0.0
        self.thread = threading.Thread(target=self._camera_loop, daemon=True)
        self.thread.start()
        self.log("workbench ready: " + str(REPO))
        self.log("workspace: " + str(out_dir().parent))

    # ------------------------------------------------------------------ #
    # logging
    # ------------------------------------------------------------------ #
    def log(self, line: str) -> None:
        line = str(line)
        with self.lock:
            self.logs.append(line)
            self.log_seq += 1

    def log_since(self, since: int) -> dict:
        with self.lock:
            seq = self.log_seq
            lines = list(self.logs)
            keep = max(0, seq - len(lines))
            start = max(0, since - keep)
            if since > seq:
                start = len(lines)
            return {"seq": seq, "lines": lines[start:]}

    # ------------------------------------------------------------------ #
    # sessions / saving
    # ------------------------------------------------------------------ #
    def new_session(self) -> str:
        self._session_no += 1
        return time.strftime("s%Y%m%d_%H%M%S") + "_" + str(self._session_no).zfill(2)

    def _save_frame(self, cls: int, center, session: str) -> bool:
        with self.lock:
            frame = self.frame.copy()
            classes = list(self.classes)
        if cls < 0 or cls >= len(classes):
            return False
        x, y = (-1, -1) if cls == 0 else (int(center[0]), int(center[1]))
        name = "g_" + session + "_" + str(time.time_ns()) + "_c" + str(cls) + ".jpg"
        path = raw_dir() / name
        if not cv2.imwrite(str(path), frame, [cv2.IMWRITE_JPEG_QUALITY, 95]):
            self.log("write failed: " + str(path))
            return False
        append_label(Label(name, cls, x, y, session), raw_dir())
        with self.lock:
            self.counts[cls] = self.counts.get(cls, 0) + 1
            self.n_labels += 1
        return True

    def save_manual(self, cls: int) -> dict:
        if not classes_path().exists():
            save_classes(self.classes)
        self._save_frame(cls, self.center, self.session)
        return {"ok": True, "counts": dict(self.counts), "session": self.session}

    # ------------------------------------------------------------------ #
    # camera loop
    # ------------------------------------------------------------------ #
    def _open(self):
        try:
            cap = open_camera(self.args.camera, 1280, 720, 30)
        except SystemExit as exc:
            self.camera_error = str(exc)
            return None
        except Exception as exc:  # noqa: BLE001
            self.camera_error = "camera error: " + repr(exc)
            return None
        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        fps = cap.get(cv2.CAP_PROP_FPS)
        with self.lock:
            self.camera_info = {"width": w, "height": h, "fps": fps, "index": self.args.camera}
            self.camera_error = ""
            self.error = ""
        self.log("camera " + str(self.args.camera) + ": " + str(w) + "x" + str(h) +
                 " @ " + str(round(fps, 1)) + " fps")
        return cap

    def _camera_loop(self) -> None:
        while not self.stop_event.is_set():
            if self.cap is None:
                self.cap = self._open()
                if self.cap is None:
                    time.sleep(2.0)
                    continue
            ok, frame = self.cap.read()
            if not ok or frame is None:
                self.log("camera read failed; reopening")
                try:
                    self.cap.release()
                except Exception:  # noqa: BLE001
                    pass
                self.cap = None
                time.sleep(1.0)
                continue
            clean = letterbox(frame)
            now = time.time()
            with self.lock:
                if self.mirror:
                    clean = cv2.flip(clean, 1)
                self.frame = clean
            self._guided_tick(clean, now)
            det = self._monitor_tick(clean, now)
            self._publish(clean, det, now)

    def _guided_tick(self, clean: np.ndarray, now: float) -> None:
        with self.lock:
            g = self.guided
            if not g or not g.get("active"):
                return
            if g["phase"] == "countdown":
                if now - g["t0"] >= 3.0:
                    g["phase"] = "record"
                    g["t0"] = now
                    g["next_save"] = now
                    g["saved"] = 0
            elif g["phase"] == "record":
                if now >= g["next_save"]:
                    self._save_frame(g["cls"], self.center, g["session"])
                    g["saved"] += 1
                    dt = 1.0 / max(0.5, g["save_fps"])
                    g["next_save"] = max(g["next_save"] + dt, now + dt * 0.5)
                if now - g["t0"] >= g["seconds"]:
                    g["idx"] += 1
                    if g["idx"] >= len(g["order"]):
                        g["round"] += 1
                        if g["round"] > g["rounds"]:
                            self.log("guided recording done: " + str(dict(self.counts)))
                            self.guided = None
                            self.mode = "idle"
                            return
                        g["idx"] = 0
                        g["session"] = self.new_session()
                    g["cls"] = g["order"][g["idx"]]
                    g["phase"] = "countdown"
                    g["t0"] = now
                    self.log("guided: round " + str(g["round"]) + "/" + str(g["rounds"]) +
                             " class " + str(g["cls"]) + " " + self.classes[g["cls"]])

    def _monitor_tick(self, clean: np.ndarray, now: float):
        with self.lock:
            mon = self.monitor
            threshold = self.threshold
            acts = self.actions
        if mon is None or torch is None:
            return None
        net, device = mon
        rgb = cv2.cvtColor(clean, cv2.COLOR_BGR2RGB)
        x = ((rgb.astype(np.float32) - 128.0) / 128.0).transpose(2, 0, 1)[None]
        xb = torch.from_numpy(np.ascontiguousarray(x)).to(device)
        with torch.inference_mode():
            ha, hb = net(xb)
            hh = torch.cat([ha, hb], dim=1)
            flat = hh.flatten(2)
            val, ch = flat.max(dim=1)
            best = int(val.argmax(dim=1))
            cls = int(ch[0, best].item() % len(self.classes))
            conf = float(val[0, best].item())
            gx, gy = best % GRID_W, best // GRID_W
        show = cls > 0 and (threshold is None or conf >= threshold)
        if acts is not None and (threshold is None or conf >= threshold):
            for ev in acts.update(cls, gx, gy, int(round(conf)), now):
                d = ev.to_dict()
                with self.lock:
                    d["id"] = self.event_seq
                    self.event_seq += 1
                    self.events.append(d)
                    if len(self.events) > 40:
                        self.events.popleft()

        # Majority vote over the last 7 frames keeps the demo from flickering.
        with self.lock:
            self.vote.append((cls, gx, gy, conf))
            votes = [v for v in self.vote if v[0] > 0]
            counts = Counter(v[0] for v in votes)
            stable = None
            if counts:
                c, n = counts.most_common(1)[0]
                need = max(4, len(self.vote) // 2 + 1)
                if n >= need:
                    pts = [v for v in votes if v[0] == c]
                    sgx = int(np.median([p[1] for p in pts]))
                    sgy = int(np.median([p[2] for p in pts]))
                    scf = float(np.mean([p[3] for p in pts]))
                    if threshold is None or scf >= threshold:
                        stable = {"cls": c, "gx": sgx, "gy": sgy, "conf": scf,
                                  "votes": n, "window": len(self.vote)}
                    if stable is None:
                        show = False
            self.stable = stable
            show = stable is not None
        det = {"cls": cls, "gx": gx, "gy": gy, "conf": conf, "show": show,
               "stable": stable}
        with self.lock:
            self.last_det = det
        return det

    def _publish(self, clean: np.ndarray, det, now: float) -> None:
        img = clean.copy()
        for gx in range(0, FRAME_W, 160):
            cv2.line(img, (gx, 0), (gx, FRAME_H), (40, 44, 52), 1)
        for gy in range(0, FRAME_H, 160):
            cv2.line(img, (0, gy), (FRAME_W, gy), (40, 44, 52), 1)
        with self.lock:
            center = tuple(self.center)
            g = dict(self.guided) if self.guided else None
            mode = self.mode
            counts = dict(self.counts)
            classes = list(self.classes)
            selected = self.selected_class
        r = 220
        cv2.rectangle(img, (max(0, center[0] - r), max(0, center[1] - r)),
                      (min(FRAME_W - 1, center[0] + r), min(FRAME_H - 1, center[1] + r)),
                      (0, 200, 0), 1)
        cv2.drawMarker(img, center, (0, 255, 0), cv2.MARKER_CROSS, 26, 2)
        title = "mode " + mode + "   selected " + safe_name(classes[selected], selected)
        if g:
            name = safe_name(classes[g["cls"]], g["cls"])
            if g["phase"] == "countdown":
                left = max(0.0, 3.0 - (now - g["t0"]))
                title = "round " + str(g["round"]) + "/" + str(g["rounds"]) + "  class " + name + \
                        "  starts in " + str(round(left, 1)) + "s"
            else:
                left = max(0.0, g["seconds"] - (now - g["t0"]))
                title = "round " + str(g["round"]) + "/" + str(g["rounds"]) + "  class " + name + \
                        "  rec " + str(g["saved"]) + "  left " + str(round(left, 1)) + "s"
        cv2.putText(img, title, (14, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 255, 255), 2)
        if det is not None:
            stable = det.get("stable")
            if stable:
                cx, cy = stable["gx"] * 16 + 8, stable["gy"] * 16 + 8
                x0, y0 = max(0, cx - 32), max(0, cy - 20)
                cv2.rectangle(img, (x0, y0), (min(FRAME_W - 1, x0 + 64), min(FRAME_H - 1, y0 + 40)),
                              (0, 255, 0), 2)
                label = safe_name(classes[stable["cls"]], stable["cls"])
                cv2.putText(img, label + " " + str(round(stable["conf"], 1)) +
                            "  " + str(stable["votes"]) + "/" + str(stable["window"]),
                            (x0, max(18, y0 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
                cv2.putText(img, "STABLE " + label, (14, 62), cv2.FONT_HERSHEY_SIMPLEX,
                            0.6, (0, 255, 0), 2)
            else:
                cv2.putText(img, "no gesture", (14, 62), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                            (180, 180, 180), 1)
        text = "  ".join(str(k) + ":" + str(v) for k, v in sorted(counts.items()))
        cv2.putText(img, "samples " + str(sum(counts.values())) + "   " + text,
                    (14, FRAME_H - 16), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (230, 230, 230), 1)
        self.annotated = img
        if now - self._last_jpeg >= 1.0 / 12.0:
            self._last_jpeg = now
            jpeg = encode_jpeg(img, 80)
            with self.lock:
                self.jpeg = jpeg

    # ------------------------------------------------------------------ #
    # actions from HTTP
    # ------------------------------------------------------------------ #
    def latest_jpeg(self) -> bytes:
        with self.lock:
            return self.jpeg

    def status(self) -> dict:
        with self.lock:
            g = None
            if self.guided:
                g = {
                    "round": self.guided["round"], "rounds": self.guided["rounds"],
                    "cls": self.guided["cls"], "name": self.classes[self.guided["cls"]],
                    "phase": self.guided["phase"],
                    "left": round(max(0.0, (3.0 - (time.time() - self.guided["t0"]))
                                       if self.guided["phase"] == "countdown"
                                       else (self.guided["seconds"] - (time.time() - self.guided["t0"]))), 1),
                    "saved": self.guided.get("saved", 0),
                }
            job = None
            if self.job:
                job = {"name": self.job["name"], "running": self.job["running"],
                       "returncode": self.job["returncode"]}
            return {
                "camera": dict(self.camera_info), "error": self.error or self.camera_error,
                "mode": self.mode, "classes": list(self.classes),
                "selected": self.selected_class, "counts": dict(self.counts),
                "n_labels": self.n_labels, "guided": g,
                "monitor": self.mode == "monitor", "threshold": self.threshold,
                "action_cfg": self.action_cfg,
                "metrics": self.metrics, "train": self.train_meta, "job": job,
                "checkpoint": (runs_dir() / "gesture.pt").exists(),
                "mirror": self.mirror,
                "last_det": self.last_det,
                "stable": self.stable,
                "events": list(self.events)[-8:],
            }

    def set_mirror(self, on: bool) -> None:
        with self.lock:
            self.mirror = bool(on)
        save_settings({"mirror": self.mirror})
        self.log("mirror " + ("on" if self.mirror else "off"))

    def set_classes(self, names) -> None:
        names = [str(n).strip() for n in names if str(n).strip()]
        if not names:
            raise ApiError("至少一个手势")
        if len(names) > 15:
            raise ApiError("最多 15 个手势（硬件头部 16 通道）")
        if read_labels():
            raise ApiError("已经有数据，改类别会破坏标签；先重置数据")
        full = ["background"] + names
        save_classes(full)
        with self.lock:
            self.classes = full
            self.selected_class = 1
            self.counts = {}
            self.n_labels = 0
        self.log("classes: " + ", ".join(full))

    def select(self, cls: int) -> None:
        with self.lock:
            self.selected_class = max(0, min(len(self.classes) - 1, int(cls)))

    def set_center(self, x: float, y: float) -> None:
        with self.lock:
            self.center = [max(0, min(FRAME_W - 1, int(x))), max(0, min(FRAME_H - 1, int(y)))]

    def start_guided(self, rounds: int, seconds: float, save_fps: float) -> None:
        if self.job and self.job.get("running"):
            raise ApiError("有训练/评估任务在跑，等它结束")
        if len(self.classes) < 2:
            raise ApiError("至少需要 background + 一个手势")
        if not classes_path().exists():
            save_classes(self.classes)
        self.stop_monitor()
        rounds = max(1, min(30, int(rounds)))
        seconds = max(2.0, min(60.0, float(seconds)))
        save_fps = max(0.5, min(15.0, float(save_fps)))
        order = list(range(1, len(self.classes))) + [0]
        with self.lock:
            self.guided = {
                "active": True, "rounds": rounds, "round": 1, "order": order,
                "idx": 0, "cls": order[0], "phase": "countdown", "t0": time.time(),
                "seconds": seconds, "save_fps": save_fps, "next_save": 0.0, "saved": 0,
                "session": self.new_session(),
            }
            self.mode = "guided"
        self.log("guided start: " + str(rounds) + " rounds, " + str(len(order)) + " classes/round")

    def stop_guided(self) -> None:
        with self.lock:
            if self.guided:
                self.log("guided stopped")
            self.guided = None
            if self.mode == "guided":
                self.mode = "idle"

    def start_monitor(self, threshold, hold=None, swipe=None, seq=None) -> None:
        if torch is None:
            raise ApiError("torch 不可用: " + TORCH_ERROR)
        ckpt = runs_dir() / "gesture.pt"
        if not ckpt.exists():
            raise ApiError("还没有模型，先训练")
        state = torch.load(str(ckpt), map_location="cpu")
        if isinstance(state, dict) and "model" in state:
            state = state["model"]
        net = MundusDet(num_classes=len(self.classes))
        try:
            net.load_state_dict(state)
        except Exception as exc:  # noqa: BLE001
            raise ApiError("checkpoint 与当前类别数不匹配: " + repr(exc))
        device = "cuda" if torch.cuda.is_available() else "cpu"
        net.to(device).eval()
        if threshold is None or threshold == "":
            threshold = None
            if self.metrics:
                f = self.metrics.get("float") or {}
                if f.get("clean_separation") and f.get("threshold") is not None:
                    threshold = float(f["threshold"])
            if threshold is None:
                self.log("no clean eval threshold; monitor shows every gesture class")
            else:
                self.log("using eval threshold " + str(threshold))

        saved = load_settings()
        hold = float(hold) if hold not in (None, "") else float(saved.get("action_hold", 0.8))
        swipe = int(swipe) if swipe not in (None, "") else int(saved.get("action_swipe", 6))
        seq = float(seq) if seq not in (None, "") else float(saved.get("action_seq", 1.2))
        hold = max(0.2, min(5.0, hold))
        swipe = max(2, min(30, swipe))
        seq = max(0.2, min(5.0, seq))
        cfg = ActionConfig(hold_seconds=hold, swipe_cells=swipe, sequence_window=seq)
        save_settings({"action_hold": hold, "action_swipe": swipe, "action_seq": seq})
        with self.lock:
            self.monitor = (net, device)
            self.actions = GestureActions(self.classes, cfg)
            self.threshold = None if threshold is None else float(threshold)
            self.action_cfg = {"hold": hold, "swipe": swipe, "seq": seq}
            self.events.clear()
            self.event_seq = 0
            self.vote.clear()
            self.stable = None
            self.mode = "monitor"
            self.guided = None
        self.log("monitor on (" + device + ", threshold " + str(self.threshold) +
                 ", hold " + str(hold) + "s, swipe " + str(swipe) +
                 " cells, seq " + str(seq) + "s)")

    def stop_monitor(self) -> None:
        with self.lock:
            was = self.mode == "monitor"
            self.monitor = None
            self.actions = None
            self.vote.clear()
            self.stable = None
            if was:
                self.mode = "idle"
                self.log("monitor off")

    def set_monitor(self, on: bool, threshold, hold=None, swipe=None, seq=None) -> None:
        if on:
            self.start_monitor(threshold, hold, swipe, seq)
        else:
            self.stop_monitor()

    # ------------------------------------------------------------------ #
    # jobs
    # ------------------------------------------------------------------ #
    def _start_job(self, name: str, commands: list[list[str]]) -> None:
        with self.lock:
            if self.job and self.job.get("running"):
                raise ApiError("已有任务在跑")
            self.job = {"name": name, "running": True, "returncode": None}

        def run():
            rc = 0
            try:
                for cmd in commands:
                    self.log("$ " + " ".join(cmd))
                    proc = subprocess.Popen(
                        cmd, cwd=str(REPO), stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True, bufsize=1,
                        env=os.environ.copy(),
                    )
                    with self.lock:
                        self.job["proc"] = proc
                    for line in proc.stdout:
                        self.log(line.rstrip())
                    rc = proc.wait()
                    if rc != 0:
                        break
            except Exception as exc:  # noqa: BLE001
                self.log("job error: " + repr(exc))
                rc = -1
            finally:
                with self.lock:
                    self.job["running"] = False
                    self.job["returncode"] = rc
                if name == "eval":
                    self.metrics = load_metrics()
                if name == "train":
                    self.train_meta = load_train_meta()
                self.log("[" + name + "] finished rc=" + str(rc))

        threading.Thread(target=run, daemon=True).start()

    def start_train(self, epochs: int, batch: int, workers: int, lr: float) -> None:
        if not read_labels():
            raise ApiError("没有数据，先录制")
        if not classes_path().exists():
            save_classes(self.classes)
        self.stop_guided()
        self.stop_monitor()
        epochs = max(1, min(500, int(epochs)))
        batch = max(1, min(16, int(batch)))
        workers = max(0, min(8, int(workers)))
        cmd = [sys.executable, str(Path(__file__).resolve().parent / "train_gestures.py"),
               "--data", str(raw_dir()), "--out", str(runs_dir() / "gesture.pt"),
               "--epochs", str(epochs), "--batch", str(batch),
               "--workers", str(workers), "--lr", str(float(lr))]
        self._start_job("train", [cmd])

    def start_eval(self) -> None:
        ckpt = runs_dir() / "gesture.pt"
        if not ckpt.exists():
            raise ApiError("还没有模型，先训练")
        self.stop_guided()
        self.stop_monitor()
        k = len(self.classes)
        cmds = [
            [sys.executable, str(REPO / "ml/export_mat.py"), "--ckpt", str(ckpt),
             "--out", str(out_dir() / "mats"), "--classes", str(k),
             "--calib-dir", str(raw_dir()), "--calib-count", "8"],
            [sys.executable, str(Path(__file__).resolve().parent / "evaluate.py"),
             "--ckpt", str(ckpt), "--data", str(raw_dir()), "--mat", str(out_dir() / "mats"),
             "--split", "val", "--out", str(out_dir() / "eval.json")],
        ]
        self._start_job("eval", cmds)

    def reset_data(self) -> None:
        with self.lock:
            if self.job and self.job.get("running"):
                raise ApiError("有任务在跑，先等它结束")
        self.stop_guided()
        self.stop_monitor()
        for p in (raw_dir(), runs_dir(), out_dir()):
            if p.exists():
                shutil.rmtree(p)
        ensure_dirs()
        with self.lock:
            self.counts = {}
            self.n_labels = 0
            self.metrics = None
            self.train_meta = None
            self.events.clear()
            self.last_det = None
            self.session = self.new_session()
            self.mode = "idle"
        self.log("reset: data/, runs/, out/ cleared (classes kept)")

    def shutdown(self) -> None:
        self.stop_event.set()
        with self.lock:
            cap = self.cap
        if cap is not None:
            try:
                cap.release()
            except Exception:  # noqa: BLE001
                pass


def load_metrics():
    p = out_dir() / "eval.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def load_train_meta():
    p = runs_dir() / "gesture.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def settings_path():
    return data_dir() / "settings.json"


def load_settings() -> dict:
    p = settings_path()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {}


def save_settings(updates: dict) -> None:
    cur = load_settings()
    cur.update(updates)
    settings_path().write_text(json.dumps(cur, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8")


INDEX_HTML = """<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ScreenSense 手势工作台</title>
<style>
  :root { --bg:#0f1115; --panel:#171a21; --line:#2a2f3a; --text:#e8eaf0;
          --muted:#8b93a7; --acc:#39d98a; --warn:#ffb020; --bad:#ff5c5c; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font:14px/1.45 system-ui, "Noto Sans CJK SC", sans-serif; }
  header { display:flex; align-items:center; justify-content:space-between;
           padding:10px 18px; border-bottom:1px solid var(--line);
           background:#13161c; position:sticky; top:0; z-index:5; }
  h1 { font-size:16px; margin:0; letter-spacing:.3px; }
  #conn { font-size:12px; color:var(--muted); }
  #conn.bad { color:var(--bad); }
  main { display:grid; grid-template-columns:minmax(0,1.35fr) minmax(340px,1fr);
         gap:14px; padding:14px 18px; align-items:start; }
  .left { min-width:0; }
  .preview { background:#000; border:1px solid var(--line); border-radius:10px;
             overflow:hidden; aspect-ratio:16/9; }
  .preview img { width:100%; height:100%; object-fit:contain; display:block;
                 cursor:crosshair; }
  .meta { display:flex; justify-content:space-between; align-items:center;
          gap:10px; flex-wrap:wrap; color:var(--muted);
          font-size:12px; padding:6px 2px; }
  .mirror { display:flex; align-items:center; gap:4px; cursor:pointer; }
  .mirror input { accent-color:var(--acc); }
  .chips { display:flex; flex-wrap:wrap; gap:6px; margin:8px 0; }
  .chip { background:#202634; color:var(--text); border:1px solid var(--line);
          border-radius:999px; padding:4px 10px; cursor:pointer; font-size:12px; }
  .chip.active { background:var(--acc); color:#07130c; border-color:var(--acc);
                 font-weight:700; }
  .counts { display:flex; flex-wrap:wrap; gap:6px; margin:8px 0; }
  .count { background:#1b2029; border:1px solid var(--line); border-radius:6px;
           padding:3px 8px; font-size:12px; color:var(--muted); }
  .row { display:flex; flex-wrap:wrap; gap:8px; align-items:end; margin:6px 0; }
  .row label { display:flex; flex-direction:column; gap:3px; font-size:12px;
               color:var(--muted); }
  input { background:#0e1117; border:1px solid var(--line); color:var(--text);
          border-radius:6px; padding:6px 8px; font-size:13px; width:100%; }
  input[type=number] { width:82px; }
  button { background:var(--acc); color:#07130c; border:0; border-radius:7px;
           padding:7px 12px; font-size:13px; font-weight:650; cursor:pointer; }
  button.ghost { background:#232a36; color:var(--text); border:1px solid var(--line); }
  button.danger { background:#3a1f24; color:#ffb3b3; border:1px solid #5c2a32; }
  button:disabled { opacity:.45; cursor:not-allowed; }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:10px;
          padding:12px; margin-bottom:10px; }
  .card h2 { font-size:13px; margin:0 0 8px; color:#cdd4e3; letter-spacing:.4px; }
  .status { color:var(--muted); font-size:12px; min-height:16px; margin-top:4px; }
  .hint { color:var(--muted); font-size:11px; margin-top:6px; }
  .err { display:none; background:#3a1f24; color:#ffb3b3; border:1px solid #5c2a32;
         border-radius:8px; padding:8px 10px; margin:8px 18px 0; font-size:12px; }
  .metrics { display:flex; gap:8px; flex-wrap:wrap; margin-top:8px; }
  .metric { background:#11151c; border:1px solid var(--line); border-radius:8px;
            padding:8px 10px; min-width:120px; }
  .metric .k { font-size:11px; color:var(--muted); }
  .metric .v { font-size:20px; font-weight:700; }
  .metric .s { font-size:11px; color:var(--muted); }
  .events { color:var(--muted); font-size:12px; white-space:pre-wrap; margin-top:6px; }
  .logwrap { margin-top:10px; display:flex; flex-direction:column; }
  .loghead { display:flex; align-items:center; justify-content:space-between;
             color:var(--muted); font-size:12px; margin-bottom:4px; }
  #log { background:#0b0e13; border:1px solid var(--line); border-radius:8px;
         margin:0; padding:8px 10px; height:200px; overflow:auto;
         color:#b7c0d0; font:12px/1.4 ui-monospace, monospace; white-space:pre-wrap; }
  @media (max-width: 1050px) { main { grid-template-columns:1fr; } }
</style>
</head>
<body>
<header>
  <h1>ScreenSense 手势工作台</h1>
  <div style="display:flex;gap:14px;align-items:center">
    <a href="/demo" target="_blank" style="color:#9fd9ff;text-decoration:none;font-size:12px">演示页 ↗</a>
    <span id="conn">连接中…</span>
  </div>
</header>
<div id="err" class="err"></div>
<main>
  <section class="left">
    <div class="preview"><img id="stream" src="/stream" alt="camera"></div>
    <div class="meta">
      <span id="cam">camera …</span>
      <label class="mirror" title="勾选=像照镜子；不勾=像别人看你（原始画面）">
        <input type="checkbox" id="mirrorChk"> 自拍镜像
      </label>
      <span id="mode">idle</span>
    </div>
    <div class="row">
      <span style="color:var(--muted);font-size:12px">点击画面设置手部中心</span>
      <span id="dataCount" style="color:var(--muted);font-size:12px"></span>
    </div>
    <div id="chips" class="chips"></div>
    <div class="row">
      <button id="saveBtn">保存一帧</button>
      <span style="color:var(--muted);font-size:12px">空格键也可保存</span>
    </div>
    <div id="counts" class="counts"></div>
    <div class="logwrap">
      <div class="loghead"><span>日志</span>
        <button id="clearLog" class="ghost" style="padding:2px 8px;font-size:11px">清屏</button></div>
      <pre id="log"></pre>
    </div>
  </section>

  <section class="right">
    <div class="card">
      <h2>1 采集</h2>
      <div class="row" style="display:block">
        <label>手势名（逗号分隔，0 是背景）<input id="names" placeholder="fist,open_palm,point"></label>
      </div>
      <div class="row">
        <button id="applyNames" class="ghost">应用类别</button>
        <span style="color:var(--muted);font-size:11px">有数据后不可改</span>
      </div>
      <div class="row">
        <label>轮数<input id="rounds" type="number" value="4" min="1" max="30"></label>
        <label>每类秒数<input id="seconds" type="number" value="8" min="2" max="60"></label>
        <label>保存帧率<input id="fps" type="number" value="5" min="1" max="15"></label>
      </div>
      <div class="row">
        <button id="startGuided">开始引导录制</button>
        <button id="stopRec" class="ghost">停止</button>
      </div>
      <div class="row">
        <button id="bgBtn" class="ghost">采集背景 6 秒</button>
        <span class="hint">约 30 张 class 0，点几次换姿势/位置</span>
      </div>
      <div id="guided" class="status"></div>
      <div class="hint">每类开始时按提示做动作；背景轮请空手/空场景。每轮独立 session。</div>
    </div>

    <div class="card">
      <h2>2 训练</h2>
      <div class="row">
        <label>epochs<input id="epochs" type="number" value="60" min="1"></label>
        <label>batch<input id="batch" type="number" value="4" min="1"></label>
        <label>workers<input id="workers" type="number" value="4" min="0"></label>
      </div>
      <div class="row"><button id="trainBtn">开始训练</button>
        <span id="job" class="status">空闲</span></div>
      <div id="trainState" class="status"></div>
    </div>

    <div class="card">
      <h2>3 量化 + 评估</h2>
      <div class="row"><button id="evalBtn">导出 .mat 并评估</button></div>
      <div id="metrics" class="metrics"><span class="hint">还没有评估结果</span></div>
    </div>

    <div class="card">
      <h2>4 实时监测</h2>
      <div class="row">
        <label>阈值<input id="thresh" type="number" step="0.1" placeholder="自动"></label>
        <label>按住 s<input id="hold" type="number" step="0.1" value="0.8"></label>
        <label>滑动格<input id="swipe" type="number" value="6"></label>
        <label>序列 s<input id="seq" type="number" step="0.1" value="1.2"></label>
        <button id="monitorBtn">开始监测</button>
      </div>
      <div id="det" class="status"></div>
      <div id="events" class="events"></div>
      <div class="hint">HOLD 需要按住时长；SWIPE 用格子位移；SEQUENCE 是两个手势在窗口内直接切换。阈值留空=不启用。</div>
    </div>

    <div class="card">
      <h2>重置</h2>
      <button id="resetBtn" class="danger">清空数据 / 模型 / 评估</button>
      <div class="hint">只删 data/runs/out，保留 venv、缓存和类别名。</div>
    </div>
  </section>
</main>
<script>
window.onerror = function(msg, src, line, col, err) {
  var el = document.getElementById('conn');
  if (el) { el.textContent = 'JS错误: ' + msg; el.className = 'bad'; }
};
var logSeq = 0;
var selected = 1;
var lastClassKey = '';
var namesInit = false;
var cfgInit = false;
var monitoring = false;

function $(id) { return document.getElementById(id); }
function setConn(text, bad) { var el = $('conn'); el.textContent = text; el.className = bad ? 'bad' : ''; }
function showErr(e) { setConn(e.message || String(e), true); }

async function api(path, body) {
  var opt = { method: body === undefined ? 'GET' : 'POST' };
  if (body !== undefined) {
    opt.headers = { 'Content-Type': 'application/json' };
    opt.body = JSON.stringify(body);
  }
  var res = await fetch(path, opt);
  var data = {};
  try { data = await res.json(); } catch (e) {}
  if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

function renderMetrics(m) {
  var el = $('metrics');
  el.textContent = '';
  if (!m) { el.innerHTML = '<span class="hint">还没有评估结果</span>'; return; }
  [['float', 'PyTorch float'], ['bit_exact', '位精确（板端）']].forEach(function(pair) {
    var d = m[pair[0]];
    if (!d) return;
    var card = document.createElement('div');
    card.className = 'metric';
    card.innerHTML = '<div class="k">' + pair[1] + '</div>' +
      '<div class="v">' + (d.accuracy * 100).toFixed(1) + '%</div>' +
      '<div class="s">' + (d.threshold === null || d.threshold === undefined
          ? '无阈值' : ('阈值 ' + d.threshold)) +
        (d.clean_separation ? ' · 分界清晰' : '') + '</div>';
    el.appendChild(card);
  });
}

function renderEvents(events) {
  var el = $('events');
  el.textContent = '';
  (events || []).slice().reverse().forEach(function(e) {
    var line = document.createElement('div');
    line.textContent = e.type + (e.gesture ? (' · ' + e.gesture) : '') +
      (e.direction ? (' · ' + e.direction) : '');
    el.appendChild(line);
  });
}

async function refresh() {
  try {
    var s = await api('/api/status');
    setConn('已连接 · ' + s.mode, false);
    $('cam').textContent = (s.camera && s.camera.width)
      ? ('camera ' + s.camera.width + 'x' + s.camera.height + ' @ ' + Math.round(s.camera.fps || 0) + ' fps')
      : 'camera 未连接';
    $('mirrorChk').checked = !!s.mirror;
    if (!cfgInit && s.action_cfg) {
      $('hold').value = s.action_cfg.hold;
      $('swipe').value = s.action_cfg.swipe;
      $('seq').value = s.action_cfg.seq;
      cfgInit = true;
    }
    $('mode').textContent = s.mode;
    $('dataCount').textContent = s.n_labels + ' 张样本';
    if (s.error) { $('err').textContent = s.error; $('err').style.display = 'block'; }
    else { $('err').style.display = 'none'; }

    var key = s.classes.join('|');
    if (key !== lastClassKey) {
      lastClassKey = key;
      var chips = $('chips');
      chips.textContent = '';
      s.classes.forEach(function(n, i) {
        var b = document.createElement('button');
        b.textContent = i + ' ' + n;
        b.className = 'chip';
        b.onclick = function() { api('/api/select', { cls: i }).then(refresh).catch(showErr); };
        chips.appendChild(b);
      });
      if (!namesInit) { $('names').value = s.classes.slice(1).join(','); namesInit = true; }
    }
    var buttons = document.querySelectorAll('#chips .chip');
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].className = 'chip' + (i === s.selected ? ' active' : '');
    }
    selected = s.selected;

    var counts = $('counts');
    counts.textContent = '';
    Object.keys(s.counts).sort(function(a, b) { return a - b; }).forEach(function(k) {
      var d = document.createElement('span');
      d.className = 'count';
      d.textContent = s.classes[k] + ' ' + s.counts[k];
      counts.appendChild(d);
    });

    $('guided').textContent = s.guided
      ? ('第 ' + s.guided.round + '/' + s.guided.rounds + ' 轮 · ' + s.guided.name +
         ' · ' + (s.guided.phase === 'record'
            ? ('录制 ' + s.guided.saved + ' 帧，剩 ' + s.guided.left + 's')
            : ('倒计时 ' + s.guided.left + 's')))
      : '';
    $('job').textContent = s.job
      ? (s.job.name + ' · ' + (s.job.running ? '运行中' : ('结束 rc=' + s.job.returncode)))
      : '空闲';
    $('trainState').textContent = (s.train && s.train.best_acc !== undefined)
      ? ('best frame-acc ' + (s.train.best_acc * 100).toFixed(2) + '% @ epoch ' + s.train.best_epoch)
      : '';
    renderMetrics(s.metrics);
    renderEvents(s.events);
    $('det').textContent = s.last_det
      ? ('最近: class ' + s.last_det.cls + ' ' + (s.classes[s.last_det.cls] || '') +
         ' · conf ' + Number(s.last_det.conf).toFixed(2) +
         ' · cell (' + s.last_det.gx + ',' + s.last_det.gy + ')' +
         (s.last_det.show ? '' : ' · 低于阈值'))
      : '';

    monitoring = !!s.monitor;
    $('monitorBtn').textContent = monitoring ? '停止监测' : '开始监测';
    $('startGuided').disabled = !!s.guided;
    $('stopRec').disabled = !s.guided;
    var busy = !!(s.job && s.job.running);
    $('bgBtn').disabled = busy || !!s.guided;
    $('mirrorChk').disabled = busy || !!s.guided;
    $('trainBtn').disabled = busy;
    $('evalBtn').disabled = busy;
    $('applyNames').disabled = busy;
    $('resetBtn').disabled = busy;
    if (s.metrics && s.metrics.float && s.metrics.float.threshold !== null &&
        s.metrics.float.threshold !== undefined && s.metrics.float.clean_separation &&
        !$('thresh').value) {
      $('thresh').value = s.metrics.float.threshold.toFixed(2);
    }
    if (monitoring) {
      $('thresh').value = (s.threshold === null || s.threshold === undefined) ? '' : s.threshold;
    }
  } catch (e) {
    setConn('未连接：' + (e.message || e), true);
  }
}

async function poll() {
  await refresh();
  setTimeout(poll, 700);
}

async function pollLog() {
  try {
    var d = await api('/api/log?since=' + logSeq);
    logSeq = d.seq;
    if (d.lines && d.lines.length) {
      var el = $('log');
      el.textContent += d.lines.join('\\n') + '\\n';
      if (el.textContent.length > 200000) el.textContent = el.textContent.slice(-150000);
      el.scrollTop = el.scrollHeight;
    }
  } catch (e) {}
  setTimeout(pollLog, 700);
}

$('saveBtn').onclick = function() { api('/api/record/save', { cls: selected }).then(refresh).catch(showErr); };
$('mirrorChk').onchange = function() {
  api('/api/mirror', { on: this.checked }).then(refresh).catch(showErr);
};
$('startGuided').onclick = function() {
  api('/api/record/guided', {
    rounds: parseInt($('rounds').value || '4', 10),
    seconds: parseFloat($('seconds').value || '8'),
    save_fps: parseFloat($('fps').value || '5')
  }).then(refresh).catch(showErr);
};
$('stopRec').onclick = function() { api('/api/record/stop', {}).then(refresh).catch(showErr); };
function sleep(ms) { return new Promise(function(resolve) { setTimeout(resolve, ms); }); }
$('bgBtn').onclick = async function() {
  if (!confirm('接下来 6 秒请不要做手势：空场景，或手自然放着。')) return;
  $('bgBtn').disabled = true;
  if (monitoring) { try { await api('/api/monitor', { on: false }); } catch (e) {} }
  for (var i = 0; i < 30; i++) {
    try { await api('/api/record/save', { cls: 0 }); }
    catch (e) { showErr(e); break; }
    await sleep(200);
  }
  $('bgBtn').disabled = false;
  refresh();
};
$('trainBtn').onclick = function() {
  api('/api/train', {
    epochs: parseInt($('epochs').value || '60', 10),
    batch: parseInt($('batch').value || '4', 10),
    workers: parseInt($('workers').value || '4', 10),
    lr: 0.0003
  }).then(refresh).catch(showErr);
};
$('evalBtn').onclick = function() { api('/api/eval', {}).then(refresh).catch(showErr); };
$('monitorBtn').onclick = function() {
  var t = $('thresh').value;
  api('/api/monitor', {
    on: !monitoring,
    threshold: t === '' ? null : parseFloat(t),
    hold: parseFloat($('hold').value || '0.8'),
    swipe: parseInt($('swipe').value || '6', 10),
    seq: parseFloat($('seq').value || '1.2')
  }).then(refresh).catch(showErr);
};
$('resetBtn').onclick = function() {
  if (!confirm('确定清空 data/、runs/、out/？venv、缓存和类别名会保留。')) return;
  api('/api/reset', { confirm: 'RESET' }).then(function() { namesInit = false; lastClassKey = ''; refresh(); }).catch(showErr);
};
$('applyNames').onclick = function() {
  var names = $('names').value.split(',').map(function(s) { return s.trim(); }).filter(Boolean);
  api('/api/classes', { names: names }).then(function() { namesInit = false; lastClassKey = ''; refresh(); }).catch(showErr);
};
$('clearLog').onclick = function() { $('log').textContent = ''; };
$('stream').onclick = function(e) {
  var r = e.target.getBoundingClientRect();
  var x = (e.clientX - r.left) / r.width * 1280;
  var y = (e.clientY - r.top) / r.height * 720;
  api('/api/center', { x: x, y: y }).catch(showErr);
};
$('stream').onerror = function() {
  var img = $('stream');
  setTimeout(function() { img.src = '/stream?t=' + Date.now(); }, 1200);
};
document.addEventListener('keydown', function(e) {
  if (e.code === 'Space' && e.target.tagName !== 'INPUT') {
    e.preventDefault();
    api('/api/record/save', { cls: selected }).then(refresh).catch(showErr);
  }
});
poll();
pollLog();
</script>
</body>
</html>
"""


DEMO_HTML = """<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ScreenSense 手势演示</title>
<style>
  * { box-sizing: border-box; }
  html, body { margin:0; height:100%; background:#07090d; color:#eef2ff;
               font-family: system-ui, "Noto Sans CJK SC", sans-serif; }
  .wrap { display:grid; grid-template-columns:minmax(0,1fr) 360px; height:100vh; }
  .stage { position:relative; background:#000; overflow:hidden;
           display:flex; align-items:center; justify-content:center; }
  .stage img { width:100%; height:100%; object-fit:contain; }
  .overlay { position:absolute; left:4vw; bottom:5vh; right:4vw; pointer-events:none; }
  .big { font-size:clamp(44px, 7vw, 110px); font-weight:800; line-height:1;
         color:#39d98a; text-shadow:0 2px 24px rgba(0,0,0,.8); letter-spacing:.02em; }
  .big.idle { color:#8b93a7; }
  .sub { margin-top:10px; font-size:clamp(16px, 1.6vw, 26px); color:#dfe6f5;
         text-shadow:0 2px 12px rgba(0,0,0,.9); }
  .action { min-height:1.15em; margin-bottom:8px; font-size:clamp(22px, 3vw, 48px);
            font-weight:800; color:#ffd166; letter-spacing:.02em;
            text-shadow:0 2px 18px rgba(0,0,0,.9); }
  .bar { position:absolute; left:0; top:0; right:0; padding:14px 20px;
         display:flex; justify-content:space-between; align-items:center;
         background:linear-gradient(rgba(0,0,0,.65), rgba(0,0,0,0)); font-size:13px;
         color:#cfd7e8; }
  .bar a { color:#9fd9ff; text-decoration:none; }
  .side { background:#0e1117; border-left:1px solid #232a36; padding:18px;
          overflow:auto; }
  .side h1 { font-size:16px; margin:0 0 10px; }
  .side .hint { color:#8b93a7; font-size:12px; line-height:1.5; }
  .ev { border:1px solid #232a36; border-radius:8px; padding:8px 10px;
        margin:8px 0; background:#11151c; font-size:13px; }
  .ev b { color:#ffd166; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%;
         background:#39d98a; margin-right:6px; }
  .dot.off { background:#5c6373; }
  @media (max-width: 900px) { .wrap { grid-template-columns:1fr; }
    .side { border-left:0; border-top:1px solid #232a36; max-height:40vh; } }
</style>
</head>
<body>
<div class="wrap">
  <div class="stage">
    <img id="stream" src="/stream" alt="camera">
    <div class="bar"><span><span id="dot" class="dot off"></span><span id="mode">idle</span></span>
      <a href="/" target="_self">返回工作台</a></div>
    <div class="overlay">
      <div id="action" class="action"></div>
      <div id="big" class="big idle">NO GESTURE</div>
      <div id="sub" class="sub">等待稳定检测…</div>
    </div>
  </div>
  <aside class="side">
    <h1>实时动作</h1>
    <div class="hint">CNN 看单帧，7 帧多数投票后显示；“动作”由 HOLD/SWIPE/SEQUENCE 状态机产生。</div>
    <div id="cfg" class="hint"></div>
    <div id="events"></div>
  </aside>
</div>
<script>
function $(id) { return document.getElementById(id); }
var lastEventId = -1;
var actionUntil = 0;
async function poll() {
  try {
    var s = await (await fetch('/api/status')).json();
    var st = s.stable;
    $('mode').textContent = s.mode + (s.monitor ? '' : ' · 未监测');
    $('dot').className = 'dot' + (st ? '' : ' off');
    if (st) {
      $('big').textContent = s.classes[st.cls] || ('class ' + st.cls);
      $('big').className = 'big';
      $('sub').textContent = 'conf ' + Number(st.conf).toFixed(2) +
        ' · ' + st.votes + '/' + st.window + ' 帧一致 · cell (' + st.gx + ',' + st.gy + ')';
    } else {
      $('big').textContent = 'NO GESTURE';
      $('big').className = 'big idle';
      $('sub').textContent = s.monitor ? '等待稳定检测…' : '点工作台“开始监测”';
    }
    var box = $('events');
    box.textContent = '';
    (s.events || []).slice().reverse().forEach(function(e) {
      var d = document.createElement('div');
      d.className = 'ev';
      d.innerHTML = '<b>' + (e.type || '') + '</b>' +
        (e.gesture ? (' · ' + e.gesture) : '') +
        (e.direction ? (' · ' + e.direction) : '');
      box.appendChild(d);
    });
    var ev = (s.events && s.events.length) ? s.events[s.events.length - 1] : null;
    if (ev && ev.id !== lastEventId) {
      lastEventId = ev.id;
      var txt = String(ev.type || '').toUpperCase();
      if (ev.gesture) txt += ' · ' + ev.gesture;
      if (ev.direction) txt += ' · ' + ev.direction;
      $('action').textContent = txt;
      actionUntil = Date.now() + 1800;
    }
    if (Date.now() > actionUntil) $('action').textContent = '';
    $('cfg').textContent = s.action_cfg
      ? ('hold ' + s.action_cfg.hold + 's · swipe ' + s.action_cfg.swipe +
         ' 格 · seq ' + s.action_cfg.seq + 's')
      : '';
  } catch (e) {
    $('mode').textContent = '未连接';
  }
  setTimeout(poll, 350);
}
poll();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    wb: Workbench = None

    def log_message(self, fmt, *args):
        pass

    def _send(self, code: int, body: bytes, ctype: str = "application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def _read_json(self) -> dict:
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:  # noqa: BLE001
            return {}

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/demo", "/demo.html"):
            self._send(200, DEMO_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif path in ("/", "/index.html"):
            html = INDEX_HTML
            qs = parse_qs(urlparse(self.path).query)
            if qs.get("nostream"):
                html = html.replace(
                    'src="/stream"',
                    'src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="')
            self._send(200, html.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/stream":
            self._stream()
        elif path == "/api/status":
            self._json(self.wb.status())
        elif path == "/api/log":
            qs = parse_qs(urlparse(self.path).query)
            try:
                since = int(qs.get("since", ["0"])[0])
            except ValueError:
                since = 0
            self._json(self.wb.log_since(since))
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            self._route(path, self._read_json())
        except ApiError as exc:
            self._json({"error": str(exc)}, exc.code)
        except Exception as exc:  # noqa: BLE001
            self.wb.log("ERROR " + repr(exc))
            self._json({"error": repr(exc)}, 500)

    def _route(self, path: str, d: dict):
        wb = self.wb
        if path == "/api/classes":
            wb.set_classes(d.get("names", []))
            self._json({"ok": True, "classes": wb.classes})
        elif path == "/api/select":
            wb.select(int(d.get("cls", 0)))
            self._json({"ok": True})
        elif path == "/api/center":
            wb.set_center(float(d.get("x", FRAME_W / 2)), float(d.get("y", FRAME_H / 2)))
            self._json({"ok": True, "center": wb.center})
        elif path == "/api/mirror":
            wb.set_mirror(bool(d.get("on")))
            self._json({"ok": True, "mirror": wb.mirror})
        elif path == "/api/record/save":
            self._json(wb.save_manual(int(d.get("cls", wb.selected_class))))
        elif path == "/api/record/guided":
            wb.start_guided(d.get("rounds", 4), d.get("seconds", 8), d.get("save_fps", 5))
            self._json({"ok": True})
        elif path == "/api/record/stop":
            wb.stop_guided()
            self._json({"ok": True})
        elif path == "/api/train":
            wb.start_train(d.get("epochs", 60), d.get("batch", 4),
                           d.get("workers", 4), d.get("lr", 3e-4))
            self._json({"ok": True})
        elif path == "/api/eval":
            wb.start_eval()
            self._json({"ok": True})
        elif path == "/api/monitor":
            wb.set_monitor(bool(d.get("on")), d.get("threshold"),
                           d.get("hold"), d.get("swipe"), d.get("seq"))
            self._json({"ok": True})
        elif path == "/api/reset":
            if d.get("confirm") != "RESET":
                raise ApiError("missing confirm")
            wb.reset_data()
            self._json({"ok": True})
        else:
            raise ApiError("not found", 404)

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            while True:
                jpeg = self.wb.latest_jpeg()
                if not jpeg:
                    time.sleep(0.05)
                    continue
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " +
                                 str(len(jpeg)).encode() + b"\r\n\r\n" + jpeg + b"\r\n")
                self.wfile.flush()
                time.sleep(1.0 / 15.0)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--camera", type=int, default=0)
    args = ap.parse_args()

    wb = Workbench(args)
    Handler.wb = wb
    try:
        httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as exc:
        print("cannot bind " + args.host + ":" + str(args.port) + " - " + repr(exc), flush=True)
        wb.shutdown()
        return 1
    httpd.daemon_threads = True
    print("workbench: http://" + args.host + ":" + str(args.port), flush=True)
    print("camera index " + str(args.camera) + "; Ctrl+C to stop", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        wb.shutdown()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

