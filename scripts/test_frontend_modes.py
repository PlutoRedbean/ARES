#!/usr/bin/env python3
"""Check recovery and FE/BE ordering in isolated predictor configurations."""
import importlib.util
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ares_kconfig', ROOT/'scripts/kconfig/ares_kconfig.py')
kc = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = kc
spec.loader.exec_module(kc)

CASES = {
    'bimodal': {'FE_TOURNAMENT': False, 'FE_BIMODAL': True, 'FE_TAGE': False,
                'FE_UTAGE': False, 'FE_MBTB': False, 'FE_RAS': False, 'FE_LOOP_PRED': False},
    'tournament': {'FE_TAGE': False, 'FE_UTAGE': False},
    'utage': {'FE_TAGE': True, 'FE_UTAGE': True},
    'tage-no-ras': {'FE_TAGE': True, 'FE_MBTB': False, 'FE_RAS': False, 'FE_LOOP_PRED': False},
}
for name, overrides in CASES.items():
    cfg = kc.build_config()
    kc.resolve(cfg, overrides)
    out = ROOT/'sim/build/frontend-modes'/name
    out.mkdir(parents=True, exist_ok=True)
    kc.write_autoconf(cfg, out/'ares_autoconf.vh')
    print(f'[frontend-mode] {name}', flush=True)
    subprocess.run(['make', '-C', str(ROOT), 'unit-frontend',
        'FE_UNIT_TBS=tb_bpu_history tb_fe_be_contract',
        'ARES_CFG_INC=+incdir+'+str(out), 'FE_UNIT_BUILD='+str(out)], check=True)
