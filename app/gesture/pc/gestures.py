"""ARES geometry rules. Pose points are (pixel x, pixel y, visibility);
hand points use MediaPipe's 3-D hand world coordinates in metres."""
from math import acos, degrees, dist, hypot

UNKNOWN, IDLE, DEFENSE, POINT = -1, 0, 1, 2
LABELS = {UNKNOWN: "unknown", IDLE: "idle", DEFENSE: "defense", POINT: "point"}
ARMS = {"left": (11, 13, 15), "right": (12, 14, 16)}


def angle(a, vertex, b):
    u = [x - y for x, y in zip(a, vertex)]
    v = [x - y for x, y in zip(b, vertex)]
    norm = hypot(*u) * hypot(*v)
    if norm == 0:
        return None
    cosine = sum(x * y for x, y in zip(u, v)) / norm
    return degrees(acos(max(-1.0, min(1.0, cosine))))


def pointing(hand):
    # Joint angles work for both a vertical and a sideways index finger.
    for mcp in (5, 9, 13, 17):
        pip = angle(hand[mcp], hand[mcp + 1], hand[mcp + 2])
        dip = angle(hand[mcp + 1], hand[mcp + 2], hand[mcp + 3])
        if pip is None or dip is None:
            return False
        if mcp == 5 and (pip < 155 or dip < 145):
            return False
        if mcp != 5 and min(pip, dip) > 115:
            return False
    # Folded/adducted thumb lies near the finger bases.
    return dist(hand[4], hand[9]) <= dist(hand[5], hand[17])


def classify(pose, hands, shield_side="right"):
    point = any(pointing(hand) for hand in hands)
    shield = False
    lowered = 0
    for side, indices in ARMS.items():
        if not pose or any(pose[i][2] <= 0.5 for i in indices):
            continue
        shoulder, elbow, wrist = [pose[i][:2] for i in indices]
        bend = angle(shoulder, elbow, wrist)
        if bend is None:
            continue
        if wrist[1] > elbow[1] > shoulder[1] and bend >= 145:
            lowered += 1
        if side == shield_side or shield_side == "either":
            if pose[0][2] > 0.5 and pose[0][1] < wrist[1] < elbow[1] and bend < 90:
                shield = True

    if point and shield:
        return UNKNOWN
    if point:
        return POINT
    if shield:
        return DEFENSE
    return IDLE if lowered == 2 else UNKNOWN


class Confirmation:
    def __init__(self):
        self.candidate = UNKNOWN
        self.count = 0

    def update(self, raw):
        if raw == UNKNOWN or raw != self.candidate:
            self.count = 0
        self.candidate = raw
        if raw != UNKNOWN:
            self.count = min(3, self.count + 1)
        return raw if self.count == 3 else UNKNOWN
