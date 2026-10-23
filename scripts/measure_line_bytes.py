#!/usr/bin/env python3
"""Compare a fixed streaming program with isolated 16/32/64B simulation builds.

Never edits menuconfig/defaults. These are functional simulation measurements;
Fmax/area require separate physical implementation and remain unverified here.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    out=ROOT/'build/perf/line-bytes'
    out.mkdir(parents=True,exist_ok=True)
    prefix=os.environ.get('CROSS_COMPILE','riscv32-unknown-linux-gnu-')
    subprocess.run([prefix+'gcc','-march=rv32im','-mabi=ilp32','-nostdlib',
        '-Wl,-Ttext=0x80000000,-e,_start,--no-relax',str(ROOT/'tests/soc-tests/c4_memory.S'),
        '-o',str(out/'stream.elf')],check=True)
    subprocess.run([prefix+'objcopy','-O','binary',str(out/'stream.elf'),str(out/'stream.bin')],check=True)
    defines=subprocess.check_output(['python3',str(ROOT/'scripts/kconfig/ares_kconfig.py'),'defs'],text=True)
    defines=re.sub(r'-DCONFIG_LINE_BYTES=\S+','',defines).strip()
    results=[]
    for line in (16,32,64):
        build=out/f'line-{line}'
        with (out/f'build-{line}.log').open('w') as log:
            subprocess.run(['make','-C',str(ROOT/'sim'),f'BUILD_DIR={build}',
                f'ARES_CFG_DEFS={defines} -DCONFIG_LINE_BYTES={line}'],stdout=log,stderr=subprocess.STDOUT,check=True)
        run=subprocess.run([str(build/'ares-sim'),'+verilator+rand+reset+0','--max-cycles=2000000',
            str(out/'stream.bin')],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True)
        (out/f'run-{line}.log').write_text(run.stdout)
        if 'HIT GOOD TRAP' not in run.stdout: raise RuntimeError(f'line {line}: no good trap')
        match=re.search(r'ARES_PERF line=(\d+) lookups=(\d+) load_hits=(\d+) load_misses=(\d+) reads=(\d+) read_busy=(\d+)',run.stdout)
        if not match or int(match[1])!=line: raise RuntimeError('configuration/counters missing')
        row=dict(zip(('line_bytes','lookups','load_hits','load_misses','read_requests','read_busy_cycles'),map(int,match.groups())))
        row['cycles']=int(re.search(r'cycles\s*:\s*(\d+)',run.stdout)[1])
        row['instructions']=int(re.search(r'instructions\s*:\s*(\d+)',run.stdout)[1])
        row['ipc']=row['instructions']/row['cycles']
        row['fmax_mhz']=None; row['area']=None
        results.append(row)
        print(json.dumps(row),flush=True)
    (out/'results.json').write_text(json.dumps({'benchmark':'16KiB streaming write/read checksum',
        'image_sha256':hashlib.sha256((out/'stream.bin').read_bytes()).hexdigest(),
        'physical_ppa_verified':False,'results':results},indent=2)+'\n')

if __name__=='__main__': main()
