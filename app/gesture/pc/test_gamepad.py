"""gamepad.py 的过滤规则：unknown 只释放，不按新键，但允许下一次 point。"""

import unittest

from gamepad import decode
from xbox_serial.gesture_actions import DEFENSE, DRINK, POINT, GestureActions


class GamepadBridge(unittest.TestCase):
    def test_unknown_is_passed_through_for_debounce(self):
        self.assertEqual(decode(-1), -1)
        self.assertEqual(decode(DEFENSE), DEFENSE)
        self.assertEqual(decode(POINT), POINT)
        self.assertEqual(decode(DRINK), DRINK)

    def test_defense_unknown_point_sequence(self):
        actions = GestureActions()
        actions.update(decode(DEFENSE), 0.0)
        self.assertIn("LB", actions.buttons(0.0))

        actions.update(decode(-1), 0.1)
        self.assertEqual(actions.buttons(0.1), set())

        # 第一次 point 仍能触发；短暂 unknown 后不重复，持续 300 ms 才重新武装。
        actions.update(decode(POINT), 0.2)
        self.assertIn("R3", actions.buttons(0.2))
        actions.update(decode(-1), 0.3)
        actions.update(decode(POINT), 0.5)
        self.assertNotIn("R3", actions.buttons(0.5))
        actions.update(decode(-1), 0.6)
        actions.update(decode(POINT), 0.95)
        self.assertIn("R3", actions.buttons(0.95))

    def test_drink_sends_dpad_down(self):
        actions = GestureActions()
        actions.update(decode(DRINK), 0.0)
        self.assertIn("DPAD_DOWN", actions.buttons(0.0))
        actions.update(decode(-1), 0.2)
        self.assertNotIn("DPAD_DOWN", actions.buttons(0.3))


if __name__ == "__main__":
    unittest.main()
