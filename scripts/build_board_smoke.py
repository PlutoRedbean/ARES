#!/usr/bin/env python3
"""Build the physical-board bare-metal image and matching HEX/COE files."""
import os
from pathlib import Path
import subprocess
from split_image import emit_image

ROOT = Path(__file__).resolve().parents[1]

def build():
    out = ROOT / 'build/firmware/c4-board'
    out.mkdir(parents=True, exist_ok=True)
    prefix = os.environ.get('CROSS_COMPILE', 'riscv32-unknown-linux-gnu-')
    subprocess.run([prefix+'gcc', '-march=rv32im_zicsr', '-mabi=ilp32', '-nostdlib',
        '-Wl,--no-relax,-T,'+str(ROOT/'tests/soc-tests/c4_board.ld'),
        str(ROOT/'tests/soc-tests/c4_board.S'), '-o', str(out/'board.elf')], check=True)
    subprocess.run([prefix+'objcopy', '-O', 'binary', str(out/'board.elf'),
        str(out/'board.bin')], check=True)
    emit_image(out/'board.bin', out)
    for name in ('irom', 'dram'):
        words = (out/(name+'.hex')).read_text().splitlines()
        (out/(name+'.coe')).write_text('memory_initialization_radix=16;\n'
            'memory_initialization_vector=\n'+',\n'.join(words)+';\n')
    print(f'Board firmware: {out} (PC=0x80000000 MTVEC=0x80000100)')

if __name__ == '__main__':
    build()
