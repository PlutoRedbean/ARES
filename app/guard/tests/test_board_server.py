"""board_server 的 IMU 接管逻辑单测（不碰真串口、不杀真进程）。"""

from __future__ import annotations

import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tools import board_server as bs  # noqa: E402


def proc(pid: int, name: str, cmd: str = "", ppid: int = 1) -> dict:
    return {"ProcessId": pid, "ParentProcessId": ppid, "Name": name, "CommandLine": cmd}


class TestProcessMatching(unittest.TestCase):
    def test_strong_and_weak(self) -> None:
        procs = [
            proc(100, "putty.exe", "putty.exe -serial COM9"),
            proc(101, "python.exe", "python tools/serial_host.py -p COM9"),
            proc(102, "python.exe", "python custom.py --port COM9"),
            proc(103, "sscom5.13.1.exe", r'"C:\sscom.exe"'),
            proc(104, "rtthread guard.exe", "rtthread guard.exe"),
        ]
        found = {p["pid"]: p for p in bs.match_holders(procs, "COM9")}
        self.assertTrue(found[100]["strong"])
        self.assertTrue(found[101]["strong"])
        self.assertTrue(found[102]["strong"])
        self.assertTrue(found[103]["weak"])
        self.assertTrue(found[104]["weak"])

    def test_never_kills_browsers_shells_or_chat_windows(self) -> None:
        procs = [
            proc(200, "chrome.exe", "chrome.exe COM9 serial"),
            proc(201, "Explorer.EXE", "explorer.exe"),
            proc(202, "DeepSeek Harness.exe", "deepseek harness COM9 serial"),
            proc(203, "XboxPcAppFT.exe", "XboxPcAppFT.exe COM9"),
            proc(204, "chat.exe", 'chat.exe "my COM9 is broken"'),
            proc(205, "notepad.exe", r"notepad.exe C:\notes\COM9.txt"),
        ]
        self.assertEqual(bs.match_holders(procs, "COM9"), [])

    def test_port_boundary(self) -> None:
        self.assertTrue(bs.port_in_cmdline("putty -serial COM9", "COM9"))
        self.assertFalse(bs.port_in_cmdline("putty -serial COM90", "COM9"))
        self.assertFalse(bs.port_in_cmdline("putty -serial COM9X", "COM9"))

    def test_exclude_ancestors(self) -> None:
        procs = [
            proc(300, "DeepSeek Harness.exe", "deepseek harness COM9 serial", ppid=1),
            proc(301, "python.exe", "python tools/board_server.py", ppid=300),
        ]
        ancestors = bs.ancestor_pids(procs, 301)
        self.assertEqual(ancestors, {300})
        self.assertEqual(bs.match_holders(procs, "COM9", exclude_pids=ancestors), [])

    def test_ancestor_walk(self) -> None:
        procs = [
            proc(10, "a", ppid=0),
            proc(11, "b", ppid=10),
            proc(12, "c", ppid=11),
        ]
        self.assertEqual(bs.ancestor_pids(procs, 12), {11, 10})


class TestCommandBuild(unittest.TestCase):
    def test_normalize_and_validate(self) -> None:
        self.assertEqual(bs.normalize_port(r"\\.\COM9"), "COM9")
        self.assertTrue(bs.valid_port("COM9"))
        self.assertTrue(bs.valid_port("/dev/ttyUSB0"))
        self.assertFalse(bs.valid_port("COM9 & del"))
        self.assertFalse(bs.valid_port(""))

    def test_controller_command(self) -> None:
        root = Path(r"D:\code\ARES\app\imu\xbox-controller")
        cmd = bs.build_controller_command(
            "py", root, "COM9", "profiles/imu_telemetry.yaml", dry_run=True, baud=115200
        )
        self.assertEqual(cmd[0], "py")
        self.assertIn("--imu-port", cmd)
        self.assertIn("COM9", cmd)
        self.assertIn("--imu-profile", cmd)
        self.assertIn("--dry-run", cmd)
        self.assertIn("--stdin-cmd", cmd)
        self.assertNotIn("--baudrate", cmd)
        self.assertTrue(cmd[2].endswith("run.py"))


class TestReleasePort(unittest.TestCase):
    def test_missing_port_does_nothing(self) -> None:
        with mock.patch.object(bs, "probe_port", return_value=("missing", "not found")) as probe, \
                mock.patch.object(bs, "kill_process") as kill:
            ok, steps, holders, err = bs._release_port(
                "COM9", kill_holders=True, force_names=True
            )
        self.assertFalse(ok)
        self.assertIn("不存在", steps[-1]["detail"])
        kill.assert_not_called()
        self.assertEqual(probe.call_count, 1)

    def test_busy_strong_holder_killed(self) -> None:
        holders = [
            {
                "pid": 4242,
                "name": "putty.exe",
                "cmdline": "putty -serial COM9",
                "strong": True,
                "weak": False,
                "reason": "命令行包含 COM9",
            }
        ]
        with mock.patch.object(bs, "probe_port", side_effect=[("busy", "denied"), ("open", "")]), \
                mock.patch.object(bs, "find_holders", return_value=holders), \
                mock.patch.object(bs, "kill_process", return_value=(True, "ok")) as kill:
            ok, steps, found, err = bs._release_port(
                "COM9", kill_holders=True, force_names=True
            )
        self.assertTrue(ok)
        kill.assert_called_once_with(4242)
        self.assertTrue(any("已结束" in s["detail"] for s in steps))

    def test_busy_without_kill_permission(self) -> None:
        with mock.patch.object(bs, "probe_port", return_value=("busy", "denied")), \
                mock.patch.object(bs, "_wait_port", return_value=("busy", "denied")), \
                mock.patch.object(bs, "find_holders", return_value=[]), \
                mock.patch.object(bs, "kill_process") as kill:
            ok, steps, _, _ = bs._release_port(
                "COM9", kill_holders=False, force_names=True
            )
        self.assertFalse(ok)
        kill.assert_not_called()


class TestBoardSequence(unittest.TestCase):
    class FakeSerial:
        def __init__(self, responses: dict[bytes, bytes]) -> None:
            self.responses = responses
            self.writes: list[bytes] = []
            self.buf = b""

        def write(self, data: bytes) -> None:
            self.writes.append(data)
            self.buf += self.responses.get(data, b"")

        def flush(self) -> None:
            pass

        def read(self, _n: int) -> bytes:
            out, self.buf = self.buf, b""
            return out

        def close(self) -> None:
            pass

    def test_guard_session_to_imu(self) -> None:
        serial = self.FakeSerial(
            {
                b"\n": b"[guard] n=001 id18=000 mode=1\r\n",
                b"\x1d": b"GUARD EXIT\r\nmsh > ",
                b"ai stop\n": b"ai stopped\r\nmsh > ",
                b"imu start\n": b"imu started\r\nD 0000\r\n",
            }
        )
        with mock.patch.object(bs, "open_serial", return_value=serial):
            result = bs.run_board_sequence("COM9", 115200)
        self.assertTrue(result["ok"])
        ids = {s["id"]: s for s in result["steps"]}
        self.assertTrue(ids["guard"]["ok"])
        self.assertTrue(ids["ai"]["ok"])
        self.assertTrue(ids["imu"]["ok"])
        self.assertIn(b"\x1d", serial.writes)
        self.assertIn(b"imu start\n", serial.writes)

    def test_msh_skips_guard_exit(self) -> None:
        serial = self.FakeSerial(
            {
                b"\n": b"msh > ",
                b"ai stop\n": b"msh > ",
                b"imu start\n": b"imu started\r\n",
            }
        )
        with mock.patch.object(bs, "open_serial", return_value=serial):
            result = bs.run_board_sequence("COM9", 115200)
        self.assertTrue(result["ok"])
        self.assertNotIn(b"\x1d", serial.writes)
        guard = [s for s in result["steps"] if s["id"] == "guard"][0]
        self.assertIn("跳过", guard["detail"])


class TestTakeoverFlow(unittest.TestCase):
    def tearDown(self) -> None:
        try:
            bs.CONTROLLER.stop(stop_imu=False)
        except Exception:  # noqa: BLE001
            pass

    def test_rejects_empty_port(self) -> None:
        with self.assertRaises(ValueError):
            bs.takeover({"port": "  "})

    def test_success_builds_step_chain(self) -> None:
        release = [
            {"id": "holders", "label": "扫描占口进程", "ok": True, "detail": "1 个"},
            {"id": "release", "label": "释放串口", "ok": True, "detail": "已结束 putty(1)"},
        ]
        board = {
            "ok": True,
            "steps": [
                {"id": "guard", "label": "退出 Guard 会话", "ok": True, "detail": "MSH"},
                {"id": "ai", "label": "停止 AI", "ok": True, "detail": "ai stop"},
                {"id": "imu", "label": "启动 IMU", "ok": True, "detail": "imu start"},
            ],
            "warnings": [],
            "transcript": "msh >",
        }
        with mock.patch.object(bs, "_release_port", return_value=(True, release, [], "")), \
                mock.patch.object(bs, "run_board_sequence", return_value=board), \
                mock.patch.object(bs, "imu_status", return_value={"ok": True}), \
                mock.patch.object(bs.CONTROLLER, "is_running", return_value=False), \
                mock.patch.object(bs.CONTROLLER, "start", return_value=(True, "pid 99", ["py"])):
            result = bs.takeover({"port": "COM9", "dry_run": True})
        self.assertTrue(result["ok"])
        ids = [s["id"] for s in result["steps"]]
        self.assertIn("controller", ids)
        self.assertIn("guard", ids)
        self.assertEqual(result["command"], ["py"])

    def test_failed_release_stops_before_board(self) -> None:
        with mock.patch.object(
            bs, "_release_port", return_value=(False, [{"id": "release", "ok": False, "detail": "busy"}], [], "busy")
        ), mock.patch.object(bs, "run_board_sequence") as board, \
                mock.patch.object(bs, "imu_status", return_value={"ok": True}):
            result = bs.takeover({"port": "COM9"})
        self.assertFalse(result["ok"])
        board.assert_not_called()


class TestControllerProcess(unittest.TestCase):
    def test_start_status_stop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "run.py").write_text(
                "import time\nprint('fake-ready', flush=True)\ntime.sleep(30)\n",
                encoding="utf-8",
            )
            proc = bs.ControllerProcess()
            started, detail, cmd = proc.start(
                root=root,
                python=sys.executable,
                port="COM9",
                profile=None,
                dry_run=True,
                baud=115200,
            )
            self.assertTrue(started, detail)
            deadline = time.time() + 8
            while time.time() < deadline:
                status = proc.status()
                if any("fake-ready" in line for line in status["log"]):
                    break
                time.sleep(0.1)
            self.assertTrue(proc.is_running())
            self.assertIn("fake-ready", "\n".join(proc.status()["log"]))
            proc.stop(stop_imu=False)
            time.sleep(0.3)
            self.assertFalse(proc.is_running())


class TestHttpApi(unittest.TestCase):
    class FakeSerial:
        responses = {
            b"\n": b"msh > ",
            b"ai stop\n": b"msh > ",
            b"imu start\n": b"imu started\r\n",
        }

        def __init__(self) -> None:
            self.buf = b""

        def write(self, data: bytes) -> None:
            self.buf += self.responses.get(data, b"")

        def flush(self) -> None:
            pass

        def read(self, _n: int) -> bytes:
            out, self.buf = self.buf, b""
            return out

        def close(self) -> None:
            pass

    def setUp(self) -> None:
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), bs.Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        try:
            bs.CONTROLLER.stop(stop_imu=False)
        except Exception:  # noqa: BLE001
            pass

    def _post(self, path: str, payload: dict) -> dict:
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=json.dumps(payload).encode(),
            headers={"content-type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)

    def test_takeover_endpoint(self) -> None:
        with mock.patch.object(bs, "probe_port", return_value=("open", "")), \
                mock.patch.object(bs, "open_serial", return_value=self.FakeSerial()), \
                mock.patch.object(bs.CONTROLLER, "is_running", return_value=False), \
                mock.patch.object(bs.CONTROLLER, "start", return_value=(True, "pid 77", ["py"])), \
                mock.patch.object(bs, "imu_status", return_value={"ok": True, "running": True}):
            result = self._post("/api/imu/takeover", {"port": "COM9", "dry_run": True})
        self.assertTrue(result["ok"])
        self.assertIn("controller", [s["id"] for s in result["steps"]])

    def test_missing_port_returns_error(self) -> None:
        with mock.patch.object(bs, "probe_port", return_value=("missing", "not found")), \
                mock.patch.object(bs, "imu_status", return_value={"ok": True}):
            result = self._post("/api/imu/takeover", {"port": "COM9"})
        self.assertFalse(result["ok"])
        self.assertIn("串口不存在", result["steps"][-1]["detail"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
