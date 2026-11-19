"""整数参考：与 RTL 逐位一致（16 位定点 requant，round-half-up）。"""
import sys, math
sys.path.insert(0, ".")
import numpy as np
from host.golden.ner import NerModel

class IntModel:
    def __init__(self, model: NerModel, s=24):
        self.m = model
        self.s = s
        self.m1 = int(round(float(model.mul1) * (1 << s)))
        self.m2 = int(round(float(model.mul2) * (1 << s)))
        self.zp1, self.zp2 = model.zp1, model.zp2

    def conv(self, x, w, b):
        L, C = x.shape
        O, K, _ = w.shape
        xp = np.zeros((L + K - 1, C), dtype=np.int32)
        off = K // 2
        xp[off:off + L] = x
        out = np.empty((L, O), dtype=np.int32)
        for o in range(O):
            acc = np.zeros(L, dtype=np.int32)
            for k in range(K):
                acc += xp[k:k + L] @ w[o, k]
            out[:, o] = acc + b[o]
        return out

    def rq(self, acc, m, zp):
        prod = acc.astype(np.int64) * m
        q = (prod + (1 << (self.s - 1))) >> self.s          # round-half-up
        q = q + zp
        return np.clip(q, 0, 127).astype(np.int32)

    def forward(self, ids):
        ids = np.asarray(ids, dtype=np.int64)
        if ids.shape[0] < self.m.window:
            ids = np.concatenate([ids, np.full(self.m.window - ids.shape[0], self.m.pad_id, dtype=np.int64)])
        x = self.m.emb_w[ids]
        h1 = self.rq(self.conv(x, self.m.conv1_w, self.m.conv1_b), self.m1, self.zp1)
        h2 = self.rq(self.conv(h1, self.m.conv2_w, self.m.conv2_b), self.m2, self.zp2)
        return h2 @ self.m.head_w.T + self.m.head_b

m = NerModel()
im = IntModel(m)
print("m1", im.m1, "m2", im.m2, "s", im.s)

import pathlib, json
vec = pathlib.Path("build/ner_vectors")
same = diff = 0
for p in sorted(vec.glob("case_*.in"))[:60]:
    data = p.read_bytes()
    text = data.decode("utf-8", "replace")
    ids_all = m.tokenize(text)
    a = m.forward(ids_all)
    b = im.forward(ids_all)
    if np.array_equal(a, b):
        same += 1
    else:
        diff += 1
        d = np.abs(a - b)
        print(p.name, "maxdiff", int(d.max()), "argmax same:", bool((a.argmax(1) == b.argmax(1)).all()))
print("identical:", same, "different:", diff)
