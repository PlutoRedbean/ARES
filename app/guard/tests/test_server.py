"""本地工作台（http.server）的冒烟测试：起线程、打 API、验返回。"""

from __future__ import annotations

import json
import sys
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.pipeline import RED_BIN  # noqa: E402
from tools.guard_server import Handler  # noqa: E402


@unittest.skipUnless(RED_BIN.exists(), "Vredact 未构建（make redact-harness）")
class TestWorkbench(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def _post(self, payload: dict) -> dict:
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/redact",
            data=json.dumps(payload).encode(),
            headers={"content-type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp)

    def test_page(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/", timeout=5) as resp:
            body = resp.read()
        self.assertEqual(resp.status, 200)
        self.assertIn(b"guard", body)

    def test_api_mask_full_rtl(self):
        j = self._post({"text": "联系 13800138000，身份证 11010519491231002X", "policy": "mask"})
        self.assertEqual(j["mode"], "rtl-mask")
        self.assertIn("*******8000", j["redacted"])
        self.assertIn("002X", j["redacted"])
        self.assertEqual(len(j["audits"]), 2)
        self.assertIn("<mark", j["html"])
        self.assertGreater(j["ms"], 0)

    def test_api_token_mode(self):
        j = self._post({"text": "手机 13800138000", "policy": "token"})
        self.assertEqual(j["mode"], "golden-token")
        self.assertIn("[MOBILE_1]", j["redacted"])

    def test_api_clean_text(self):
        j = self._post({"text": "下周二的评审改到 15:30", "policy": "mask"})
        self.assertEqual(j["audits"], [])
        self.assertEqual(j["redacted"], "下周二的评审改到 15:30")


if __name__ == "__main__":
    unittest.main(verbosity=2)
