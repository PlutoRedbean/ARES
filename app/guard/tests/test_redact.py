"""红action / 关键词 单测（stdlib unittest）。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.keywords import KEYWORDS, find_keywords  # noqa: E402
from host.golden.pii_rules import (  # noqa: E402
    TYPE_BANK,
    TYPE_EMAIL,
    TYPE_MOBILE,
    Span,
    scan,
)
from host.golden.redact import RULE_IDS, audit_json, merge, redact  # noqa: E402


class TestMerge(unittest.TestCase):
    def test_email_beats_inner_ipv4(self):
        spans = scan(b"1.2.3.4@x.com")
        self.assertEqual(sorted(s.type for s in spans), [TYPE_EMAIL, 6])
        merged = merge(spans)
        self.assertEqual([s.type for s in merged], [TYPE_EMAIL])

    def test_identical_start_priority(self):
        # 手工构造：同起点、邮箱优先级高于 IPv4
        spans = [Span(6, 0, 13), Span(5, 0, 13)]
        self.assertEqual([s.type for s in merge(spans)], [5])

    def test_non_overlapping_preserved(self):
        spans = scan(b"13800138000,4111111111111111")
        self.assertEqual([s.type for s in merge(spans)], [TYPE_MOBILE, TYPE_BANK])


class TestRedact(unittest.TestCase):
    def test_token_numbering_per_type(self):
        out, audits = redact(b"13800138000,13800138001")
        self.assertIn(b"[MOBILE_1]", out)
        self.assertIn(b"[MOBILE_2]", out)
        self.assertEqual([a.index for a in audits], [1, 2])
        self.assertEqual([a.type for a in audits], ["mobile", "mobile"])

    def test_mask_keeps_last_four(self):
        out, audits = redact(b"4111111111111111", policy="mask")
        self.assertEqual(out, b"************1111")
        self.assertEqual(audits[0].action, "mask")
        self.assertEqual(audits[0].replacement, "************1111")

    def test_redacted_has_no_more_hits(self):
        text = "手机 13800138000，邮箱 a@b.co，卡 4111111111111111".encode()
        out, _ = redact(text)
        self.assertEqual(scan(out), [])

    def test_audit_rule_ids_and_offsets(self):
        data = b"x,13800138000,y"
        out, audits = redact(data)
        self.assertEqual(len(audits), 1)
        a = audits[0]
        self.assertEqual((a.start, a.length), (2, 11))
        self.assertEqual(a.rule, RULE_IDS[3])
        self.assertEqual(out, b"x,[MOBILE_1],y")

    def test_unknown_policy(self):
        with self.assertRaises(ValueError):
            redact(b"123", policy="nope")

    def test_audit_json_is_valid_json(self):
        import json

        _, audits = redact(b"13800138000")
        parsed = json.loads(audit_json(audits))
        self.assertEqual(parsed[0]["type"], "mobile")
        self.assertEqual(parsed[0]["rule"], "prefix.mobile")


class TestKeywords(unittest.TestCase):
    def test_basic(self):
        data = "请提供身份证和银行卡".encode()
        hits = find_keywords(data)
        kids = {h.kid for h in hits}
        self.assertEqual(kids, {KEYWORDS.index("身份证"), KEYWORDS.index("银行卡")})
        first = [h for h in hits if h.kid == KEYWORDS.index("身份证")][0]
        self.assertEqual(first.start, len("请提供".encode()))
        self.assertEqual(first.length, 9)

    def test_all_keywords_present(self):
        data = "".join(KEYWORDS).encode()
        hits = find_keywords(data)
        self.assertEqual(sorted(h.kid for h in hits), list(range(len(KEYWORDS))))

    def test_no_false_positive(self):
        self.assertEqual(find_keywords(b"nothing here"), [])

    def test_at_most_one_per_position(self):
        data = "身份证".encode()
        self.assertEqual(len(find_keywords(data)), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
