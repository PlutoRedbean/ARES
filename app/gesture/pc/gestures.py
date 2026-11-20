"""ARES hand-only gesture rules (defense / point / drink).

MediaPipe hand world landmarks provide finger curl, thumb abduction and index
reach.  Pose (shoulder/elbow/wrist) is intentionally ignored: it made any
raised hand look like a shield and disappeared whenever the operator was close
to the camera.  ``run.py`` still draws Pose for the preview window.
"""
from math import acos, degrees, dist, hypot

UNKNOWN, IDLE, DEFENSE, POINT, DRINK = -1, 0, 1, 2, 3
LABELS = {UNKNOWN: "unknown", IDLE: "idle", DEFENSE: "defense",
          POINT: "point", DRINK: "drink"}


def angle(a, vertex, b):
    u = [x - y for x, y in zip(a, vertex)]
    v = [x - y for x, y in zip(b, vertex)]
    norm = hypot(*u) * hypot(*v)
    if norm == 0:
        return None
    cosine = sum(x * y for x, y in zip(u, v)) / norm
    return degrees(acos(max(-1.0, min(1.0, cosine))))


def hand_shape(hand):
    """Return finger curl, thumb/palm ratio and relative index reach."""

    mins = []
    for mcp in (5, 9, 13, 17):
        pip = angle(hand[mcp], hand[mcp + 1], hand[mcp + 2])
        dip = angle(hand[mcp + 1], hand[mcp + 2], hand[mcp + 3])
        if pip is None or dip is None:
            return None, None, None
        mins.append(min(pip, dip))
    palm = dist(hand[5], hand[17])
    thumb = dist(hand[4], hand[9])
    tips = {5: 8, 9: 12, 13: 16, 17: 20}
    reach = {mcp: dist(hand[0], hand[tip]) / max(palm, 1e-9)
             for mcp, tip in tips.items()}
    other = max(reach[9], reach[13], reach[17])
    index_ratio = reach[5] / other if other > 0 else 0.0
    return mins, (thumb / palm if palm else 0.0), index_ratio


def pointing(hand):
    """A pointing index is much farther from the wrist than the other fingers.

    This reach ratio is invariant to which direction the index points, unlike
    a raw joint-angle threshold that collapsed when the finger pointed toward
    or away from the camera.
    """

    mins, thumb_ratio, index_ratio = hand_shape(hand)
    if mins is None:
        return False
    # The recordings show a pointing thumb is abducted (~1.4); a shield/fist
    # thumb is tucked in (~0.6).
    return thumb_ratio >= 1.0 and index_ratio >= 1.2


def defense_hand(hand):
    """A fist/loose fist with the thumb tucked against the palm."""

    mins, thumb_ratio, _index_ratio = hand_shape(hand)
    if mins is None:
        return False
    # Open palms (all fingers straight) are not a shield.
    if min(mins) > 150:
        return False
    return mins[0] <= 150 and thumb_ratio <= 0.9


def _image_center_y(image):
    if image is None:
        return None
    points = getattr(image, "landmark", image)
    if not points:
        return None
    ys = []
    for point in points:
        if hasattr(point, "y"):
            ys.append(point.y)
        else:
            ys.append(point[1])
    return sum(ys) / len(ys) if ys else None


def drink_hand(hand, image=None):
    """A curled hand with the thumb out, held near the mouth (top of frame)."""

    mins, thumb_ratio, index_ratio = hand_shape(hand)
    if mins is None:
        return False
    if max(mins) > 145:
        return False
    if thumb_ratio < 1.1 or index_ratio > 1.2:
        return False
    # The drink recording is near the mouth, around y=0.18; points are lower
    # in the frame.  Only use this when image landmarks are available.
    center_y = _image_center_y(image)
    if center_y is not None and center_y > 0.30:
        return False
    return True


def classify(pose, hands, shield_side="right", hand_images=None):
    """Classify using hand landmarks only.

    ``pose`` and ``shield_side`` are kept for callers/replays; shoulder and
    elbow geometry is no longer used (it made any raised hand look like a
    shield and failed whenever Pose dropped an arm).
    """

    images = hand_images or []
    point = any(pointing(hand) for hand in hands)
    shield = any(defense_hand(hand) for hand in hands)
    drink = any(
        drink_hand(hand, images[i] if i < len(images) else None)
        for i, hand in enumerate(hands)
    )

    if sum((point, shield, drink)) > 1:
        return UNKNOWN
    if point:
        return POINT
    if shield:
        return DEFENSE
    if drink:
        return DRINK
    return UNKNOWN


class Confirmation:
    # Defense must be held a little longer than point: raising a hand through
    # the camera should not fire LB on a single transient pose.
    HOLDS = {DEFENSE: 8, POINT: 3, DRINK: 5, IDLE: 3}

    def __init__(self, defense_hold=8):
        self.candidate = UNKNOWN
        self.count = 0
        self.holds = dict(self.HOLDS)
        self.holds[DEFENSE] = int(defense_hold)

    def update(self, raw):
        if raw == UNKNOWN or raw != self.candidate:
            self.count = 0
        self.candidate = raw
        hold = self.holds.get(raw, 3)
        if raw != UNKNOWN:
            self.count = min(hold, self.count + 1)
        return raw if raw != UNKNOWN and self.count >= hold else UNKNOWN
