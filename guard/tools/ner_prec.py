import sys
sys.path.insert(0, ".")
import numpy as np
from host.golden.ner import NerModel
from pathlib import Path

m = NerModel()

def rq(acc, m_int, s):
    p = acc.astype(np.int64) * m_int
    q = (p + (1 << (s - 1))) >> s
    return np.clip(q, 0, 127).astype(np.int32)

def conv(x, w, b):
    L, C = x.shape
    O, K, _ = w.shape
    xp = np.zeros((L + K - 1, C), dtype=np.int32)
    xp[K // 2:K // 2 + L] = x
    out = np.empty((L, O), dtype=np.int32)
    for o in range(O):
        acc = np.zeros(L, dtype=np.int32)
        for k in range(K):
            acc += xp[k:k + L] @ w[o, k]
        out[:, o] = acc + b[o]
    return out

for s in (24, 28, 32):
    m1 = int(round(float(m.mul1) * (1 << s)))
    m2 = int(round(float(m.mul2) * (1 << s)))
    same = 0
    total = 0
    bad = 0
    for p in sorted(Path("build/ner_vectors").glob("case_*.in"))[:60]:
        ids = m.tokenize(p.read_bytes().decode("utf-8", "replace"))
        a = m.forward(ids)
        x = m.emb_w[np.array(ids + [0] * (64 - len(ids)))]
        h1 = rq(conv(x, m.conv1_w, m.conv1_b), m1, s)
        h2 = rq(conv(h1, m.conv2_w, m.conv2_b), m2, s)
        b = h2 @ m.head_w.T + m.head_b
        total += 1
        if np.array_equal(a, b):
            same += 1
        elif not (a.argmax(1) == b.argmax(1)).all():
            bad += 1
    print(f"s={s:2d}  m1={m1:>12d} m2={m2:>12d}  logits identical {same}/{total}, argmax diff {bad}")
