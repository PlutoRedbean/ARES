set -e
cd /mnt/e/qs/ScreenSense/ml
rm -rf /tmp/mats /tmp/out
python3 - <<'PY'
import torch
from model_template import MundusDet
torch.save(MundusDet(4).state_dict(), '/tmp/m.pt')
print('checkpoint saved')
PY
python3 export_mat.py --ckpt /tmp/m.pt --out /tmp/mats --classes 4 > /tmp/export.log 2>&1
tail -2 /tmp/export.log
python3 pack_model.py --mat /tmp/mats \
  --gen /mnt/e/qs/ScreenSense/fpga/python_script/CnnHardwareGenerator_pds.py \
  --out-mem /tmp/out/mem_data --out-vh /tmp/out/header > /tmp/pack.log 2>&1 || true
tail -12 /tmp/pack.log
echo '--- generated headers ---'
ls -1 /tmp/out/header 2>/dev/null | head -5
echo '--- generated mem ---'
ls -1 /tmp/out/mem_data 2>/dev/null | head -5
