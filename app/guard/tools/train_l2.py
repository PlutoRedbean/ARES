"""训练 L2 的 INT4 权重（纯 Python，无第三方依赖）。

流程：
  1. 生成带标签的样本：8 个特征（关键词窗口 / 距离 / 位数 / ':' 前缀 / 偏置）+ 类别；
  2. 训练一个 float 的 softmax 线性分类器（4 类 × 8 特征）；
  3. 量化到 INT4（-8..7），再用坐标下降在整数格点上微调（目标 = RTL 的精确语义）；
  4. 写 host/golden/l2_weights.py（金标与 RTL 的唯一来源）。

RTL 的判定规则（必须一致）：class = argmax_c W[c]·x；若最高分 <= 0 则判 0(none)；
并列取小下标。
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.keywords import KEYWORDS  # noqa: E402
from host.golden.l2_int4 import L2_CLASSES, L2_FEATURES, features_from_hits  # noqa: E402

KID = {name: i for i, name in enumerate(KEYWORDS)}
CLASS_OF_KID = {KID["身份证"]: 1, KID["银行卡"]: 2, KID["手机号"]: 3}


# --------------------------------------------------------------------------- 数据
def sample(rng: random.Random) -> tuple[list[int], int]:
    """造一个 (特征, 标签) 样本。标签是"这句话里这个号码应该被判成什么"。"""
    label = rng.choices([0, 1, 2, 3], weights=[28, 26, 24, 22])[0]

    if label == 0:
        kind = rng.random()
        if kind < 0.5:                     # 完全没有关键词
            kid, d = None, 0
        elif kind < 0.62:                  # 关键词太远（>12）
            kid, d = rng.choice([KID["身份证"], KID["银行卡"], KID["手机号"]]), rng.randint(13, 24)
        elif kind < 0.78:                  # 关键词就在旁边，但这段数字太短（不可能是一个 PII）
            kid, d = rng.choice([KID["身份证"], KID["银行卡"], KID["手机号"]]), rng.randint(1, 8)
        else:                              # 别的 PII 关键词（地址/姓名/密码/账号）
            kid, d = rng.choice([KID["地址"], KID["姓名"], KID["密码"], KID["账号"]]), rng.randint(1, 8)
        # 短数字（<11 位）不该被上下文带成 PII：与 L1 的兜底规则一致（11..19 位才认）
        run_len = rng.choice([2, 3, 4, 5, 6, 8, 10]) if kind >= 0.62 else rng.choice([4, 6, 8, 10, 11, 13, 16, 18, 19])
    else:
        kid = {1: KID["身份证"], 2: KID["银行卡"], 3: KID["手机号"]}[label]
        kind = rng.random()
        if kind < 0.86:
            pass                           # 关键词正确
        elif kind < 0.94:
            kid = rng.choice([KID["身份证"], KID["银行卡"], KID["手机号"]])
            if {KID["身份证"]: 1, KID["银行卡"]: 2, KID["手机号"]: 3}[kid] != label:
                label = 0                  # 关键词说错了，模型该按关键词走？不——标签跟着关键词
                label = {KID["身份证"]: 1, KID["银行卡"]: 2, KID["手机号"]: 3}[kid]
        else:
            kid = None                     # 没关键词（L1 的活儿），标签仍是 none
            label = 0
        d = rng.randint(1, 6) if rng.random() < 0.85 else rng.randint(7, 12)
        run_len = {1: rng.choice([15, 16, 17, 18]),
                   2: rng.choice([13, 15, 16, 19]),
                   3: 11}[label] if label else rng.choice([4, 8, 18])

    hits = [] if kid is None else [(kid, 100 - d)]
    feat = features_from_hits(hits, 100, run_len, 0x3A if rng.random() < 0.3 else 0x20)
    return feat, label


def make_dataset(n: int, seed: int) -> list[tuple[list[int], int]]:
    rng = random.Random(seed)
    return [sample(rng) for _ in range(n)]


# --------------------------------------------------------------------------- 判定
def scores_int(w: list[list[int]], feat: list[int]) -> list[int]:
    return [sum(w[c][f] * feat[f] for f in range(L2_FEATURES)) for c in range(L2_CLASSES)]


def predict(w: list[list[int]], feat: list[int]) -> int:
    s = scores_int(w, feat)
    best, best_v = 0, s[0]
    for c in range(1, L2_CLASSES):
        if s[c] > best_v:
            best, best_v = c, s[c]
    return best if best_v > 0 else 0


def accuracy(w: list[list[int]], data: list[tuple[list[int], int]]) -> float:
    ok = sum(1 for f, y in data if predict(w, f) == y)
    return ok / len(data)


# --------------------------------------------------------------------------- 训练
def train_float(data, epochs: int = 4000, lr: float = 0.08) -> list[list[float]]:
    w = [[0.0] * L2_FEATURES for _ in range(L2_CLASSES)]
    n = len(data)
    for _ in range(epochs):
        grad = [[0.0] * L2_FEATURES for _ in range(L2_CLASSES)]
        for feat, y in data:
            s = [sum(w[c][f] * feat[f] for f in range(L2_FEATURES)) for c in range(L2_CLASSES)]
            mx = max(s)
            ex = [2.718281828459045 ** (v - mx) for v in s]
            tot = sum(ex)
            p = [v / tot for v in ex]
            for c in range(L2_CLASSES):
                g = p[c] - (1.0 if c == y else 0.0)
                for f in range(L2_FEATURES):
                    grad[c][f] += g * feat[f]
        for c in range(L2_CLASSES):
            for f in range(L2_FEATURES):
                w[c][f] -= lr * grad[c][f] / n
    return w


def quantize(w: list[list[float]]) -> list[list[int]]:
    return [[max(-8, min(7, int(round(v)))) for v in row] for row in w]


def refine(w: list[list[int]], data, rounds: int = 6) -> list[list[int]]:
    """整数坐标下降：逐参数试遍 -8..7，留让准确率最高的值。"""
    best = [row[:] for row in w]
    best_acc = accuracy(best, data)
    for _ in range(rounds):
        improved = False
        for c in range(L2_CLASSES):
            for f in range(L2_FEATURES):
                cur = best[c][f]
                for cand in range(-8, 8):
                    if cand == cur:
                        continue
                    best[c][f] = cand
                    a = accuracy(best, data)
                    if a > best_acc:
                        best_acc = a
                        cur = cand
                        improved = True
                    else:
                        best[c][f] = cur
        if not improved:
            break
    return best


def main() -> int:
    train_set = make_dataset(4000, seed=20261117)
    holdout = make_dataset(2000, seed=7)

    wf = train_float(train_set)
    wq = quantize(wf)
    print(f"float  train={accuracy([[int(round(v)) for v in r] for r in wf], train_set):.3f}")
    print(f"int4   train={accuracy(wq, train_set):.3f}  holdout={accuracy(wq, holdout):.3f}")
    wq = refine(wq, train_set)
    print(f"refine train={accuracy(wq, train_set):.3f}  holdout={accuracy(wq, holdout):.3f}")

    print("\nW_INT4 = [")
    for c, row in enumerate(wq):
        print(f"    {row},   # {['none','id18','bank','mobile'][c]}")
    print("]")

    out = Path("host/golden/l2_weights.py")
    out.write_text(
        '"""L2 INT4 权重：由 tools/train_l2.py 训练生成，请勿手改。\n\n'
        f"训练集 {len(train_set)} 例 / 留出集 {len(holdout)} 例；\n"
        f"INT4 量化后 train={accuracy(wq, train_set):.3f} holdout={accuracy(wq, holdout):.3f}。\n"
        '规则与 RTL 一致：argmax；最高分 <= 0 判 0(none)。\n"""\n\n'
        f"W_INT4 = {wq!r}\n",
        encoding="utf-8",
    )
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())