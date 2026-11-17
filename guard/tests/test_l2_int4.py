"""L2 INT4 语义层金标测试（分类结果 + GEMM 与 RTL 同源）。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.l2_int4 import (  # noqa: E402
    CLASS_NAMES,
    classify,
    features_from_hits,
    int4,
    semantic_scan,
    W_INT4,
)


class TestL2Golden(unittest.TestCase):
    def test_weights_are_int4(self) -> None:
        for row in W_INT4:
            self.assertEqual(len(row), 8)
            for w in row:
                self.assertEqual(int4(w), w)

    def test_keyword_maps_to_class(self) -> None:
        cases = {
            "身份证 330203300422240391": "id18",
            "银行卡 6222020000000000001": "bank",
            "手机号 13800138000": "mobile",
        }
        for text, want in cases.items():
            rows = semantic_scan(text.encode())
            self.assertEqual(len(rows), 1, text)
            self.assertEqual(CLASS_NAMES[rows[0][2]], want, text)

    def test_no_keyword_is_none(self) -> None:
        rows = semantic_scan("号码 330203300422240391".encode())
        self.assertEqual(CLASS_NAMES[rows[0][2]], "none")

    def test_far_keyword_is_none(self) -> None:
        rows = semantic_scan("身份证".encode() + b" " * 30 + b"330203300422240391")
        self.assertEqual(CLASS_NAMES[rows[0][2]], "none")

    def test_short_runs_are_not_promoted_by_context(self) -> None:
        # 4 位数不可能是一个 PII：关键词再近也判 none（与 L1 兜底的 11..19 位一致）
        rows = semantic_scan("身份证 1234".encode())
        self.assertEqual(CLASS_NAMES[rows[0][2]], "none")

    def test_grouped_mobile_still_typed(self) -> None:
        rows = semantic_scan("手机号 138 0013 8000".encode())
        self.assertTrue(rows)
        self.assertTrue(all(CLASS_NAMES[r[2]] in ("mobile", "none") for r in rows))

    def test_features_of_no_hits(self) -> None:
        f = features_from_hits([], 10, 18, 0x20)
        self.assertEqual(f, [0, 0, 0, 0, 3, 1, 0, 1])
        cls, _ = classify(f)
        self.assertEqual(cls, 0)


if __name__ == "__main__":
    unittest.main()