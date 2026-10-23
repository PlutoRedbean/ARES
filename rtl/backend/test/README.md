# rtl/backend/test - backend simulation support (C1)

Simulation-only helpers and self-checking benches for the backend.  Nothing in
this directory is synthesizable or part of the delivered core.

| File | Role |
|---|---|
| `fe_stub.sv` | Behavioural frontend (F0) for the DPI harness: always-not-taken fetch source that obeys `frontend_backend_contract.md` §2–§4 (C0 deliverable). |
| `tb_fe_stub.sv` | Self-checking contract test for the stub (C0). |
| `lsu_stub.sv` | Ideal LSU port model for backend verification (backend.md §9.6): guaranteed accept, LQ/SQ credits, one completion per accepted operation, kill handling, `store_commit_ok` from registered state only. |
| `unit/fe_model.sv` | Instruction fetch model with a program image (`imem`), contract-shaped `iq_valid/iq_accept_count`, same-cycle redirect and no holes. |
| `unit/tb_decode.sv` | `be_decode` unit test: every RV32IM/Zicsr encoding, immediate formats, CFI classification, `csr_write_en` table, all `decode_err` classes (3106 checks, fixed seed). |
| `unit/tb_fu_exec.sv` | `fu_alu` / `fu_smul` / `fu_mul` / `fu_div` unit test: boundary tables + 100k/20k randomised reference comparisons, II=1 throughput, kill semantics, both `MUL_LATENCY` settings (224072 checks). |
| `unit/tb_bru_csr.sv` | `fu_bru` / `csr_file` / `fu_csr` unit test: branch/jump resolution, pred_npc match/mismatch recovery, every CSR field mask and priority, all six Zicsr forms (10695 checks, fixed seed). |
| `unit/tb_backend.sv` | **C1 integration gate**: `be_top` + `fe_model` + `lsu_stub`, independent RV32IM golden model. |

## Running (C1 gate)

From the repository root:

```bash
make lint-backend      # backend lint, 13 tops, -Wall --assert, zero warnings
make unit              # build + run the four self-checking backend benches
make all               # C0 + C1 gate: lint + lint-backend + all unit benches
```

The unit benches are standalone (`verilator --binary --timing`, own clock) and
live two directory levels down, so `sim/Makefile`'s `backend/*/*.sv` glob does
not pick them up; `make unit` builds each top explicitly.

## What `tb_backend` checks

* phase 1 - directed program checked instruction by instruction against an
  independent golden model (retire PC, `rd`, value): dependency chains,
  taken/not-taken branches, JAL, JALR with matching `actual_npc == pred_npc` (no recovery) and mismatching targets, loads/stores, MUL/DIV/REM,
  serialising CSR write/read, 2-wide dispatch and store commit handshake;
* phase 2 - `ECALL` -> `mtvec` handler -> `MRET` and a machine timer interrupt:
  2 trap entries, 2 MRET retires, `mepc/mcause/mstatus` path, interrupt
  restore point verified through the golden model and direct `mepc`/first
  resumed-retire PC checks;
* phase 3 - fixed-seed random programs (10 rounds), >10k cycles with the golden
  model checking every retire and the contract assertions running throughout:
  `backend_redirect_valid |-> iq_accept_count == 0`, `lsu_issue_valid ->
  lsu_can_accept`, BPU events <= registered credit, no `decode_err`, no
  dependency-pointer protocol error, no deadlock.

The bench now requires all four CIQ states and six legal non-self state
transitions, observed from registered entries across all phases. This is CIQ
state-transition coverage, not a claim of full RTL line/toggle coverage.
The `make unit` launcher preserves the simulator exit status and saves each
bench's output in `sim/build/unit/<tb>/run.log`.

Result of the current run:

```
phase1+2: 44 retires, 8 redirects (4 branch / 4 arch), 6 bpu events, 2 traps, 2 MRETs, 150 cycles
phase3: 10878 cycles, 4839 retires, 65 redirects, golden checks 9022 (27 unchecked)
ALL TESTS PASSED: tb_backend (directed + traps + random, 480 retires, 65 redirects)
```

## Known limits of this bench

* the golden model treats CSR reads as unknown (`gold_poison`) and skips their
  consumers' value comparison; CSR semantics are covered by the directed phase
  and by `tb_bru_csr`;
* `lsu_stub` returns `src1+imm` for loads (no memory model) - memory semantics
  belong to the LSU benches (C2);
* PPA is not evaluated here (no Vivado project, SPEC-M10): the C1 exit is a
  functional gate only.
