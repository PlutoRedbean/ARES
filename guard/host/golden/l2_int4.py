"""L2 INT4 语义层金标：上下文特征 → INT4 权重 → 4 类 (none/id18/bank/mobile)。"""
from __future__ import annotations
from host.golden.keywords import find_keywords

L2_FEATURES = 8
L2_CLASSES = 4
CLASS_NAMES = ("none", "id18", "bank", "mobile")
KW_WINDOW = 12

W_INT4 = [
    [   0,     0,     0,     0,     0,   0,   0,   2],
    [   6,    -6,    -6,    -6,    -2,   1,   0,   0],
    [  -6,     6,    -6,    -6,    -2,   1,   0,   0],
    [  -6,    -6,     6,    -6,    -2,   1,   0,   0],
]


def int4(v: int) -> int:
    return max(-8, min(7, v))


def gemm4(a, b, acc):
    out = [[acc[i][j] + sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)]
           for i in range(4)]
    return out


def scores(feat):
    a1 = [[int4(W_INT4[c][k]) for k in range(4)] for c in range(4)]
    b1 = [[feat[k] for _ in range(4)] for k in range(4)]
    c1 = gemm4(a1, b1, [[0] * 4 for _ in range(4)])
    a2 = [[int4(W_INT4[c][k + 4]) for k in range(4)] for c in range(4)]
    b2 = [[feat[k + 4] for _ in range(4)] for k in range(4)]
    c2 = gemm4(a2, b2, c1)
    return [c2[c][0] for c in range(4)]


def classify(feat):
    s = scores(feat)
    best, best_v = 0, s[0]
    for c in range(1, L2_CLASSES):
        if s[c] > best_v:
            best, best_v = c, s[c]
    return (best if best_v > 0 else 0), s


def dist_bucket(d: int) -> int:
    if d <= 2:
        return 0
    if d <= 5:
        return 1
    if d <= KW_WINDOW:
        return 2
    return 3


def features_from_hits(hits, run_start: int, run_len: int, prev_byte: int):
    """hits: [(kid, end)] 全部关键词命中；只取窗口内的。"""
    near = [(kid, end) for kid, end in hits
            if run_start >= end and (run_start - end) <= KW_WINDOW]
    f = [0] * L2_FEATURES
    for kid, _ in near:
        if kid == 0:
            f[0] = 1
        elif kid == 1:
            f[1] = 1
        elif kid == 2:
            f[2] = 1
        else:
            f[3] = 1
    d = min(run_start - end for _, end in near) if near else 99
    f[4] = dist_bucket(d)
    f[5] = 1 if 11 <= run_len <= 19 else 0
    f[6] = 1 if prev_byte in (0x3A, 0x3D) else 0
    f[7] = 1
    return f


def semantic_scan(data: bytes):
    """扫描字节流：每个数字游程给一个 (start, len, class, scores)。"""
    hits = [(k.kid, k.start + k.length) for k in find_keywords(data)]
    out = []
    i, n = 0, len(data)
    while i < n:
        if 0x30 <= data[i] <= 0x39:
            j = i
            while j < n and 0x30 <= data[j] <= 0x39:
                j += 1
            prev = data[i - 1] if i > 0 else 0
            feat = features_from_hits(hits, i, j - i, prev)
            cls, s = classify(feat)
            out.append((i, j - i, cls, s))
            i = j
        else:
            i += 1
    return out