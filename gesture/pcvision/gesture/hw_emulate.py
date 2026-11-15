"""Bit-exact emulator of the FPGA network.

Runs the same integer arithmetic as the RTL: int weight * int activation,
integer shift requantisation, ReLU, per-cell argmax.  Feeding it the .mat files
produced by export_mat.py gives the exact result the board will show, so a PC
preview is not an approximation.

The convolution is evaluated in float64: every product and partial sum is an
integer below 2**53, so the sums are exact while numpy can use BLAS.
"""

import os

import numpy as np
import scipy.io as sio

# grid geometry of the hardware
GRID_H, GRID_W = 45, 80
FRAME_W, FRAME_H = 1280, 720

# (mat name, kernel, stride, relu) in execution order
LAYERS = [
    ('node_conv2d',    3, 2, True),   # 0
    ('node_conv2d_1',  3, 2, True),   # 1
    ('node_conv2d_2',  3, 2, True),   # 2
    ('node_conv2d_3',  3, 2, True),   # 3
    ('node_conv2d_4',  3, 1, True),   # 4
    ('node_conv2d_5',  3, 1, True),   # 5
    ('node_conv2d_6',  3, 1, True),   # 6
    ('node_conv2d_7',  1, 1, False),  # 7   head A
    ('node_conv2d_8',  3, 1, True),   # 8   from layer 4
    ('node_conv2d_9',  3, 1, True),   # 9
    ('node_conv2d_10', 1, 1, False),  # 10  head B
]
SRC = {0: -1, 1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 6, 8: 4, 9: 8, 10: 9}


def _requantise(y, shift, relu):
    """output_layer.sv: arithmetic shift + rounding bit, then saturate/ReLU."""
    if shift > 0:
        y = (y >> shift) + ((y >> (shift - 1)) & 1)
    y = np.clip(y, -128, 127)
    if relu:
        y = np.maximum(y, 0)
    return y


def _conv(x, w, b, stride, k):
    """x: (Cin,H,W) int -> (Cout,H',W') int64, 'same' padding."""
    cin, h, wd = x.shape
    cout, kcin, kh, kw = w.shape
    assert kcin == cin and kh == k and kw == k
    pad = k // 2
    xp = np.pad(x.astype(np.float64), ((0, 0), (pad, pad), (pad, pad)), mode='constant')
    oh = (h + 2 * pad - k) // stride + 1
    ow = (wd + 2 * pad - k) // stride + 1
    out = np.zeros((cout, oh, ow), dtype=np.float64)
    wf = w.astype(np.float64)
    for i in range(k):
        for j in range(k):
            sl = xp[:, i:i + oh * stride:stride, j:j + ow * stride:stride]
            out += np.tensordot(wf[:, :, i, j], sl, axes=([1], [0]))
    out += b[:, None, None]
    return np.rint(out).astype(np.int64)


class HWModel:
    """Loads the packed .mat layers and evaluates them with integer maths."""

    def __init__(self, mat_dir):
        self.layers = {}
        for i, (name, k, s, relu) in enumerate(LAYERS):
            m = sio.loadmat(os.path.join(mat_dir, name + '.mat'))
            self.layers[i] = dict(
                w=np.asarray(m['weight'], dtype=np.int64),
                b=np.asarray(m['bias'], dtype=np.int64).reshape(-1),
                shift=int(np.asarray(m['shift_k']).ravel()[0]),
                k=k, s=s, relu=relu,
            )

    @staticmethod
    def _conv(x, w, b, stride, k):
        return _conv(x, w, b, stride, k)

    def forward(self, img):
        """img: (3,720,1280) uint8 RGB -> (head_a, head_b) int64 maps."""
        x = img.astype(np.int64) - 128          # same offset the RTL uses
        outs = {-1: x}
        for i, (name, k, s, relu) in enumerate(LAYERS):
            L = self.layers[i]
            y = _conv(outs[SRC[i]], L['w'], L['b'], s, k)
            outs[i] = _requantise(y, L['shift'], relu)
        return outs[7], outs[10]

    @staticmethod
    def argmax(ha, hb):
        """Per-cell argmax across both heads -> (cls, x, y, conf) of the peak."""
        h = np.concatenate([ha, hb], axis=0)     # (2K, 45, 80)
        k_channels = h.shape[0] // 2
        flat = h.reshape(h.shape[0], -1)
        per_cell_val = flat.max(axis=0)          # strongest channel per cell
        per_cell_ch = flat.argmax(axis=0)        # which channel that was
        idx = int(per_cell_val.argmax())         # strongest cell overall
        return (int(per_cell_ch[idx] % k_channels),
                int(idx % GRID_W), int(idx // GRID_W), int(per_cell_val[idx]))


def detect(model, frame_rgb):
    """frame_rgb: (720,1280,3) uint8 -> (cls, gx, gy, conf)."""
    img = np.transpose(frame_rgb, (2, 0, 1))
    ha, hb = model.forward(img)
    return HWModel.argmax(ha, hb)


def verify_mat_reference(mat_dir, verbose=False):
    """Check every layer against the input/output pair stored in its .mat."""
    bad = []
    for i, (name, k, s, relu) in enumerate(LAYERS):
        m = sio.loadmat(os.path.join(mat_dir, name + '.mat'))
        w = np.asarray(m['weight'], dtype=np.int64)
        b = np.asarray(m['bias'], dtype=np.int64).reshape(-1)
        shift = int(np.asarray(m['shift_k']).ravel()[0])
        x = np.asarray(m['input'], dtype=np.int64)[0]
        want = np.asarray(m['output'], dtype=np.int64)[0]
        y = _requantise(_conv(x, w, b, s, k), shift, relu)
        ok = y.shape == want.shape and np.array_equal(y, want)
        if verbose:
            print(f'  {name:16s} bit-exact={ok} shape={y.shape}')
        if not ok:
            bad.append(name)
    return bad


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--mat', required=True)
    ap.add_argument('--frames', default=None)
    ap.add_argument('--verify', action='store_true', help='check the .mat input/output pairs')
    args = ap.parse_args()
    m = HWModel(args.mat)
    if args.verify:
        bad = verify_mat_reference(args.mat, verbose=True)
        print('ALL MATCH' if not bad else 'MISMATCH: ' + ', '.join(bad))
        raise SystemExit(0 if not bad else 1)
    if args.frames:
        import cv2
        frame = cv2.imread(args.frames)
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    else:
        frame = np.zeros((FRAME_H, FRAME_W, 3), dtype=np.uint8)
    print('detect =', detect(m, frame))
