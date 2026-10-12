# rtl/backend/test - backend simulation support

Simulation-only helpers for backend / core verification.  Nothing in this
directory is synthesizable or part of the delivered core.

| File | Role |
|---|---|
| `fe_stub.sv` | Behavioural frontend (F0): always-not-taken fetch source that obeys `frontend_backend_contract.md` §2–§4. Instruction data comes from the shared DPI model (`irom_read`). |
| `tb_fe_stub.sv` | Self-checking contract test for the stub. |

## Running

From the repository root:

```bash
make tb-fe-stub        # build + run (HIT GOOD TRAP == pass)
make lint-all          # lint every top with -Wall --assert
```

or directly through the simulation flow:

```bash
make -C sim ARES_RTL=1 RTL_ROOT=$PWD/rtl tb-fe-stub
```

Both forms need one test image to exist (`ARES_UNIT_IMAGE`, default
`tests/cpu-tests/build/add-riscv32-ares.bin`); build it with
`make -C tests/cpu-tests ARCH=riscv32-ares ALL=add`.  The stub checks the
instruction stream against the same DPI image, so any image works.

## What the stub guarantees (contract §2–§4)

* `iq_valid` is only `00/01/11`, slot 0 is the oldest, no holes
* `iq_accept_count` is the only consumption basis (no `rready`), prefix pops
* with `accept=0` the head entry and its metadata stay stable
* `backend_redirect_valid` clears the queue in the same cycle and refetches
  from `backend_redirect_pc`
* `pred_npc = pc+4`, `pred_meta` is raw, `need_redirect = 0`
* `bpu_update_credit = 2` from a constant (no BE→FE→BE combinational loop)

## What `tb_fe_stub` checks (consumer side)

Every fetched word against the DPI image, `cfi_type` against an independent
classifier, slot ordering, head stability, and the PC sequence of all consumed
instructions (dense `pc, pc+4, ...` with a restart at the redirect PC after
every redirect, including a redirect storm).  The stub itself carries the
producer-side SVA.
