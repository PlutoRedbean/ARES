# miniTensor SoC integration (S09 / SPEC-M6 adaptation)

> Status: **2026-10-14, first adaptation landed.** mini_tensor_top is
> instantiated in the ARES SoC and driven through an ARES-owned CV-X-IF host
> adapter over the documented JYD MMIO seam. This is the **control-path
> adaptation** only; the in-core XIF path and the shared-memory Fabric remain
> open (SPEC-M6 / SPEC-M7).

> **C5 update (2026-10-18)**: `student_top` now contains the real Frontend and
> IROM path; FE injection/ifetch ports were removed from both platform and
> `ares_soc_top`. This does not complete CPU/DMA arbitration, in-core XIF or RTOS.

## 1. Scope

Done in this change:

1. mini_tensor_top is instantiated by a real ARES SoC top
   ([ares_soc_top.sv](../rtl/top/ares_soc_top.sv)). It is no longer only a
   standalone / npc behavioral-model fixture.
2. The ARES CV-X-IF host adapter
   ([ares_mt_host_adapter.sv](../rtl/soc/ares_mt_host_adapter.sv)) converts the
   JYD 32-bit MMIO command window into the CV-X-IF
   issue / register / commit / result transaction expected by
   mini_tensor_top.

Deliberately **not** done here (left to the FE/BE owners and the SoC/Fabric
scope, see section 8):

- decoding custom-0 in the backend and issuing it from be_issue_sched
  (the seven SPEC-M6 blanks);
- CPU/DMA memory arbitration, cache-coherency/visibility policy, and
  lsu_mmio_order_idle / architectural_next_pc interaction
  (SPEC-M7/M19/M20/M21);
- an ARES RT-Thread BSP; the imported rtthread-nano/ tree still targets the
  legacy MundusJyd platform.

## 2. Architecture

student_top already exposes the documented miniTensor control seam
(mt_wr_en / mt_wr_idx / mt_wr_data / mt_status_rd / mt_status / mt_result,
decoded from 0x8020_1000-0x8020_101F by perip_bridge). The migration decision
kept that seam external to student_top; this change connects it in a new
integration top instead of editing the platform subtree:

    ares_soc_top
      |- student_top                         (real ares_core_top Core + JYD SoC)
      |    |- perip_bridge -- mt_* seam --------+
      |- ares_mt_host_adapter <-----------------+   MMIO -> CV-X-IF master
      |    |- core_v_xif mt_xif -----------------+
      |- mini_tensor_top <-----------------------+   CV-X-IF slave
           |- mt_mem_* 128-bit uncached DMA  ---> exported at ares_soc_top
           |- ub_rd_*  observation-only port (tied off)

Control flow: CPU MMIO write -> perip_bridge register decode -> adapter
command queue -> CV-X-IF issue / register / commit -> accelerator FSM ->
CV-X-IF result -> MT_STATUS / MT_RESULT read back by software.

Data flow: MT_LOAD / MT_STORE drive mini_tensor_top's 128-bit DMA master. That
master is exported as mt_mem_* on ares_soc_top (the future Fabric boundary);
this change does not invent an arbiter or coherency policy.

Clock/reset: single CPU clock w_cpu_clk, synchronous active-high w_clk_rst,
identical to student_top and mini_tensor_top.

## 3. Files

| File | Role |
| --- | --- |
| rtl/soc/ares_mt_host_adapter.sv | ARES CV-X-IF host adapter (MMIO -> CV-X-IF). |
| rtl/top/ares_soc_top.sv | Integration top: student_top + adapter + mini_tensor_top, DMA exported. |
| Makefile (lint-mt, ARES_MT_SRCS) | Elaboration/lint gate for the integrated subtree. |
| docs/miniTensor_soc_integration.md | This document. |

student_top, perip_bridge and the miniTensor RTL are unchanged. The adapter is
an ARES-owned adaptation of the retained legacy
miniTensor/integration/npc/mt_cvxif_shim.sv (same contract and sequencer), so the
ARES integration does not depend on the retired NPC tree.

## 4. Control register map

The adapter consumes the perip_bridge seam; byte offsets from the JYD
miniTensor base 0x8020_1000 (reg_wr_idx = perip_addr[4:2]):

| Offset | Name | Dir | Semantics |
| --- | --- | --- | --- |
| 0x00 | MT_INSTR | W | 32-bit custom-0 instruction word |
| 0x04 | MT_RS1 | W | becomes CV-X-IF register.rs[0] |
| 0x08 | MT_RS2 | W | becomes CV-X-IF register.rs[1] |
| 0x0C | MT_KICK | W | write 1 to queue the staged INSTR/RS1/RS2 |
| 0x10 | MT_STATUS | R | bit0 busy, bit1 done, bit2 err, bit3 accept_err, bit4 kick_err; a read while not busy clears the flags |
| 0x14 | MT_RESULT | R | result.data (miniTensor returns 0) |

## 5. CV-X-IF sequencer

- Exactly one command is in flight (mini_tensor_top.issue_ready is only high in
  S_IDLE); the depth-8 queue keeps commands back-to-back.
- commit_valid is **held** from REGISTER_TO_COMMIT until the result arrives. A
  one-cycle commit pulse that lands before the register beat would be dropped by
  mini_tensor_top and the command would hang forever (there is no timeout).
- Unsupported funct7/funct3 returns accept=0; the adapter sets accept_err and
  moves on instead of hanging.
- Staging and execution registers are separate, so a queue pop cannot clobber a
  software write of the next command.
- A full queue drops the kick and sets kick_err (the peripheral bus is never
  stalled, which would lock the LSU store path).

## 6. DMA boundary

mini_tensor_top emulates an uncached second master: 16-byte aligned beats, a
two-phase read (single outstanding, no ID/burst) and a single-phase full-line
write. ares_soc_top exports that master as mt_mem_*; no CPU/DMA arbitration and
no cache-coherency policy is added. Until the Fabric exists (SPEC-M7), any
integration must attach it to memory and keep accelerator buffers uncached
(software alias rules).

## 7. Verification

### 7.1 Permanent lint gate

    make lint-mt

Elaborates the real JYD subtree, mini_tensor_top, core_v_xif and the ARES
adapter with --lint-only -Wall --assert; result on 2026-10-14 was **0 warnings**
(72 modules, 19.5 MB of sources). make lint-soc continues to pass unchanged.

### 7.2 Temporary functional simulation (deleted after passing)

The adapted control/data path was brought up once with a throwaway bench
(ares_mt_host_adapter + mini_tensor_top + a self-contained 128-bit memory,
driving the MMIO seam exactly like perip_bridge). It exercised:

| Check | Result |
| --- | --- |
| 4x MT_LOAD (A / B / bias / config) through the adapter | ok |
| MT_GEMM + MT_EPILOGUE + MT_STORE (A=1, B=2 -> out=8) | ok |
| UB row round-trip (MT_STORE of a loaded row -> 1) | ok |
| unsupported funct7 -> accept_err, no hang | ok |

Final line: *** ARES MT ADAPTER TEST PASSED ***.

Per the task instruction the bench and its build directory were **not kept**;
only this evidence is recorded. The DUT composition above plus make lint-mt is
enough to recreate it.

## 8. Remaining work

| Item | Owner / dependency |
| --- | --- |
| Backend custom-0 decode -> issue -> commit -> CIQ result (SPEC-M6, 7 blanks) | FE/BE owners |
| CPU <-> DMA Fabric, single-outstanding read owner, uncached alias policy (SPEC-M7/M20/M21) | SoC owner |
| I-cache maintenance / visibility after DMA (SPEC-M19) | FE owner |
| commit_kill generation on flush/trap/redirect (SPEC-M6) | FE/BE owners |
| ARES RT-Thread BSP, timer/interrupt/console/linker/firmware packaging | RTOS owner |

Until these land, ares_soc_top is a subsystem integration/verification top, not
a sign-off SoC, and the soc Vivado profile still targets student_top.
