"""NER 金标的四条断言（docs/ubuntu-ner.md 第 6 节 1/3/4/6）。

  1. 指标：eval.json 的 heldout / hard 门槛；
  2. 一致性：numpy 整数推理 == ONNX(Runtime) argmax，500 例逐 token 相同（gate 3）；
  3. 向量：build/ner_vectors 200 例，host/golden/ner.py 全对（gate 6）；
  4. 尺寸：params <= 60k、int8 <= 120 KB、MAC/window <= 4M（gate 4）。

另附：weights_int8.npz 的 sha256 必须和 eval.json 一致（gate 5 的交付完整性；
"同 seed 两次训练 hash 相同" 用 tools/train_ner.py 复跑验证，见 models/ner/README.md）。
"""

from __future__ import annotations

import hashlib
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.ner import NerModel  # noqa: E402

MODEL = ROOT / "models" / "ner"
VEC = ROOT / "build" / "ner_vectors"
DATA = ROOT / "data" / "ner"


def _json(name: str) -> dict:
    return json.loads((MODEL / name).read_text(encoding="utf-8"))


class TestNerGolden(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.eval = _json("eval.json")
        cls.model = NerModel(MODEL)
        # 向量缺失时自动生成，保证 fresh clone 跑 make test 也能过
        if not (VEC.exists() and len(list(VEC.glob("case_*.in"))) >= 200):
            import subprocess

            subprocess.run([sys.executable, str(ROOT / "tools" / "gen_ner_vectors.py"),
                            "--data", str(DATA), "--out", str(VEC), "--n", "200"],
                           check=True)

    # ---------------------------------------------------------------- 1 指标
    def test_1_metrics(self) -> None:
        h = self.eval["heldout"]
        self.assertGreaterEqual(h["span_f1"], 0.92, h)
        self.assertGreaterEqual(h["span_precision"], 0.95, h)
        self.assertGreaterEqual(h["span_recall"], 0.88, h)
        a = self.eval["hard"]
        self.assertGreaterEqual(a["span_recall"], 0.75, a)
        self.assertGreaterEqual(a["span_f1"], 0.80, a)

    # ---------------------------------------------------------------- 3 ONNX
    def test_2_numpy_matches_onnx(self) -> None:
        try:
            import onnxruntime  # noqa: F401
        except ImportError as exc:  # pragma: no cover
            self.fail(f"onnxruntime not installed (docs/ubuntu-ner.md 0): {exc}")
        sys.path.insert(0, str(ROOT / "tools"))
        import ner_onnx  # noqa: E402

        rows = [json.loads(l) for l in (DATA / "heldout.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
        texts = [r["text"] for r in rows[:500]]
        self.assertGreaterEqual(len(texts), 500)
        onnx_path = ROOT / "build" / "ner" / "test_model.onnx"
        bad, n = ner_onnx.check_parity(MODEL, texts, limit=500, onnx_path=onnx_path)
        self.assertEqual(bad, 0, f"{bad}/{n} ONNX/numpy argmax mismatches")
        self.assertEqual(n, 500)

    # ---------------------------------------------------------------- 6 向量
    def test_3_vectors(self) -> None:
        cases = sorted(VEC.glob("case_*.in"))
        self.assertGreaterEqual(len(cases), 200)
        bad = []
        for p in cases:
            want = set()
            exp = p.with_suffix(".exp")
            for line in exp.read_text(encoding="utf-8").splitlines():
                f = line.split()
                if len(f) == 3:
                    want.add((int(f[2]), int(f[0]), int(f[1])))   # (type,start,len)
            got = set(self.model.decode(p.read_bytes()))
            if got != want:
                bad.append((p.name, sorted(want), sorted(got)))
        self.assertEqual(bad, [], f"{len(bad)} vector mismatches, first: {bad[:3]}")

    # ---------------------------------------------------------------- 4 尺寸
    def test_4_size(self) -> None:
        s = self.eval["size"]
        self.assertLessEqual(s["params"], 60_000, s)
        self.assertLessEqual(s["int8_bytes"], 120 * 1024, s)
        self.assertLessEqual(s["macs_per_window"], 4_000_000, s)
        # 实际 npz 也不能超过 120 KB
        self.assertLessEqual((MODEL / "weights_int8.npz").stat().st_size, 120 * 1024)

    # ---------------------------------------------------------------- 5 权重哈希
    def test_5_weights_sha256(self) -> None:
        got = hashlib.sha256((MODEL / "weights_int8.npz").read_bytes()).hexdigest()
        self.assertEqual(got, self.eval["checksums"]["weights_sha256"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
