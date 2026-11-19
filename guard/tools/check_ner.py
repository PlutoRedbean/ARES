"""校验 Ubuntu 侧交付的 NER 模型是否满足 docs/ubuntu-ner.md 的门槛。

原有 1~8、v3 的 9~11、v4 的 12（longdoc）逐条打印 PASS/FAIL；任何一条 FAIL 都以非零退出。

  --repro  额外做第 5 条的“同 seed 两次训练 hash 相同”：在临时目录重训一次并比对
           weights_int8.npz 的 sha256（约 40s）。make ner-check 默认带上。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "models" / "ner"
VEC = ROOT / "build" / "ner_vectors"
DATA = ROOT / "data" / "ner"

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
    "tools/gen_ner_vectors.py", "tests/test_ner_golden.py", "tools/name_chars.py",
]


def gate(ok: bool, name: str, detail: str) -> bool:
    print(f"[{'PASS' if ok else 'FAIL'}] {name:<34} {detail}")
    return ok


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repro", action="store_true",
                    help="重训一次（同 seed）并比对 weights_sha256（第 5 条）")
    args = ap.parse_args()

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

    # 3：numpy 整数推理 == ONNX(Runtime) argmax，500 例逐 token
    try:
        sys.path.insert(0, str(ROOT / "tools"))
        import ner_onnx  # noqa: E402

        rows = [json.loads(l) for l in (DATA / "heldout.jsonl").read_text(encoding="utf-8").splitlines()
                if l.strip()]
        texts = [r["text"] for r in rows[:500]]
        bad, n = ner_onnx.check_parity(MODEL, texts, limit=500,
                                       onnx_path=ROOT / "build" / "ner" / "check_model.onnx")
        ok_all &= gate(n >= 500 and bad == 0, "3 numpy==ONNX argmax",
                       f"{n - bad}/{n} identical")
    except Exception as exc:  # noqa: BLE001
        ok_all &= gate(False, "3 numpy==ONNX argmax", f"{type(exc).__name__}: {exc}")

    # 6 / 5：向量与权重完整性
    sys.path.insert(0, str(ROOT))
    try:
        from host.golden.ner import decode as ner_decode  # type: ignore
    except Exception as exc:  # noqa: BLE001
        ok_all &= gate(False, "6 numpy inference", f"import host.golden.ner failed: {exc}")
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

    # 5：权重 checksum 与 eval.json 一致；--repro 时再重训一次比 hash
    w = MODEL / "weights_int8.npz"
    got_sha = None
    if w.exists():
        got_sha = sha256_file(w)
        want = ev.get("checksums", {}).get("weights_sha256")
        ok_all &= gate(want == got_sha, "5 weights sha256",
                       f"{got_sha[:12]}... vs eval.json {str(want)[:12]}...")
    else:
        ok_all &= gate(False, "5 weights sha256", "weights_int8.npz missing")

    if args.repro:
        if got_sha is None:
            ok_all &= gate(False, "5b same-seed retrain", "weights_int8.npz missing")
        else:
            tmp = Path(tempfile.mkdtemp(prefix="ner_repro_"))
            try:
                print("[....] 5b same-seed retrain (约 40s) ...", flush=True)
                cmd = [sys.executable, str(ROOT / "tools" / "train_ner.py"),
                       "--data", str(DATA), "--out", str(tmp / "m"),
                       "--seed", str(ev.get("seed", 20261118))]
                proc = subprocess.run(cmd, capture_output=True, text=True)
                if proc.returncode != 0:
                    ok_all &= gate(False, "5b same-seed retrain",
                                   f"train_ner failed: {proc.stderr[-300:]}")
                else:
                    h2 = sha256_file(tmp / "m" / "weights_int8.npz")
                    ok_all &= gate(h2 == got_sha, "5b same-seed retrain sha256",
                                   f"{h2[:12]}... vs {got_sha[:12]}...")
            except Exception as exc:  # noqa: BLE001
                ok_all &= gate(False, "5b same-seed retrain", f"{type(exc).__name__}: {exc}")
            finally:
                shutil.rmtree(tmp, ignore_errors=True)

    # ---- 门槛 7：散文集误报 ----
    prose = ROOT / "data" / "ner" / "prose.jsonl"
    if ner_decode is not None and prose.exists():
        import json as _json
        rows = [_json.loads(l) for l in prose.read_text(encoding="utf-8").splitlines() if l.strip()]
        spans = 0
        for r in rows:
            spans += len(ner_decode(r["text"].encode("utf-8")))
        per = spans / max(len(rows), 1)
        ok_all &= gate(per <= 0.05, "7 prose false spans/sentence", f"{per:.3f} <= 0.05 ({spans}/{len(rows)})")
    else:
        ok_all &= gate(False, "7 prose false spans/sentence", "data/ner/prose.jsonl or ner.py missing")

    # ---- 门槛 8：证据集 11 句 ----
    evidence_ok = 0
    if ner_decode is not None:
        battery = [
            ("联系人张三，电话 13800138000", {(9, 9, 6)}),
            ("王经理您好", {(9, 0, 9)}),
            ("收件人欧阳娜娜，地址：北京市朝阳区建国路88号", {(9, 12, 12), (10, 33, 33)}),
            ("我住在中关村大街27号", {(10, 9, 24)}),
            ("刘德华的演唱会在上海", {(9, 0, 9)}),
            ("请把文件发给杨帆", {(9, 18, 6)}),
            ("陈静打了个电话", {(9, 0, 6)}),
        ]
        for text, want in battery:
            got = set(ner_decode(text.encode("utf-8")))
            if got == want:
                evidence_ok += 1
        ok_all &= gate(evidence_ok >= 5, "8 evidence set exact", f"{evidence_ok}/{len(battery)} >= 5")
    else:
        ok_all &= gate(False, "8 evidence set exact", "ner.py missing")

    # ---- 门槛 9：训练没出现过的 500+ 全名，召回 >= 0.95
    unseen_path = DATA / "unseen_names.jsonl"
    if ner_decode is not None and unseen_path.exists():
        rows = [json.loads(l) for l in unseen_path.read_text(encoding="utf-8").splitlines() if l.strip()]
        ok = 0
        for r in rows:
            gold = {(9, s, ln) for s, ln, y in r["spans"] if y == 1}
            pred = {x for x in ner_decode(r["text"].encode("utf-8")) if x[0] == 9}
            ok += int(gold == pred)
        rec = ok / max(len(rows), 1)
        ev_rec = ev.get("unseen_names", {}).get("recall")
        ok_all &= gate(len(rows) >= 500 and rec >= 0.95 and ev_rec is not None and abs(ev_rec - rec) < 1e-6,
                       "9 unseen names recall", f"{rec:.3f} >= 0.95 ({ok}/{len(rows)})")
    else:
        ok_all &= gate(False, "9 unseen names recall", f"{unseen_path} missing")

    # ---- 门槛 10：含数字地址，整段连续命中率 >= 0.98
    addr_path = DATA / "addr_digits.jsonl"
    if ner_decode is not None and addr_path.exists():
        rows = [json.loads(l) for l in addr_path.read_text(encoding="utf-8").splitlines() if l.strip()]
        ok = 0
        for r in rows:
            gold = {(10, s, ln) for s, ln, y in r["spans"] if y == 2}
            pred = {x for x in ner_decode(r["text"].encode("utf-8")) if x[0] == 10}
            ok += int(gold == pred)
        rate = ok / max(len(rows), 1)
        ev_rate = ev.get("addr_digits", {}).get("exact_span_rate")
        ok_all &= gate(len(rows) >= 500 and rate >= 0.98 and ev_rate is not None and abs(ev_rate - rate) < 1e-6,
                       "10 addr digits exact span", f"{rate:.3f} >= 0.98 ({ok}/{len(rows)})")
    else:
        ok_all &= gate(False, "10 addr digits exact span", f"{addr_path} missing")

    # ---- 门槛 11：固定跨时代/复姓名
    fixed_names = ["马嘉祺", "周杰伦", "欧阳娜娜", "司马相如"]
    fixed_ok = 0
    if ner_decode is not None:
        for name in fixed_names:
            text = name + "的演唱会在上海"
            want = (9, 0, len(name.encode("utf-8")))
            got = set(ner_decode(text.encode("utf-8")))
            fixed_ok += int(want in got)
        ok_all &= gate(fixed_ok == len(fixed_names), "11 fixed famous names",
                       f"{fixed_ok}/{len(fixed_names)}")
    else:
        ok_all &= gate(False, "11 fixed famous names", "ner.py missing")

    # ---- 门槛 12：长文档（强负样本 + 1~4 个 PII）----
    longdoc_path = DATA / "longdoc.jsonl"
    if ner_decode is not None and longdoc_path.exists():
        rows = [json.loads(l) for l in longdoc_path.read_text(encoding="utf-8").splitlines()
                if l.strip()]
        tp = fp = fn = 0
        fp_spans = 0
        total_bytes = 0
        for r in rows:
            b = r["text"].encode("utf-8")
            total_bytes += len(b)
            gold = {(9 if y == 1 else 10, s, ln) for s, ln, y in r["spans"] if y in (1, 2)}
            pred = set(ner_decode(b))
            tp += len(gold & pred)
            extra = len(pred - gold)
            fp += extra
            fp_spans += extra
            fn += len(gold - pred)
        p = tp / (tp + fp) if tp + fp else 0.0
        rcl = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * p * rcl / (p + rcl) if p + rcl else 0.0
        fp100 = fp_spans * 100 / max(total_bytes, 1)
        ok_all &= gate(len(rows) >= 200 and p >= 0.9 and rcl >= 0.9 and f1 >= 0.9,
                       "12a longdoc span", f"P/R/F1 {p:.3f}/{rcl:.3f}/{f1:.3f} ({len(rows)} docs)")
        ok_all &= gate(fp100 <= 0.10, "12b longdoc fp/100B",
                       f"{fp100:.3f} <= 0.10 ({fp_spans} FP / {total_bytes} B)")
    else:
        ok_all &= gate(False, "12 longdoc", f"{longdoc_path} missing")

    print("\n" + ("全部通过，可以接 RTL。" if ok_all else "有门槛没过，先别接 RTL。"))
    return 0 if ok_all else 2


if __name__ == "__main__":
    raise SystemExit(main())