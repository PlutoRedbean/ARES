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

`student_top` exposes two build-time switches:

- `USE_ICACHE` (default `1`): `0` instantiates only the 1-cycle passthrough
  and reproduces the pre-cache baseline exactly.
- `ICACHE_PIPE_HITS` (default `1`): `1` lets the cache accept a new request
  every cycle while the current lookup hits; `0` keeps the original serialised
  `S_IDLE -> S_LOOK -> response` cadence for A/B comparison.

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
| Hit throughput | 1 instruction/cycle with `ICACHE_PIPE_HITS=1` |
| In-flight requests | 2 (one response slot + one lookup) |
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
clears the metadata-queue occupancy (`metaCount`) so stale responses can never
be delivered to the new PC; the stale entries themselves are unreachable.

## IFU handshake

`MundusPayloads.scala` replaces the old `IROM.addr/data` pair with:

```scala
req_valid / req_addr / req_ready
rsp_valid / rsp_data / rsp_ready
flush
```

`IFU.scala` tracks up to two in-flight requests in a two-entry metadata queue
(`metaVec` + `metaCount`).  The head entry pairs with the cache response, the
tail with the request still in the cache pipeline.  On `req_fire` the IFU
pushes `{pc, snpc, predicted_taken, predicted_pc}`; on `rsp_fire` it pops the
head.  When both happen in the same cycle the freed slot is reused, so the
queue stays full and the request cadence is one instruction per cycle on hits.
The fetch buffer reserves one slot per outstanding request or held response
(`fqCount + metaCount < depth`).

`PC` and the BPU only advance on `req_valid && req_ready`; a response is held
by the cache until `rsp_ready`, so the IFU has no separate response register.
On a miss the cache stops accepting new requests and refills the line; the
younger request, if any, has already been accepted only when the previous
lookup hit, so responses remain in program order without a reorder buffer.

The 2-cycle hit latency means a redirect still costs one extra cycle versus
the 1-cycle IROM passthrough, but steady-state fetch is now 1 instruction per
cycle.  This recovers most of the cache-induced CoreMark loss without the
4-wide window/window-FIFO/BPU changes.

## FSM

```text
S_IDLE   : accept a request when no unconsumed response is held
S_LOOK   : tag compare; hit -> commit response and (PIPE_HITS=1) accept the
           next request in the same cycle; miss -> S_REFILL
S_REFILL : issue 8 word beats / capture responses
S_FILL   : write data RAM + tag/valid/age
S_RELOOK : one cycle for the synchronous data read
S_RESP   : hold the response until rsp_ready; then commit and accept the next
           request in the same cycle
flush    : any state -> S_IDLE, drop response/refill state
```

With `ICACHE_PIPE_HITS=0`, `req_ready` is asserted only in `S_IDLE`, exactly
reproducing the earlier serialised cache.

`S_RESP` is a backpressure fallback for a client that cannot accept a response
immediately.  The buffered IFU reserves a slot for every in-flight response,
so in the current configuration `rsp_ready` is normally already high when the
response is valid; the pipelined accept therefore happens in `S_LOOK`.

The counters `hits/misses/refills/reqs` are 64-bit outputs.  `student_top`
pulses `stats_dump` when the core retires `EBREAK`; under `__VERILATOR__` the
cache prints them then (pure Verilog `$display`, no SystemVerilog `final`
block):

```text
ICACHE hits=36483040 misses=36676 refills=13772 reqs=37483188
```

## Verification

| Test | Result |
| --- | --- |
| `make pipeline-lint` | pass (warnings only) |
| `make pipeline-smoke` | pass, `write_events=2`, `ebreak_seen=1` |
| `make pipeline-isa` | 36/36 pass |
| `make pipeline-coremark` (`ICACHE_PIPE_HITS=1`) | `CoreMark PASS`, CRC match, `2.233867` CoreMark/MHz |
| `make pipeline-coremark-full` (`ICACHE_PIPE_HITS=1`) | `CoreMark PASS`, CRC match, `7.526562` CoreMark/MHz |
| `ICACHE_PIPE_HITS=0` CoreMark | `72,712,371` cycles / `1.376911`; full `18,927,949` / `5.306702` |
| `USE_ICACHE=0` CoreMark | `43,659,057` cycles / `2.293038`; full `12,501,880` / `8.030366` |

The pipelined hit path recovers the fetch-rate loss: baseline is within about
2.6% of the cache-off cycles (`44,818,745` vs `43,659,057`) and full is within
about 6.7% (`13,340,720` vs `12,501,880`).  The remaining gap is the 2-cycle
hit latency on redirects plus refill exposure, not steady-state fetch
bandwidth.

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
- A 4-wide response + window FIFO + prechecker was evaluated but is not
  needed for the single-issue backend once the hit path is pipelined: fetch is
  already 1 instruction/cycle, and the remaining gap is redirect/refill
  latency rather than width.
