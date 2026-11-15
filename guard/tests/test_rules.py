"""L1 金标规则单元测试（stdlib unittest，无第三方依赖）。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.corpus.synth import build_case, make_id18  # noqa: E402
from host.golden.pii_rules import (  # noqa: E402
    TYPE_BANK,
    TYPE_EMAIL,
    TYPE_ID15,
    TYPE_ID18,
    TYPE_IPV4,
    TYPE_MOBILE,
    TYPE_PLATE,
    TYPE_USCC,
    id18_check_digit,
    scan,
)
import random  # noqa: E402


def b(s: str) -> bytes:
    return s.encode("utf-8")


class TestChecksums(unittest.TestCase):
    def test_id18_check_digit(self):
        # 国标示例：11010519491231002X
        self.assertEqual(id18_check_digit("11010519491231002"), "X")
        self.assertEqual(id18_check_digit("11010519491231002") + "", "X")

    def test_id18_valid_hit(self):
        spans = scan(b("11010519491231002X"))
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_ID18, 0, 18)])

    def test_id18_lowercase_x(self):
        spans = scan(b("11010519491231002x"))
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_ID18, 0, 18)])

    def test_id18_bad_check(self):
        spans = scan(b("110105194912310021"))
        self.assertFalse([s for s in spans if s.type == TYPE_ID18])

    def test_id18_bad_date(self):
        # 月份 13，即使校验位自洽也不是身份证
        num = make_id18(random.Random(7), invalid_date=True)
        spans = scan(b(num))
        self.assertFalse([s for s in spans if s.type == TYPE_ID18])


class TestOtherTypes(unittest.TestCase):
    def test_id15(self):
        spans = scan(b("110105491231002"))
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_ID15, 0, 15)])

    def test_mobile(self):
        spans = scan(b("13800138000"))
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_MOBILE, 0, 11)])

    def test_mobile_bad_prefix(self):
        spans = scan(b("12800138000"))
        self.assertFalse([s for s in spans if s.type == TYPE_MOBILE])

    def test_mobile_with_separators(self):
        spans = scan(b("138 0013 8000"))
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_MOBILE, 0, 13)])

    def test_bank_visa_test_number(self):
        spans = scan(b("4111111111111111"))
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_BANK, 0, 16)])

    def test_bank_grouped(self):
        spans = scan(b("4111 1111 1111 1111"))
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_BANK, 0, 19)])

    def test_bank_bad_luhn(self):
        spans = scan(b("4111111111111112"))
        self.assertFalse([s for s in spans if s.type == TYPE_BANK])

    def test_too_long_run(self):
        self.assertEqual(scan(b("12345678901234567890")), [])
        self.assertEqual(scan(b("123456789012345678901")), [])


class TestOffsets(unittest.TestCase):
    def test_utf8_offsets(self):
        text = "身份证：11010519491231002X。"
        spans = scan(b(text))
        start = len("身份证：".encode())
        self.assertEqual([(s.type, s.start, s.length) for s in spans], [(TYPE_ID18, start, 18)])

    def test_two_hits_in_order(self):
        text = "张三 13800138000，卡号 4111111111111111 谢谢"
        spans = scan(b(text))
        self.assertEqual([s.type for s in spans], [TYPE_MOBILE, TYPE_BANK])
        self.assertLess(spans[0].start, spans[1].start)
        for s in spans:
            self.assertEqual(text.encode()[s.start : s.start + s.length].decode()[:1].isdigit(), True)


class TestTextTypes(unittest.TestCase):
    def _types(self, s: bytes):
        return [(x.type, x.start, x.length) for x in scan(s)]

    def test_email(self):
        self.assertEqual(self._types(b"user@example.com"), [(TYPE_EMAIL, 0, 16)])

    def test_email_trailing_dot_trimmed(self):
        self.assertEqual(self._types(b"a@b.com."), [(TYPE_EMAIL, 0, 7)])

    def test_email_invalid_shapes(self):
        for bad in (b"a..b@x.com", b"a@b", b"a@-b.com", b"@example.com", b"a@b-.com"):
            self.assertEqual(self._types(bad), [], bad)

    def test_email_too_long_run(self):
        self.assertEqual(self._types(b"a@" + b"x" * 64 + b".com"), [])

    def test_ipv4(self):
        self.assertEqual(self._types(b"10.0.0.1"), [(TYPE_IPV4, 0, 8)])

    def test_ipv4_invalid(self):
        for bad in (b"256.1.1.1", b"01.2.3.4", b"1.2.3", b"1.2.3.4.5"):
            self.assertEqual(self._types(bad), [], bad)

    def test_uscc(self):
        self.assertEqual(self._types(b"91350100M000100Y43"), [(TYPE_USCC, 0, 18)])

    def test_uscc_invalid_check(self):
        self.assertEqual(self._types(b"91350100M000100Y44"), [])

    def test_uscc_all_digits_not_uscc(self):
        self.assertEqual(self._types(b"913501000000100043"), [])
        # 18 位全数字仍会走身份证/银行卡分支，这里只断言没有 USCC
        self.assertFalse([x for x in scan(b"913501000000100043") if x.type == TYPE_USCC])

    def test_plate(self):
        self.assertEqual(self._types("京A12345".encode()), [(TYPE_PLATE, 0, 9)])

    def test_plate_bad_letter(self):
        self.assertEqual(self._types("京A1234I".encode()), [])

    def test_plate_followed_by_alnum_rejected(self):
        self.assertEqual(self._types("京A12345A".encode()), [])

    def test_plate_followed_by_chinese_ok(self):
        self.assertEqual(self._types("京A12345的快递".encode()), [(TYPE_PLATE, 0, 9)])

    def test_plate_two_in_a_row(self):
        self.assertEqual(
            [(x.type, x.length) for x in scan("京A12345沪B67890".encode())],
            [(TYPE_PLATE, 9), (TYPE_PLATE, 9)],
        )

    def test_mixed_offsets(self):
        text = "手机 13800138000，卡 4111111111111111，邮箱 a@b.co，IP 10.0.0.1"
        spans = scan(text.encode())
        self.assertEqual([s.type for s in spans], [TYPE_MOBILE, TYPE_BANK, TYPE_EMAIL, TYPE_IPV4])
        data = text.encode()
        for s in spans:
            self.assertTrue(data[s.start : s.start + s.length])


class TestInvariants(unittest.TestCase):
    def test_generated_cases(self):
        rng = random.Random(42)
        for _ in range(300):
            data = build_case(rng)
            spans = scan(data)
            prev_end = 0
            for s in spans:
                self.assertGreater(s.length, 0)
                self.assertGreaterEqual(s.start, prev_end)
                self.assertLessEqual(s.start + s.length, len(data))
                prev_end = s.start + s.length


if __name__ == "__main__":
    unittest.main(verbosity=2)
