#!/usr/bin/env python3
"""Freeze existing CoreMark images and compare cycles across the IRQ change."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/rtos_regression'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, log):
    with log.open('w') as stream:
        subprocess.run(args, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
    return log.read_text()


def main():
    phase = sys.argv[1]
    if phase not in ('before', 'after'):
        raise SystemExit('usage: test_rtos_coremark.py before|after')
    folder = OUT / phase
    if phase == 'before' and (folder / 'results.json').exists():
        raise SystemExit('baseline already exists; keep it for comparison')
    folder.mkdir(parents=True, exist_ok=True)
    images = [ROOT / f'build/{name}/coremark.bin' for name in
              ('coremark', 'coremark_full', 'coremark_full_mc')]
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in images}
    hashes.update({str(p.relative_to(ROOT)): digest(p)
                   for p in (ROOT / 'build/pipeline').glob('*') if p.is_file()})
    if phase == 'after':
        expected = json.loads((OUT / 'before/results.json').read_text())
        assert hashes == expected['hashes'], 'CoreMark/board images changed'
    single = OUT / 'single'
    run(['verilator', '--cc', '--exe', '--build', '-j', '4',
         '--language', '1800-2017', '-D__VERILATOR__', '-Wno-fatal',
         '--top-module', 'tb_pipeline_isa', '-f', 'rtl/pipeline/pipeline.f',
         'rtl/pipeline/test/tb_pipeline_isa.sv',
         str(ROOT / 'rtl/pipeline/test/sim_isa_main.cpp'),
         '-Mdir', str(single), '-o', str(single / 'run')], folder / 'build_single.log')
    records = {}
    for name, image in zip(('baseline', 'full'), images):
        output = run([str(single / 'run'), str(image),
                      '200000000'], folder / f'{name}.log')
        records[name] = re.findall(r'(?:Total ticks[^\n]*|CoreMark/MHz[^\n]*|.*crc[^\n]*|cycles=[^\n]*)', output)
        assert 'CoreMark PASS' in output
    for cores in (2, 4):
        model = OUT / f'model{cores}'
        run(['verilator', '--cc', '--exe', '--build', '-j', '4',
             '--language', '1800-2017', '-D__VERILATOR__', '-Wno-fatal',
             '--top-module', 'tb_pipeline_coremark_amp', f'-GCORES={cores}',
             '-GICACHE_LINES=512', '-f', 'rtl/pipeline/pipeline.f',
             'rtl/pipeline/test/tb_pipeline_coremark_amp.sv',
             str(ROOT / 'rtl/pipeline/test/sim_coremark_amp_main.cpp'),
             '-Mdir', str(model), '-o', str(model / 'run')], folder / f'build_amp{cores}.log')
        output = run([str(model / 'run'), str(images[2]), '200000000', str(cores)],
                     folder / f'amp{cores}.log')
        records[f'amp{cores}'] = re.findall(r'(?:.*Total ticks[^\n]*|.*CoreMark/MHz[^\n]*|.*crc[^\n]*|.*cycles=[^\n]*)', output)
        assert 'PASS' in output
    logs = {name: digest(folder / f'{name}.log') for name in records}
    result = dict(hashes=hashes, records=records, logs=logs)
    (folder / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    if phase == 'after':
        assert records == expected['records'], 'CoreMark result/cycle regression'
        assert logs == expected['logs'], 'CoreMark console/CRC output changed'
    print(f'CoreMark {phase}: 4 configurations PASS', flush=True)


if __name__ == '__main__':
    main()
