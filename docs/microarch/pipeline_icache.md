# Pipeline instruction cache

Status: P2 integrated in the single-hart `rtl/pipeline` SoC.  The cache is
Verilog-2005 style (`.v`, no SystemVerilog types/interfaces), self-contained
under `rtl/pipeline`, and does not depend on `rtl/frontend` or its
`fe_pkg`/AXI interfaces.

## Purpose and scope

The pipeline core originally fetched every instruction from a private 32 KiB
`IROM_BMEM32` with a fixed one-cycle read latency.  The instruction cache is a
competition-required front-end structure: it sits between the IFU and the IROM,
owns a request/response handshake, and can later be re-pointed at DRAM/L2
without changing the IFU.

First version deliberately keeps the IROM as the backing store:

```text
IFU (Mundus)  <->  pipeline_icache  <->  pipeline_irom_passthrough  <->  IROM_BMEM32
   req/rsp            1-wide, 4 KiB          refill adapter, 1 cycle/beat
```

`student_top` exposes `USE_ICACHE` (default `1`).  `USE_ICACHE=0` instantiates
only the 1-cycle passthrough and reproduces the pre-cache baseline exactly.

## Geometry and storage

| Item | Value |
| --- | --- |
| Capacity | 4 KiB |
| Line | 32 B (8 instructions) |
| Sets / ways | 32 / 4 |
| Tag / index / offset | `PC[31:10]` / `PC[9:5]` / `PC[4:0]` |
| Replacement | age-based LRU (ages stay a permutation; victim = age `NR_WAYS-1`) |
| Data array | one 256-bit line per `{way,set}`, single read port, inferred BRAM |
| Directory | flattened valid/tag/age arrays, FF/LUTRAM |
| Refill beat | 32-bit, 8 beats per line |
| Hit latency | 2 cycles |
| Response width | 1 instruction |

The way is resolved before the RAM read: a combinational tag check on the live
request selects `{way,set}` for the synchronous data read.  This avoids four
parallel data copies and keeps the data array at the logical 4 KiB size.  The
original 4-wide/line-B datapath from `rtl/frontend` was removed because a
single-issue core never needs cross-line stitching.

## Interfaces

Core side:

```systemverilog
req_valid, req_addr, req_ready
rsp_valid, rsp_data, rsp_ready
flush
```

Memory side:

```systemverilog
refill_req_valid, refill_req_addr, refill_req_ready
refill_rsp_valid, refill_rsp_data, refill_rsp_ready
```

`pipeline_irom_passthrough` is reused as the refill adapter: it presents one
word per cycle to the IROM and slices `req_addr[14:2]` for the 32 KiB window,
preserving the original out-of-window alias behaviour.  A future L2/DRAM
adapter only has to implement the same refill contract.

`flush` is asserted on every backend redirect.  The cache aborts the in-flight
request/refill, clears its response slot, and keeps cached lines.  The IFU
clears `reqPending`; stale responses can therefore never be delivered to the
new PC.

## IFU handshake

`MundusPayloads.scala` replaces the old `IROM.addr/data` pair with:

```scala
req_valid / req_addr / req_ready
rsp_valid / rsp_data / rsp_ready
flush
```

`IFU.scala` now tracks one outstanding request (`reqPending`) and latches the
request metadata in `reqMeta`.  The fetch buffer reserves one slot for a
pending request and one for a held response.  `PC` and the BPU only advance on
`req_valid && req_ready`; a held response is held by the cache until
`rsp_ready`, so there is no separate response register in the IFU.

With a 2-cycle hit path the sustained fetch rate is one instruction per two
cycles.  This is the accepted first-version trade-off; the measured CoreMark
regression is about 1.5-1.7x.  If that becomes unacceptable, the Plan B is a
4-wide response plus a 4-entry window FIFO in front of the IFU, restoring one
instruction per cycle.

## FSM

```text
S_IDLE   : accept a request when no unconsumed response is held
S_LOOK   : tag compare; hit -> commit response; miss -> S_REFILL
S_REFILL : issue 8 word beats / capture responses
S_FILL   : write data RAM + tag/valid/age
S_RELOOK : one cycle for the synchronous data read
S_RESP   : hold the response until rsp_ready
flush    : any state -> S_IDLE, drop response/refill state
```

The counters `hits/misses/refills/reqs` are 64-bit outputs.  `student_top`
pulses `stats_dump` when the core retires `EBREAK`; under `__VERILATOR__` the
cache prints them then (pure Verilog `$display`, no SystemVerilog `final`
block):

```text
ICACHE hits=35249046 misses=22478 refills=13871 reqs=35397652
```

## Verification

| Test | Result |
| --- | --- |
| `make pipeline-lint` | pass (warnings only) |
| `make pipeline-smoke` | pass, `write_events=2`, `ebreak_seen=1` |
| `make pipeline-isa` | 36/36 pass |
| `make pipeline-coremark` | `CoreMark PASS`, CRC `e714/1fd7/8e3a/988c`, 1.376911 CoreMark/MHz |
| `make pipeline-coremark-full` | `CoreMark PASS`, CRC match, 5.306702 CoreMark/MHz |
| `USE_ICACHE=0` CoreMark | `cycles=43,659,057`, matches the P0 measurement on this tree |
| `USE_ICACHE=1` CoreMark | `cycles=72,712,371` (baseline) / `18,927,949` (full) |

The cache-on numbers are a structural first version, not a performance
optimisation: IROM is already a one-cycle memory, so the only effect is the
extra lookup pipeline stage and occasional refill.

The P0 comparison is `43,659,057` cycles, measured immediately before the
cache/IFU change on this working tree.  The older M1 plan records
`43,597,126` from an earlier tree; the two are not the same build and should
not be compared as a regression.

## Limitations / next steps

- `FENCE.I` is still decoded as a generic `FENCE` barrier and does not
  invalidate the cache or flush the fetch queue.  The IROM is read-only, so
  this is safe today; add an invalidate port before supporting writable code.
- Backing is still the private IROM.  Moving code to DRAM/L2 only requires a
  new refill adapter (the cache interface is already generic).
- Single-hart only.  `pipeline_hart.sv` currently uses the passthrough path;
  per-hart cache integration is a later step.
- No critical-word-first, hit-under-miss, MSHR, or abortable refill.  A
  redirect during a refill waits for the abort and then restarts.
