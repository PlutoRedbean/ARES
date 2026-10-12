# rtl/memory/test - LSU / memory simulation support

Self-checking tests for the TB-side memory models used by the core test bench.
Nothing in this directory is synthesizable.

| File | Role |
|---|---|
| `tb_mem_model.sv` | Checks `sim/rtl/tb_mem_beat_if.sv` (128-bit beat bus) and `sim/rtl/tb_mmio_if.sv` (MMIO bridge) against an independent byte-level shadow model. |

The adapters themselves live in `sim/rtl/` because they belong to the
simulation environment, not to the delivered RTL.

## Running

```bash
make tb-mem-model      # from the repository root
make -C sim ARES_RTL=1 RTL_ROOT=$PWD/rtl tb-mem-model
```

## What is verified

* full-beat (16B, `be=16'hffff`) write/read round trip through the DPI model
* arbitrary byte enables, including `0x0005` and `0x8000` — patterns the
  model's 2-bit size mask cannot express directly, i.e. the classic silent
  corruption case when the lane offset is applied to an unaligned address
* same-cycle write + read of the same beat is ordered write-first
  (memory.md §6.7)
* a stalled response keeps its data stable (no live re-read of memory)
* MMIO: single outstanding, exactly one response per request, response one
  cycle after the request and never before the side effect completed
* the DPI memory itself matches the shadow model (writes really landed in the
  expected byte lanes)
