#!/usr/bin/env python3
"""训练字符级 人名/地址 模型并量化到 INT8。

    python3 tools/train_ner.py --data data/ner --out models/ner --seed 20261118

产物（docs/ubuntu-ner.md 第 2/4/5 节）：
    config.json  vocab.json  weights_int8.npz  quant.json  eval.json

流程：
  1. 只用 train.jsonl 建词表（<=1600 项）并训练 float 模型
     （Embedding(32) + 2xConv1d(k=3,32->32,ReLU) + Conv1d(1x1,32->3)）；
  2. 权重 per-tensor INT8 对称（zp=0），bias 折到 INT32；
  3. 用训练集校准 h1/h2 的激活 scale，重量化乘子 mul=(w_scale*a_in)/a_out；
  4. 用 host/golden/ner.py 的**整数推理**在 heldout/hard 上算 span P/R/F1，
     写 eval.json（指标是真算的，不是填的）；
  5. 导出 ONNX 整数图，逐 token 比对 numpy 与 ONNXRuntime 的 argmax（500 例）。

完全确定性：同 seed 两次训练 weights_int8.npz 的 sha256 相同。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import ner_onnx  # noqa: E402
from host.golden.ner import ADDR, NAME, PAD_ID, UNK_ID, NerModel  # noqa: E402

WINDOW = 64
MAX_VOCAB = 1600
EMB = 32
CH = 32
CLASSES = 3


# --------------------------------------------------------------------------- 数据
def load_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def build_vocab(rows: list[dict], max_vocab: int = MAX_VOCAB) -> list[str]:
    cnt: Counter[str] = Counter()
    for r in rows:
        cnt.update(r["text"])
    chars = sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))
    tokens = ["<pad>", "<unk>"] + [c for c, _ in chars[: max_vocab - 2]]
    return tokens


def encode(rows: list[dict], stoi: dict[str, int]) -> tuple[np.ndarray, np.ndarray]:
    n = len(rows)
    ids = np.zeros((n, WINDOW), dtype=np.int64)
    labels = np.full((n, WINDOW), -100, dtype=np.int64)
    for k, r in enumerate(rows):
        text = r["text"]
        if len(text) > WINDOW:
            text = text[:WINDOW]
        offs = [0]
        for ch in text:
            offs.append(offs[-1] + len(ch.encode("utf-8")))
        lab = [0] * len(text)
        for s, ln, y in r["spans"]:
            if y not in (NAME, ADDR):
                continue
            for i in range(len(text)):
                if offs[i] >= s and offs[i + 1] <= s + ln:
                    lab[i] = y
        ids[k, : len(text)] = [stoi.get(ch, UNK_ID) for ch in text]
        labels[k, : len(text)] = lab
    return ids, labels


# --------------------------------------------------------------------------- 模型
def make_model(vocab_size: int):
    import torch
    import torch.nn as nn

    class TinyNER(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.emb = nn.Embedding(vocab_size, EMB, padding_idx=PAD_ID)
            nn.init.normal_(self.emb.weight, mean=0.0, std=0.08)
            with torch.no_grad():
                self.emb.weight[PAD_ID].zero_()
            self.conv1 = nn.Conv1d(EMB, CH, 3, padding=1)
            self.conv2 = nn.Conv1d(CH, CH, 3, padding=1)
            self.head = nn.Conv1d(CH, CLASSES, 1)

        def forward(self, x):
            h = self.emb(x).transpose(1, 2)
            h = torch.relu(self.conv1(h))
            h = torch.relu(self.conv2(h))
            return self.head(h)

    return TinyNER()


def train(args, ids, labels, vocab_size: int):
    import torch
    import torch.nn.functional as F

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    torch.use_deterministic_algorithms(True)
    torch.backends.mkldnn.enabled = False
    g = torch.Generator()
    g.manual_seed(args.seed)

    model = make_model(vocab_size)
    X = torch.from_numpy(ids)
    Y = torch.from_numpy(labels)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    n = len(X)
    steps_per_epoch = max(1, (n + args.batch - 1) // args.batch)
    total = steps_per_epoch * args.epochs
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=max(total, 1), eta_min=args.lr * 0.05)
    weight = torch.tensor([1.0, args.w_name, args.w_addr], dtype=torch.float32)

    t0 = time.time()
    model.train()
    for ep in range(args.epochs):
        perm = torch.randperm(n, generator=g)
        tot_loss = 0.0
        nb = 0
        for b in range(0, n, args.batch):
            idx = perm[b:b + args.batch]
            logits = model(X[idx]).permute(0, 2, 1).reshape(-1, CLASSES)
            loss = F.cross_entropy(logits, Y[idx].reshape(-1), ignore_index=-100, weight=weight)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step()
            sched.step()
            tot_loss += float(loss.item())
            nb += 1
        if (ep + 1) % max(1, args.epochs // 4) == 0 or ep == 0:
            print(f"  epoch {ep + 1:2d}/{args.epochs}  loss={tot_loss / max(nb, 1):.4f}  "
                  f"lr={sched.get_last_lr()[0]:.2e}", flush=True)
    train_time = time.time() - t0
    model.eval()
    return model, train_time


# --------------------------------------------------------------------------- 量化
def quant_per_tensor(w: np.ndarray) -> tuple[np.ndarray, float]:
    w = np.asarray(w, dtype=np.float32)
    s = float(np.abs(w).max()) / 127.0
    if s <= 0.0:
        s = 1e-8
    q = np.clip(np.rint(w / s), -127, 127).astype(np.int8)
    return q, s


def requant(acc: np.ndarray, mul: float, zp: int = 0) -> np.ndarray:
    f = acc.astype(np.float32) * np.float32(mul)
    q = np.rint(f).astype(np.int32) + np.int32(zp)
    return np.clip(q, 0, 127).astype(np.int32)


def conv_acc(x: np.ndarray, w: np.ndarray, b: np.ndarray) -> np.ndarray:
    """x [B,L,C] int32, w [O,K,C] int32, b [O] -> [B,L,O] int32（padding=1）。"""
    B, L, C = x.shape
    O, K, _ = w.shape
    xp = np.zeros((B, L + K - 1, C), dtype=np.float32)
    off = K // 2
    xp[:, off:off + L, :] = x.astype(np.float32)
    wf = w.astype(np.float32)
    acc = np.zeros((B, L, O), dtype=np.float32)
    for k in range(K):
        acc += xp[:, k:k + L, :] @ wf[:, k, :].T
    return np.rint(acc).astype(np.int32) + b.reshape(1, 1, O)


def quantize_model(model, calib_ids: np.ndarray, args) -> dict:
    sd = {k: v.detach().cpu().numpy() for k, v in model.state_dict().items()}
    emb_w, s_emb = quant_per_tensor(sd["emb.weight"])
    c1 = np.transpose(sd["conv1.weight"], (0, 2, 1)).copy()   # [O,I,K] -> [O,K,I]
    c2 = np.transpose(sd["conv2.weight"], (0, 2, 1)).copy()
    c1q, s_c1 = quant_per_tensor(c1)
    c2q, s_c2 = quant_per_tensor(c2)
    hq, s_hw = quant_per_tensor(sd["head.weight"].reshape(CLASSES, CH))

    sx = s_emb
    b1i = np.rint(sd["conv1.bias"].astype(np.float64) / (s_c1 * sx)).astype(np.int32)

    # ---- 校准 h1
    calib_ids = calib_ids[: args.calib]
    x = emb_w.astype(np.int32)[calib_ids]                     # [B,64,32]
    acc1 = conv_acc(x, c1q.astype(np.int32), b1i)
    m1 = float(np.max(acc1)) * (s_c1 * sx)
    s_h1 = m1 / 127.0 if m1 > 0 else 1e-8
    mul1 = (s_c1 * sx) / s_h1
    h1 = requant(acc1, mul1, 0)

    b2i = np.rint(sd["conv2.bias"].astype(np.float64) / (s_c2 * s_h1)).astype(np.int32)
    acc2 = conv_acc(h1, c2q.astype(np.int32), b2i)
    m2 = float(np.max(acc2)) * (s_c2 * s_h1)
    s_h2 = m2 / 127.0 if m2 > 0 else 1e-8
    mul2 = (s_c2 * s_h1) / s_h2

    b3i = np.rint(sd["head.bias"].astype(np.float64) / (s_hw * s_h2)).astype(np.int32)

    return {
        "emb_w": emb_w,
        "conv1_w": c1q,
        "conv1_b": b1i,
        "conv2_w": c2q,
        "conv2_b": b2i,
        "head_w": hq,
        "head_b": b3i,
        "scales": {
            "emb_w": s_emb, "conv1_w": s_c1, "conv2_w": s_c2, "head_w": s_hw,
            "x": sx, "h1": s_h1, "h2": s_h2,
            "mul1": mul1, "mul2": mul2,
        },
        "zp": {"conv1": 0, "conv2": 0},
    }


# --------------------------------------------------------------------------- 指标
def spans_from_labels(text: str, labels: np.ndarray) -> set[tuple[int, int, int]]:
    offs = [0]
    for ch in text:
        offs.append(offs[-1] + len(ch.encode("utf-8")))
    out: set[tuple[int, int, int]] = set()
    i = 0
    n = len(text)
    while i < n:
        if labels[i] == 0:
            i += 1
            continue
        j = i + 1
        while j < n and labels[j] == labels[i]:
            j += 1
        out.add((int(labels[i]), offs[i], offs[j] - offs[i]))
        i = j
    return out


def prf(tp: int, fp: int, fn: int) -> dict:
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    return {"span_precision": round(p, 6), "span_recall": round(r, 6), "span_f1": round(f, 6)}


def eval_int8(model: NerModel, rows: list[dict], dump_fail: list | None = None,
              max_fail: int = 8) -> dict:
    tp = fp = fn = 0
    per = {NAME: [0, 0, 0], ADDR: [0, 0, 0]}
    for r in rows:
        text = r["text"]
        gold = {(y, s, ln) for s, ln, y in r["spans"] if y in (NAME, ADDR)}
        pred = set(model.decode_chars(text))
        tp += len(gold & pred)
        fp += len(pred - gold)
        fn += len(gold - pred)
        for y in (NAME, ADDR):
            g = {x for x in gold if x[0] == y}
            p = {x for x in pred if x[0] == y}
            per[y][0] += len(g & p)
            per[y][1] += len(p - g)
            per[y][2] += len(g - p)
        if dump_fail is not None and len(dump_fail) < max_fail and gold != pred:
            dump_fail.append({
                "text": text,
                "gold": sorted(gold),
                "pred": sorted(pred),
            })
    out = prf(tp, fp, fn)
    out["tp"], out["fp"], out["fn"] = tp, fp, fn
    out["per_label"] = {
        "name": prf(per[NAME][0], per[NAME][1], per[NAME][2]),
        "addr": prf(per[ADDR][0], per[ADDR][1], per[ADDR][2]),
    }
    return out


def eval_float(model, rows: list[dict], stoi: dict[str, int]) -> dict:
    import torch

    tp = fp = fn = 0
    X = []
    texts = []
    for r in rows:
        text = r["text"]
        ids = [stoi.get(c, UNK_ID) for c in text]
        ids = ids + [PAD_ID] * (WINDOW - len(ids))
        X.append(ids)
        texts.append(text)
    with torch.no_grad():
        logits = model(torch.tensor(X, dtype=torch.int64)).numpy()   # [N,3,64]
    for k, r in enumerate(rows):
        lab = logits[k].argmax(axis=0).astype(np.int32)[: len(texts[k])]
        pred = spans_from_labels(texts[k], lab)
        gold = {(y, s, ln) for s, ln, y in r["spans"] if y in (NAME, ADDR)}
        tp += len(gold & pred)
        fp += len(pred - gold)
        fn += len(gold - pred)
    return prf(tp, fp, fn)


# --------------------------------------------------------------------------- 主流程
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(ROOT / "data" / "ner"))
    ap.add_argument("--out", default=str(ROOT / "models" / "ner"))
    ap.add_argument("--seed", type=int, default=20261118)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=2.5e-3)
    ap.add_argument("--weight-decay", type=float, default=1e-4)
    ap.add_argument("--w-name", type=float, default=2.5)
    ap.add_argument("--w-addr", type=float, default=2.5)
    ap.add_argument("--calib", type=int, default=2000)
    ap.add_argument("--max-vocab", type=int, default=MAX_VOCAB)
    ap.add_argument("--parity", type=int, default=500)
    args = ap.parse_args()

    data = Path(args.data)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    train_rows = load_jsonl(data / "train.jsonl")
    held_rows = load_jsonl(data / "heldout.jsonl")
    hard_rows = load_jsonl(data / "hard.jsonl")
    print(f"data: train={len(train_rows)} heldout={len(held_rows)} hard={len(hard_rows)}")

    tokens = build_vocab(train_rows, args.max_vocab)
    stoi = {t: i for i, t in enumerate(tokens)}
    print(f"vocab: {len(tokens)} tokens (cap {args.max_vocab})")

    ids_tr, lab_tr = encode(train_rows, stoi)

    def oov(rows):
        n = sum(len(r["text"]) for r in rows)
        bad = sum(1 for r in rows for c in r["text"] if c not in stoi)
        return bad, n

    oh, nh = oov(held_rows)
    oa, na = oov(hard_rows)
    print(f"OOV chars: heldout {oh}/{nh}, hard {oa}/{na}")

    model, train_time = train(args, ids_tr, lab_tr, len(tokens))
    print(f"train time: {train_time:.1f}s")

    # 校准集：均匀抽样，确定性
    rng = np.random.default_rng(args.seed)
    cal_idx = rng.choice(len(ids_tr), size=min(args.calib, len(ids_tr)), replace=False)
    q = quantize_model(model, ids_tr[np.sort(cal_idx)], args)

    # ---- 写产物
    arrs = {
        "emb_w": q["emb_w"].astype(np.int8),
        "conv1_w": q["conv1_w"].astype(np.int8),
        "conv1_b": q["conv1_b"].astype(np.int32),
        "conv2_w": q["conv2_w"].astype(np.int8),
        "conv2_b": q["conv2_b"].astype(np.int32),
        "head_w": q["head_w"].astype(np.int8),
        "head_b": q["head_b"].astype(np.int32),
    }
    npz_path = out / "weights_int8.npz"
    np.savez_compressed(npz_path, **arrs)

    sc = q["scales"]
    quant = {
        "scheme": "weights per-tensor int8 symmetric (zp=0); activations int8 asymmetric; acc int32",
        "weights": {
            "emb_w": {"scale": sc["emb_w"], "zp": 0},
            "conv1_w": {"scale": sc["conv1_w"], "zp": 0},
            "conv2_w": {"scale": sc["conv2_w"], "zp": 0},
            "head_w": {"scale": sc["head_w"], "zp": 0},
        },
        "activations": {
            "x": {"scale": sc["x"], "zp": 0},
            "h1": {"scale": sc["h1"], "zp": q["zp"]["conv1"]},
            "h2": {"scale": sc["h2"], "zp": q["zp"]["conv2"]},
        },
        "requant": {
            "conv1": {"mul": sc["mul1"], "zp": q["zp"]["conv1"]},
            "conv2": {"mul": sc["mul2"], "zp": q["zp"]["conv2"]},
        },
        "head": {"scale": sc["head_w"] * sc["h2"], "zp": 0},
    }
    (out / "quant.json").write_text(json.dumps(quant, indent=2) + "\n", encoding="utf-8")
    (out / "vocab.json").write_text(json.dumps({"tokens": tokens, "size": len(tokens)},
                                               ensure_ascii=False) + "\n", encoding="utf-8")
    macs = WINDOW * (CH * 3 * EMB + CH * 3 * CH + CLASSES * CH)
    config = {
        "model": "guard-ner-char-v2",
        "window": WINDOW,             # 字节窗口（UTF-8 字符对齐切）
        "window_bytes": WINDOW,
        "window_tokens": WINDOW,      # ids[64] 上限
        "vocab_size": len(tokens),
        "emb_dim": EMB,
        "channels": CH,
        "num_classes": CLASSES,
        "kernel": 3,
        "padding_id": PAD_ID,
        "unk_id": UNK_ID,
        "labels": ["none", "name", "addr"],
        "macs_per_window": macs,
        "layout": {
            "conv1_w": "[out, kernel, in]",
            "conv2_w": "[out, kernel, in]",
            "head_w": "[out, in]",
        },
    }
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")

    # ---- 用交付的整数推理算指标
    nm = NerModel(out)
    hard_fails: list[dict] = []
    held = eval_int8(nm, held_rows)
    hard = eval_int8(nm, hard_rows, dump_fail=hard_fails)
    print("\nint8 heldout:", {k: held[k] for k in ("span_precision", "span_recall", "span_f1")},
          "tp/fp/fn", held["tp"], held["fp"], held["fn"])
    print("int8 hard   :", {k: hard[k] for k in ("span_precision", "span_recall", "span_f1")},
          "tp/fp/fn", hard["tp"], hard["fp"], hard["fn"])
    print("  heldout per-label:", held["per_label"])
    print("  hard    per-label:", hard["per_label"])
    fl_h = eval_float(model, held_rows, stoi)
    fl_a = eval_float(model, hard_rows, stoi)
    print(f"float heldout F1={fl_h['span_f1']:.4f}  hard F1={fl_a['span_f1']:.4f} "
          f"(quantization delta heldout {held['span_f1'] - fl_h['span_f1']:+.4f})")

    # ---- 尺寸
    params = int(sum(a.size for a in arrs.values()))
    int8_bytes = int(sum(a.nbytes for a in arrs.values()))
    print(f"size: params={params} int8_bytes={int8_bytes} macs/window={macs} "
          f"npz={npz_path.stat().st_size}B")

    # ---- ONNX 一致性（gate 3）
    onnx_path = ROOT / "build" / "ner" / "model.onnx"
    texts = [r["text"] for r in held_rows[: args.parity]]
    bad, ncmp = ner_onnx.check_parity(out, texts, limit=args.parity, onnx_path=onnx_path)
    print(f"ONNX parity: {ncmp - bad}/{ncmp} identical (mismatch {bad})")
    print(f"onnx: {onnx_path}")

    # ---- 可复现 checksum
    sha = hashlib.sha256(npz_path.read_bytes()).hexdigest()
    print(f"weights_sha256: {sha}")

    eval_obj = {
        "seed": args.seed,
        "data": {"train": len(train_rows), "heldout": len(held_rows), "hard": len(hard_rows)},
        "heldout": {k: held[k] for k in ("span_precision", "span_recall", "span_f1")},
        "hard": {k: hard[k] for k in ("span_precision", "span_recall", "span_f1")},
        "size": {"params": params, "int8_bytes": int8_bytes, "macs_per_window": macs},
        "checksums": {"weights_sha256": sha},
    }
    (out / "eval.json").write_text(json.dumps(eval_obj, indent=2) + "\n", encoding="utf-8")

    fails_path = ROOT / "build" / "ner" / "hard_failures.json"
    fails_path.parent.mkdir(parents=True, exist_ok=True)
    fails_path.write_text(json.dumps(hard_fails, ensure_ascii=False, indent=2) + "\n",
                          encoding="utf-8")
    if hard_fails:
        print("\ntypical hard failures:")
        for f in hard_fails:
            print("  -", f["text"], "gold", f["gold"], "pred", f["pred"])

    print(f"\nwrote {out}/eval.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
