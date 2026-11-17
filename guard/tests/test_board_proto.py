"""板级协议（board_proto）的单测：摘要行格式、期望流、回读门槛。

这些是 `make board-sim` 和 `tools/serial_host.py --check` 的共同基准，
所以必须在 PC 上就能测，不需要板子。
"""

from __future__ import annotations

import unittest

from host.golden.board_proto import (
    BOARD_FIELDS,
    expected_stream,
    expand_lf,
    output_thresholds,
    parse_report,
    report_line,
    split_frames,
    split_stream,
    type_counts,
)
from host.golden.redact import redact


class TestReportLine(unittest.TestCase):
    def test_empty(self) -> None:
        line = report_line({})
        self.assertTrue(line.startswith(b"[guard] n=000 "))
        self.assertIn(b"ovf=000", line)
        self.assertIn(b"kw=000", line)
        self.assertIn(b"kwm=000", line)
        self.assertTrue(line.endswith(b"mode=1"))
        # n + 8 个类型 + kw + kwm + ovf + mode
        self.assertEqual(line.count(b"="), 1 + len(BOARD_FIELDS) + 4)

    def test_counts_and_clamp(self) -> None:
        line = report_line({3: 2, 1: 1, 5: 300})
        self.assertIn(b"n=255", line)                 # 总数同样截到 255
        self.assertIn(b"mobile=002", line)
        self.assertIn(b"id18=001", line)
        self.assertIn(b"email=255", line)          # 8 位计数器上限

    def test_err_flag(self) -> None:
        self.assertIn(b"ovf=001", report_line({}, err=1))

    def test_parse_roundtrip(self) -> None:
        line = report_line({1: 1, 4: 2}, kw=5, kwm=0x24, mode=1)
        got = parse_report(line)
        self.assertIsNotNone(got)
        assert got is not None
        self.assertEqual(got["n"], 3)
        self.assertEqual(got["id18"], 1)
        self.assertEqual(got["bank"], 2)
        self.assertEqual(got["kw"], 5)
        self.assertEqual(got["kwm"], 36)
        self.assertEqual(got["ovf"], 0)
        self.assertEqual(got["mode"], 1)

    def test_kw_stats(self) -> None:
        from host.golden.board_proto import kw_stats

        self.assertEqual(kw_stats(b"no keyword here"), (0, 0))
        kw, kwm = kw_stats("身份证 手机号 邮箱".encode())
        self.assertEqual(kw, 3)
        self.assertEqual(kwm, (1 << 0) | (1 << 2) | (1 << 3))

    def test_parse_rejects_other_lines(self) -> None:
        self.assertIsNone(parse_report(b"hello world"))
        self.assertIsNone(parse_report(b"[guard] n=001 broken"))


class TestFrames(unittest.TestCase):
    def test_split_frames(self) -> None:
        self.assertEqual(split_frames(b"a\nb\n"), [b"a\n", b"b\n"])
        self.assertEqual(split_frames(b"a\nb"), [b"a\n", b"b"])
        self.assertEqual(split_frames(b""), [])

    def test_expand_lf(self) -> None:
        self.assertEqual(expand_lf(b"a\nb"), b"a\r\nb")


class TestExpectedStream(unittest.TestCase):
    def test_mask_and_report(self) -> None:
        data = "手机 13800138000\n".encode()
        out = expected_stream(data)
        red, audits = redact(data, policy="mask")
        self.assertTrue(out.startswith(expand_lf(red)))
        self.assertIn(b"mobile=001", out)
        self.assertEqual(len(audits), 1)
        self.assertTrue(out.endswith(b"\r\n"))

    def test_report_is_prefixed_when_no_lf(self) -> None:
        out = expected_stream("手机 13800138000".encode())
        # 没有换行结尾：正文后面要补 CRLF 再接摘要
        self.assertIn(b"*******8000\r\n[guard] ", out)

    def test_no_double_cr(self) -> None:
        out = expected_stream(b"a\n")
        self.assertNotIn(b"\r\r", out)

    def test_clean_passthrough(self) -> None:
        data = "下周二的评审在 3 楼。\n".encode()
        out = expected_stream(data)
        text, reports = split_stream(out)
        self.assertEqual(text, expand_lf(data))
        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0]["n"], 0)

    def test_split_stream_roundtrip(self) -> None:
        data = "邮箱 a@b.co\n手机 13800138000\n".encode()
        out = expected_stream(data)
        text, reports = split_stream(out)
        self.assertEqual(len(reports), 2)
        self.assertEqual(reports[0]["email"], 1)
        self.assertEqual(reports[1]["mobile"], 1)
        self.assertEqual(text.count(b"[guard]"), 0)
        self.assertIn(b"a@b.co", text.replace(b"**b.co", b"a@b.co"))

    def test_type_counts(self) -> None:
        _, audits = redact(b"a@b.co 13800138000", policy="mask")
        c = type_counts(audits)
        self.assertEqual(c.get(5), 1)
        self.assertEqual(c.get(3), 1)


class TestThresholds(unittest.TestCase):
    def test_monotonic_and_bounded(self) -> None:
        data = ("联系人 13800138000\n" * 4).encode()
        gates = output_thresholds(data)
        self.assertEqual(len(gates), len(data) + 1)
        self.assertEqual(gates[0], 0)
        expect = len(expected_stream(data))
        for i in range(1, len(gates)):
            self.assertGreaterEqual(gates[i], gates[i - 1])
            self.assertLess(gates[i], expect + 1)

    def test_first_frame_can_start(self) -> None:
        # 前 66 字节以内还没回声，门槛必须是 0，否则上位机会等不到回读
        gates = output_thresholds(b"x" * 200 + b"\n")
        self.assertTrue(all(g == 0 for g in gates[:66]))


if __name__ == "__main__":
    unittest.main()