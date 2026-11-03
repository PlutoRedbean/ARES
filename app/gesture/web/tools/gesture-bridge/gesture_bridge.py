#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gesture-bridge —— 把板子的手势串口输出变成 ARES 全息页的指令。

    板子（每秒 10 行 hand: rock/paper/scissors） --USB-TTL--> COM9
        -> 本程序：解析 / 连续报告判定 / 手势 -> 指令映射
        -> 本机 SSE 服务 http://127.0.0.1:8765/events
        -> 浏览器里的 ARES 页面（EventSource）走同一条指令链路

为什么不让网页自己开串口：一个 COM 口只能被一个进程打开，而板子的输出
是 hand: xxx，不是网页认识的 START/FIST/MODE。这里做翻译，网页那边只是一行
指令，和串口进来的完全一样（源码见 src/serial/BridgeLink.ts）。

用法：

    python gesture_bridge.py                 # 读 COM9，开 :8765，等网页来连
    python gesture_bridge.py --list-ports    # 看串口号
    python gesture_bridge.py --no-server     # 不开服务，只把指令打到 stdout
    python gesture_bridge.py --replay sample_hand_lines.txt --replay-interval 0.1
    python gesture_bridge.py --self-test     # 不用板子和浏览器，跑一遍样例
"""

from __future__ import annotations

import argparse
import configparser
import json
import logging
import logging.handlers
import os
import queue
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

APP_NAME = "ares-gesture-bridge"
APP_VERSION = "1.0.0"

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(HERE, "config.ini")
DEFAULT_LOG = os.path.join(HERE, "logs", "gesture_bridge.log")
SAMPLE_REPLAY = os.path.join(HERE, "sample_hand_lines.txt")

GESTURES = ("rock", "paper", "scissors")
COMMANDS = ("START", "FIST", "POINT", "MODE", "CONFIRM", "ULTIMATE", "RESET", "IDLE")
#: 固件里 margin < 4 就把类别打成 "(weak)"，这里再兜一层。
MARGIN_GATE = 4

log = logging.getLogger("bridge")


# --------------------------------------------------------------------------- #
# 1. 解析板子的输出
# --------------------------------------------------------------------------- #

_HAND_RE = re.compile(r"hand:\s*(?P<label>\S+)")
_MARGIN_RE = re.compile(r"margin\s+(?P<margin>-?\d+)")


@dataclass(frozen=True)
class Report:
    gesture: str | None = None
    label: str = ""
    margin: int | None = None
    raw: str = ""

    @property
    def neutral(self) -> bool:
        return self.gesture is None


def parse_hand_line(line: str) -> Report | None:
    """解析一行板子输出；不是识别行（启动横幅等）返回 None。"""

    text = line.rstrip("\r\n").rstrip()
    match = _HAND_RE.search(text)
    if not match:
        return None

    label = match.group("label")
    margin_match = _MARGIN_RE.search(text)
    margin = int(margin_match.group("margin")) if margin_match else None

    gesture = label if label in GESTURES else None
    if gesture is not None and margin is not None and margin < MARGIN_GATE:
        gesture = None
    return Report(gesture=gesture, label=label, margin=margin, raw=text)


# --------------------------------------------------------------------------- #
# 2. 从连击到指令
# --------------------------------------------------------------------------- #

class IdleWatch:
    """手离开取景框一会儿后发一条"空画面"指令，让页面从握拳/模式退回待机。

    只在"先看到过手势"之后才发，避免页面还没启动就被这条指令打扰；
    每次离开只发一条，重新看到手势才重新武装。
    """

    def __init__(self, command: str, after_ms: int, emit) -> None:
        self._command = command if command in COMMANDS else ""
        self._after = max(0, int(after_ms)) / 1000.0
        self._emit = emit
        self._last_gesture = 0.0
        self._sent = False

    def on_report(self, report: Report, now: float) -> None:
        if not self._command:
            return
        if report.gesture:
            self._last_gesture = now
            self._sent = False
            return
        if self._sent or self._last_gesture <= 0:
            return
        if now - self._last_gesture >= self._after:
            self._sent = True
            self._emit(self._command)


class GestureHoldFSM:
    """一个手势 = 一个状态；保持到 short_ms 进状态，继续到 long_ms 放第二招。

    板子 10 Hz 上报，"保持多久"就是"连续多少行"。对外还提供 hold()，
    给页面画进度条用（含状态名和两个动作名）。
    """

    def __init__(self, actions: dict[str, str], long_actions: dict[str, str],
                 states: dict[str, str], short_ms: int = 200, long_ms: int = 1200,
                 cooldown_ms: int = 400, report_gap_ms: int = 500,
                 clock=time.monotonic):
        self._actions = dict(actions)
        self._long_actions = dict(long_actions)
        self._states = dict(states)
        self._short_ms = max(0, int(short_ms))
        self._long_ms = max(0, int(long_ms))
        self._cooldown = max(0, int(cooldown_ms)) / 1000.0
        self._gap = max(0, int(report_gap_ms)) / 1000.0
        self._clock = clock
        self._armed = True
        self._gesture: str | None = None
        self._started = 0.0
        self._short_done = False
        self._long_done = False
        self._last_fire = float("-inf")
        self._last_report = float("-inf")

    def hold(self) -> dict | None:
        """正在保持的手势（进度条用）；没有就返回 None。"""

        if self._gesture is None or not self._armed:
            return None
        return {
            "gesture": self._gesture,
            "state": self._states.get(self._gesture, self._gesture),
            "short": self._actions.get(self._gesture, ""),
            "long": self._long_actions.get(self._gesture, ""),
            "elapsed": int(round((self._clock() - self._started) * 1000)),
            "short_ms": self._short_ms,
            "long_ms": self._long_ms,
        }

    def feed(self, report: Report, now: float | None = None) -> list[str]:
        now = self._clock() if now is None else now
        out: list[str] = []

        if self._gap and now - self._last_report > self._gap:
            self._release()
        self._last_report = now

        if report.neutral:
            self._release()
            return out

        if not self._armed:
            return out

        if report.gesture != self._gesture:
            self._gesture = report.gesture
            self._started = now
            self._short_done = False
            self._long_done = False

        assert self._gesture is not None
        elapsed_ms = (now - self._started) * 1000.0

        if not self._short_done and elapsed_ms >= self._short_ms:
            self._short_done = True
            command = self._actions.get(self._gesture, "")
            if command in COMMANDS and now - self._last_fire >= self._cooldown:
                out.append(command)
                self._last_fire = now

        if not self._long_done and self._long_ms > self._short_ms and elapsed_ms >= self._long_ms:
            self._long_done = True
            command = self._long_actions.get(self._gesture, "")
            if command in COMMANDS and now - self._last_fire >= self._cooldown:
                out.append(command)
                self._last_fire = now
            self._armed = False

        return out

    def _release(self) -> None:
        self._gesture = None
        self._short_done = False
        self._long_done = False
        self._armed = True


# --------------------------------------------------------------------------- #
# 3. 配置
# --------------------------------------------------------------------------- #

CONFIG_TEMPLATE = """\
# gesture-bridge 配置（改完重启程序生效）
# 串口号： python gesture_bridge.py --list-ports

[serial]
port = COM9
baudrate = 115200
reconnect_ms = 1000

[gesture]
# 手势 = 网页指令。指令只能是 START / FIST / POINT / MODE / CONFIRM / ULTIMATE / RESET，
# 写 IGNORE 表示这个手势不做动作。
# 默认按网页自己文档里的手势名对应：张开手掌=START、握拳=FIST、V 字=MODE。
paper = START
rock = FIST
scissors = MODE

# 手离开取景框多久之后发"空画面"指令，让页面退回待机。
# 指令写 IGNORE 表示不做这件事（页面就会一直停在最后一个手势上）。
idle_command = IDLE

[hold]
# 一个手势 = 一个状态：保持 short_ms 进状态，继续到 long_ms 放这个状态的第二招。
short_ms = 200
long_ms = 900
# <手势>_state 是这个状态在界面上的名字；<手势>_long 是长按触发的指令（IGNORE = 没有）
rock_state = 蓄力
rock_long = ULTIMATE
paper_state = 启动
paper_long = CONFIRM
scissors_state = 模型
scissors_long = POINT

[timing]
# 连续几行（板子 10 Hz）一致才发指令：2 行约 0.2 秒。
confirm_reports = 3
# 两条指令之间的最小间隔（网页自己还有一层冷却）。
cooldown_ms = 800
# 静默这么久没有任何行 = 手已离开，重新上膛。
report_gap_ms = 500
# 手离开多久之后发 idle_command（从最后一个手势行算起）。
idle_after_ms = 1200

[server]
host = 127.0.0.1
port = 8765
"""


@dataclass
class Config:
    port: str = "COM9"
    baudrate: int = 115200
    reconnect_s: float = 1.0
    actions: dict[str, str] = field(default_factory=dict)
    long_actions: dict[str, str] = field(default_factory=dict)
    states: dict[str, str] = field(default_factory=dict)
    short_ms: int = 200
    long_ms: int = 1200
    confirm_reports: int = 2
    cooldown_ms: int = 400
    report_gap_ms: int = 500
    idle_command: str = "IDLE"
    idle_after_ms: int = 800
    host: str = "127.0.0.1"
    http_port: int = 8765


def load_config(path: str) -> Config:
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(CONFIG_TEMPLATE)
        log.info("未找到配置文件，已生成默认配置：%s", path)

    parser = configparser.ConfigParser()
    parser.read_string(CONFIG_TEMPLATE)
    parser.read(path, encoding="utf-8")

    config = Config()
    config.port = parser.get("serial", "port", fallback=config.port).strip()
    config.baudrate = parser.getint("serial", "baudrate", fallback=config.baudrate)
    config.reconnect_s = max(0.05, parser.getint("serial", "reconnect_ms", fallback=1000) / 1000.0)

    actions: dict[str, str] = {}
    long_actions: dict[str, str] = {}
    states: dict[str, str] = {}
    for gesture in GESTURES:
        raw = parser.get("gesture", gesture, fallback="IGNORE").strip().upper()
        actions[gesture] = raw if raw in COMMANDS else ""
        raw_long = parser.get("hold", gesture + "_long", fallback="IGNORE").strip().upper()
        long_actions[gesture] = raw_long if raw_long in COMMANDS else ""
        states[gesture] = parser.get("hold", gesture + "_state", fallback=gesture).strip()
    config.actions = actions
    config.long_actions = long_actions
    config.states = states
    config.short_ms = max(0, parser.getint("hold", "short_ms", fallback=200))
    config.long_ms = max(0, parser.getint("hold", "long_ms", fallback=1200))

    config.confirm_reports = max(1, parser.getint("timing", "confirm_reports", fallback=3))
    config.cooldown_ms = max(0, parser.getint("timing", "cooldown_ms", fallback=800))
    config.report_gap_ms = max(0, parser.getint("timing", "report_gap_ms", fallback=500))

    idle_command = parser.get("gesture", "idle_command", fallback="IDLE").strip().upper()
    config.idle_command = idle_command if idle_command in COMMANDS else ""
    config.idle_after_ms = max(0, parser.getint("timing", "idle_after_ms", fallback=1200))

    config.host = parser.get("server", "host", fallback="127.0.0.1").strip() or "127.0.0.1"
    config.http_port = parser.getint("server", "port", fallback=8765)
    return config


# --------------------------------------------------------------------------- #
# 4. SSE 服务
# --------------------------------------------------------------------------- #

class Broadcaster:
    """把指令推给所有已连接的页面。"""

    def __init__(self) -> None:
        self._clients: set[queue.Queue] = set()
        self._lock = threading.Lock()
        self.sent = 0

    @property
    def clients(self) -> int:
        with self._lock:
            return len(self._clients)

    def register(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=64)
        with self._lock:
            self._clients.add(q)
        return q

    def unregister(self, q: queue.Queue) -> None:
        with self._lock:
            self._clients.discard(q)

    def publish(self, command: str) -> int:
        with self._lock:
            targets = list(self._clients)
        for q in targets:
            try:
                q.put_nowait(command)
            except queue.Full:
                pass
        if targets:
            self.sent += 1
        return len(targets)


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, broadcaster: Broadcaster, state: dict):
        super().__init__(address, Handler)
        self.broadcaster = broadcaster
        self.state = state


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: BridgeServer

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - 覆盖父类，静音
        log.debug("http %s", fmt % args)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 的约定
        path = urlparse(self.path).path
        if path == "/events":
            self._stream()
        elif path == "/status":
            self._json(200, {
                "app": APP_NAME,
                "version": APP_VERSION,
                "clients": self.server.broadcaster.clients,
                "pushed": self.server.broadcaster.sent,
                **self.server.state,
            })
        else:
            self._json(200, {
                "app": APP_NAME,
                "usage": [
                    "/events  SSE 指令流（网页的 EventSource 连这里）",
                    "/status  JSON 状态",
                ],
            })

    def do_OPTIONS(self) -> None:  # noqa: N802 - CORS 预检
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _stream(self) -> None:
        broadcaster = self.server.broadcaster
        client = broadcaster.register()
        log.info("页面已连接（当前 %d 个）", broadcaster.clients)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-transform")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Transfer-Encoding", "chunked")
            self._cors()
            self.end_headers()

            def chunk(payload: bytes) -> None:
                self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")
                self.wfile.flush()

            chunk(b": connected to " + APP_NAME.encode() + b"\n\n")
            last_ping = time.monotonic()
            while True:
                try:
                    item = client.get(timeout=0.5)
                except queue.Empty:
                    if time.monotonic() - last_ping > 15:
                        chunk(b": ping\n\n")
                        last_ping = time.monotonic()
                    continue
                if item is None:
                    break
                chunk(("data: %s\n\n" % item).encode("utf-8"))
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            broadcaster.unregister(client)
            log.info("页面断开（剩 %d 个）", broadcaster.clients)


def start_server(host: str, port: int, broadcaster: Broadcaster, state: dict) -> BridgeServer:
    server = BridgeServer((host, port), broadcaster, state)
    thread = threading.Thread(target=server.serve_forever, name="sse", daemon=True)
    thread.start()
    return server


# --------------------------------------------------------------------------- #
# 5. 串口 / 回放
# --------------------------------------------------------------------------- #

def list_serial_ports() -> int:
    try:
        from serial.tools import list_ports
    except ImportError:
        print("没装 pyserial：python -m pip install pyserial", file=sys.stderr)
        return 1
    ports = list(list_ports.comports())
    for item in ports:
        print("%s: %s" % (item.device, item.description))
    return 0 if ports else 1


def run_serial(port: str, baudrate: int, reconnect_s: float, on_line, stop: threading.Event) -> None:
    try:
        import serial
    except ImportError:
        log.error("没装 pyserial：python -m pip install pyserial")
        raise SystemExit(2)

    while not stop.is_set():
        try:
            link = serial.Serial(port=port, baudrate=baudrate, timeout=0.2)
        except Exception as exc:  # noqa: BLE001 - 打不开就重试
            log.warning("串口打开失败 %s：%s；%.1f 秒后重试", port, exc, reconnect_s)
            stop.wait(reconnect_s)
            continue

        log.info("串口已打开：%s @%d 8N1", port, baudrate)
        buffer = b""
        try:
            while not stop.is_set():
                chunk = link.read(256)
                if not chunk:
                    continue
                buffer += chunk
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    on_line(raw.decode("ascii", "replace"))
        except Exception as exc:  # noqa: BLE001 - 拔线
            log.warning("串口读失败：%s；重连", exc)
        finally:
            try:
                link.close()
            except Exception:  # noqa: BLE001
                pass
        stop.wait(reconnect_s)


def run_replay(path: str, interval: float, on_line, stop: threading.Event) -> None:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    log.info("回放 %d 行：%s（间隔 %.2f 秒）", len(lines), path, interval)
    for line in lines:
        if stop.is_set():
            return
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        on_line(line)
        if stop.wait(interval):
            return


# --------------------------------------------------------------------------- #
# 6. 命令行
# --------------------------------------------------------------------------- #

def setup_logging(level_name: str, log_file: str | None) -> None:
    level = getattr(logging, level_name.upper(), logging.INFO)
    root = logging.getLogger()
    for handler in list(root.handlers):
        root.removeHandler(handler)
    root.setLevel(level)

    fmt = logging.Formatter("%(asctime)s %(levelname)-7s [%(name)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    console = logging.StreamHandler(sys.stderr)
    console.setFormatter(fmt)
    root.addHandler(console)

    if log_file:
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
            rotating = logging.handlers.RotatingFileHandler(
                log_file, maxBytes=1 << 20, backupCount=3, encoding="utf-8")
            rotating.setFormatter(fmt)
            root.addHandler(rotating)
        except OSError as exc:
            log.warning("日志文件打不开（%s），只输出到控制台", exc)


EXPECTED_SELF_TEST = ["START", "FIST", "FIST", "MODE", "START"]


def self_test(config: Config) -> int:
    if not os.path.exists(SAMPLE_REPLAY):
        print("缺少样例文件：%s" % SAMPLE_REPLAY, file=sys.stderr)
        return 2

    fsm = GestureHoldFSM(config.actions, config.long_actions, config.states,
                         config.short_ms, config.long_ms, config.cooldown_ms, 0)
    got: list[str] = []
    with open(SAMPLE_REPLAY, "r", encoding="utf-8") as handle:
        for index, line in enumerate(handle.read().splitlines()):
            report = parse_hand_line(line)
            if report is None:
                continue
            got.extend(fsm.feed(report, now=index * 0.1))

    ok = got == EXPECTED_SELF_TEST
    print("期望：%s" % " ".join(EXPECTED_SELF_TEST))
    print("实际：%s" % " ".join(got))
    print("自检：%s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gesture_bridge.py",
        description="板子手势串口 -> ARES 全息页指令（本机 SSE 服务）")
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="配置文件（默认同目录 config.ini）")
    parser.add_argument("--port", help="串口号，例如 COM9")
    parser.add_argument("--baud", type=int, help="波特率，默认 115200")
    parser.add_argument("--http-port", type=int, help="SSE 服务端口，默认 8765")
    parser.add_argument("--no-server", action="store_true", help="不开服务，只把指令打到 stdout")
    parser.add_argument("--replay", metavar="FILE", help="回放抓包文件，不打开串口")
    parser.add_argument("--replay-interval", type=float, default=0.1, help="回放间隔秒，默认 0.1")
    parser.add_argument("--loop", action="store_true", help="回放循环，方便一边看页面一边调")
    parser.add_argument("--list-ports", action="store_true", help="列出串口后退出")
    parser.add_argument("--self-test", action="store_true", help="内置样例跑一遍，不碰硬件")
    parser.add_argument("--log-level", default="INFO", help="DEBUG/INFO/WARNING/ERROR")
    parser.add_argument("--log-file", default=DEFAULT_LOG, help="日志文件；空字符串表示不写文件")
    parser.add_argument("--version", action="version", version="%s %s" % (APP_NAME, APP_VERSION))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    setup_logging(args.log_level, args.log_file or None)
    log.info("%s %s 启动（Python %s）", APP_NAME, APP_VERSION,
             ".".join(map(str, sys.version_info[:3])))

    if args.list_ports:
        return list_serial_ports()

    config = load_config(args.config)
    if args.port:
        config.port = args.port
    if args.baud:
        config.baudrate = args.baud
    if args.http_port:
        config.http_port = args.http_port

    log.info("映射：%s", "  ".join("%s->%s" % (g, config.actions.get(g) or "IGNORE") for g in GESTURES))
    log.info("判定：保持 %d ms 进状态；%d ms 长按第二招；间隔 %d ms",
             config.short_ms, config.long_ms, config.cooldown_ms)
    log.info("空画面：手离开 %d ms 后发 %s", config.idle_after_ms,
             config.idle_command or "IGNORE（不发）")

    if args.self_test:
        return self_test(config)

    state = {"last": None, "lastAt": None, "commands": 0, "reports": 0}
    broadcaster = Broadcaster()
    server = None
    if not args.no_server:
        try:
            server = start_server(config.host, config.http_port, broadcaster, state)
        except OSError as exc:
            log.error("端口 %d 起不来（%s）——换个端口：--http-port 8766，同时页面加 ?bridge=8766",
                      config.http_port, exc)
            return 2
        log.info("SSE 服务：http://%s:%d/events （页面里 ?bridge=%d 可改端口）",
                 config.host, config.http_port, config.http_port)

    fsm = GestureHoldFSM(config.actions, config.long_actions, config.states,
                         config.short_ms, config.long_ms, config.cooldown_ms,
                         0 if args.replay else config.report_gap_ms)
    stop = threading.Event()

    def emit(command: str) -> None:
        state["last"] = command
        state["lastAt"] = time.time()
        state["commands"] += 1
        targets = broadcaster.publish(command) if server else 0
        if args.no_server:
            print(command, flush=True)
        log.info(">>> %s%s", command, "" if not server else "（推给 %d 个页面）" % targets)

    idle = IdleWatch(config.idle_command, config.idle_after_ms, emit)

    # 进度条：状态名 + 两个动作 + 已保持时长（10 Hz，变化才发）
    hold_last = {"line": ""}

    def publish_hold(info: dict | None) -> None:
        if server is None:
            return
        if info is None:
            line = "HOLD off"
        else:
            line = "HOLD %s %s %d %d %d %s" % (
                info["state"], info["short"] or "-", info["elapsed"],
                info["short_ms"], info["long_ms"], info["long"] or "-")
        if line == hold_last["line"]:
            return
        hold_last["line"] = line
        broadcaster.publish(line)

    def handle_line(line: str) -> None:
        report = parse_hand_line(line)
        if report is None:
            log.debug("忽略：%s", line.strip())
            return
        state["reports"] += 1
        now = time.monotonic()
        idle.on_report(report, now)
        for command in fsm.feed(report, now):
            emit(command)
        publish_hold(fsm.hold())

    try:
        while not stop.is_set():
            try:
                if args.replay:
                    run_replay(args.replay, args.replay_interval, handle_line, stop)
                    if not args.loop:
                        break
                    stop.wait(1.0)
                else:
                    run_serial(config.port, config.baudrate, config.reconnect_s, handle_line, stop)
            except KeyboardInterrupt:
                raise
    except KeyboardInterrupt:
        log.info("收到 Ctrl+C")
    finally:
        stop.set()
        if server:
            server.shutdown()
            server.server_close()
        log.info("退出：报告 %d 行，指令 %d 条，最后一条 %s",
                 state["reports"], state["commands"], state["last"] or "-")
    return 0


if __name__ == "__main__":
    sys.exit(main())
