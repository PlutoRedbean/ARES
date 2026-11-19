"""L2b 实体层（人名 / 地址）规则测试。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.entities import mask_entities, scan_entities  # noqa: E402


def spans_of(text: str) -> list[tuple[str, str]]:
    b = text.encode()
    return [("name" if ty == 9 else "addr", b[s:s + ln].decode("utf-8", "replace"))
            for ty, s, ln in scan_entities(b)]


class TestNames(unittest.TestCase):
    def test_cue_before(self) -> None:
        self.assertEqual(spans_of("联系人张三，电话 13800138000"), [("name", "张三")])

    def test_cue_with_colon(self) -> None:
        self.assertEqual(spans_of("姓名：李四"), [("name", "李四")])

    def test_surname_plus_title(self) -> None:
        self.assertEqual(spans_of("王经理您好"), [("name", "王经理")])

    def test_boundary(self) -> None:
        self.assertEqual(spans_of("联系人：李娜。"), [("name", "李娜")])

    def test_no_cue_no_hit(self) -> None:
        self.assertEqual(spans_of("订单号 330203300422240391"), [])


class TestAddresses(unittest.TestCase):
    def test_with_cue_and_digits(self) -> None:
        self.assertEqual(spans_of("地址：北京市朝阳区建国路88号"),
                         [("addr", "北京市朝阳区建国路88号")])

    def test_with_cue_building(self) -> None:
        self.assertEqual(spans_of("住址：广东省深圳市南山区科技园1栋"),
                         [("addr", "广东省深圳市南山区科技园1栋")])

    def test_cue_verb(self) -> None:
        self.assertEqual(spans_of("我住在杭州市西湖区文三路100号"),
                         [("addr", "杭州市西湖区文三路100号")])


class TestMasking(unittest.TestCase):
    def test_entities_are_fully_masked(self) -> None:
        text = "联系人张三，地址：北京市朝阳区建国路88号"
        b = text.encode()
        out = mask_entities(b, scan_entities(b)).decode()
        self.assertNotIn("张三", out)
        self.assertNotIn("建国路", out)
        self.assertIn("联系人", out)      # 线索词不遮
        self.assertIn("*", out)


if __name__ == "__main__":
    unittest.main()
