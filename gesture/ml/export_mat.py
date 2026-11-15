"""ScreenSense - export a trained MundusDet to hardware .mat files.

Writes one .mat per layer with the fields the Pango generator reads:
    weight (Cout,Cin,Kh,Kw) int32, bias (Cout,) int32, shift_k float,
    input  (1,Cin,H,W) int32, output (1,Cout,H,W) int32   <- bit-exact pair.

Quantisation is symmetric per layer (weights scaled into 9-bit signed).  The
requantisation shift is a power of two chosen from the calibration peak.  Pass
--calib-dir to calibrate on real frames instead of one random image; that is
what the gesture pipeline does, because a random image underestimates the
activations of a real hand.
"""

import argparse
import csv
import glob
import os
import random

import numpy as np
import torch
import torch.nn.functional as F
import scipy.io as sio

from model_template import MundusDet


# (mat index, attribute, kernel, stride, has_relu)
LAYERS = [
    (0,  'l0',  3, 2, True),  (1,  'l1',  3, 2, True),
    (2,  'l2',  3, 2, True),  (3,  'l3',  3, 2, True),
    (4,  'l4',  3, 1, True),  (5,  'l5',  3, 1, True),
    (6,  'l6',  3, 1, True),  (7,  'l7',  1, 1, False),
    (8,  'l8',  3, 1, True),  (9,  'l9',  3, 1, True),
    (10, 'l10', 1, 1, False),
]

# which layer output feeds each layer (the 80x45 branch leaves l4)
SRC = {0: 'in', 1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 6,
       8: 4, 9: 8, 10: 9}

FRAME_W, FRAME_H = 1280, 720
IMAGE_EXT = ('.png', '.jpg', '.jpeg', '.bmp')


def mat_names(i):
    conv = 'node_conv2d' if i == 0 else f'node_conv2d_{i}'
    if i in (7, 10):
        relu = None
    elif i == 0:
        relu = 'node_relu'
    elif i <= 6:
        relu = f'node_relu_{i}'
    else:
        relu = f'node_relu_{i - 1}'      # the generator's L8/L9 naming
    return conv, relu


def int_conv(x, w, b, stride, pad):
    """Exact integer convolution via float64 (all values are small integers)."""
    xt = torch.from_numpy(x.astype(np.float64))[None]
    wt = torch.from_numpy(w.astype(np.float64))
    bt = torch.from_numpy(b.astype(np.float64))
    y = F.conv2d(xt, wt, bt, stride=stride, padding=pad)
    return y[0].round().to(torch.int64).numpy()


def quantise_weights(w, b, c_in: float = 1.0):
    """Quantise one layer.

    c_in is the accumulated activation scale: the integer input of this layer
    is c_in times the float activation.  Scaling the bias by c_in keeps the
    integer network a scalar multiple of the float network; without it the
    bias term drifts layer by layer and can dominate the final argmax.
    """
    amax = float(np.abs(w).max())
    scale = (amax / 255.0) if amax > 0 else 1.0
    wq = np.clip(np.round(w / scale), -256, 255).astype(np.int32)
    bq = np.clip(np.round(b * c_in / scale), -(2**22), 2**22 - 1).astype(np.int64)
    return wq, bq, scale


def pick_shift(peak, ceiling=127):
    """Smallest shift that keeps the calibration peak inside int8."""
    shift = 0
    while (int(peak) >> shift) > ceiling:
        shift += 1
    return shift


def requantise(acc, shift, relu):
    """Match output_layer.sv: arithmetic shift, then add the rounding bit."""
    if shift > 0:
        acc = (acc >> shift) + ((acc >> (shift - 1)) & 1)
    out = np.clip(acc, -128, 127).astype(np.int32)
    if relu:
        out = np.maximum(out, 0)
    return out


def quantise(w, b, x, stride, kernel, relu, ceiling=127, c_in: float = 1.0):
    """Single-image helper (keeps the corrected bias scaling)."""
    wq, bq, _ = quantise_weights(w, b, c_in)
    acc = int_conv(x, wq, bq, stride, kernel // 2)
    shift = pick_shift(np.abs(acc).max(), ceiling)
    return wq, bq.astype(np.int32), shift, requantise(acc, shift, relu)


def _letterbox_rgb(bgr):
    import cv2
    h, w = bgr.shape[:2]
    if (w, h) == (FRAME_W, FRAME_H):
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    scale = min(FRAME_W / w, FRAME_H / h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    small = cv2.resize(bgr, (nw, nh), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((FRAME_H, FRAME_W, 3), np.uint8)
    y0, x0 = (FRAME_H - nh) // 2, (FRAME_W - nw) // 2
    canvas[y0:y0 + nh, x0:x0 + nw] = small
    return cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)


def pick_calibration_files(directory, count, seed=0):
    """Prefer balanced classes when a labels.csv is present."""
    import cv2
    rng = random.Random(seed)
    labels = os.path.join(directory, 'labels.csv')
    files = []
    if os.path.exists(labels):
        by_cls = {}
        with open(labels, encoding='utf-8', newline='') as f:
            for row in csv.DictReader(f):
                p = os.path.join(directory, row['file'])
                if os.path.exists(p):
                    by_cls.setdefault(int(row['cls']), []).append(p)
        classes = sorted(by_cls)
        while len(files) < count and any(by_cls.values()):
            for c in classes:
                if by_cls[c] and len(files) < count:
                    files.append(by_cls[c].pop(rng.randrange(len(by_cls[c]))))
    else:
        files = [p for e in IMAGE_EXT for p in glob.glob(os.path.join(directory, '*' + e))]
        rng.shuffle(files)
        files = files[:count]
    out = []
    for p in files:
        bgr = cv2.imread(p)
        if bgr is not None:
            rgb = _letterbox_rgb(bgr)                 # H,W,3 uint8
            out.append(rgb.transpose(2, 0, 1).astype(np.int32) - 128)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ckpt', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--classes', type=int, default=4)
    ap.add_argument('--calib', default=None, help='optional .npy (3,720,1280) uint8')
    ap.add_argument('--calib-dir', default=None, help='directory of frames for calibration')
    ap.add_argument('--calib-count', type=int, default=8)
    ap.add_argument('--calib-seed', type=int, default=0)
    ap.add_argument('--shift-ceiling', type=int, default=127,
                    help='max representable magnitude after the shift (127 = no clipping)')
    ap.add_argument('--bias-mode', choices=['corrected', 'legacy'], default='corrected',
                    help='corrected scales each bias by the accumulated activation scale')
    ap.add_argument('--input-scale', type=float, default=128.0,
                    help='training input scale: q0 = round(x_norm * input-scale)')
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    net = MundusDet(num_classes=args.classes)
    state = torch.load(args.ckpt, map_location='cpu')
    if isinstance(state, dict) and 'model' in state:
        state = state['model']
    net.load_state_dict(state)
    net.eval()

    ref_imgs = []
    if args.calib:
        ref_imgs.append(np.load(args.calib).astype(np.int32) - 128)
    if args.calib_dir:
        ref_imgs.extend(pick_calibration_files(args.calib_dir, args.calib_count, args.calib_seed))
    if not ref_imgs:
        rng = np.random.default_rng(0)
        ref_imgs.append(rng.integers(0, 256, size=(3, FRAME_H, FRAME_W)).astype(np.int32) - 128)
    print(f'calibration frames: {len(ref_imgs)}')

    inputs = {'in': ref_imgs}
    corrected = args.bias_mode == 'corrected'
    c_in = float(args.input_scale) if corrected else 1.0
    for idx, attr, k, stride, relu in LAYERS:
        conv_name, relu_name = mat_names(idx)
        xs = inputs[SRC[idx]]
        layer = getattr(net, attr)
        w = layer.weight.detach().numpy()
        b = layer.bias.detach().numpy()

        wq, bq, scale = quantise_weights(w, b, c_in)
        accs = [int_conv(x, wq, bq, stride, k // 2) for x in xs]
        peak = max(int(np.abs(a).max()) for a in accs)
        shift = pick_shift(peak, args.shift_ceiling)
        outs = [requantise(a, shift, relu) for a in accs]
        clipped = max(float(np.mean(np.abs(a >> shift) > 127)) for a in accs)
        inputs[idx] = outs
        if corrected:
            c_in = c_in / (scale * (2 ** shift))

        sio.savemat(os.path.join(args.out, conv_name + '.mat'), {
            'weight': wq,
            'bias': bq.astype(np.int32),
            'shift_k': float(shift),
            'input': xs[0][None].astype(np.int32),
            'output': outs[0][None].astype(np.int32),
        })
        if relu_name:
            sio.savemat(os.path.join(args.out, relu_name + '.mat'), {'shift_k': float(shift)})

        print(f'{conv_name:16s} {tuple(wq.shape)} stride={stride} peak={peak:>8d} '
              f'shift={shift} clip={clipped * 100:.2f}% '
              f'bias_max={int(np.abs(bq).max())} out={outs[0].shape}')

    print('done ->', args.out)


if __name__ == '__main__':
    main()
