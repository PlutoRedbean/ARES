#!/usr/bin/env python3
"""Run history/order tests with all optional predictors off, in isolated builds."""
import importlib.util
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ares_kconfig', ROOT/'scripts/kconfig/ares_kconfig.py')
kc = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = kc
spec.loader.exec_module(kc)
cfg = kc.build_config()
kc.resolve(cfg, {'FE_TOURNAMENT': False, 'FE_RAS': False, 'FE_LOOP_PRED': False})
out = ROOT/'sim/build/frontend-bimodal'
out.mkdir(parents=True, exist_ok=True)
kc.write_autoconf(cfg, out/'ares_autoconf.vh')
subprocess.run(['make', '-C', str(ROOT), 'unit-frontend',
    'FE_UNIT_TBS=tb_bpu_history tb_fe_be_contract',
    'ARES_CFG_INC=+incdir+'+str(out), 'FE_UNIT_BUILD='+str(out)], check=True)
