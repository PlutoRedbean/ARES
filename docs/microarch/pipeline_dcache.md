# Pipeline data cache (2-way set associative)

Status: integrated in the single-hart `rtl/pipeline` SoC and in the coherent
multi-hart SoC (`pipeline_hart.sv`).  The competition requirement is a
**2-way set-associative D-cache**; this document records the geometry, the
replacement policy, the hazards that the associativity introduces and the
structure that keeps the change off the critical path.

The cache is written in Chisel and generated into
`rtl/pipeline/core/vsrc/build/Mundus.sv` (`make pipeline-core-gen`).  The
arrays are the same Verilog RAM wrappers the direct-mapped version used
(`rtl/pipeline/soc/ip/DCache*_BRAM.v`), so simulation and both synthesis flows
infer block RAM without new primitives.

## Purpose and scope

The D-cache sits between the LSU and the write-through peripheral port:

```text
LSU (Ls1 lookup)  ->  DCache (Tag/Data/LRU RAMs)  ->  Ls2 response
                           ^        |
                  refill   |        |  store (write-through)
                           |        v
                     peripheral / L2 (backing store, coherence sideband)
```

It accelerates loads only: stores are written through to memory and also
update a line that hits, so memory is always current and a dropped fill can
never lose data.  Coherence is write-invalidate with an epoch (see
[docs/pipeline_multicore.md](../pipeline_multicore.md)); the L2 invalidates the
whole Set and a refill whose epoch changed in flight is dropped.

## Geometry and storage

| Item | Value |
| --- | --- |
| Capacity | 8 KiB (`CONFIG_DCACHE_SIZE_KB`) |
| Sets / Ways | 1024 / `CONFIG_DCACHE_WAYS` = 2 |
| Entry | one 32-bit word: there is no line fill, a miss refills one word |
| Index / Tag / Offset | `addr[11:2]` / `addr[17:12]` / `addr[1:0]` |
| Cacheable window | `0x8010_0000-0x8013_ffff` (whole DRAM), so `addr[31:18]` is constant |
| Data array | one 32-bit 1W1R RAM per Way (`DCacheData_BRAM`) |
| Tag array | one `{valid, tag}` 1W1R RAM per Way (`DCacheTag_BRAM`) |
| Replacement array | one 1-bit 1W1R RAM per Set (`DCacheLru_BRAM`) |
| Replacement | fill/hit LRU, one MRU Way per Set |
| Hit latency | lookup in Ls1, data and hit in Ls2 |
| Reset | directory (valid bits + LRU) cleared one Set per cycle, 1024 cycles |

Keeping the total capacity at 8 KiB means associativity halves the number of
Sets (2048 direct-mapped entries become 1024 Sets x 2 Ways).  For a
conflict-free working set this is neutral; for a set that aliases it removes
the direct-mapped thrashing entirely, which is the point of the requirement.

## Request pipeline

```text
cycle T     Iss drives lookup_addr; all Read ports (2 Tag, 2 Data, 1 LRU) issue
cycle T+1   Ls1 req_valid: tag compare per Way, 2:1 Way mux -> resp_* register
cycle T+2   Ls2: resp_hit/resp_data consumed by the LSU; a store that hit writes
            its merged word into every Way that hit
cycle T+3   Ls3: a load miss' slow word arrives and is installed by refill
```

The LSU carries the **Victim Way** of each request (captured from
`io_req_way` when the request is accepted) through `ls2_cache_way` /
`ls3_cache_way` and hands it back with the refill (`io_refill_way`), so the
refill installs the word in the Way that was chosen at lookup time.

## Structure and why the clock is not affected

The direct-mapped cache read both RAMs in parallel with the speculative Iss
lookup and compared the tag on the RAM output.  The 2-way version keeps that
shape and only adds logic after the RAM outputs:

* Both Ways have independent Tag/Data RAMs and are read in parallel, so the
  lookup is still one cycle and no RAM port is shared or multiplexed.
* The only added delay in front of the response register is the 2:1 Way mux on
  the data output (one LUT per bit) plus the OR of the two tag comparators on
  the hit path.  That is **one extra LUT level** on the load data path
  (`RAM out -> tag compare -> Way mux -> store-forward muxes -> resp_data`);
  nothing else changed.  A 1-bit `hit_way` drives both the hit decision and
  the data mux (priority to Way 0), so they can never disagree even if a line
  were ever duplicated.
* Nothing was added in front of a RAM **address** port except the per-Way
  write enables.  The write enables are flop-driven, except the refill write
  enable, which already depended on the epoch/slow-response condition.
* The replacement state lives in its own small RAM that is read **in
  parallel** with the Tag RAM (same registered latency), so the Victim is
  available at request time and does not have to be resolved with a 1024:1
  multiplexer at refill time.  Carrying the Victim through the LSU keeps the
  refill write port a flop-to-flop path.
* The bits that were already there (tag comparison, the refill read/write
  collision forwarding, the store->load forwarding, the held-Ls1 capture) kept
  their depth; the collision forward was moved from "select the whole word" to
  "select the written Way", so it did not add a level.

The reported PnR bottleneck of the current SoC is the `mtx9` accelerator
array, not the load path, so the extra LUT does not move the achieved
frequency; see [README.md](../../README.md).

## Replacement policy

`lru[s]` is the Way of Set `s` that was used most recently:

* a **fill** writes the installed Way,
* a **hit** writes the Way that hit when the request is accepted.

The Victim of a request is the first invalid Way of the Set if there is one
(cold start, after an invalidate), otherwise the Way after `lru[s]`.  For two
Ways this is the classic bi-state LRU: after a fill the other Way becomes the
next Victim, and a hit "refreshes" the Way it used, which is what keeps a hot
line resident while a stream flows through the Set.

A same-cycle hit update and refill update can collide on the single LRU write
port; the refill wins.  Losing one update only affects which Way is evicted
later, never correctness.

## Store path

Stores are write-through: the peripheral write happens in Ls1, the cache copy
is updated in Ls2 when the request hit.  Three details matter for 2 Ways:

* The store writes **every Way that matched** when the request was accepted
  (`resp_hit_vec`), not just the Way that supplied the data.  Two Ways can
  only ever hold the same tag if one word was refilled twice back-to-back
  (the Victim is decided one Lookup ahead); updating both copies means such a
  duplicate cannot leave a stale Way behind.
* The base word of a byte/half store is the word that the request read
  (`resp_data`), which is exactly the pre-store value for that address, so
  the merge is correct for both Ways.
* A refill can steal the Way a store hit between the lookup that resolved the
  hit and the Ls2 array write (the hit is resolved from the read that
  preceded the request).  `store_clash[]` remembers, per Way, that a refill
  of the same Set took it since the request was accepted (it also survives a
  stalled response), and the store's write into that Way is dropped: the line
  it hit is gone by then, and memory already holds the store.

## Refill hazards

* **Read/write collision.**  A refill to the Set Iss is looking up corrupts
  that read (the written Way's Tag and Data and the Set's Victim bit).  The
  collision is registered and the just-written word is forwarded to the
  request that consumes the corrupted read (one cycle later), per Way.
* **Younger store.**  Installing a word that a younger store already
  overwrote would leave a stale line with a valid tag, so the refill is
  dropped when a store to the same word sits in Ls2 **or Ls1**.  Dropping a
  fill is always safe: the word simply is not cached.
* **Invalidate.**  A remote store invalidates the whole Set (both Ways, a
  flop-to-flop tag write).  If an invalidate and a refill collide on the
  directory write port the invalidate wins and the fill is dropped.
* **Epoch.**  A refill is installed only if the L2 epoch captured when the
  load left L1 still matches.

## Verification

| Test | Result |
| --- | --- |
| `make pipeline-lint` | pass (warnings only) |
| `make pipeline-dcache-test` | pass, 1520 checks: both aliases of a Set resident, LRU Victim choice, per-Way store update, byte/half merge, write-through store miss, invalidate of both Ways, stale-epoch drop, held-Ls1 lookup, refill/lookup collision, 4000-request random stream |
| `make pipeline-smoke` | pass, `write_events=2`, `ebreak_seen=1` |
| `make pipeline-isa` | 36/36 pass |
| `make pipeline-coremark` | `CoreMark PASS`, CRC match, same cycles as the direct-mapped baseline |

### Measured impact (Verilator, `build/coremark/coremark.bin`, 100 iterations)

| Configuration | cycles | CoreMark/MHz |
| --- | --- | --- |
| Direct-mapped 8 KiB (before) | 44,798,214 | 2.235012 |
| 2-way 8 KiB (after) | 44,798,214 | 2.235012 |
| D-cache bypassed (reference) | 47,636,293 | 2.101799 |

The D-cache is worth about 6% of the baseline CoreMark cycles, so it is
definitely in the loop.  CoreMark's data working set fits in 8 KiB without
conflicts, so halving the Set count costs nothing there, and the associativity
only shows up on aliasing working sets (which is exactly what the unit test
checks).  The load path is not the PnR bottleneck of this SoC, so the extra
Way mux does not move the achieved frequency; a PnR A/B was not run in this
tree (no synthesis licence available), the argument is structural.

The unit test drives the generated `DCache` directly (the cache is
functionally transparent, so the ISA suite cannot see associativity) and
checks the properties that only a 2-way cache has: two aliases of one Set
resident at the same time, the LRU Victim order, the per-Way store update and
the hazard handling above.  `rtl/pipeline/test/tb_dcache.sv`.

## Limitations / next steps

* No line fill: a miss refills the single requested word, so spatial locality
  is not exploited.  A line-based version needs a fill FSM and changes the
  refill contract with the bridge.
* No hit-under-miss: a miss blocks the request stream until its word arrives.
* A store miss does not allocate.  That is deliberate for write-through +
  write-invalidate coherence, but a write-allocate policy would need
  care with the epoch guard.
* The replacement policy is fill/hit LRU.  A 4-way or victim-cache extension
  would replace `DCacheLru_BRAM` and the Victim pick, and the same Victim
  carry can be reused.
