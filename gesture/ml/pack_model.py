"""ScreenSense - pack exported .mat into hardware headers and memories.

Trick that keeps the hardware untouched: the two head layers are fixed at 16
output channels.  We pad your K classes up to 16 and give the unused channels
a huge negative bias, so they can never win the per-cell argmax.  That means
any K <= 16 works without changing a single PE parameter.
"""

import argparse, os, re, shutil, subprocess, sys
import numpy as np
import scipy.io as sio


HEAD_LAYERS = ('node_conv2d_7.mat', 'node_conv2d_10.mat')
HW_CHANNELS = 16


def pad_head(path):
    """Pad a head layer from K to HW_CHANNELS output channels."""
    m = sio.loadmat(path)
    w = np.asarray(m['weight'], dtype=np.int32)
    b = np.asarray(m['bias'], dtype=np.int32).reshape(-1)
    k = w.shape[0]
    if k == HW_CHANNELS:
        return k
    if k > HW_CHANNELS:
        raise SystemExit(f'{path}: {k} classes > {HW_CHANNELS} hardware channels')
    pad = HW_CHANNELS - k
    w = np.concatenate([w, np.zeros((pad,) + w.shape[1:], dtype=np.int32)], axis=0)
    b = np.concatenate([b, np.full(pad, -2**20, dtype=np.int32)])
    out = {k2: v for k2, v in m.items() if not k2.startswith('__')}
    out['weight'] = w
    out['bias'] = b
    if 'output' in out:
        o = np.asarray(out['output'], dtype=np.int32)
        out['output'] = np.concatenate(
            [o, np.full((1, pad) + o.shape[2:], -128, dtype=np.int32)], axis=1)
    sio.savemat(path, out)
    return k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mat', required=True, help='directory with node_*.mat')
    ap.add_argument('--gen', required=True, help='CnnHardwareGenerator_pds.py')
    ap.add_argument('--out-mem', required=True)
    ap.add_argument('--out-vh', required=True)
    args = ap.parse_args()

    stage = os.path.abspath(args.mat) + '_hw'
    os.makedirs(stage, exist_ok=True)
    for f in os.listdir(args.mat):
        if f.endswith('.mat'):
            shutil.copy(os.path.join(args.mat, f), os.path.join(stage, f))

    for h in HEAD_LAYERS:
        p = os.path.join(stage, h)
        if os.path.exists(p):
            print(f'{h}: padded from {pad_head(p)} classes to {HW_CHANNELS}')

    src = open(args.gen, encoding='utf-8').read()

    # generate only the YOLO layers; constructing the LPRNet ones is harmless
    # because load_mat_data() only runs inside generate_layer().
    src = re.sub(
        r'all_layers = \[layer0[\s\S]*?\]',
        'all_layers = [layer0, layer1, layer2, layer3, layer4, layer5, '
        'layer6, layer7, layer8, layer9, layer10]',
        src)

    src = src.replace('mat_file_dir="conv_data_yolov3_new_pds"',
                      f'mat_file_dir=r"{stage}"')
    src = re.sub(r'output_mem_dir="[^"]*"', f'output_mem_dir=r"{os.path.abspath(args.out_mem)}"', src)
    src = re.sub(r'output_vh_dir="[^"]*"',  f'output_vh_dir=r"{os.path.abspath(args.out_vh)}"', src)

    tmp = os.path.join(os.path.dirname(os.path.abspath(args.out_mem)), '_gen_custom.py')
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    os.makedirs(args.out_mem, exist_ok=True)
    os.makedirs(args.out_vh, exist_ok=True)
    base = os.path.dirname(os.path.abspath(args.out_mem))
    os.makedirs(os.path.join(base, 'conv_data_hex_pds'), exist_ok=True)
    open(tmp, 'w', encoding='utf-8').write(src)
    print('generator ->', tmp)
    r = subprocess.run([sys.executable, tmp], cwd=base)
    sys.exit(r.returncode)


if __name__ == '__main__':
    main()
