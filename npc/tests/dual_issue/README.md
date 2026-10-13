# Dual-issue directed regression

Run from this directory:

```sh
make
```

The standalone RV32IM/Zicsr image runs with NEMU differential testing.
It covers the complete slot-1 RV32I ALU whitelist, same-group flat RAW
forwarding, safe WAW-only and WAW-plus-flat-RAW pairing, rejected
load/M-to-ALU RAW and WAW-plus-RAW, allowed WAR and x0 cases, cross-group
Ex2/Ex3/Ex4/WB forwarding, youngest-producer priority, Ex1 branch and
multiply operands, full slot-0 M/load/store operations paired with slot
1, long-operation group stalls, both positions in a 64-bit branch block,
redirect to a high slot, pairing across fetch blocks, EX4 CSR operand
forwarding, and ordered CSR read/modify/write updates.

The checker requires a good trap, at least one dual retirement and flat
ALU0-to-ALU1 bypass, all reachable centralized pairing rejection classes,
zero dependent same-group load pairs, the presence of the optimized
`slot1-late` accounting row, and a valid retirement-width identity.
