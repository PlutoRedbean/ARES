import unittest
from types import SimpleNamespace

from gestures import (DEFENSE, DRINK, IDLE, POINT, UNKNOWN, Confirmation, classify,
                      defense_hand, pointing)
from motion import MotionFeed, parse
from score import measure


def pose():
    joints = [(0, 0, 0)] * 33
    joints[0] = (300, 50, .9)
    for x, arm in [(250, (11, 13, 15)), (350, (12, 14, 16))]:
        for i, y in zip(arm, (100, 155, 210)):
            joints[i] = (x, y, .9)
    return joints


def hand():
    pts = [(0, 0, 0)] * 21
    for base, x in [(5, 1), (9, 0), (13, -1), (17, -2)]:
        pts[base:base + 4] = [(x, 0, 0), (x, 1, 0), (x, 1, 1), (x, 0, 1)]
    pts[7:9] = [(1, 2, 0), (1, 3, 0)]
    return pts


def fist():
    pts = hand()
    # Index bent like the other three; thumb remains tucked at the palm.
    pts[5:9] = [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)]
    return pts


class Gestures(unittest.TestCase):
    def test_held_point_and_rotation(self):
        pts = hand()
        pts[4] = (8, 1, 0)  # pointing thumb is abducted, not tucked
        side = [(-y, x, z) for x, y, z in pts]
        for h in (pts, side):
            self.assertTrue(pointing(h))
            self.assertEqual(classify([], [h]), POINT)
            confirm = Confirmation()
            self.assertEqual([confirm.update(classify([], [h])) for _ in range(8)],
                             [UNKNOWN, UNKNOWN] + [POINT] * 6)
        bent = hand()
        bent[4] = (8, 1, 0)
        bent[5:9] = [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)]
        low = [(0.5, 0.6, 0)] * 21
        self.assertEqual(classify([], [bent], "either", [low]), UNKNOWN)
        pts = hand()
        pts[4] = (8, 1, 0)
        for base in (9, 13, 17):
            pts[base:base + 4] = [(0, y, 0) for y in range(4)]
        self.assertEqual(classify([], [pts]), UNKNOWN)

    def test_hand_only_defense_and_point(self):
        self.assertEqual(classify([], [fist()]), DEFENSE)
        palm = hand()
        palm[4] = (8, 1, 0)
        self.assertEqual(classify([], [palm]), POINT)
        self.assertEqual(classify([], [palm, fist()]), UNKNOWN)
        self.assertEqual(classify([], []), UNKNOWN)
        # Pose/shoulders are intentionally ignored now.
        self.assertEqual(classify(pose(), []), UNKNOWN)

    def test_open_hand_is_not_defense(self):
        straight = hand()
        for base in (5, 9, 13, 17):
            straight[base:base + 4] = [(0, 0, 0), (0, 1, 0), (0, 2, 0), (0, 3, 0)]
        self.assertFalse(defense_hand(straight))
        self.assertNotEqual(classify([], [straight]), DEFENSE)

    def test_drink_uses_mediapipe_landmark_objects(self):
        curled = fist()
        curled[4] = (8, 1, 0)  # thumb abducted
        image = [SimpleNamespace(y=0.20) for _ in range(21)]
        self.assertEqual(classify([], [curled], "either", [image]), DRINK)

    def test_confirmation_release_and_recovery(self):
        seq = ([DEFENSE] * 5 + [IDLE, POINT] + [IDLE] * 3 +
               [UNKNOWN] + [DEFENSE] * 3)
        confirm = Confirmation(defense_hold=3)
        self.assertEqual([confirm.update(raw) for raw in seq],
                         [-1, -1, 1, 1, 1, -1, -1, -1, -1, 0, -1, -1, -1, 1])

    def test_default_defense_hold_is_longer(self):
        confirm = Confirmation()
        self.assertEqual([confirm.update(DEFENSE) for _ in range(8)],
                         [-1] * 7 + [DEFENSE])

    def test_motion_wire_order_and_expiry(self):
        wire = b"M1 4294967295 1 3 2 01" + b"00" * 16 + b"80\r\n"
        report = parse(wire)
        self.assertEqual(list(report.mirrored_tiles()), [(15, 0), (0, 8)])
        feed = MotionFeed()
        feed.accept(report, 1)
        feed.accept(report, 1.49)
        self.assertEqual(feed.current(1.49), report)
        self.assertIsNone(feed.current(1.5))
        feed.accept(parse(b"M1 0 0 0 0 " + b"00" * 18), 1.51)
        self.assertIsNone(feed.current(1.51))
        for bad in (wire.replace(b"3 2 ", b"3 1 "), wire.replace(b"1 3 ", b"0 3 "),
                    wire.replace(b"01", b"0g"), b"msh >", wire + b"z"):
            self.assertIsNone(parse(bad))

    def test_hold_metrics(self):
        events = [dict(t=i / 10, stable=s) for i, s in enumerate([2, -1, 1, 1, -1, -1, 1])]
        result = measure(events, 0, 1, DEFENSE, POINT)
        self.assertEqual((result["enter_ms"], result["previous_release_ms"],
                          result["false_releases"]), (200, 100, 1))
        self.assertIsNone(measure(events, 1, 2, IDLE, DEFENSE)["enter_ms"])


if __name__ == "__main__":
    unittest.main()
