#!/usr/bin/env python3
"""Pack the 3-class gesture model into the miniTensor RPS image.

This is the RPS counterpart of ``tools/model/pack_weights.py``.  It consumes
``checkpoints/gesture3.npz`` (float weights from ``train_gesture.py``) and
emits the two headers used by the AMP firmware:

    firmware/app/rps_weights.h
    firmware/app/rps_params.h

The packed format is exactly the one already consumed by ``mt_detect.c``:
four INT8 convolution layers, per-tensor symmetric quantisation, and the
integer reference images/golden used by ``ai selftest``.

The PC training pipeline quantises the camera patch as ``q = luma >> 1`` and
feeds ``q / 127`` to the model.  Therefore the packed input multiplier is 128,
not the 194 used by the older rock/paper/scissors image.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]       # app/gesture
H = W = 32
C_IN = 4
GRID = 8
CLASSES = ("idle", "defense", "point")
NUM_CLASSES = len(CLASSES)

LAYERS = [
    dict(h=32, w=32, c_in=4,  c_out=8,  k=3, pad=1, relu=1),
    dict(h=16, w=16, c_in=8,  c_out=16, k=3, pad=1, relu=1),
    dict(h=8,  w=8,  c_in=16, c_out=16, k=3, pad=1, relu=1),
    dict(h=8,  w=8,  c_in=16, c_out=8,  k=1, pad=0, relu=0),
]

MULT_MAX = 32767
SHIFT_MAX = 31


def quant(x, bits=8):
    m = float(np.max(np.abs(x)))
    if m < 1e-12:
        return np.zeros_like(x, dtype=np.int32), 1.0
    s = m / ((1 << (bits - 1)) - 1)
    return np.round(x / s).astype(np.int32), s


def conv_float(x, w, b, pad):
    h, ww, _ = x.shape
    k = w.shape[2]
    xp = np.pad(x, ((pad, pad), (pad, pad), (0, 0)))
    out = np.zeros((h, ww, w.shape[0]), dtype=np.float64)
    for ky in range(k):
        for kx in range(k):
            out += np.einsum("hwc,oc->hwo", xp[ky:ky + h, kx:kx + ww, :],
                             w[:, :, ky, kx])
    return out + b


def pool2(x):
    h, ww, c = x.shape
    return x.reshape(h // 2, 2, ww // 2, 2, c).max(axis=(1, 3))


def choose_nmt(L):
    ng, k, nm = L["c_in"] // 4, L["k"], L["c_out"] // 4
    ntiles = L["w"] // 4
    by_wt = 144 // (k * k * ng)
    by_c = 68 // (ntiles * 4)
    return max(1, min(nm, by_wt, by_c))


def to_rows(wq, L, mult, shift, bq, zp, relu, nmt):
    ng, nm, k = L["c_in"] // 4, L["c_out"] // 4, L["k"]
    ntap = ng * k * k
    ntile = (nm + nmt - 1) // nmt
    wt = np.zeros(ntile * ntap * nmt * 16, dtype=np.uint8)
    for ti in range(ntile):
        mg0 = ti * nmt
        for g in range(ng):
            for ky in range(k):
                for kx in range(k):
                    q = (g * k * k) + (ky * k) + kx
                    for j in range(min(nmt, nm - mg0)):
                        mg = mg0 + j
                        row = (ti * ntap * nmt) + (q * nmt) + j
                        for kk in range(4):
                            for jj in range(4):
                                ic = g * 4 + kk
                                oc = mg * 4 + jj
                                wt[row * 16 + 4 * kk + jj] = \
                                    np.uint8(wq[oc, ic, ky, kx] & 0xFF)
    bias = np.zeros(nm * 4 * 16, dtype=np.uint8)
    for mg in range(nm):
        for r in range(4):
            for j in range(4):
                v = np.int32(bq[mg * 4 + j])
                off = mg * 64 + r * 16 + j * 4
                bias[off:off + 4] = np.frombuffer(v.tobytes(), dtype=np.uint8)
    cfg = np.zeros(16, dtype=np.uint8)
    word = (int(mult) & 0xFFFF) | ((int(shift) & 0x1F) << 16) | \
           ((int(zp) & 0xFF) << 21) | ((1 if relu else 0) << 29)
    cfg[0:4] = np.frombuffer(np.uint32(word).tobytes(), dtype=np.uint8)
    cfg[4] = nmt & 0xFF
    return wt, bias, cfg


def signed8(x):
    return np.asarray(x).astype(np.uint8).view(np.int8).astype(np.int32)


def to_mem(a_hwc):
    h, w, c = a_hwc.shape
    ng = c // 4
    v = a_hwc.reshape(h, w, ng, 4).transpose(2, 0, 1, 3).reshape(-1)
    return (v & 0xFF).astype(np.uint8)


def from_mem(mem, h, w, c):
    ng = c // 4
    v = signed8(mem).reshape(ng, h, w, 4).transpose(1, 2, 0, 3).reshape(h, w, c)
    return v


def pool_mem(mem, h, w, c):
    ng = c // 4
    a = signed8(mem).reshape(ng, h, w, 4)
    a = a.reshape(ng, h // 2, 2, w // 2, 2, 4).max(axis=(2, 4))
    return (a.reshape(-1) & 0xFF).astype(np.uint8)


def pad_group(xq, L):
    xq = signed8(xq) if np.asarray(xq).dtype == np.uint8 else np.asarray(xq, np.int32)
    ng, k, pad = L["c_in"] // 4, L["k"], L["pad"]
    h, ww = L["h"], L["w"]
    ph = h + 2 * pad
    out = np.zeros((k, ng, ph, ww, 4), dtype=np.int32)
    for kx in range(k):
        for g in range(ng):
            for r in range(ph):
                for c in range(ww):
                    sh = r - pad
                    sw = c + kx - pad
                    if 0 <= sh < h and 0 <= sw < ww:
                        out[kx, g, r, c, :] = xq[sh, sw, g * 4:g * 4 + 4]
    return out


def int_forward(img_q, packed):
    mem = np.asarray(img_q, dtype=np.uint8)
    hh, ww, cc = H, W, C_IN
    for idx, L in enumerate(LAYERS):
        buf = pad_group(from_mem(mem, hh, ww, cc), L)
        ng, nm, k = L["c_in"] // 4, L["c_out"] // 4, L["k"]
        out = np.zeros((L["h"], L["w"], L["c_out"]), dtype=np.int32)
        wt = packed[idx]["wt"].reshape(-1, 16)
        for ky in range(k):
            for kx in range(k):
                for g in range(ng):
                    row = ((g * k * k) + (ky * k) + kx) * nm
                    for t in range(L["w"] // 4):
                        A = buf[kx, g, :, t * 4:t * 4 + 4, :]
                        for mg in range(nm):
                            Bs = signed8(wt[row + mg].reshape(4, 4))
                            for r in range(L["h"]):
                                arow = A[r + ky]
                                acc = arow.astype(np.int32) @ Bs.astype(np.int32)
                                out[r, t * 4:t * 4 + 4, mg * 4:mg * 4 + 4] += acc
        res = np.zeros_like(out)
        for mg in range(nm):
            bq = packed[idx]["bias_q"][mg * 4:mg * 4 + 4]
            mult = packed[idx]["mult"]
            shift = packed[idx]["shift"]
            zp = packed[idx]["zp"]
            relu = packed[idx]["relu"]
            v = (out[:, :, mg * 4:mg * 4 + 4].astype(np.int64) + bq[None, None, :]) \
                * np.int64(mult)
            v = v >> np.int64(shift)
            v = v + np.int64(zp)
            if relu:
                v = np.maximum(v, 0)
            res[:, :, mg * 4:mg * 4 + 4] = np.clip(v, -128, 127)
        mem = to_mem(res)
        hh, ww, cc = L["h"], L["w"], L["c_out"]
        if idx < 2:
            mem = pool_mem(mem, hh, ww, cc)
            hh, ww = hh // 2, ww // 2
    return mem


def read_patch(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        arr = np.asarray(im.convert("L"), dtype=np.uint8)
    if arr.shape != (H, W):
        raise ValueError(f"{path}: expected {H}x{W}, got {arr.shape}")
    return arr


def collect_patches(data_dir: Path):
    paths, labels = [], []
    for label_idx, label in enumerate(CLASSES):
        root = data_dir / label
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.png")):
            paths.append(path)
            labels.append(label_idx)
    if not paths:
        raise SystemExit(f"no PNGs under {data_dir}/idle, defense or point")
    return paths, np.asarray(labels, dtype=np.int64)


def calibration_set(paths, labels, limit):
    """Evenly sample, but keep all three classes represented."""
    if len(paths) <= limit:
        return np.arange(len(paths), dtype=np.int64)
    picked = []
    for cls in range(NUM_CLASSES):
        idx = np.flatnonzero(labels == cls)
        if len(idx):
            picked.append(int(idx[0]))
    rest = [i for i in np.linspace(0, len(paths) - 1, limit).astype(int)
            if int(i) not in picked]
    return np.asarray((picked + rest)[:limit], dtype=np.int64)


def float_scores(patch, conv_w, biases, head_w):
    q = (patch.astype(np.uint16) >> 1).astype(np.float32) / 127.0
    a = q[:, :, None].repeat(C_IN, axis=2)
    for li in range(3):
        a = conv_float(a, conv_w[li], biases[li], LAYERS[li]["pad"])
        if LAYERS[li]["relu"]:
            a = np.maximum(a, 0.0)
        if li < 2:
            a = pool2(a)
    o = conv_float(a, head_w, biases[3], 0)
    return [float(o[:, :, c].mean()) for c in range(NUM_CLASSES)]


def pick_images(paths, labels, conv_w, biases, head_w, count):
    """Pick high-margin, correctly-classified samples, point first.

    The first image is used by the AMP acceptance test (and by the packed
    selftest reconstruction), so it must be an unambiguous POINT sample.
    """
    per_class = []
    for cls in (2, 1, 0):
        idx = np.flatnonzero(labels == cls)
        if len(idx) == 0:
            raise SystemExit(f"no samples for class {CLASSES[cls]}")
        # Keep the picker cheap but representative.
        take = idx[np.linspace(0, len(idx) - 1, min(len(idx), 256)).astype(int)]
        scored = []
        for i in take:
            s = float_scores(read_patch(paths[int(i)]), conv_w, biases, head_w)
            pred = int(np.argmax(s))
            second = max(s[(pred + 1) % NUM_CLASSES], s[(pred + 2) % NUM_CLASSES])
            if pred == cls:
                scored.append((s[pred] - second, int(i)))
        scored.sort(reverse=True)
        if not scored:
            raise SystemExit(f"model cannot classify any {CLASSES[cls]} sample")
        per_class.append(scored)

    chosen = [per_class[0][0][1], per_class[1][0][1], per_class[2][0][1]]
    fill = sorted((x for group in per_class for x in group[1:]),
                  key=lambda t: t[0], reverse=True)
    for _, i in fill:
        if i not in chosen:
            chosen.append(i)
        if len(chosen) >= count:
            break
    return chosen[:count]


def input_images(paths, indices, s_in0):
    """Return [N,4096] images in the same [g][h][w][4] order as the RTL."""
    out = np.zeros((len(indices), H * W * C_IN), dtype=np.uint8)
    for n, i in enumerate(indices):
        patch = read_patch(paths[i])
        q = (patch.astype(np.uint16) >> 1).astype(np.float32) / 127.0
        flat = np.zeros(H * W * C_IN, dtype=np.float32)
        flat[0::4] = q.reshape(-1)
        flat[1::4] = q.reshape(-1)
        flat[2::4] = q.reshape(-1)
        # channel 3 stays zero, matching rps_forward()
        v = np.clip(np.round(flat / s_in0), -128, 127).astype(np.int32)
        out[n] = ((v & 0xFF).astype(np.uint8)).reshape(-1)
    return out


def carr(name, data):
    body = ",".join(str(int(v)) for v in np.asarray(data).reshape(-1))
    return "static const unsigned char %s[%d] = {%s};\n" % \
           (name, np.asarray(data).size, body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", type=Path,
                    default=ROOT / "tools/ml/checkpoints/gesture3.npz")
    ap.add_argument("--data", type=Path,
                    default=ROOT / "tools/ml/data")
    ap.add_argument("--calib-samples", type=int, default=256)
    ap.add_argument("--images", type=int, default=8)
    ap.add_argument("--out", type=Path,
                    default=ROOT / "firmware/app/rps_weights.h")
    args = ap.parse_args()

    d = np.load(args.checkpoint)
    w1, w2, w3 = d["w1"], d["w2"], d["w3"]
    wh, bh = d["wh"], d["bh"]
    conv_w = [w1, w2, w3]
    head_w = wh.reshape(8, 16, 1, 1)
    biases = [d["b1"], d["b2"], d["b3"], bh]
    classes = [str(x) for x in d["classes"]] if "classes" in d else list(CLASSES)
    if classes != list(CLASSES):
        raise SystemExit(f"checkpoint classes {classes} != {CLASSES}")
    input_mult = int(d["input_mult"]) if "input_mult" in d else 128

    paths, labels = collect_patches(args.data)
    cal_idx = calibration_set(paths, labels, max(1, args.calib_samples))
    print(f"calibration: {len(cal_idx)}/{len(paths)} patches")

    # Float activations for the calibration set.
    mx = [0.0, 0.0, 0.0, 0.0]
    for i in cal_idx:
        patch = read_patch(paths[i])
        q = (patch.astype(np.uint16) >> 1).astype(np.float32)
        a = (q / 127.0)[:, :, None].repeat(C_IN, axis=2)
        for li in range(3):
            L = LAYERS[li]
            a = conv_float(a, conv_w[li], biases[li], L["pad"])
            if L["relu"]:
                a = np.maximum(a, 0.0)
            mx[li] = max(mx[li], float(np.max(np.abs(a))))
            if li < 2:
                a = pool2(a)
        o = conv_float(a, head_w, bh, 0)
        mx[3] = max(mx[3], float(np.max(np.abs(o))))

    # The input is q/127 in [0,1]; calibrate from the data instead of assuming.
    mx0 = 1.0
    s_in = [mx0 / 127.0] + [m / 127.0 for m in mx]

    packed = []
    for li, L in enumerate(LAYERS):
        w = [w1, w2, w3, head_w][li]
        b = biases[li]
        wq, s_w = quant(w)
        s_x_in, s_x_out = s_in[li], s_in[li + 1]
        ratio = s_x_in * s_w / s_x_out
        shift = 0
        while shift < SHIFT_MAX and ratio * (1 << (shift + 1)) <= MULT_MAX:
            shift += 1
        mult = int(round(ratio * (1 << shift)))
        mult = max(1, min(MULT_MAX, mult))
        bq = np.round(b / (s_x_in * s_w)).astype(np.int32)
        nmt = choose_nmt(L)
        wt, bias, cfg = to_rows(wq, L, mult, shift, bq, 0, L["relu"], nmt)
        packed.append(dict(wt=wt, bias=bias, cfg=cfg, bias_q=bq, nmt=nmt,
                           mult=mult, shift=shift, zp=0, relu=L["relu"]))
        print("L%d: s_in=%.5f s_w=%.5f s_out=%.5f -> mult=%d shift=%d nmt=%d"
              % (li + 1, s_x_in, s_w, s_x_out, mult, shift, nmt))

    # Test images: image 0 is the highest-margin POINT sample, because the
    # AMP acceptance test reconstructs that image and expects stable=2.
    chosen = pick_images(paths, labels, conv_w, biases, head_w, args.images)
    if len(chosen) < args.images:
        raise SystemExit("not enough correctly-classified samples to fill --images")

    imgs = input_images(paths, chosen, s_in[0])
    gold = np.zeros((len(chosen), GRID * GRID * 8), dtype=np.uint8)
    for i in range(len(chosen)):
        gold[i] = (int_forward(imgs[i], packed).reshape(-1) & 0xFF).astype(np.uint8)

    print("packed test images:")
    for i, src in enumerate(chosen):
        lane = gold[i].reshape(2, GRID, GRID, 4).astype(np.int8)
        scores = [int(lane[c // 4, :, :, c % 4].mean()) for c in range(NUM_CLASSES)]
        pred = int(np.argmax(scores))

        patch = read_patch(paths[src])
        q = (patch.astype(np.uint16) >> 1).astype(np.float32) / 127.0
        a = q[:, :, None].repeat(C_IN, axis=2)
        for li in range(3):
            a = conv_float(a, conv_w[li], biases[li], LAYERS[li]["pad"])
            if LAYERS[li]["relu"]:
                a = np.maximum(a, 0.0)
            if li < 2:
                a = pool2(a)
        o = conv_float(a, head_w, bh, 0)
        fs = [float(o[:, :, c].mean()) for c in range(NUM_CLASSES)]
        print("  %d: label=%-7s pred=%-7s scores=%s float=%s"
              % (i, CLASSES[int(labels[src])], CLASSES[pred], scores,
                 ["%.2f" % v for v in fs]))

    # Emit headers.
    out = args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", newline="\n") as f:
        f.write("/* Auto-generated by tools/ml/pack_rps.py -- do not edit. */\n")
        f.write("#ifndef RPS_WEIGHTS_H\n#define RPS_WEIGHTS_H\n\n")
        f.write("#define RPS_CLASSES %d\n" % NUM_CLASSES)
        f.write("#define RPS_IN_MULT %d\n" % input_mult)
        f.write("#define det_imgs rps_imgs\n")
        f.write("#define det_gold rps_gold\n\n")
        for li, p in enumerate(packed):
            f.write(carr("det_wt%d" % (li + 1), p["wt"]))
            f.write(carr("det_bias%d" % (li + 1), p["bias"]))
            f.write(carr("det_cfg%d" % (li + 1), p["cfg"]))
            f.write("\n")
        f.write(carr("rps_imgs", imgs))
        f.write("\n")
        f.write(carr("rps_gold", gold))
        f.write("\n#endif\n")

    params = out.parent / "rps_params.h"
    with open(params, "w", newline="\n") as f:
        f.write("/* Auto-generated by tools/ml/pack_rps.py -- do not edit. */\n")
        f.write("#ifndef RPS_PARAMS_H\n#define RPS_PARAMS_H\n\n")
        f.write("#define RPS_IN_MULT %d\n" % input_mult)
        f.write("#define RPS_CLASSES %d\n\n" % NUM_CLASSES)
        f.write("#endif\n")
    print("wrote", out)
    print("wrote", params)
    print("images:", [CLASSES[int(labels[i])] for i in chosen])


if __name__ == "__main__":
    main()
