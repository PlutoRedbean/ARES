# Dual-core CoreMark bug report (for hand-off)

Branch: \`l2-cache\`
Commit: \`55a8e25\` + the reproduction target in \`Makefile\`
Status: **single-hart CoreMark passes; dual-hart CoreMark fails. Do not report a dual score.**

## 1. Symptom

\`tb_2core_coremark\` runs two software-CRC CoreMark images (100 iterations) on
two real frontends sharing one L2. Both harts start together. At about
**44.7 ms simulated**, hart0 hits the LSU natural-alignment assertion:

\`\`\`text
MISALIGN addr=000000a3 size=1 load=1 store=0
[44695475000] %Error: lsu_agu.sv:188: a_natural_align
\`\`\`

At the failure both harts have retired about 1.842M instructions, both around
PC \`0x8000_0634\`, L2 hit/miss about \`3261/203\`. It is a data/pointer
corruption symptom, not a CoreMark completion.

Single-hart reference on the same frontend/L2 path:

\`\`\`text
ALL TESTS PASSED: 2 checks - ARES real FE + shared L2 CoreMark
retires=21,229,636 cycles=49,944,724 IPC=0.425063 CM/MHz=2.0022 a0=0
\`\`\`

## 2. Reproduce

Build the software-CRC CoreMark image (100 iterations) and its 128-bit-wide
memory image:

~~~bash
export MUNDUS_HOME=/home/ccy/Documents/qs/Mundus
rm -rf /tmp/coremark_sw
cp -a $MUNDUS_HOME/am-kernels/benchmarks/coremark /tmp/coremark_sw
rm -rf /tmp/coremark_sw/build
sed -i 's/^#define ITERATIONS .*/#define ITERATIONS 100/' \
    /tmp/coremark_sw/include/core_portme.h

python3 - <<'PY'
from pathlib import Path
p = Path('/tmp/coremark_sw/src/core_main.c')
s = p.read_text()
s = s.replace('\ttotal_time=get_time();\n',
              '\ttotal_time=get_time();\n\t(void)total_time;\n', 1)
p.write_text(s)
PY

cd /tmp/coremark_sw
AM_HOME=$MUNDUS_HOME/abstract-machine \
NPC_HOME=$MUNDUS_HOME/npc NEMU_HOME=$MUNDUS_HOME/nemu \
MUNDUS_HOME=$MUNDUS_HOME \
make ARCH=riscv32-jyd CROSS_COMPILE=riscv64-unknown-elf- image

python3 - <<'PY'
from pathlib import Path
b = Path('/tmp/coremark_sw/build/coremark-riscv32-jyd.bin').read_bytes()
if len(b) % 16:
    b += b'\0' * (16 - len(b) % 16)
with open('/tmp/coremark_sw_dmem.hex', 'w') as f:
    for i in range(0, len(b), 16):
        f.write(f'{int.from_bytes(b[i:i+16], "little"):032x}\n')
PY
~~~

Run the known-failing reproduction (about 2 min to the assertion):

~~~bash
cd /home/ccy/Documents/qs/ARES
make repro-2core-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

The single-hart reference is:

~~~bash
make unit-coremark DMEM=/tmp/coremark_sw_dmem.hex
~~~

## 3. What has already been ruled out

| Experiment | Result |
|---|---|
| hart1 held in reset | hart0 runs through 50 ms, no misalign |
| hart1 D completely disabled | hart0 runs through 50 ms, no misalign |
| hart1 writes disabled, reads enabled | **hart0 still fails** |
| hart1 D addresses | all in \`0x8020_xxxx\`; offset correct |
| hart0 writes into hart1 range | none observed |
| c1 L2 read response vs backing memory | **no mismatches** for 50 ms |
| L2 unit test: c1 read evicts c0 dirty line | passes |
| L2 unit test: c0/c1 concurrent reads | passes |
| Different c1 data offset (different L2 set) | **still fails** |
| Fixed I0 priority vs alternating I0/I1 | **still fails** |

Therefore this is **not**:

- a missing \`MULTITHREAD=2\` compile flag (this is AMP, two independent images);
- a wrong hart1 data offset;
- a simple c1 response routing error;
- a simple dirty-victim writeback error.

## 4. Ranked hypotheses

1. **c1 instruction-fetch path (L2 i1)**
   - Disabling c1 D also stops the c1 core after its first load, which stops
     i1 traffic. The two effects have not been separated yet.
   - Suspect: i1 request/response routing, line refill, or i1 evicting a c0
     line while c0 has an outstanding L1D refill.

2. **L1D/L2 interaction during c1-driven eviction**
   - L2 directed tests pass, but they do not model an L1D MSHR holding a line
     while the L2 victim/writeback path runs.
   - Suspect: \`dcache_top\`/\`mshr\`/\`line_adapter\` plus L2 \`S_WB\`/\`S_RF_*\`.

3. **Shared L2 one-outstanding I/D interleaving**
   - \`l2_top\` serves one transaction at a time; c0/c1/i0/i1 share
     \`rsp_data_q\`, \`rsp_valid_q\`, and \`req_port\`.
   - Suspect: a response/ready race when an I response and a D response are
     adjacent, especially around \`req_port\` \`3'd2/3'd3\`.

4. **Core0 data corruption via c1 reads, not c1 writes**
   - c1 writes can be disabled and hart0 still fails.
   - This points at a read-triggered eviction or response-side effect, not a
     direct c1 store overwriting hart0 data.

## 5. Where to probe

- [rtl/l2/l2_top.sv](../rtl/l2/l2_top.sv)
  - arbitration around lines 151-181 (i0/i1/c0/c1)
  - response mux lines 191-202 (\`req_port\`, \`selected_rsp_ready\`)
  - victim/writeback lines 208-215 (\`victim_tag\`, \`mem_wb_addr\`)
- [rtl/top/ares_frontend_hart.sv](../rtl/top/ares_frontend_hart.sv)
  - D offset lines 138/144
  - I response wiring lines 111-125
- [rtl/top/ares_2core_frontend_l2_top.sv](../rtl/top/ares_2core_frontend_l2_top.sv)
  - c1 D / i1 connections lines 130-137
- [rtl/frontend/interface/axi_l2_bridge.sv](../rtl/frontend/interface/axi_l2_bridge.sv)
- [rtl/top/test/tb_2core_coremark.sv](../rtl/top/test/tb_2core_coremark.sv)
- [rtl/memory/lsu_agu.sv](../rtl/memory/lsu_agu.sv) line 188 (observing assertion)

Useful probes:

- c0/c1 \`mem_rd_valid/addr\`, \`mem_rsp_valid/data\`
- L2 \`state_q\`, \`req_port\`, \`req_addr\`, \`rsp_valid_q\`, \`rsp_data_q\`
- i0/i1 \`rd_valid/ready\`, \`rsp_valid/ready\`
- L1D \`mshr\` state and \`line_adapter\` active line
- first divergent hart0 retire PC/instruction between single-hart and dual-hart

## 6. Suggested next experiments

1. **Separate I1 from D reads**
   - Give hart1 a private instruction source (or freeze i1 after reset) while
     leaving c1 D reads enabled. If hart0 passes, i1 is the culprit.
   - Conversely, bypass c1 D reads to a private memory while keeping i1; if
     hart0 passes, c1 D/L1D-L2 is the culprit.

2. **Hart0 lockstep trace**
   - Run single-hart and dual-hart with the same image. Record hart0's
     committed PC/instruction stream and find the first divergence.

3. **c0 response shadow check**
   - Keep a shadow of hart0's known data (or a sentinel region) and compare
     every c0 L2 response to it. The current c1 checker only proves c1's
     responses are correct; c0 may be the one receiving bad data.

4. **Disable L1D allocation for c1**
   - Make c1 D reads bypass the private L1D and go straight to L2/uncached. If
     the failure disappears, the bug is L1D/L2 interaction, not L2 alone.

5. **One-core-at-a-time retirement**
   - Let hart1 fetch only (no D) for a while; then enable D. Find the exact
     transition that starts corruption.

## 7. Important

The frontend adapter, AXI bridge, and AMP data offset all work in the
single-hart run. Do **not** change the frontend contract or recompile
CoreMark with \`MULTITHREAD=2\` as a first response; the failure is in the
shared-L2 / dual-hart data path.

