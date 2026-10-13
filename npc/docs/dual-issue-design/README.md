# RV32IM In-Order Dual-Issue Design

## Goals and invariants

The dual-issue implementation keeps the existing in-order pipeline and gives
the second slot an explicitly bounded set of resources:

- slot 0 retains the full current execution path;
- slot 1 executes ordinary RV32I integer ALU, branch/jump, load/store, and
  RV32M integer multiply instructions;
- slot 1 has its own ALU and fixed-latency integer MAC, but shares the branch
  pipeline and the current single memory pipeline with slot 0;
- a pipeline group is either `01` or `11`; `10` is never legal;
- instructions retire in program order, slot 0 before slot 1;
- slot 1 excludes divide/remainder, CSR/environment operations, fences,
  optional bit-manipulation instructions, and unrecognised instructions;
- a branch/jump in slot 0 issues alone, while a branch/jump may occupy slot 1;
- the current memory implementation admits at most one load/store candidate
  per group.

The implementation is RISC-V-specific.  Cortex-A53 source is used to understand
the architecture, not as RTL to copy.

## Cortex-A53 design mapping

The main references are:

- `cortexa53/logical/ca53dpu/verilog/ca53dpu_iq.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_iq_dih.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_dec1.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_dec1_br.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_dec1_ls.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_de.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_ctl.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_dp.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_mac.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_params.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_pmu.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_store.v`
- `cortexa53/logical/ca53dpu/verilog/ca53dpu_cp.v`

`ca53dpu_iq` combines a queue body with head and holding entries.  It accepts
and removes zero, one, or two instructions and only exposes the oldest
contiguous prefix.  Mundus maps this to an eight-entry instruction queue whose
head always contains the oldest two instructions.  The dequeue count is
selected by the dual-issue decoder, so a rejected slot 1 remains at the head
and can become the next slot 0.  Unlike the old experimental four-issue branch,
the queue is not drained in fixed fetch groups, which permits pairing across
64-bit fetch boundaries.

`ca53dpu_iq_dih` centralises data, readiness, register-port, and datapath
resource hazards.  In particular, branch, DCU/load-store, and MAC availability
are explicit issue properties instead of consequences hidden inside execution.
Mundus uses a smaller RISC-V-specific checker with the same separation:

- slot classes state which execution resources each instruction needs;
- two memory instructions are currently split because they contend for the
  single AGU/LSU request path;
- WAW pairs are split, WAR is allowed, and x0 creates no dependency;
- slot 1 may not delay an otherwise-ready slot 0 because of an older producer;
- an intra-pair RAW is accepted only when the slot 0 result is an ordinary ALU
  value and the slot 1 consumer has a supported flat or late-data path.

The A53 datapath has a deliberately flat ALU0 Ex1 to ALU1 Ex1 path.  Mundus
implements the corresponding 32-bit combinational path for slot 1 ALU,
branch/JALR, and multiply operands.  The same-group value may also become
slot 1 store data because store data is consumed by the late EX4 path.  It is
deliberately not accepted as a slot 1 memory address: address RAW pairs are
split until there is an independently timed AGU bypass.  Loads, divide,
CSR, and optional bit-manipulation results cannot produce this flat value.

`ca53dpu_dec1` is a restricted second decoder.  Mundus reuses the common RV32
decoder for field extraction but qualifies slot 1 with explicit resource
classes: LUI/AUIPC, base OP-IMM and OP operations, branch/JAL/JALR, all base
loads/stores, and MUL/MULH/MULHSU/MULHU.  DIV/REM, CSR/environment, fence,
and configured bit-manipulation operations remain unsupported.  An
unsupported second instruction is retained and later executes through the
full slot 0 path.

A53 carries per-slot validity and writeback state through the pipeline.  Mundus
maps this to two-lane group payloads.  Stalls, flushes, load replay, and
long-operation waits act on the whole group.  CSR/environment operations and a
slot 0 control-flow instruction are serialised.  A slot 1 branch/jump is the
last instruction in its group, so its redirect does not require cancellation
of a younger same-group instruction.

### Shared branch pipeline

The A53 decode/issue and `ca53dpu_de` logic preserve the instruction's slot
identity while selecting one owner for the branch datapath.  Mundus follows
that pattern in EX1: both lanes carry branch metadata, and a side-lane
branch/jump selects the shared BRU input because a slot 0 control-flow
instruction cannot be paired.  The owner selection includes PC, sequential
PC, prediction metadata, immediate, and both source operands.

The shared BRU returns a single resolved next PC and predictor update.  For a
slot 1 branch, slot 0 still retires to slot 1's PC while slot 1 records the
resolved target/fall-through.  A misprediction is qualified by EX1 fire, so a
group held by an older backend or writeback stall cannot repeatedly redirect
the frontend.  ALU0-to-slot1 forwarding covers branch comparisons and JALR
bases.

### Shared memory pipeline and future ports

The A53 issue logic treats the DCU/AGU as an explicit shared resource, while
its datapath and store pipeline select the issuing instruction and keep its
metadata aligned through later stages.  Mundus makes the same ownership
boundary visible:

- both lanes form a memory candidate containing address, load/store control,
  size/sign, and store data;
- decode currently prevents two candidates in one group, and EX1 converts the
  surviving candidate to a one-hot grant for the single physical LSU request;
- the owner lane tag accompanies fast and slow load results and routes them
  back into the matching lane pipeline;
- each lane carries store metadata to EX4, where one shared store commit owner
  is selected and the resolved data is enqueued.

This is also the compatibility seam for a two-bank D-Cache with two load pipes
and one store pipe.  That extension can replace the current single-candidate
assertion and one-hot grant with per-bank load grants plus a store grant while
retaining the candidate bundles, lane tags, response routing, and ordered
group retirement.  Bank conflicts and the single-store-port conflict should
be resolved at this boundary rather than reintroducing a blanket
slot-1-memory restriction.

### Independent slot 1 MAC

A53 exposes MAC demand as an issue resource class.  Mundus keeps that explicit
classification but provisions a second fixed-latency `MUL` instance for slot
1, as required by the FPGA design target.  Its clock enable follows the side
metadata pipeline stall, keeping the 64-bit result aligned with the owning
instruction.  Writeback applies the lane's MUL/MULH/MULHSU/MULHU low/high
selection independently.  Divide and remainder remain slot 0 long operations.

### Late operands and architectural commit

A53 describes register availability and consumption with independent
thermometer-coded `rf_wr_when_*` and `rf_rd_need_*` values.  Its issue
interlock therefore asks whether a producer is ready by the consumer's actual
need stage instead of requiring every source at issue.  Mundus uses the same
principle with relative `when` and `need` masks.  A late operand records the
youngest matching lane and pipeline stage, then advances through EX2, EX3, and
EX4 while taking the newest available forwarded value.

`ca53dpu_store` keeps store data in a dedicated pipeline, applies forwarding
at multiple stages, and presents the final value at writeback.  Mundus
similarly computes the store address and control early but does not require
the data register until EX4.  EX4 enqueues the resolved value into a core
store buffer.  Loads compare against older buffered stores and merge matching
bytes before using cache data; MMIO remains ordered and bypasses buffering.

The A53 coprocessor path carries validity and decode from issue through
writeback.  CP writes consume `st0_data_wr_i`, reusing the late store-data
path, and qualify state changes with writeback exception and condition checks.
Mundus maps that architectural pattern, rather than the ARM-specific
registers, to Zicsr: EX1 performs the combinational CSR read needed for the
destination result and early trap target, while CSR writes, ECALL state, and
MRET state update only when EX4 fires.  CSR source data uses the shared late
operand path.  A system-in-flight interlock serialises CSR/environment
instructions so that a younger CSR read cannot pass an older uncommitted
update.

## Frontend and prediction

IROM is 16 KiB organised as 2048 64-bit words.  A word is ordered as
`{instruction at PC+4, instruction at PC}` and addressed with an eight-byte
aligned PC.

The branch predictor is block-aware.  Its tag/index identify an eight-byte
block and its entry records the predicted instruction slot.  A prediction in
slot 0 enqueues only slot 0, while a slot 1 prediction enqueues both slots.
When a redirect starts at slot 1, an older prediction for slot 0 is ignored.
Predictor and IROM responses carry the same requested PC and are checked for
alignment.

## Issue and execution policy

Slot 0 may pair a recognised non-control ALU, load/store, M-extension, or
configured bit-manipulation instruction with a supported slot 1 ALU,
branch/jump, load/store, or multiply instruction.  A memory/memory pair is
split while the LSU has one request port.  A slot 0 branch/jump and all
system/CSR operations issue alone.  Division, carry-less multiply,
cache/peripheral backpressure, and load slow paths hold the complete pair.

Pair rejection remains mutually exclusive for accounting.  In priority order
the decision reports slot 0 serial, slot 1 unsupported, shared resource, WAW,
unforwardable same-group RAW, or slot 1 requiring a longer issue wait than
slot 0.  This distinguishes instructions that still lack a slot 1 execution
path from those that are supported but cannot pair in a particular cycle.

The synchronous register file becomes four-read/two-write.  Forwarding chooses
the nearest older pipeline group first and the younger lane within a group
first.  A load-miss dependency in either lane replays the complete younger
group from its slot 0 PC.

Simulation retirement uses an ordered event queue.  RTL may enqueue two events
in one hardware cycle, while the reference model consumes one event and
executes one architectural instruction at a time.

## Performance counters

Simulation-only counters report:

- issue and retirement widths 0/1/2 and per-slot utilisation;
- instruction-queue occupancy buckets;
- successful pair decisions and one mutually-exclusive rejection reason;
- flat slot 0 to slot 1 RAW bypass use;
- aggregate backend, long-operation, issue, redirect, cache, and store-buffer
  statistics;
- one mutually-exclusive primary cause for every frozen pipeline cycle, plus
  a raw overlapping cause mask that preserves simultaneous pressure.

The report checks that retirement width reconstructs the total retired count
and that all pair opportunities are accounted for.

Primary stall attribution follows the oldest blocking stage:

1. writeback DIV/REM;
2. writeback carry-less multiply;
3. backend store;
4. backend load;
5. issue system serialization;
6. issue long-operation resource;
7. issue load versus unresolved older-store overlap;
8. issue MMIO ordering;
9. issue load-port availability;
10. issue operand readiness.

The primary counters report cycles and events and must sum exactly to frozen
cycles.  An event starts when the selected primary cause changes, including
the transition from no stall.  Raw counters may overlap and therefore sum to
more than frozen cycles; they are intended to expose secondary bottlenecks
hidden by the oldest-stage priority.  The simulation report also projects IPC
after removing each primary cause's cycles.  Directed coverage creates
overlapping DIV/resource/operand waits and checks both the primary identity
and raw-overlap accounting.
