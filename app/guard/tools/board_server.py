#!/usr/bin/env python3
"""Local board service for guard/web: static files, JTAG programming, IMU takeover.

The browser cannot run ``cdt_cfg`` itself, and it cannot take a COM port away
from other programs, so this tiny local server exposes:

* ``GET  /api/board/bitstreams`` / ``POST /api/board/program`` — flash a bitstream;
* ``GET  /api/serial/ports``        — list COM ports;
* ``GET  /api/serial/holders``      — who is holding a COM port;
* ``POST /api/serial/release``      — stop the holders and test the port;
* ``GET  /api/imu/status``          — xbox-controller process + log tail;
* ``POST /api/imu/takeover``        — one-click: free COM, exit Guard, start IMU,
  launch ``xbox-controller --imu-port``;
* ``POST /api/imu/stop``            — stop the controller and put the board back
  into MSH with ``imu stop``.

    py -3.11 app/guard/tools/board_server.py --port 8788 --open-browser

The server binds to 127.0.0.1 only.
"""
from __future__ import annotations

import argparse
import atexit
import functools
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import webbrowser
from collections import deque
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable, Optional
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[3]
WEB = Path(__file__).resolve().parents[1] / "web"
PROGRAM = Path(__file__).resolve().with_name("program_guard.ps1")

FLASH_LOCK = threading.Lock()
TAKEOVER_LOCK = threading.Lock()
DEFAULT_BAUD = 115200
DEFAULT_PORT = 8788

CONTROLLER_CANDIDATES = (
    ROOT / "app" / "imu" / "xbox-controller",
    ROOT / "app" / "gesture" / "xbox-controller",
)

#: 这些进程即使命令行里没有 COMx，也大概率是在占串口。按进程名前缀匹配。
DEFAULT_KILL_NAMES = (
    "sscom",
    "xcom",
    "putty",
    "plink",
    "kitty",
    "xshell",
    "securecrt",
    "mobaxterm",
    "minicom",
    "cutecom",
    "gtkterm",
    "arduino",
    "arduino-ide",
    "rtthread",
    "rt-thread",
    "rt_thread",
    "rtthreadstudio",
    "rtthread guard",
    "rtt guard",
    "rtt",
    "xbox-serial",
    "xbox_serial",
    "serialassistant",
    "uartassistant",
    "comassistant",
    "vofa",
    "vofa+",
    "hercules",
    "termite",
    "realterm",
    "hterm",
    "serialmonitor",
)

#: 绝对不能因为命令行提到 COMx 就被结束的进程（浏览器/终端/系统进程）。
EXCLUDED_NAMES = {
    "system",
    "registry",
    "idle",
    "memory compression",
    "smss",
    "csrss",
    "wininit",
    "winlogon",
    "services",
    "lsass",
    "svchost",
    "explorer",
    "dwm",
    "fontdrvhost",
    "ctfmon",
    "sihost",
    "taskhostw",
    "runtimebroker",
    "searchhost",
    "startmenuexperiencehost",
    "shellexperiencehost",
    "textinputhost",
    "applicationframehost",
    "conhost",
    "openconsole",
    "windowsterminal",
    "cmd",
    "powershell",
    "pwsh",
    "bash",
    "wsl",
    "wslhost",
    "git",
    "code",
    "devenv",
    "chrome",
    "msedge",
    "firefox",
    "brave",
    "opera",
    "vivaldi",
    "safari",
    "xboxpcapp",
    "xboxpcappft",
    "gamebar",
    "gamebarftserver",
    "deepseek harness",
    "electron",
}


def _decode_console(data: bytes) -> str:
    for enc in ("utf-8", "mbcs", "latin-1"):
        try:
            return data.decode(enc)
        except (LookupError, UnicodeDecodeError):
            continue
    return data.decode("utf-8", "replace")


def _json_field(item: dict, name: str) -> Any:
    if name in item:
        return item[name]
    low = name.lower()
    for k, v in item.items():
        if str(k).lower() == low:
            return v
    return None


def _name_key(name: str) -> str:
    n = str(name or "").strip().lower()
    return n[:-4] if n.endswith(".exe") else n


def _name_matches(name: str, key: str) -> bool:
    """已知串口程序的名字匹配；长名字用前缀，短名字要完全相等。"""
    n = _name_key(name)
    k = _name_key(key)
    if not n or not k:
        return False
    if n == k:
        return True
    return len(k) >= 4 and n.startswith(k)


def normalize_port(name: str) -> str:
    s = str(name or "").strip()
    if s.upper().startswith("\\\\.\\"):
        s = s[4:]
    return s


def valid_port(name: str) -> bool:
    return bool(re.fullmatch(r"(?:COM\d{1,3}|/dev/tty[A-Za-z0-9._-]+)", name, re.I))


def _serial_context(name: str, cmdline: str, kill_names: Iterable[str]) -> bool:
    """命令行里出现 COM9 还不够：要有串口工具的上下文，避免误杀聊天窗口。"""

    if any(_name_matches(name, k) for k in kill_names):
        return True
    blob = f"{name} {cmdline}".lower()
    if re.search(
        r"\b(?:serial|uart|comport|com_port|tty|modem|putty|plink|sscom|"
        r"rtthread|rt-thread|rt_thread|jlink|stlink|rtt|terminal)",
        blob,
    ):
        return True
    return bool(
        re.search(
            r"(?:^|\s)(?:-p|--port|--com|--serial|-serial|--imu-port|--state-port|/port)"
            r"(?:=|\s+)\S+",
            blob,
        )
    )


def port_in_cmdline(cmdline: str, port: str) -> bool:
    if not cmdline:
        return False
    port = normalize_port(port)
    if not port:
        return False
    if port.upper().startswith("COM"):
        pattern = rf"(?<![a-z0-9_]){re.escape(port.lower())}(?![a-z0-9_])"
    else:
        pattern = re.escape(port.lower())
    return re.search(pattern, cmdline.lower()) is not None


def match_holders(
    processes: Iterable[dict],
    port: str,
    kill_names: Iterable[str] = DEFAULT_KILL_NAMES,
    exclude_pids: Iterable[int] = (),
) -> list[dict]:
    """从 ``Win32_Process`` 快照里挑出可能占用 ``port`` 的进程。

    ``strong`` = 命令行里明确写了这个端口；``weak`` = 进程名属于已知串口
    工具（命令行不一定带端口）。浏览器/终端/系统进程永不在结果里。
    """

    excluded = {int(p) for p in exclude_pids}
    keys = tuple(k for k in kill_names if k)
    out: list[dict] = []
    for raw in processes or []:
        try:
            pid = int(_json_field(raw, "ProcessId") or _json_field(raw, "pid") or 0)
        except (TypeError, ValueError):
            continue
        if pid <= 4 or pid in excluded:
            continue
        name = str(_json_field(raw, "Name") or _json_field(raw, "name") or "")
        cmd = str(_json_field(raw, "CommandLine") or _json_field(raw, "cmdline") or "")
        key = _name_key(name)
        if not key or key in EXCLUDED_NAMES:
            continue
        low_cmd = cmd.lower()
        if "board_server.py" in low_cmd:
            continue
        strong = port_in_cmdline(cmd, port) and _serial_context(name, cmd, keys)
        weak = any(_name_matches(name, k) for k in keys)
        if not strong and not weak:
            continue
        reason = "命令行包含 " + normalize_port(port) if strong else "已知串口程序"
        out.append(
            {
                "pid": pid,
                "name": name,
                "cmdline": cmd[:240],
                "strong": strong,
                "weak": not strong,
                "reason": reason,
            }
        )
    out.sort(key=lambda x: (not x["strong"], x["name"].lower(), x["pid"]))
    return out


def build_controller_command(
    python: str,
    root: Path,
    port: str,
    profile: Optional[str] = None,
    dry_run: bool = False,
    baud: Optional[int] = None,
) -> list[str]:
    cmd = [
        python,
        "-u",
        str(Path(root) / "run.py"),
        "--imu-port",
        normalize_port(port),
        "--stdin-cmd",
    ]
    if profile:
        cmd += ["--imu-profile", profile]
    if baud and int(baud) != DEFAULT_BAUD:
        cmd += ["--baudrate", str(int(baud))]
    if dry_run:
        cmd.append("--dry-run")
    return cmd


def list_profiles(root: Path) -> list[str]:
    pdir = Path(root) / "profiles"
    if not pdir.is_dir():
        return []
    return [f"profiles/{p.name}" for p in sorted(pdir.glob("*.yaml"))]


def _serial_module():
    try:
        import serial  # noqa: PLC0415

        return serial
    except ImportError as exc:  # noqa: BLE001
        raise RuntimeError(
            "缺少 pyserial：py -3.11 -m pip install pyserial"
        ) from exc


def list_serial_ports() -> list[dict]:
    _serial_module()
    from serial.tools import list_ports  # noqa: PLC0415

    items: list[dict] = []
    for p in list_ports.comports():
        vid = getattr(p, "vid", None)
        pid = getattr(p, "pid", None)
        desc = getattr(p, "description", "") or ""
        hwid = getattr(p, "hwid", "") or ""
        likely = bool(
            vid in (0x10C4, 0x1A86, 0x0403, 0x2341, 0x303A)
            or re.search(r"usb|uart|serial|cp210|ch340|ft232", desc + " " + hwid, re.I)
        )
        # 盘古板最常见的 USB-UART 是 CP210x / CH340；多个串口时优先选它。
        priority = 3 if vid in (0x10C4, 0x1A86) else 2 if vid == 0x0403 else 1 if likely else 0
        items.append(
            {
                "device": p.device,
                "description": desc,
                "hwid": hwid,
                "vid": f"{vid:04X}" if isinstance(vid, int) else "",
                "pid": f"{pid:04X}" if isinstance(pid, int) else "",
                "likely": likely,
                "priority": priority,
            }
        )
    items.sort(key=lambda x: (-x["priority"], not x["likely"], x["device"].lower()))
    return items


@functools.lru_cache(maxsize=4)
def python_modules(python: str) -> dict:
    code = (
        "import json\n"
        "res = {}\n"
        "for m in ('serial', 'yaml', 'vgamepad'):\n"
        "    try:\n"
        "        __import__(m)\n"
        "        res[m] = True\n"
        "    except Exception:\n"
        "        res[m] = False\n"
        "print(json.dumps(res))\n"
    )
    try:
        proc = subprocess.run(
            [python, "-c", code], capture_output=True, timeout=30, text=True,
            encoding="utf-8", errors="replace",
        )
        lines = [ln for ln in (proc.stdout or "").splitlines() if ln.strip()]
        data = json.loads(lines[-1]) if lines else {}
    except Exception:  # noqa: BLE001
        data = {}
    return {
        "serial": bool(data.get("serial")),
        "yaml": bool(data.get("yaml")),
        "vgamepad": bool(data.get("vgamepad")),
    }


def list_windows_processes() -> list[dict]:
    """``Win32_Process`` 快照；失败时返回空列表（只会导致“找不到占口进程”）。"""

    if os.name != "nt":
        try:
            proc = subprocess.run(
                ["ps", "-eo", "pid=,comm=,args="],
                capture_output=True, timeout=10, text=True, errors="replace",
            )
        except Exception:  # noqa: BLE001
            return []
        out: list[dict] = []
        for line in (proc.stdout or "").splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 2:
                continue
            try:
                pid = int(parts[0])
            except ValueError:
                continue
            out.append({"ProcessId": pid, "Name": parts[1], "CommandLine": parts[2] if len(parts) > 2 else ""})
        return out

    exe = shutil.which("powershell") or shutil.which("pwsh")
    if not exe:
        return []
    script = (
        "$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8\n"
        "Get-CimInstance Win32_Process | Select-Object ProcessId,Name,CommandLine | "
        "ConvertTo-Json -Compress\n"
    )
    try:
        proc = subprocess.run(
            [exe, "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True, timeout=20,
        )
        text = _decode_console(proc.stdout or b"").strip()
    except Exception:  # noqa: BLE001
        return []
    if not text:
        return []
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        # PowerShell 偶尔会在 JSON 前后带一行噪声；取最后一行 JSON。
        for line in reversed(text.splitlines()):
            try:
                data = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
        else:
            return []
    if isinstance(data, dict):
        return [data]
    return [x for x in data if isinstance(x, dict)]


def ancestor_pids(processes: Iterable[dict], start_pid: int) -> set[int]:
    """沿 ParentProcessId 向上走，返回祖先 PID（防止误杀启动本服务的终端/宿主）。"""

    parent: dict[int, int] = {}
    for raw in processes or []:
        try:
            pid = int(_json_field(raw, "ProcessId") or 0)
            ppid = int(_json_field(raw, "ParentProcessId") or 0)
        except (TypeError, ValueError):
            continue
        if pid > 0:
            parent[pid] = ppid
    out: set[int] = set()
    pid = int(start_pid)
    for _ in range(64):
        ppid = parent.get(pid)
        if not ppid or ppid <= 4 or ppid in out:
            break
        out.add(ppid)
        pid = ppid
    return out


def find_holders(port: str) -> list[dict]:
    processes = list_windows_processes()
    exclude = {os.getpid()} | ancestor_pids(processes, os.getpid())
    # 正在运行的 xbox-controller 是“预期占口者”，不要在 UI 里当成敌人。
    try:
        own = CONTROLLER.status().get("pid")
        if own:
            exclude.add(int(own))
    except Exception:  # noqa: BLE001
        pass
    return match_holders(
        processes,
        port,
        kill_names=SERVER.kill_names,
        exclude_pids=exclude,
    )


def probe_port(port: str, baud: int = DEFAULT_BAUD) -> tuple[str, str]:
    """返回 ``("open"|"busy"|"missing"|"error", detail)``。

    ``busy`` 才值得结束占口进程；``missing``（COM 口不存在/板子没插）绝不能
    因为命令行里恰好有别的 COM 号就去杀串口助手。
    """

    try:
        serial = _serial_module()
    except RuntimeError as exc:
        return "error", str(exc)
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud
    ser.timeout = 0.05
    ser.write_timeout = 0.5
    ser.dtr = False
    ser.rts = False
    try:
        ser.open()
        return "open", ""
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        low = msg.lower()
        if isinstance(exc, FileNotFoundError) or "file not found" in low or "cannot find" in low or "系统找不到" in msg:
            return "missing", msg
        if isinstance(exc, PermissionError) or "access is denied" in low or "permission" in low or "拒绝访问" in msg:
            return "busy", msg
        return "error", msg
    finally:
        try:
            ser.close()
        except Exception:  # noqa: BLE001
            pass


def can_open_port(port: str, baud: int = DEFAULT_BAUD) -> tuple[bool, str]:
    status, detail = probe_port(port, baud)
    return status == "open", detail


def open_serial(port: str, baud: int = DEFAULT_BAUD, retry_s: float = 2.5):
    serial = _serial_module()
    deadline = time.monotonic() + max(0.0, retry_s)
    while True:
        ser = serial.Serial()
        ser.port = port
        ser.baudrate = baud
        ser.timeout = 0.05
        ser.write_timeout = 1.0
        ser.dtr = False
        ser.rts = False
        try:
            ser.open()
            return ser
        except Exception:  # noqa: BLE001
            try:
                ser.close()
            except Exception:  # noqa: BLE001
                pass
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.2)


def kill_process(pid: int) -> tuple[bool, str]:
    if pid <= 4 or pid == os.getpid():
        return False, "拒绝结束系统进程/自身"
    if os.name == "nt":
        try:
            proc = subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True, timeout=15,
            )
            out = _decode_console((proc.stdout or b"") + (proc.stderr or b"")).strip()
            return proc.returncode == 0, out or f"taskkill exit={proc.returncode}"
        except Exception as exc:  # noqa: BLE001
            return False, str(exc)
    try:
        os.kill(pid, 15)
        return True, "SIGTERM"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def _read_for(ser, seconds: float, transcript: bytearray) -> str:
    end = time.monotonic() + max(0.0, seconds)
    while time.monotonic() < end:
        try:
            chunk = ser.read(4096)
        except Exception:  # noqa: BLE001
            break
        if chunk:
            transcript += chunk
        else:
            time.sleep(0.02)
    return transcript.decode("utf-8", "replace")


def _read_until(ser, needles: Iterable[str], timeout: float, transcript: bytearray) -> tuple[bool, str]:
    end = time.monotonic() + max(0.0, timeout)
    buf = bytearray()
    needles = tuple(n for n in needles if n)
    while time.monotonic() < end:
        try:
            chunk = ser.read(4096)
        except Exception:  # noqa: BLE001
            break
        if chunk:
            buf += chunk
            transcript += chunk
            text = buf.decode("utf-8", "replace")
            if any(n in text for n in needles):
                return True, text
        else:
            time.sleep(0.02)
    return False, buf.decode("utf-8", "replace")


def run_board_sequence(
    port: str,
    baud: int = DEFAULT_BAUD,
    *,
    exit_guard: bool = True,
    stop_ai: bool = True,
    start_imu: bool = True,
) -> dict:
    """在浏览器松开串口之后，把板子从 Guard/AI 切到 IMU 遥测。

    返回 ``{"ok": bool, "steps": [...], "warnings": [...], "transcript": str}``。
    步骤 id 与前端 ``#imuSteps`` 的 data-step 对齐。
    """

    steps: list[dict] = []
    warnings: list[str] = []
    transcript = bytearray()

    try:
        ser = open_serial(port, baud, retry_s=2.5)
    except Exception as exc:  # noqa: BLE001
        return {
            "ok": False,
            "steps": [{"id": "port", "label": "打开串口", "ok": False, "detail": str(exc)}],
            "warnings": ["串口仍被占用，或驱动/端口名不对"],
            "transcript": "",
        }

    try:
        ser.write(b"\n")
        ser.flush()
        probe = _read_for(ser, 1.2, transcript)
        guard = "[guard]" in probe.lower()

        if guard:
            if not exit_guard:
                steps.append({"id": "guard", "label": "退出 Guard 会话", "ok": False, "detail": "检测到 Guard 会话，但本次没有允许退出"})
                return {"ok": False, "steps": steps, "warnings": warnings, "transcript": probe[-4000:]}
            ser.write(b"\x1d")
            ser.flush()
            hit, out = _read_until(ser, ("GUARD EXIT", "msh >"), 3.0, transcript)
            if not hit:
                steps.append({"id": "guard", "label": "退出 Guard 会话", "ok": False, "detail": "没有收到 GUARD EXIT / msh >"})
                return {"ok": False, "steps": steps, "warnings": ["Guard 会话没有退出，xbox-controller 会读到审计行"], "transcript": transcript.decode("utf-8", "replace")[-4000:]}
            if "msh >" not in out:
                _read_until(ser, ("msh >",), 1.5, transcript)
            steps.append({"id": "guard", "label": "退出 Guard 会话", "ok": True, "detail": "Ctrl+] → MSH"})
        else:
            steps.append({"id": "guard", "label": "退出 Guard 会话", "ok": True, "detail": "当前不在 Guard 会话，跳过"})

        if stop_ai:
            ser.write(b"ai stop\n")
            ser.flush()
            hit, out = _read_until(ser, ("msh >",), 2.5, transcript)
            ok = hit or "stop" in out.lower()
            if not hit:
                warnings.append("ai stop 没有等到 msh >：AI 可能正在跑自检/CoreMark，先等它结束")
            steps.append({"id": "ai", "label": "停止 AI 手势流", "ok": ok, "detail": "ai stop" + ("" if hit else "（未确认）")})

        if start_imu:
            ser.write(b"imu start\n")
            ser.flush()
            hit, out = _read_until(ser, ("imu started",), 1.5, transcript)
            ok = hit
            if not ok:
                warnings.append("没有看到 imu started：固件可能没有 IMU 线程，或板子还在执行别的命令")
            steps.append(
                {
                    "id": "imu",
                    "label": "启动 IMU 遥测",
                    "ok": ok,
                    "detail": "imu start" if ok else "imu start（未确认）",
                }
            )
        else:
            steps.append({"id": "imu", "label": "启动 IMU 遥测", "ok": True, "detail": "本次跳过"})

        return {
            "ok": True,
            "steps": steps,
            "warnings": warnings,
            "transcript": transcript.decode("utf-8", "replace")[-4000:],
        }
    finally:
        try:
            ser.close()
        except Exception:  # noqa: BLE001
            pass


def send_board_command(port: str, baud: int, command: str, wait: float = 0.8) -> tuple[bool, str]:
    try:
        ser = open_serial(port, baud, retry_s=1.5)
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    try:
        ser.write((command + "\n").encode("ascii", "replace"))
        ser.flush()
        time.sleep(wait)
        try:
            data = ser.read(4096)
        except Exception:  # noqa: BLE001
            data = b""
        return True, data.decode("utf-8", "replace").strip()
    finally:
        try:
            ser.close()
        except Exception:  # noqa: BLE001
            pass


class ControllerProcess:
    """``xbox-controller`` 子进程：单实例、日志环形缓冲、可被 Web 停止。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._proc: Optional[subprocess.Popen] = None
        self._reader: Optional[threading.Thread] = None
        self._lines: deque[str] = deque(maxlen=1200)
        self._log: deque[str] = deque(maxlen=6000)
        self._meta: dict[str, Any] = {}
        self._started = 0.0

    def is_running(self) -> bool:
        with self._lock:
            return self._proc is not None and self._proc.poll() is None

    def start(
        self,
        root: Path,
        python: str,
        port: str,
        profile: Optional[str],
        dry_run: bool,
        baud: int,
    ) -> tuple[bool, str, Optional[list[str]]]:
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                return False, "xbox-controller 已经在运行", None

            cmd = build_controller_command(python, root, port, profile, dry_run, baud)
            env = os.environ.copy()
            env["PYTHONUNBUFFERED"] = "1"
            env.setdefault("PYTHONIOENCODING", "utf-8")
            flags = 0
            if os.name == "nt":
                flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(
                    subprocess, "CREATE_NEW_PROCESS_GROUP", 0
                )
            try:
                proc = subprocess.Popen(
                    cmd,
                    cwd=str(root),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    bufsize=1,
                    env=env,
                    creationflags=flags,
                )
            except Exception as exc:  # noqa: BLE001
                return False, f"启动 xbox-controller 失败：{exc}", cmd

            self._proc = proc
            self._started = time.time()
            self._meta = {
                "port": normalize_port(port),
                "profile": profile or "",
                "dry_run": bool(dry_run),
                "baud": int(baud),
                "command": cmd,
                "root": str(root),
                "python": python,
            }
            self._lines.clear()
            self._log.clear()
            self._log.append("[launch] " + " ".join(cmd))
            self._reader = threading.Thread(target=self._pump, args=(proc,), daemon=True)
            self._reader.start()
            return True, f"pid {proc.pid}", cmd

    def _pump(self, proc: subprocess.Popen) -> None:
        stream = proc.stdout
        if stream is not None:
            for raw in stream:
                line = raw.rstrip("\r\n")
                with self._lock:
                    self._lines.append(line)
                    self._log.append(line)
        code = proc.wait()
        if stream is not None:
            try:
                stream.close()
            except Exception:  # noqa: BLE001
                pass
        with self._lock:
            note = f"[xbox-controller 已退出，exit={code}]"
            self._lines.append(note)
            self._log.append(note)

    def status(self) -> dict:
        with self._lock:
            proc = self._proc
            running = proc is not None and proc.poll() is None
            code = None
            if proc is not None and not running:
                code = proc.poll()
            return {
                "running": running,
                "pid": proc.pid if proc is not None else None,
                "exit": code,
                "started": self._started or None,
                "uptime": round(time.time() - self._started, 1) if running else 0,
                "meta": dict(self._meta),
                "lines": list(self._lines)[-120:],
                "log": list(self._log)[-200:],
            }

    def stop(self, stop_imu: bool = True) -> dict:
        with self._lock:
            proc = self._proc
        if proc is None or proc.poll() is not None:
            return {"stopped": False, "detail": "xbox-controller 没有在运行"}

        meta = dict(self._meta)
        sent = False
        if stop_imu and proc.stdin is not None:
            try:
                proc.stdin.write("imu stop\n")
                proc.stdin.flush()
                sent = True
                time.sleep(0.25)
            except Exception:  # noqa: BLE001
                sent = False
        try:
            if proc.stdin is not None:
                try:
                    proc.stdin.close()
                except Exception:  # noqa: BLE001
                    pass
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                    capture_output=True, timeout=15,
                )
            else:
                proc.terminate()
            try:
                proc.wait(timeout=6)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
        except Exception as exc:  # noqa: BLE001
            return {"stopped": True, "detail": f"结束进程时出错：{exc}", "meta": meta, "sent_imu_stop": sent}
        return {"stopped": True, "detail": "xbox-controller 已停止", "meta": meta, "sent_imu_stop": sent}

    def stop_silent(self) -> None:
        try:
            self.stop(stop_imu=False)
        except Exception:  # noqa: BLE001
            pass


class _Settings:
    controller_root: Path = CONTROLLER_CANDIDATES[0]
    python: str = sys.executable
    kill_names: tuple[str, ...] = DEFAULT_KILL_NAMES
    host: str = "127.0.0.1"
    port: int = DEFAULT_PORT


SERVER = _Settings()
CONTROLLER = ControllerProcess()
atexit.register(CONTROLLER.stop_silent)


def controller_info() -> dict:
    root = SERVER.controller_root
    mods = python_modules(SERVER.python)
    return {
        "available": (Path(root) / "run.py").is_file(),
        "root": str(root),
        "python": SERVER.python,
        "serial": bool(mods.get("serial")),
        "yaml": bool(mods.get("yaml")),
        "vgamepad": bool(mods.get("vgamepad")),
        "profiles": list_profiles(Path(root)),
    }


def _resolve_controller_root(explicit: Optional[str]) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()
    for cand in CONTROLLER_CANDIDATES:
        if (cand / "run.py").is_file():
            return cand
    return CONTROLLER_CANDIDATES[0]


def _step(step_id: str, label: str, ok: bool, detail: str = "") -> dict:
    return {"id": step_id, "label": label, "ok": bool(ok), "detail": detail}


def _wait_port(port: str, attempts: int = 8, delay: float = 0.2) -> tuple[str, str]:
    """浏览器 ``port.close()`` 不是瞬时的：busy 时多等一会儿再判占用。"""

    status, err = probe_port(port)
    for _ in range(max(0, attempts)):
        if status != "busy":
            return status, err
        time.sleep(delay)
        status, err = probe_port(port)
    return status, err


def _release_port(port: str, *, kill_holders: bool, force_names: bool) -> tuple[bool, list[dict], list[dict], str]:
    """结束占口进程；返回 (端口是否已可打开, 步骤, 检测到的进程, 错误)。"""

    steps: list[dict] = []
    status, err = probe_port(port)
    if status == "open":
        steps.append(_step("holders", "扫描占口进程", True, "串口空闲，没有占口进程"))
        steps.append(_step("release", "释放串口", True, "不需要结束进程"))
        return True, steps, [], ""
    if status == "missing":
        steps.append(_step("release", "释放串口", False, "串口不存在：" + (err or port)))
        return False, steps, [], err or "串口不存在"
    if status == "error":
        steps.append(_step("release", "释放串口", False, "打开串口失败：" + (err or "unknown")))
        return False, steps, [], err or "打开串口失败"

    # status == "busy"：只在这个端口确实存在且被占用时才扫描/结束进程。
    try:
        holders = find_holders(port)
    except Exception as exc:  # noqa: BLE001
        holders = []
        steps.append(_step("holders", "扫描占口进程", False, f"扫描失败：{exc}"))
    else:
        strong = [h for h in holders if h["strong"]]
        weak = [h for h in holders if h["weak"]]
        detail = f"{len(strong)} 个明确占用 / {len(weak)} 个疑似串口程序"
        steps.append(_step("holders", "扫描占口进程", True, detail))

    if not holders:
        # 可能是另一个浏览器标签页刚 close()，给驱动一点时间。
        status, err = _wait_port(port)
        if status == "open":
            steps.append(_step("release", "释放串口", True, "端口已空闲（其它程序刚释放）"))
            return True, steps, holders, ""
        if status == "missing":
            steps.append(_step("release", "释放串口", False, "串口不存在：" + (err or port)))
            return False, steps, holders, err or "串口不存在"

    if not kill_holders:
        steps.append(_step("release", "释放串口", False, "串口被占用，但本次没有允许结束进程"))
        return False, steps, holders, err or "端口被占用"

    killed: list[str] = []
    candidates = [h for h in holders if h["strong"]] + (
        [h for h in holders if h["weak"]] if force_names else []
    )
    if not candidates:
        steps.append(
            _step(
                "release",
                "释放串口",
                False,
                "端口被占用，但没找到可识别的占口进程；请手动关闭串口助手/其它浏览器标签页",
            )
        )
        return False, steps, holders, err or "端口被占用"

    for h in candidates:
        ok, detail = kill_process(int(h["pid"]))
        tag = f"{h['name']}({h['pid']})"
        if ok:
            killed.append(tag)
            steps.append(_step("release", "释放串口", True, f"已结束 {tag}"))
        else:
            steps.append(_step("release", "释放串口", False, f"结束 {tag} 失败：{detail}"))
        time.sleep(0.35)
        status, err = probe_port(port)
        if status in ("open", "missing"):
            break

    if status == "busy":
        status, err = _wait_port(port)

    if status == "open":
        steps.append(
            _step("release", "释放串口", True, "已结束：" + "、".join(killed) if killed else "串口已空闲")
        )
        return True, steps, holders, ""
    if status == "missing":
        steps.append(_step("release", "释放串口", False, "串口在接管过程中消失（板子被拔掉/驱动重载）"))
        return False, steps, holders, err or "串口不存在"
    steps.append(_step("release", "释放串口", False, "结束进程后端口仍被占用：" + (err or "unknown")))
    return False, steps, holders, err or "端口仍被占用"


def takeover(body: dict) -> dict:
    port = normalize_port(body.get("port"))
    if not port:
        raise ValueError("缺少串口名（例如 COM9）")
    if not valid_port(port):
        raise ValueError(f"串口名不合法：{port}")
    baud = int(body.get("baud") or DEFAULT_BAUD)
    root = Path(SERVER.controller_root)
    if not (root / "run.py").is_file():
        raise ValueError(f"找不到 xbox-controller：{root}")
    profile = body.get("profile") or None
    dry_run = bool(body.get("dry_run"))
    kill_holders = bool(body.get("kill_holders", True))
    force_names = bool(body.get("force_names", True))
    exit_guard = bool(body.get("exit_guard", True))
    stop_ai = bool(body.get("stop_ai", True))
    start_imu = bool(body.get("start_imu", True))

    if not TAKEOVER_LOCK.acquire(blocking=False):
        raise RuntimeError("另一个接管请求还在执行")

    steps: list[dict] = []
    warnings: list[str] = []
    try:
        if CONTROLLER.is_running():
            stop_info = CONTROLLER.stop(stop_imu=False)
            steps.append(_step("previous", "停止旧 xbox-controller", True, stop_info.get("detail", "")))

        ok, release_steps, holders, release_err = _release_port(
            port, kill_holders=kill_holders, force_names=force_names
        )
        steps.extend(release_steps)
        if not ok:
            return {
                "ok": False,
                "port": port,
                "steps": steps,
                "holders": holders,
                "warnings": warnings,
                "error": release_err or "串口仍被占用",
                "status": imu_status(),
            }

        board = run_board_sequence(
            port, baud, exit_guard=exit_guard, stop_ai=stop_ai, start_imu=start_imu
        )
        steps.extend(board["steps"])
        warnings.extend(board["warnings"])
        if not board["ok"]:
            return {
                "ok": False,
                "port": port,
                "steps": steps,
                "holders": holders,
                "warnings": warnings,
                "error": "板子没有切到 IMU 遥测",
                "transcript": board.get("transcript", ""),
                "status": imu_status(),
            }

        started, detail, cmd = CONTROLLER.start(
            root=root,
            python=SERVER.python,
            port=port,
            profile=profile,
            dry_run=dry_run,
            baud=baud,
        )
        steps.append(_step("controller", "启动 xbox-controller", started, detail))
        if not started:
            return {
                "ok": False,
                "port": port,
                "steps": steps,
                "holders": holders,
                "warnings": warnings,
                "error": detail,
                "transcript": board.get("transcript", ""),
                "status": imu_status(),
            }
        if not dry_run:
            mods = python_modules(SERVER.python)
            if not mods.get("vgamepad"):
                warnings.append("这个 Python 里 import vgamepad 失败：虚拟手柄不会出现，先用 dry-run 验证链路")
        return {
            "ok": True,
            "port": port,
            "steps": steps,
            "holders": holders,
            "warnings": warnings,
            "transcript": board.get("transcript", ""),
            "command": cmd,
            "status": imu_status(),
        }
    finally:
        TAKEOVER_LOCK.release()


def imu_status() -> dict:
    status = CONTROLLER.status()
    status.update(
        {
            "ok": True,
            "controller": controller_info(),
            "ports": list_serial_ports() if _serial_available() else [],
            "server": {"host": SERVER.host, "port": SERVER.port, "root": str(ROOT)},
        }
    )
    return status


def _serial_available() -> bool:
    try:
        _serial_module()
        return True
    except RuntimeError:
        return False


def stop_imu(body: dict) -> dict:
    stop_imu_flag = bool(body.get("stop_imu", True))
    meta = dict(CONTROLLER.status().get("meta") or {})
    if not TAKEOVER_LOCK.acquire(blocking=False):
        raise RuntimeError("另一个接管请求还在执行")
    try:
        info = CONTROLLER.stop(stop_imu=stop_imu_flag)
        port = normalize_port(body.get("port") or meta.get("port") or "")
        baud = int(body.get("baud") or meta.get("baud") or DEFAULT_BAUD)
        steps = [_step("stop", "停止 xbox-controller", True, info.get("detail", ""))]
        warnings: list[str] = []
        if stop_imu_flag and port and valid_port(port):
            ok, detail = send_board_command(port, baud, "imu stop", wait=0.6)
            if ok:
                steps.append(_step("imu", "停止 IMU 遥测", True, detail[-160:] or "imu stop"))
            else:
                warnings.append("已经停止手柄，但没能再打开串口发 imu stop：" + detail)
        return {"ok": True, "steps": steps, "warnings": warnings, "status": imu_status()}
    finally:
        TAKEOVER_LOCK.release()


def release_only(body: dict) -> dict:
    port = normalize_port(body.get("port"))
    if not port:
        raise ValueError("缺少串口名（例如 COM9）")
    if not valid_port(port):
        raise ValueError(f"串口名不合法：{port}")
    kill_holders = bool(body.get("kill_holders", True))
    force_names = bool(body.get("force_names", True))
    if not TAKEOVER_LOCK.acquire(blocking=False):
        raise RuntimeError("另一个接管请求还在执行")
    try:
        steps: list[dict] = []
        if CONTROLLER.is_running():
            stop_info = CONTROLLER.stop(stop_imu=False)
            steps.append(_step("stop", "停止 xbox-controller", True, stop_info.get("detail", "")))
        ok, release_steps, holders, err = _release_port(
            port, kill_holders=kill_holders, force_names=force_names
        )
        steps.extend(release_steps)
        return {
            "ok": ok,
            "port": port,
            "steps": steps,
            "holders": holders,
            "error": "" if ok else (err or "串口仍被占用"),
        }
    finally:
        TAKEOVER_LOCK.release()


# --------------------------------------------------------------------------- flash


def list_bitstreams() -> list[dict]:
    items: list[dict] = []
    seen: set[str] = set()
    for base in (ROOT / "build", ROOT / "prj_tasks"):
        if not base.exists():
            continue
        for p in base.rglob("*.sbit"):
            try:
                rel = p.relative_to(ROOT).as_posix()
            except ValueError:
                continue
            if rel in seen:
                continue
            seen.add(rel)
            st = p.stat()
            items.append({"path": rel, "size": st.st_size, "mtime": st.st_mtime})
    # The PDS flow keeps a copy under build/ and prj_tasks/; show one entry per name,
    # preferring the stable build/ copy.
    best: dict[str, dict] = {}
    for item in items:
        name = Path(item["path"]).name
        prev = best.get(name)
        if prev is None or (item["path"].startswith("build/") and not prev["path"].startswith("build/")):
            best[name] = item
    items = list(best.values())
    items.sort(key=lambda x: x["mtime"], reverse=True)
    return items


def resolve_sbit(rel: str) -> Path:
    p = (ROOT / rel).resolve()
    if p.suffix.lower() != ".sbit":
        raise ValueError("not a .sbit file")
    try:
        parts = p.relative_to(ROOT.resolve()).parts
    except ValueError:
        raise ValueError("outside repository") from None
    if not parts or parts[0] not in ("build", "prj_tasks"):
        raise ValueError("only build/ and prj_tasks/ are allowed")
    if not p.is_file():
        raise ValueError("file not found")
    return p


# --------------------------------------------------------------------------- HTTP


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB), **kwargs)

    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        n = int(self.headers.get("content-length", "0") or 0)
        if n > 1_000_000:
            raise ValueError("request body too large")
        raw = self.rfile.read(n) if n else b"{}"
        data = json.loads(raw or b"{}")
        if not isinstance(data, dict):
            raise ValueError("JSON object expected")
        return data

    def _local_origin(self) -> bool:
        origin = self.headers.get("Origin")
        if not origin:
            return True
        try:
            host = urlparse(origin).hostname
        except ValueError:
            return False
        return host in (None, "127.0.0.1", "localhost", "::1")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/board/bitstreams":
            self._json(200, {"bitstreams": list_bitstreams()})
            return
        if path == "/api/board/ping":
            self._json(200, {"ok": True})
            return
        if path == "/api/serial/ports":
            try:
                ports = list_serial_ports()
                self._json(200, {"ok": True, "ports": ports, "controller": controller_info()})
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"ok": False, "error": str(exc), "ports": []})
            return
        if path == "/api/serial/holders":
            port = normalize_port((parse_qs(parsed.query).get("port") or [""])[0])
            if not port:
                self._json(400, {"ok": False, "error": "missing port"})
                return
            try:
                if CONTROLLER.is_running():
                    self._json(
                        200,
                        {
                            "ok": True,
                            "port": port,
                            "state": "controller",
                            "holders": [],
                            "openable": False,
                            "error": "xbox-controller 正在占用该串口",
                        },
                    )
                    return
                status, err = probe_port(port)
                holders = find_holders(port) if status == "busy" else []
                self._json(
                    200,
                    {
                        "ok": True,
                        "port": port,
                        "state": status,
                        "holders": holders,
                        "openable": status == "open",
                        "error": "" if status == "open" else err,
                    },
                )
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"ok": False, "error": str(exc)})
            return
        if path == "/api/imu/status":
            try:
                self._json(200, imu_status())
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"ok": False, "error": str(exc)})
            return
        super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._local_origin():
            self._json(403, {"ok": False, "error": "cross-origin request refused"})
            return
        if path == "/api/board/program":
            self._handle_program()
            return
        if path == "/api/imu/takeover":
            self._handle_action(takeover, "takeover")
            return
        if path == "/api/imu/stop":
            self._handle_action(stop_imu, "stop")
            return
        if path == "/api/serial/release":
            self._handle_action(release_only, "release")
            return
        self._json(404, {"ok": False, "error": "not found"})

    def _handle_action(self, func, label: str) -> None:
        try:
            body = self._body()
            result = func(body)
            self._json(200, result)
        except ValueError as exc:
            self._json(400, {"ok": False, "error": str(exc)})
        except RuntimeError as exc:
            self._json(409, {"ok": False, "error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"ok": False, "error": f"{label} failed: {exc}"})

    def _handle_program(self) -> None:
        try:
            req = self._body()
            rel = str(req.get("bitstream", ""))
            target = resolve_sbit(rel)
        except Exception as exc:  # noqa: BLE001
            self._json(400, {"ok": False, "error": str(exc)})
            return

        if not FLASH_LOCK.acquire(blocking=False):
            self._json(409, {"ok": False, "error": "another programming request is running"})
            return
        try:
            started = time.time()
            try:
                proc = subprocess.run(
                    [
                        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(PROGRAM), "-Bitstream", str(target),
                    ],
                    capture_output=True,
                    timeout=180,
                )
                log = (proc.stdout or b"").decode("utf-8", "replace") + (proc.stderr or b"").decode("utf-8", "replace")
                ok = proc.returncode == 0 and "PROGRAM OK" in log
                result = {
                    "ok": ok,
                    "exit": proc.returncode,
                    "bitstream": target.relative_to(ROOT).as_posix(),
                    "seconds": round(time.time() - started, 1),
                    "log": log[-30000:],
                }
            except subprocess.TimeoutExpired:
                result = {"ok": False, "error": "programming timed out after 180 s"}
            except FileNotFoundError:
                result = {"ok": False, "error": "powershell.exe not found"}
            self._json(200, result)
        finally:
            FLASH_LOCK.release()


def _parse_kill_names(text: str) -> tuple[str, ...]:
    items = tuple(x.strip() for x in (text or "").split(",") if x.strip())
    return items or DEFAULT_KILL_NAMES


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="ARES guard web + board programming + IMU takeover service")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--open-browser", action="store_true")
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--controller-root", help="xbox-controller 目录（默认 app/imu/xbox-controller）")
    ap.add_argument("--python", default=sys.executable, help="运行 xbox-controller 的 Python")
    ap.add_argument(
        "--kill-names",
        default=",".join(DEFAULT_KILL_NAMES),
        help="以逗号分隔的进程名前缀；只用于“疑似占口程序”",
    )
    args = ap.parse_args(argv)

    SERVER.host = args.host
    SERVER.port = args.port
    SERVER.controller_root = _resolve_controller_root(args.controller_root)
    SERVER.python = args.python or sys.executable
    SERVER.kill_names = _parse_kill_names(args.kill_names)

    try:
        httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as exc:
        print(f"无法绑定 {args.host}:{args.port}: {exc}", file=sys.stderr)
        print("换一个 --port，或先关掉占用该端口的程序。", file=sys.stderr)
        return 1
    url = f"http://{args.host}:{args.port}"
    print(f"ARES board server: {url}")
    print(f"  static:     {WEB}")
    print(f"  programmer: {PROGRAM}")
    print(f"  controller: {SERVER.controller_root}")
    print(f"  python:     {SERVER.python}")
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print("  warning:    非 loopback 监听会暴露“结束进程/接管串口”接口，仅限可信网络")
    if not (SERVER.controller_root / "run.py").is_file():
        print("  warning:    xbox-controller/run.py 不存在，IMU 接管会失败")
    mods = python_modules(SERVER.python)
    if not mods.get("serial"):
        print("  warning:    Python 缺 pyserial：py -3.11 -m pip install pyserial")
    if not mods.get("yaml"):
        print("  warning:    Python 缺 PyYAML：py -3.11 -m pip install pyyaml")
    if not mods.get("vgamepad"):
        print("  note:       Python 缺 vgamepad：IMU 页先勾 dry-run，或装 ViGEmBus")
    print("  Ctrl-C to stop")
    if args.open_browser and not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        httpd.server_close()
        CONTROLLER.stop_silent()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
