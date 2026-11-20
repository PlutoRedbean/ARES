import unittest

from gestures import DEFENSE, IDLE, POINT, UNKNOWN, Confirmation, classify
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


class Gestures(unittest.TestCase):
    def test_held_point_and_rotation(self):
        pts = hand()
        side = [(-y, x, z) for x, y, z in pts]
        for h in (pts, side):
            self.assertEqual(classify([], [h]), POINT)
            confirm = Confirmation()
            self.assertEqual([confirm.update(classify([], [h])) for _ in range(8)],
                             [UNKNOWN, UNKNOWN] + [POINT] * 6)
        pts[4] = (8, 1, 0)
        self.assertEqual(classify([], [pts]), UNKNOWN)
        pts = hand()
        pts[9:13] = [(0, y, 0) for y in range(4)]
        self.assertEqual(classify([], [pts]), UNKNOWN)

    def test_visible_arms_and_conflict(self):
        joints = pose()
        self.assertEqual(classify(joints, []), IDLE)
        joints[16] = (320, 110, .9)
        self.assertEqual(classify(joints, []), DEFENSE)
        self.assertEqual(classify(joints, [], "left"), UNKNOWN)
        self.assertEqual(classify(joints, [hand()]), UNKNOWN)
        joints[12] = (350, 100, .2)
        self.assertEqual(classify(joints, []), UNKNOWN)
        self.assertEqual(classify([], []), UNKNOWN)

    def test_confirmation_release_and_recovery(self):
        seq = ([DEFENSE] * 5 + [IDLE, POINT] + [IDLE] * 3 +
               [UNKNOWN] + [DEFENSE] * 3)
        confirm = Confirmation()
        self.assertEqual([confirm.update(raw) for raw in seq],
                         [-1, -1, 1, 1, 1, -1, -1, -1, -1, 0, -1, -1, -1, 1])

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
