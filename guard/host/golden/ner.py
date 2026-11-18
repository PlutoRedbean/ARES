"""字符级 人名/地址 的**纯 numpy 整数推理**（交付金标）。

严格按 docs/ubuntu-ner.md 4.2 的配方：

    x        = emb_w[ids]
    h1[i][o] = requant(sum conv1_w[o][k][ci]*x[i+k-1][ci], mul1, zp1)
    h1       = clamp(h1, 0, 127)
    h2[i][o] = requant(sum conv2_w[o][k][ci]*h1[i+k-1][ci], mul2, zp2)
    h2       = clamp(h2, 0, 127)
    logit[c][i] = sum head_w[c][o]*h2[i][o] + head_b[c]     # int32, 不重量化
    label[i]    = argmax_c logit[c][i]                      # 并列取小 c

约束：本文件只用 numpy 与标准库，不依赖任何深度学习/神经网络推理框架。
窗口是 64 **字节**（UTF-8 字符对齐切）；ids 最多 64 个 token（ASCII 最坏情况），
不足补 <pad>=0。所有卷积累加都是 int32，激活是 int8、每层非对称 scale/zp。
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

WINDOW = 64
PAD_ID = 0
UNK_ID = 1
LABELS = ("none", "name", "addr")
NONE, NAME, ADDR = 0, 1, 2

# span 至少 2 个字符（1 个字符的命中在实测里全是噪声）
MIN_SPAN_CHARS = 2

# 模型内部的 0/1/2 标签 <-> 整条流水线用的 span type（和 l2_entity / pii_rules 一致）
TYPE_OF_LABEL = {NAME: 9, ADDR: 10}

DEFAULT_MODEL = Path(__file__).resolve().parents[2] / "models" / "ner"


def _load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


class NerModel:
    """整数量化模型。只依赖 weights_int8.npz / vocab.json / quant.json / config.json。"""

    def __init__(self, model_dir: str | Path | None = None) -> None:
        self.dir = Path(model_dir) if model_dir is not None else DEFAULT_MODEL
        cfg = _load_json(self.dir / "config.json")
        vocab = _load_json(self.dir / "vocab.json")
        quant = _load_json(self.dir / "quant.json")
        w = np.load(self.dir / "weights_int8.npz")

        # 窗口按 **UTF-8 字节** 计（64B），字符对齐切；ids 最多 64 个 token（ASCII 最坏情况）
        self.window = int(cfg.get("window_bytes", cfg.get("window", WINDOW)))
        self.tokens: list[str] = list(vocab["tokens"])
        self.stoi = {t: i for i, t in enumerate(self.tokens)}
        self.pad_id = int(cfg.get("padding_id", PAD_ID))
        self.unk_id = int(cfg.get("unk_id", UNK_ID))

        self.emb_w = w["emb_w"].astype(np.int32)          # [V, 32]
        self.conv1_w = w["conv1_w"].astype(np.int32)      # [32, 3, 32]
        self.conv1_b = w["conv1_b"].astype(np.int32)      # [32]
        self.conv2_w = w["conv2_w"].astype(np.int32)      # [32, 3, 32]
        self.conv2_b = w["conv2_b"].astype(np.int32)      # [32]
        self.head_w = w["head_w"].astype(np.int32)        # [3, 32]
        self.head_b = w["head_b"].astype(np.int32)        # [3]

        rq = quant["requant"]
        self.mul1 = np.float32(rq["conv1"]["mul"])
        self.zp1 = int(rq["conv1"]["zp"])
        self.mul2 = np.float32(rq["conv2"]["mul"])
        self.zp2 = int(rq["conv2"]["zp"])

        self.classes = int(cfg.get("num_classes", 3))

    # ------------------------------------------------------------------ tokenizer
    def tokenize(self, text: str) -> list[int]:
        """按字符（UTF-8 3 字节对齐）切；ASCII 每字符 1 项。"""
        return [self.stoi.get(ch, self.unk_id) for ch in text]

    # ------------------------------------------------------------------ int ops
    @staticmethod
    def _conv1d(x: np.ndarray, w: np.ndarray, b: np.ndarray) -> np.ndarray:
        """x [L,C] int32, w [O,K,C] int32, b [O] -> acc [L,O] int32，padding=1 补 0。"""
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

    @staticmethod
    def _requant(acc: np.ndarray, mul: np.float32, zp: int) -> np.ndarray:
        # 与整数参考实现逐位一致：float32 乘 + 四舍六入五成双（round-half-even）
        f = acc.astype(np.float32) * mul
        q = np.rint(f).astype(np.int32) + np.int32(zp)
        return np.clip(q, 0, 127).astype(np.int32)

    def forward(self, ids: list[int] | np.ndarray) -> np.ndarray:
        """ids[64] -> logits[64,3] int32。"""
        ids = np.asarray(ids, dtype=np.int64)
        if ids.shape[0] < self.window:
            pad = np.full(self.window - ids.shape[0], self.pad_id, dtype=np.int64)
            ids = np.concatenate([ids, pad])
        elif ids.shape[0] > self.window:
            ids = ids[:self.window]
        x = self.emb_w[ids]                                # [64,32] int32
        acc1 = self._conv1d(x, self.conv1_w, self.conv1_b)
        h1 = self._requant(acc1, self.mul1, self.zp1)
        acc2 = self._conv1d(h1, self.conv2_w, self.conv2_b)
        h2 = self._requant(acc2, self.mul2, self.zp2)
        logits = h2 @ self.head_w.T + self.head_b         # [64,3] int32
        return logits

    def predict_ids(self, ids: list[int] | np.ndarray) -> np.ndarray:
        logits = self.forward(ids)
        return np.argmax(logits, axis=1).astype(np.int32)  # 并列取小 id

    # ------------------------------------------------------------------ spans
    def decode_chars(self, text: str) -> list[tuple[int, int, int]]:
        """64 字节（字符对齐）滑窗，返回 (label, start_byte, len_byte)。"""
        chars = list(text)
        n = len(chars)
        if n == 0:
            return []
        byte_len = [len(ch.encode("utf-8")) for ch in chars]
        off = [0]
        for b in byte_len:
            off.append(off[-1] + b)
        ids_all = self.tokenize(text)
        labels = np.zeros(n, dtype=np.int32)
        i = 0
        while i < n:
            j = i
            nb = 0
            while j < n and nb + byte_len[j] <= self.window:
                nb += byte_len[j]
                j += 1
            if j == i:                      # 单字符比窗口还大（不会发生，防御）
                j = i + 1
            lab = self.predict_ids(ids_all[i:j])
            labels[i:j] = lab[: j - i]
            i = j
        spans: list[tuple[int, int, int]] = []
        i = 0
        while i < n:
            if labels[i] == NONE:
                i += 1
                continue
            j = i + 1
            while j < n and labels[j] == labels[i]:
                j += 1
            # 单个字符的 span 一律丢掉：实测里 `新`/`丰`/`王` 这类全是噪声，
            # 真正的人名/地址至少 2 个字符（复姓 2 字也算在 span 里）。
            if (j - i) >= MIN_SPAN_CHARS:
                spans.append((int(labels[i]), off[i], off[j] - off[i]))
            i = j
        return spans

    def decode(self, data: bytes) -> list[tuple[int, int, int]]:
        """bytes -> [(type, start_byte, len_byte)]；type 9=name, 10=addr（与 l2_entity 一致）。"""
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = data.decode("utf-8", "replace")
        return [(TYPE_OF_LABEL[lab], s, ln) for lab, s, ln in self.decode_chars(text)]


_DEFAULT: NerModel | None = None


def load(model_dir: str | Path | None = None) -> NerModel:
    return NerModel(model_dir)


def decode(data: bytes, model_dir: str | Path | None = None) -> list[tuple[int, int, int]]:
    """check_ner.py 的入口：返回 (type, start, len) 三元组列表。"""
    global _DEFAULT
    if model_dir is not None:
        return NerModel(model_dir).decode(data)
    if _DEFAULT is None:
        _DEFAULT = NerModel()
    return _DEFAULT.decode(data)


def predict_text(text: str, model_dir: str | Path | None = None) -> list[tuple[int, int, int]]:
    return NerModel(model_dir).decode_chars(text)