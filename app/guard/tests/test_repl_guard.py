"""交互模式的 shell 误输入识别（用户把 shell 命令打进 repl 是真实发生过的）。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.serial_host import _looks_like_shell  # noqa: E402


class TestShellGuard(unittest.TestCase):
    def test_shell_commands_detected(self) -> None:
        for line in ("python tools\\serial_host.py -p COM9",
                     "powershell -ExecutionPolicy Bypass -File x.ps1",
                     "cd guard", "git status", "make test", "wsl -e bash",
                     ".\\tools\\program_guard.ps1", "--repl"):
            self.assertTrue(_looks_like_shell(line), line)

    def test_plain_text_passes(self) -> None:
        for line in ("手机 13800138000", "身份证 330203300422240391",
                     "hello, cd is fine inside a sentence", "pythonista"):
            self.assertFalse(_looks_like_shell(line), line)


if __name__ == "__main__":
    unittest.main()
