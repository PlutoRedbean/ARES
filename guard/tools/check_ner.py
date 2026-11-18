"""校验 Ubuntu 侧交付的 NER 模型是否满足 docs/ubuntu-ner.md 的门槛。

六条门槛逐条打印 PASS/FAIL；任何一条 FAIL 都以非零退出。
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "models" / "ner"
VEC = ROOT / "build" / "ner_vectors"

GATES = {
    "heldout_f1": 0.92,
    "heldout_p": 0.95,
    "heldout_r": 0.88,
    "hard_r": 0.75,
    "hard_f1": 0.80,
    "params": 60_000,
    "int8_bytes": 120 * 1024,
    "macs": 4_000_000,
}

FILES = [
    "config.json", "vocab.json", "weights_int8.npz", "quant.json", "eval.json",
]

EXTRA = [
    "host/golden/ner.py", "tools/train_ner.py", "tools/gen_ner_data.py",
    "tools/gen_ner_vectors.py", "tests/test_ner_golden.py",
]


def gate(ok: bool, name: str, detail: str) -> bool:
    print(f"[{'PASS' if ok else 'FAIL'}] {name:<34} {detail}")
    return ok


def main() -> int:
    print("== 交付物 ==")
    ok_all = True
    for f in FILES:
        ok_all &= gate((MODEL / f).exists(), "file:" + f, str(MODEL / f))
    for f in EXTRA:
        ok_all &= gate((ROOT / f).exists(), "file:" + f, str(ROOT / f))
    if not (MODEL / "eval.json").exists():
        print("\n还是空的：先把 docs/ubuntu-ner.md 做完再来。")
        return 1

    ev = json.loads((MODEL / "eval.json").read_text(encoding="utf-8"))
    size = ev.get("size", {})
    held = ev.get("heldout", {})
    hard = ev.get("hard", {})

    print("\n== 门槛 ==")
    ok_all &= gate(held.get("span_f1", 0) >= GATES["heldout_f1"], "1a heldout F1",
                   f"{held.get('span_f1', 0):.3f} >= {GATES['heldout_f1']}")
    ok_all &= gate(held.get("span_precision", 0) >= GATES["heldout_p"], "1b heldout P",
                   f"{held.get('span_precision', 0):.3f} >= {GATES['heldout_p']}")
    ok_all &= gate(held.get("span_recall", 0) >= GATES["heldout_r"], "1c heldout R",
                   f"{held.get('span_recall', 0):.3f} >= {GATES['heldout_r']}")
    ok_all &= gate(hard.get("span_recall", 0) >= GATES["hard_r"], "2a hard R",
                   f"{hard.get('span_recall', 0):.3f} >= {GATES['hard_r']}")
    ok_all &= gate(hard.get("span_f1", 0) >= GATES["hard_f1"], "2b hard F1",
                   f"{hard.get('span_f1', 0):.3f} >= {GATES['hard_f1']}")
    ok_all &= gate(size.get("params", 1 << 30) <= GATES["params"], "4a params",
                   f"{size.get('params', -1)} <= {GATES['params']}")
    ok_all &= gate(size.get("int8_bytes", 1 << 30) <= GATES["int8_bytes"], "4b int8 bytes",
                   f"{size.get('int8_bytes', -1)} <= {GATES['int8_bytes']}")
    ok_all &= gate(size.get("macs_per_window", 1 << 30) <= GATES["macs"], "4c MAC/window",
                   f"{size.get('macs_per_window', -1)} <= {GATES['macs']}")

    # 3 / 6：跑 ner.py 对向量，和 .exp 比
    sys.path.insert(0, str(ROOT))
    try:
        from host.golden.ner import decode as ner_decode  # type: ignore
    except Exception as exc:  # noqa: BLE001
        ok_all &= gate(False, "3 numpy inference", f"import host.golden.ner failed: {exc}")
        ner_decode = None

    if ner_decode is not None and VEC.exists():
        cases = sorted(VEC.glob("case_*.in"))
        ok_all &= gate(len(cases) >= 200, "6a vectors", f"{len(cases)} cases (need 200)")
        bad = 0
        for p in cases:
            data = p.read_bytes()
            want = []
            exp = p.with_suffix(".exp")
            if exp.exists():
                for line in exp.read_text(encoding="utf-8").splitlines():
                    f = line.split()
                    if len(f) == 3:
                        want.append((int(f[0]), int(f[1]), int(f[2])))
            got = [(s, ln, ty) for ty, s, ln in ner_decode(data)]
            if sorted(got) != sorted(want):
                bad += 1
        ok_all &= gate(bad == 0, "6b vectors match", f"{bad} mismatched of {len(cases)}")
    else:
        ok_all &= gate(False, "6 vectors", f"{VEC} missing")

    # 5：权重 checksum 与 eval.json 一致
    w = MODEL / "weights_int8.npz"
    if w.exists():
        got = hashlib.sha256(w.read_bytes()).hexdigest()
        want = ev.get("checksums", {}).get("weights_sha256")
        ok_all &= gate(want == got, "5 weights sha256",
                       f"{got[:12]}... vs eval.json {str(want)[:12]}...")
    else:
        ok_all &= gate(False, "5 weights sha256", "weights_int8.npz missing")

    print("\n" + ("全部通过，可以接 RTL。" if ok_all else "有门槛没过，先别接 RTL。"))
    return 0 if ok_all else 2


if __name__ == "__main__":
    raise SystemExit(main())