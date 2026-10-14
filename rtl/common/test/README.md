# rtl/common/test - shared package self-test

| File | Role |
|---|---|
| `tb_ares_pkg.sv` | Pins the frozen cross-module layout of `rtl/common/ares_pkg.sv`: type widths, enum encodings, parameter relationships and a distinct-value round trip of every cross-boundary struct. |

The package is the single source of truth for the FE/BE/LSU interface
(SPEC-I3), so a silent width or encoding change would break all consumers at
once.  This TB is the regression guard for that layout.

It also validates the `make menuconfig` selections (`MUL_LATENCY` in 2..3,
`LINE_BYTES` in 16/32/64, DCache geometry / power-of-two set count) and prints
the effective configuration, so every run records what the build elaborated
with.

## Running

```bash
make tb-ares-pkg        # from the repository root
make -C sim ARES_RTL=1 RTL_ROOT=$PWD/rtl tb-ares-pkg
```

## Changing the package

Every expectation in `tb_ares_pkg.sv` is deliberately explicit.  When a
reviewed package change alters a width or encoding, update the expectation in
the same commit and mention it in the review - that diff is the record of the
interface change.
