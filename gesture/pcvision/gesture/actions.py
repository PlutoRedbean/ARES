"""Temporal layer: turn per-frame detections into gesture actions.

The FPGA network classifies one frame at a time.  Real "actions" (hold, swipe)
need a few frames of history, so this module is the policy layer the PC runs
today and the RISC-V scheduler can run later.  Input is exactly what the board
produces: (class, grid x, grid y, confidence) per frame.

No torch / cv2 dependency, so it is cheap to port and easy to unit test.
"""

from __future__ import annotations

import json
import time
from collections import Counter, deque
from dataclasses import dataclass, field


@dataclass
class ActionConfig:
    window: int = 7                 # frames in the majority-vote window
    min_votes: int = 5              # votes needed to lock a gesture
    conf_threshold: float = -1e9    # raw logits can be negative; only filter if set
    hold_seconds: float = 0.8       # "hold" event after this long
    swipe_cells: int = 6            # 6 cells = 96 px of travel
    swipe_seconds: float = 0.35     # travel window
    cooldown: float = 0.7           # minimum gap between swipes
    sequence_window: float = 1.2    # A -> B must happen within this time
    sequence_cooldown: float = 1.0  # minimum gap between sequences


@dataclass
class Event:
    type: str                       # gesture_start | gesture_end | hold | swipe | sequence
    gesture: str = ""
    cls: int = 0
    direction: str = ""
    t: float = 0.0
    gx: int = 0
    gy: int = 0
    conf: int = 0
    source: str = ""                # sequence: the previous gesture

    def to_dict(self) -> dict:
        d = {"type": self.type, "gesture": self.gesture, "cls": self.cls,
             "t": round(self.t, 3)}
        if self.direction:
            d["direction"] = self.direction
        if self.source:
            d["source"] = self.source
        if self.type in ("gesture_start", "hold", "swipe", "sequence"):
            d.update(gx=self.gx, gy=self.gy, conf=self.conf)
        return d


class GestureActions:
    def __init__(self, names: list[str], cfg: ActionConfig | None = None):
        self.names = names
        self.cfg = cfg or ActionConfig()
        self.buf: deque[tuple[float, int, int, int, int]] = deque(maxlen=self.cfg.window)
        self.locked = 0
        self.lock_since = 0.0
        self.hold_sent = False
        self.pos_hist: deque[tuple[float, int, int]] = deque()
        self.last_swipe = {"left": -1e9, "right": -1e9, "up": -1e9, "down": -1e9}
        self.last_lock: tuple[float, int] | None = None
        self.last_sequence = -1e9

    def name(self, cls: int) -> str:
        return self.names[cls] if 0 <= cls < len(self.names) else str(cls)

    def reset(self) -> None:
        self.buf.clear()
        self.pos_hist.clear()
        self.locked = 0
        self.hold_sent = False
        self.last_lock = None
        self.last_sequence = -1e9

    def update(self, cls: int, gx: int, gy: int, conf: int,
               t: float | None = None) -> list[Event]:
        cfg = self.cfg
        t = time.monotonic() if t is None else float(t)
        self.buf.append((t, int(cls), int(gx), int(gy), int(conf)))
        if len(self.buf) < cfg.window:
            return []

        votes = Counter(d[1] for d in self.buf
                        if d[1] > 0 and d[4] >= cfg.conf_threshold)
        stable = 0
        if votes:
            cls_v, n = votes.most_common(1)[0]
            if n >= cfg.min_votes:
                stable = cls_v

        events: list[Event] = []
        if stable != self.locked:
            prev = self.last_lock
            if self.locked:
                events.append(Event("gesture_end", self.name(self.locked), self.locked, t=t))
            self.locked = stable
            self.lock_since = t
            self.hold_sent = False
            self.pos_hist.clear()
            if stable:
                if (prev is not None and prev[1] != stable
                        and 0 < t - prev[0] <= cfg.sequence_window
                        and t - self.last_sequence >= cfg.sequence_cooldown):
                    self.last_sequence = t
                    events.append(Event(
                        "sequence",
                        self.name(prev[1]) + " -> " + self.name(stable),
                        stable, t=t, gx=gx, gy=gy, conf=conf,
                        source=self.name(prev[1]),
                    ))
                self.last_lock = (t, stable)
                events.append(Event("gesture_start", self.name(stable), stable, t=t,
                                    gx=gx, gy=gy, conf=conf))
        if not self.locked:
            return events

        # Keep the last-lock time fresh so a direct A -> B transition is
        # measured from A's last frame, not from when A first appeared.
        self.last_lock = (t, self.locked)

        self.pos_hist.append((t, gx, gy))
        while self.pos_hist and t - self.pos_hist[0][0] > cfg.swipe_seconds:
            self.pos_hist.popleft()

        if not self.hold_sent and t - self.lock_since >= cfg.hold_seconds:
            self.hold_sent = True
            events.append(Event("hold", self.name(self.locked), self.locked, t=t,
                                gx=gx, gy=gy, conf=conf))

        if len(self.pos_hist) >= 2:
            t0, x0, y0 = self.pos_hist[0]
            t1, x1, y1 = self.pos_hist[-1]
            if t1 - t0 >= cfg.swipe_seconds * 0.5:
                dx, dy = x1 - x0, y1 - y0
                direction = ""
                if abs(dx) >= cfg.swipe_cells and abs(dx) > abs(dy) * 1.2:
                    direction = "right" if dx > 0 else "left"
                elif abs(dy) >= cfg.swipe_cells and abs(dy) > abs(dx) * 1.2:
                    direction = "down" if dy > 0 else "up"
                if direction and t - self.last_swipe[direction] >= cfg.cooldown:
                    self.last_swipe[direction] = t
                    events.append(Event("swipe", self.name(self.locked), self.locked,
                                        direction=direction, t=t, gx=x1, gy=y1, conf=conf))
        return events


class EventLog:
    """Append events as JSON lines (one file per run)."""

    def __init__(self, path: str):
        self.path = path
        self.f = open(path, "a", encoding="utf-8")

    def write(self, ev: Event) -> None:
        self.f.write(json.dumps(ev.to_dict(), ensure_ascii=False) + "\n")
        self.f.flush()

    def close(self) -> None:
        self.f.close()
