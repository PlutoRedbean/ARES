# ARES real frontend + shared L2 CoreMark bring-up

## Status

The existing `rtl/frontend` is now integrated into a single-hart simulation
top through:

- `rtl/frontend/fe_legacy_adapter.sv` — legacy IQ/redirect mapping and a
  4-entry 2-push/1-pop BPU-update FIFO;
- `rtl/frontend/interface/axi_l2_bridge.sv` — ICache AXI4-Lite reads to the
  L2 128-bit I read port (16 B beat buffer);
- `rtl/top/ares_frontend_l2_top.sv` — frontend + adapter + `ares_core_top` +
  `l2_top`;
- `rtl/top/test/tb_ares_coremark.sv` — 16 MiB backing memory and CoreMark
  image loader.

The frontend RTL itself was not modified.

## Test image

Software-CRC CoreMark, `ITERATIONS=100`, built with the Mundus AM JYD
toolchain and linked at `0x8000_0000` (stack at `0x8014_0000`).  The testbench
consumes a 128-bit-wide `$readmemh` image:

```bash
python3 - <<'PY'
from pathlib import Path
b = Path('/tmp/coremark_sw/build/coremark-riscv32-jyd.bin').read_bytes()
if len(b) % 16:
    b += b'\0' * (16 - len(b) % 16)
with open('/tmp/coremark_sw_dmem.hex', 'w') as f:
    for i in range(0, len(b), 16):
        f.write(f'{int.from_bytes(b[i:i+16], "little"):032x}\n')
PY
```

## Run

```bash
make unit-coremark DMEM=/tmp/coremark_sw_dmem.hex
```

The run takes about 9 minutes of Verilator wall time.

## Measured result

```text
ALL TESTS PASSED: 2 checks - ARES real FE + shared L2 CoreMark
CoreMark metrics:
  retires=21,229,636
  cycles=49,944,724
  IPC=0.425063
  CoreMark/MHz=2.0022
  time=499,447,286 ns
  L2 hits=10,133  misses=165
  a0=0 (EBREAK exit)
```

At the 100 MHz simulation clock this is about 200.2 iterations/s.  The
CoreMark/MHz value is clock-independent.

## Scope

This is a **single-hart** ARES run.  It proves:

- real BPU/FTQ/IFU/ICache → legacy adapter → current backend;
- ICache AXI → L2 I port;
- D-side L1D/L2 write-back path;
- CoreMark execution and EBREAK exit (a0=0).

It is not yet the 2-core SoC or a dual-core CoreMark score.  The 2-core top
still uses the FE contract externally; the next step is to instantiate a second
frontend + adapter + core and give the L2 an AMP data layout.
