# Dual-core CoreMark status (AMP bring-up)

## Implemented

- `ares_frontend_hart`: real frontend + adapter + ICache AXI bridge + core,
  with a D-side AMP address offset.
- `ares_2core_frontend_l2_top`: two harts, shared `l2_top`, two I ports
  (i0/i1) and two D ports (c0/c1).
- `l2_top`: second instruction read port, I0/I1 alternating arbitration.
- `tb_2core_coremark`: two CoreMark images, hart1 data/stack loaded at
  `+0x100000`, both harts start together.

## Single-hart result

The single-hart real-frontend CoreMark passes:

```text
retires=21,229,636 cycles=49,944,724 IPC=0.425063 CoreMark/MHz=2.0022
```

## Dual-hart result: not passing yet

The dual test reaches about 44.7 ms simulated, then hart0 hits the LSU
natural-alignment assertion on a halfword load at `addr=0x000000a3`.
This is a data/pointer corruption symptom, not a CoreMark completion.

Debug isolation so far:

- hart1 held in reset: hart0 runs correctly through 50 ms (no misalign).
- hart1 I + D active, hart1 writes disabled: hart0 still misaligns.
- hart1 D disabled entirely: hart0 runs correctly through 50 ms.
- hart1 D addresses stay in `0x8020_xxxx` (monitor), so the offset itself is
  applied.
- A c1-response data checker compared every c1 L2 response with the backing
  memory image for 50 ms; it found **no mismatches**.
- L2 unit tests (including c0/c1 concurrent reads and c1 displacing a c0 dirty
  line) pass.

The next debugging step is to separate "c1 instruction fetch / I1 traffic" from
"c1 data read traffic", because disabling all c1 D also stops the c1 frontend
after the first load. The remaining suspects are the shared L2 I1 path and a
L1D/L2 interaction, not the basic c0/c1 response routing or the AMP offset.

**Do not quote a dual-core CoreMark score until this is fixed.**
