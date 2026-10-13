# Mundus CRC16 custom-instruction regression

This test checks the `custom-0` CoreMark CRC16 instruction independently of
CoreMark.  It validates the flattened parity model against the reference
algorithm for 100,004 vectors, then runs directed RTL cases covering both
issue slots, same-group forwarding, dependent CRC operations, and `rd=x0`.

Run it with:

```sh
make run
```

A successful run ends with `CRC16 directed regression passed` and
`HIT GOOD TRAP`.
