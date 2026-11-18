"""评估 NER 模型在"真实感"文本上的表现（不是它自己的合成集）。

三部分：
  1. 手写句子：无线索词的人名 / 口语地址；
  2. 语料 300 例：模型多报的 span（相对规则层）；
  3. 置信度阈值扫描：sacrifice 多少召回换多少误报。

用法：python3 tools/eval_ner.py
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.corpus.synth import build_case  # noqa: E402
from host.golden.entities import scan_entities  # noqa: E402
from host.golden.ner import NerModel  # noqa: E402

BATTERY = [
    "刘德华的演唱会在上海",
    "请把文件发给杨帆",
    "电话簿里存的是孙悦",
    "王小明说他要来",
    "张总今天不在",
    "李雷和韩梅梅是同学",
    "联系人张三，电话 13800138000",
    "王经理您好",
    "收件人欧阳娜娜，地址：北京市朝阳区建国路88号",
    "我住在中关村大街27号",
    "方向不对，重新算一下",
]


def spans(model: NerModel, data: bytes, abs_margin: int = 0, min_chars: int = 2):
    """带置信度门（|top1-top2| 的 int32 阈值）的 span 解码。"""
    text = data.decode("utf-8", "replace")
    chars = list(text)
    if not chars:
        return []
    bl = [len(c.encode("utf-8")) for c in chars]
    off = [0]
    for b in bl:
        off.append(off[-1] + b)
    ids = model.tokenize(text)
    n = len(chars)
    labels = np.zeros(n, dtype=np.int32)
    ok = np.ones(n, dtype=bool)
    i = 0
    while i < n:
        j, nb = i, 0
        while j < n and nb + bl[j] <= model.window:
            nb += bl[j]
            j += 1
        if j == i:
            j = i + 1
        lg = model.forward(ids[i:j])
        srt = np.sort(lg, axis=1)[:, ::-1]
        mg = (srt[:, 0] - srt[:, 1]).astype(np.int32)
        labels[i:j] = np.argmax(lg, axis=1)[: j - i]
        ok[i:j] = (mg >= abs_margin)[: j - i]
        i = j
    out = []
    i = 0
    while i < n:
        if labels[i] == 0:
            i += 1
            continue
        j = i + 1
        while j < n and labels[j] == labels[i]:
            j += 1
        if (j - i) >= min_chars and ok[i:j].all():
            out.append((9 if labels[i] == 1 else 10, off[i], off[j] - off[i]))
        i = j
    return out


def main() -> int:
    m = NerModel()

    print("== 手写句子（模型 vs 规则）==")
    for t in BATTERY:
        b = t.encode()
        ner = [(ty, b[s:s + ln].decode("utf-8", "replace")) for ty, s, ln in spans(m, b)]
        rule = [(ty, b[s:s + ln].decode("utf-8", "replace")) for ty, s, ln in scan_entities(b)]
        print(f"  {t}\n     ner={ner or '-'}\n     rule={rule or '-'}")

    print("\n== 阈值扫描（语料 300 例）==")
    print(f"  {'abs_margin':>10} {'模型多报 span':>14}")
    for thr in (0, 2000, 4000, 6000, 8000):
        rng = random.Random(11)
        extra = 0
        for _ in range(300):
            d = build_case(rng)
            rule = set(scan_entities(d))
            extra += len([g for g in spans(m, d, thr) if g not in rule])
        print(f"  {thr:>10} {extra:>14}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
