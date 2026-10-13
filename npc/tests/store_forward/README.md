# Transient store forwarding directed regression

Run from this directory:

```sh
make
```

The standalone RV32IM image runs with NEMU differential testing. It checks
byte-level forwarding from in-flight stores to younger cacheable loads,
youngest-store priority, partial merges, late store-data stalls, cache-hit and
miss paths, committed refill after a transient miss, wrong-path flush behavior,
and sustained store/load pressure. The test waits for D-cache initialization so
the hit and refill checks exercise the cache rather than the startup bypass.

The checker also requires the Ex1/Ex2 overlap, successful forwarding,
forwarded-byte, not-ready-data, and multi-store-merge statistics to be
exercised.
