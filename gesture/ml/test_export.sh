#!/usr/bin/env bash
# Round-trip test: random checkpoint -> .mat -> shape report
set -e
cd /mnt/e/qs/ScreenSense/ml
python3 - <<'PY'
import torch
from model_template import MundusDet
torch.save(MundusDet(4).state_dict(), '/tmp/m.pt')
print('checkpoint saved')
PY
python3 export_mat.py --ckpt /tmp/m.pt --out /tmp/mats --classes 4
echo '--- files ---'
ls -1 /tmp/mats | head -20
