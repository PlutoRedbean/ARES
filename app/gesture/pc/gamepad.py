#!/usr/bin/env python3
"""Read ``run.py`` JSONL on stdin and drive the Xbox 360 pad.

Actions forwarded:

* ``stable == 1`` (defense): hold **LB**
* ``stable == 2`` (point): one **R3** pulse (120 ms)
* ``stable == 3`` (drink): one **D-pad down** pulse (120 ms)
* ``stable == 0`` (idle) or ``-1`` (unknown): release LB, press nothing
* no JSON for 0.5 s: release everything

``unknown`` is deliberately treated like idle for re-arming: you said you only
care about defense / point / drink, so a lost pose must not permanently block
the next pulse.  The R3/D-pad pulses are short and self-releasing.

    py -3.11 run.py --camera 0 --headless --shield-side either |
        py -3.11 gamepad.py --dry-run
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from pathlib import Path

XBOX_ROOT = Path(__file__).resolve().parents[1] / "xbox-controller"
sys.path.insert(0, str(XBOX_ROOT))
try:
    from xbox_serial.controller import Controller, ControllerError  # noqa: E402
    from xbox_serial.gesture_actions import GestureActions  # noqa: E402
    from xbox_serial.input_state import InputState  # noqa: E402
finally:
    # 不要把 xbox-controller 留在 sys.path：它也有一份 run.py，会遮蔽本目录的 run.py。
    try:
        sys.path.remove(str(XBOX_ROOT))
    except ValueError:
        pass

STALE_S = 0.5
LOOP_S = 0.008


def decode(stable: int) -> int:
    """Pass unknown through; GestureActions debounces its re-arm after 300 ms."""

    return stable


class Reader(threading.Thread):
    """后台读 stdin；主循环只取最新一条，避免积压。"""

    def __init__(self) -> None:
        super().__init__(name="jsonl-reader", daemon=True)
        self.lock = threading.Lock()
        self.latest = None  # (stable, monotonic)
        self.eof = False

    def run(self) -> None:
        try:
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("event") == "end":
                    return
                if event.get("event") != "frame":
                    continue
                stable = event.get("stable")
                if not isinstance(stable, int) or stable not in (-1, 0, 1, 2, 3):
                    continue
                with self.lock:
                    self.latest = (stable, time.monotonic())
        finally:
            with self.lock:
                self.eof = True


def run(args) -> int:
    try:
        controller = Controller(dry_run=args.dry_run)
    except ControllerError as error:
        print(f"虚拟手柄初始化失败：{error}", file=sys.stderr)
        return 2

    actions = GestureActions()
    reader = Reader()
    reader.start()
    last_key = None
    try:
        while True:
            now = time.monotonic()
            with reader.lock:
                latest = reader.latest
                eof = reader.eof
            if latest is not None and now - latest[1] <= STALE_S:
                actions.update(decode(latest[0]), now)
            else:
                actions.update(None, now, stale=True)
            state = InputState(buttons=actions.buttons(now))
            controller.apply(state)
            if args.verbose:
                key = state.key()
                if key != last_key:
                    print(f"GAMEPAD {state.describe()}", flush=True)
                    last_key = key
            if eof:
                break
            time.sleep(LOOP_S)
    except KeyboardInterrupt:
        pass
    finally:
        actions.reset()
        try:
            controller.reset()
        finally:
            controller.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="不创建 ViGEmBus 设备，只打印按键")
    parser.add_argument("--verbose", action="store_true", help="按键变化时打印一行")
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
