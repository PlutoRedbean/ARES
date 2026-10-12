# ARES simulation flow

Verilator based RTL simulation for ARES, ported from the
`ysyx-workbench/npc` environment (`npc/Makefile`, `npc/csrc/wave`,
`npc/vsrc/testbench`).

The flow is deliberately RTL agnostic: it takes a DUT, a test bench and the
compiled test image and turns them into a pass/fail result.  Until the ARES
RTL is complete the DUT is the npc (Mundus) core from
`$(NPC_HOME)/vsrc`, which is what `RTL_ROOT` points at today.

## Quick start

```bash
# build the simulator
make -C sim

# run one image
make -C sim run PROGRAM=tests/cpu-tests/build/add-riscv32-ares.bin

# build + run the whole ISA regression
make -C tests/cpu-tests ARCH=riscv32-ares run

# capture a waveform
make -C sim wave PROGRAM=...
```

## Layout

| Path | Contents |
| --- | --- |
| `sim/Makefile` | Verilator build + run rules, RTL source list, flags |
| `sim/rtl/tb_mundus_npc.sv` | ARES owned test bench for the temporary npc DUT |
| `sim/rtl/generated/Mundus.sv` | Chisel generated DUT, elaborated with `CONFIG_SIMULATION=true` |
| `sim/config/autoconf.vh` | Verilog side configuration, kept in step with the DUT |
| `sim/csrc/main.cpp` | Verilator harness: reset, clock, run loop, trap report |
| `sim/csrc/memory.cpp` | Guest memory + MMIO model, image loading |
| `sim/csrc/dut.cpp` | DPI-C entry points seen by the RTL |
| `sim/scripts/gen_mundus.sh` | Re-elaborate the Chisel RTL into `rtl/generated/` |

## How a test runs

1. `tests/cpu-tests/Makefile` builds `<test>.bin` through the ARES
   AbstractMachine (`ARCH=riscv32-ares`), which links the image for the memory
   map below and appends the `mainargs` placeholder.
2. `platform/ares.mk` calls `make -C $(SIM_HOME) run PROGRAM=...`.
3. The harness loads the flat image at `0x8000_0000`, resets the DUT for 20
   cycles and toggles the clock until an EBREAK retirement is reported.
4. The DUT reports each retired instruction through `retire_event_enqueue`,
   so the harness tracks the architectural PC and GPR file and can sample the
   halt code (`a0`) at the EBREAK.
5. Exit status: `0` = HIT GOOD TRAP, `1` = HIT BAD TRAP, `2` = model error,
   `3` = cycle budget exhausted.

## Guest memory map

| Range | Model |
| --- | --- |
| `0x8000_0000 + 32 KiB` | IROM, instruction port only (8 byte aligned 64 bit fetch) |
| `0x8010_0000 + 256 KiB` | DRAM, the D-cacheable window |
| `0x8030_0000 + 256 KiB` | uncached mirror of the cacheable window (bit 21 clear) |
| `0x8040_0000 .. 0x80FF_FFFF` | uncached DRAM extension |
| `0xA000_0000` | MMIO: console at `+0x3F8`, RTC at `+0x48/+0x4C` |

The image is one flat blob loaded at `0x8000_0000`, matching the linker script
(`tests/abstract-machine/scripts/ares-linker.ld`): IROM first, DRAM at
`+0x10_0000`.  Anything outside the table above is a hard model error.

## RTL contract implemented by the test bench

The temporary DUT exposes the npc "JYD style" interface; the test bench
reproduces the timings its `IROM_BMEM` / `perip_bridge` counterparts have in the
ysyx-workbench SoC.  These details are contract, not decoration - each one was
verified against the reference behaviour and getting it wrong corrupts
execution:

* **Instruction port**: `io_irom_addr` is a byte address and the data is
  **registered** (`CONFIG_IROM_READ_LATENCY=1`).  Returning the fetched word in
  the same cycle shifts the instruction stream by one 8 byte block, which shows
  up as AUIPC / JAL link values that are 8 bytes too small.
* **Peripheral reads** return the **word aligned to the request address**; the
  LSU extracts the addressed byte/half word itself.
* **Peripheral writes** carry the payload in the low lane together with a 2 bit
  size mask (`2'b10` word, `2'b01` half, `2'b00` byte).  The model replicates
  the payload and derives the byte enables from the address, exactly like
  `store_word_data` / `store_byte_enable` in `perip_bridge.sv`.  A byte store
  must be applied to `(addr & ~3) + lane`, never to `addr + lane`.
* **Read responses** leave a **two deep** pipeline (like `response_tag_r` /
  `response_tag_r2`).  A deeper response queue lets the 4 entry LSU completion
  queue overflow and trips its assertion.
* **Writes are applied when the request handshakes**; a load captures its data
  at handshake time, so reads never observe a younger store.

## DPI-C surface

Implemented for real:

```
irom_read(addr)                       instruction fetch
perip_read(addr) / perip_write(...)   data port
init_reg(data, idx)                   architectural initial state
get_npc_pc / get_npc_pc_next          fetch PC visibility
retire_event_enqueue(...)             retirement stream (PC + GPR writes)
interrupt_redirect(target)            interrupt redirect notification
ebreak()                              end of test
```

Accepted and ignored (they are the npc performance analysis hooks, not needed
for functional verification): `sim_stats_enabled` and the `get_*_counts`
collectors, `record_issue_operand_stall`, `difftest_skip_ref` and the
`branch_difftest_*` family.

## Options

```
--max-cycles=N     abort after N clock cycles        (default 20000000)
--reset-cycles=N   reset duration in cycles          (default 20)
--itrace           print every retired instruction
--perip-trace      print every peripheral request/response
-v, --verbose      extra diagnostics + register dump
-l/--elf/--diff/--csv   accepted for AM compatibility
```

`+verilator+rand+reset+0` is passed by the `run` rule: the DUT has state that
its reset does not clear, and the reference flow also needs the zero reset
mode rather than Verilator's random one.

## Using ARES' own RTL

```bash
make -C sim RTL_ROOT=<path to ARES rtl> TOPNAME=<ares tb top>
```

The pieces to provide are a test bench that drives the ARES clock/reset and
exposes the same DPI-C calls (`sim/csrc` stays unchanged), plus an entry in
`VSRCS` in `sim/Makefile`.  The AM platform
(`tests/abstract-machine/scripts/platform/ares.mk`) only needs a new linker
script if the memory map changes.

## Regenerating the Chisel DUT

```bash
sim/scripts/gen_mundus.sh [NPC_HOME] [OUTPUT]
```

It copies the npc Chisel project into `sim/build/chisel` (the npc working tree
is never modified), enables `CONFIG_SIMULATION`, runs `mill` and writes
`sim/rtl/generated/Mundus.sv`.  Without `CONFIG_SIMULATION` the generated
design contains no `Mundus_DPIC` instance at all, so there would be no EBREAK
callback and no way to detect the end of a test.

## Limitations

* The statistics / branch-difftest hooks are stubbed, so the npc performance
  reports are not produced here.
* No NEMU difftest, no instruction disassembler, no interactive debugger.
* Single hart, no device interrupts (the interrupt input is tied low); the
  timer interrupt path of the npc SoC is not exercised.
