#!/usr/bin/env python3
"""Build the fixed bare-metal JYD smoke fixture; no legacy BSP/tool dependency."""
import os
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
out = ROOT / 'sim/build/soc-smoke'
out.mkdir(parents=True, exist_ok=True)
prefix = os.environ.get('CROSS_COMPILE', 'riscv32-unknown-linux-gnu-')
subprocess.run([prefix+'gcc', '-march=rv32im', '-mabi=ilp32', '-nostdlib',
    '-Wl,-Ttext=0x80000000,-e,_start,--no-relax', str(ROOT/'tests/soc-tests/c5_smoke.S'),
    '-o', str(out/'smoke.elf')], check=True)
subprocess.run([prefix+'objcopy', '-O', 'binary', '-j', '.text', str(out/'smoke.elf'), str(out/'smoke.bin')], check=True)
from split_image import emit_image
emit_image(out/'smoke.bin', out)
