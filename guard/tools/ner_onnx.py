"""把量化模型导出成 ONNX（整数算子），并与 numpy 金标逐 token 比对。

ONNX 图刻意只用整数算子复刻 docs/ubuntu-ner.md 4.2 的配方：

    Gather(emb_w) -> Transpose -> ConvInteger(k=3,pad=1) -> +bias(int32)
      -> Cast(float32) -> Mul(mul) -> Round -> Cast(int32) -> Clip(0,127) -> Cast(int8)
      -> ConvInteger(k=3,pad=1) -> ... -> ConvInteger(1x1) -> +bias -> ArgMax

这样 ORT 的 argmax 与 host/golden/ner.py 的结果可以做到逐 token 相同（gate 3）。
本文件只在训练/测试里用；ner.py 不 import 它。
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.ner import NerModel  # noqa: E402


def _init(name: str, arr: np.ndarray):
    return numpy_helper.from_array(np.ascontiguousarray(arr), name)


def build_model(model_dir: str | Path) -> onnx.ModelProto:
    d = Path(model_dir)
    cfg = json.loads((d / "config.json").read_text(encoding="utf-8"))
    quant = json.loads((d / "quant.json").read_text(encoding="utf-8"))
    w = np.load(d / "weights_int8.npz")

    window = int(cfg.get("window", 64))
    emb = w["emb_w"].astype(np.int8)                    # [V,32]
    c1 = w["conv1_w"].astype(np.int8)                   # [O,K,I]
    b1 = w["conv1_b"].astype(np.int32)
    c2 = w["conv2_w"].astype(np.int8)
    b2 = w["conv2_b"].astype(np.int32)
    hw = w["head_w"].astype(np.int8)                    # [3,32]
    hb = w["head_b"].astype(np.int32)

    mul1 = np.float32(quant["requant"]["conv1"]["mul"])
    zp1 = np.int32(quant["requant"]["conv1"]["zp"])
    mul2 = np.float32(quant["requant"]["conv2"]["mul"])
    zp2 = np.int32(quant["requant"]["conv2"]["zp"])

    # ONNX Conv 权重布局 [M, C, kH, kW]；npz 是 [out, kernel, in]
    c1_onnx = np.transpose(c1, (0, 2, 1))          # [O, C, K]，1D 卷积
    c2_onnx = np.transpose(c2, (0, 2, 1))
    hw_onnx = hw[:, :, None]                         # [3, 32, 1]

    inits = [
        _init("emb_w", emb),
        _init("c1_w", c1_onnx), _init("c1_b", b1.reshape(1, -1, 1)),
        _init("c2_w", c2_onnx), _init("c2_b", b2.reshape(1, -1, 1)),
        _init("hw", hw_onnx), _init("hb", hb.reshape(1, -1, 1)),
        _init("mul1", np.array(mul1, dtype=np.float32)),
        _init("mul2", np.array(mul2, dtype=np.float32)),
        _init("zp1", np.array(zp1, dtype=np.int32)),
        _init("zp2", np.array(zp2, dtype=np.int32)),
        _init("cmin", np.array(0, dtype=np.int32)),
        _init("cmax", np.array(127, dtype=np.int32)),
    ]

    nodes = [
        helper.make_node("Gather", ["emb_w", "ids"], ["x8"], axis=0),
        helper.make_node("Transpose", ["x8"], ["xt"], perm=[0, 2, 1]),

        helper.make_node("ConvInteger", ["xt", "c1_w"], ["c1_acc"], pads=[1, 1]),
        helper.make_node("Add", ["c1_acc", "c1_b"], ["c1_out"]),
        helper.make_node("Cast", ["c1_out"], ["c1_f"], to=TensorProto.FLOAT),
        helper.make_node("Mul", ["c1_f", "mul1"], ["c1_m"]),
        helper.make_node("Round", ["c1_m"], ["c1_r"]),
        helper.make_node("Cast", ["c1_r"], ["c1_i"], to=TensorProto.INT32),
        helper.make_node("Add", ["c1_i", "zp1"], ["c1_z"]),
        helper.make_node("Clip", ["c1_z", "cmin", "cmax"], ["c1_clip"]),
        helper.make_node("Cast", ["c1_clip"], ["h1"], to=TensorProto.INT8),

        helper.make_node("ConvInteger", ["h1", "c2_w"], ["c2_acc"], pads=[1, 1]),
        helper.make_node("Add", ["c2_acc", "c2_b"], ["c2_out"]),
        helper.make_node("Cast", ["c2_out"], ["c2_f"], to=TensorProto.FLOAT),
        helper.make_node("Mul", ["c2_f", "mul2"], ["c2_m"]),
        helper.make_node("Round", ["c2_m"], ["c2_r"]),
        helper.make_node("Cast", ["c2_r"], ["c2_i"], to=TensorProto.INT32),
        helper.make_node("Add", ["c2_i", "zp2"], ["c2_z"]),
        helper.make_node("Clip", ["c2_z", "cmin", "cmax"], ["c2_clip"]),
        helper.make_node("Cast", ["c2_clip"], ["h2"], to=TensorProto.INT8),

        helper.make_node("ConvInteger", ["h2", "hw"], ["c3_acc"], pads=[0, 0]),
        helper.make_node("Add", ["c3_acc", "hb"], ["logits"]),          # int32 [1,3,64]
        helper.make_node("ArgMax", ["logits"], ["labels"], axis=1, keepdims=0,
                         select_last_index=0),
    ]

    graph = helper.make_graph(
        nodes, "guard_ner_int8",
        [helper.make_tensor_value_info("ids", TensorProto.INT64, [1, window])],
        [helper.make_tensor_value_info("labels", TensorProto.INT64, [1, window])],
        initializer=inits,
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 8
    model.producer_name = "guard-ner"
    onnx.checker.check_model(model)
    return model


def save_model(model_dir: str | Path, out_path: str | Path) -> Path:
    model = build_model(model_dir)
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, out)
    return out


def _ids(model: NerModel, text: str) -> np.ndarray:
    ids = model.tokenize(text)[: model.window]
    ids = ids + [model.pad_id] * (model.window - len(ids))
    return np.asarray([ids], dtype=np.int64)


def check_parity(model_dir: str | Path, texts, limit: int = 500,
                 onnx_path: str | Path | None = None) -> tuple[int, int]:
    """返回 (mismatch, compared)；逐 token argmax 必须完全一致。"""
    import onnxruntime as ort

    d = Path(model_dir)
    if onnx_path is None:
        tmp = tempfile.NamedTemporaryFile(suffix=".onnx", delete=False)
        tmp.close()
        onnx_path = tmp.name
        save_model(d, onnx_path)
    else:
        # 每次重建，避免旧图（权重不同）被复用
        save_model(d, onnx_path)
    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    nm = NerModel(d)
    bad = 0
    n = 0
    for text in texts:
        if n >= limit:
            break
        feed = _ids(nm, text)
        want = sess.run(None, {"ids": feed})[0].reshape(-1).astype(np.int64)
        got = nm.predict_ids(feed[0]).astype(np.int64)
        if not np.array_equal(want, got):
            bad += 1
        n += 1
    return bad, n


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    if args.out:
        print(save_model(args.model_dir, args.out))
    else:
        print("ok:", build_model(args.model_dir).graph.name)
