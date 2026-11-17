"""帧结束字符（TERM_CHAR / TERM_KEEP）的模型测试。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.board_proto import (  # noqa: E402
    expected_stream,
    frames_with_spans,
    output_thresholds,
    split_frames,
)

CTRL_D = 0x04


class TestTerminator(unittest.TestCase):
    def test_lf_frames_unchanged(self) -> None:
        data = b"abc\ndef\n"
        self.assertEqual(split_frames(data), [b"abc\n", b"def\n"])

    def test_ctrl_d_ends_frame_and_is_swallowed(self) -> None:
        data = b"abc" + bytes([CTRL_D]) + b"def" + bytes([CTRL_D])
        self.assertEqual(split_frames(data, term=CTRL_D, keep=False), [b"abc", b"def"])
        #  eaten 字节数要把结束字符算进去（pace 门槛按输入下标对齐）
        self.assertEqual(frames_with_spans(data, term=CTRL_D, keep=False),
                         [(b"abc", 4), (b"def", 4)])

    def test_ctrl_d_kept_when_asked(self) -> None:
        data = b"abc" + bytes([CTRL_D])
        self.assertEqual(split_frames(data, term=CTRL_D, keep=True),
                         [b"abc" + bytes([CTRL_D])])

    def test_lf_still_ends_frames_in_ctrl_d_mode(self) -> None:
        data = b"abc\n" + bytes([CTRL_D])
        self.assertEqual(split_frames(data, term=CTRL_D, keep=False), [b"abc\n", b""])

    def test_stream_and_gates_cover_every_input_byte(self) -> None:
        data = b"abc" + bytes([CTRL_D]) + b"def" + bytes([CTRL_D])
        self.assertEqual(len(output_thresholds(data, term=CTRL_D, keep=False)), len(data) + 1)
        # 两帧 → 两行摘要；正文只有 abc / def（结束字符没进正文）
        out = expected_stream(data, term=CTRL_D, keep=False)
        self.assertEqual(out.count(b"[guard] "), 2)
        self.assertNotIn(bytes([CTRL_D]), out)

    def test_first_gate_is_zero_with_ctrl_d(self) -> None:
        data = b"abc" + bytes([CTRL_D])
        self.assertEqual(output_thresholds(data, term=CTRL_D, keep=False)[0], 0)


if __name__ == "__main__":
    unittest.main()
