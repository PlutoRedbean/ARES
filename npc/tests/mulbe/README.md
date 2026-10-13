# Mundus MULBE custom-instruction regression

`MULBE` is encoded as `custom-0`, `funct7=1`, `funct3=0`.  It computes:

```text
product = rs1 * rs2
rd = ((product >> 2) & 0xf) * ((product >> 5) & 0x7f)
```

The directed RTL cases cover edge values, both issue slots, a dependent
consumer, simultaneous independent multiplies, and `rd=x0`.

Run it with:

```sh
make run
```
