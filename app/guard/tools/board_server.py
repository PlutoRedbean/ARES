#!/usr/bin/env python3
"""Local board service for guard/web: static files + JTAG programming.

The browser cannot run cdt_cfg itself, so this tiny local server exposes
/api/board/bitstreams and /api/board/program.  It binds to 127.0.0.1 only and
only accepts .sbit files under build/ or prj_tasks/.

    python app/guard/tools/board_server.py --port 8788
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WEB = Path(__file__).resolve().parents[1] / "web"
PROGRAM = Path(__file__).resolve().with_name("program_guard.ps1")
FLASH_LOCK = threading.Lock()


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

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/board/bitstreams":
            self._json(200, {"bitstreams": list_bitstreams()})
            return
        if path == "/api/board/ping":
            self._json(200, {"ok": True})
            return
        super().do_GET()

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/api/board/program":
            self._json(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("content-length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
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


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="ARES guard web + board programming service")
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args(argv)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"ARES board server: http://{args.host}:{args.port}")
    print(f"  static: {WEB}")
    print(f"  programmer: {PROGRAM}")
    print("  Ctrl-C to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
