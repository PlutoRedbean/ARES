# CoreMark CRC hardware acceleration

> Status: implemented and measured on the shared-L2 dual-hart CoreMark flow.
> The vendored EEMBC benchmark sources, including `src/core_util.c`, are not
> modified. The acceleration is a separate build variant plus one custom
> instruction in the ARES backend.
> The single-issue pipeline core also decodes this instruction, split into a
> two-stage CRC datapath; see [pipeline_accel_images.md](pipeline_accel_images.md).

## 1. Scope

The accelerated variant replaces the bit-serial `crcu8()` loop in CoreMark with
a single custom-0 instruction, while keeping the reference C sources untouched.
It is intended for performance experiments; the default `make coremark-image`
flow and its recorded baseline hashes are unchanged.

The implementation has three parts:

1. a compile-time symbol rename for **only** `core_util.o`, so the reference
   CRC definitions become dead `*_orig` symbols;
2. a new translation unit `crc_hw.c` that defines the canonical
   `crcu8 / crcu16 / crc16 / crcu32` symbols using the custom instruction;
3. an ARES custom-0 CRC8 instruction decoded by `be_decode` and executed by
   `fu_alu`.

No CoreMark source file is edited. `core_util.c` is byte-identical to the
vendored file.

## 2. Build flow

`scripts/build_coremark_crc.py` stages a private copy of
`tests/benchmarks/coremark`, adds `src/crc_hw.c`, appends a target-specific
CFLAGS rule to the copied Makefile, and invokes the normal
`scripts/build_coremark_image.py` pipeline.

```bash
python3 scripts/build_coremark_crc.py --out build/coremark_crc --jobs 4
```

The target-specific rule is applied only to `core_util.o`:

```make
$(DST_DIR)/src/core_util.o: CFLAGS += \
    -Dcrcu8=crcu8_orig -Dcrcu16=crcu16_orig \
    -Dcrcu32=crcu32_orig -Dcrc16=crc16_orig
```

All other translation units still call the canonical names, which now resolve
to `crc_hw.c`. With `--gc-sections`, the unreferenced `*_orig` definitions
are dropped from the image.

Run the accelerated image through the existing dual-hart regression:

```bash
make unit-2core-coremark DMEM=build/coremark_crc/coremark_dmem.hex
```

The default `make coremark-image` / `make unit-coremark` /
`make unit-2core-coremark` flow continues to use the unmodified image.

## 3. Instruction encoding

```text
.insn r 0x0b, 0, 0x00, rd, rs1, rs2
```

| field | value |
| --- | --- |
| opcode | `7'b0001011` (custom-0) |
| funct3 | `3'b000` |
| funct7 | `7'b0000000` |
| result | `rd = crc8_step(rs1[7:0], rs2[15:0])` |

The operation is unrolled eight times in `fu_alu` and matches the reference
`crcu8()` recurrence exactly:

```text
x16 = (data & 1) ^ (crc & 1)
data >>= 1
if (x16) { crc ^= 0x4002; carry = 1; } else carry = 0
crc >>= 1
if (carry) crc |= 0x8000; else crc &= 0x7fff
```

It has latency 1 and is routed through the existing ALU0/ALU1 ports; no new
issue port, queue or completion path is required.  On the single-issue pipeline
core the same encoding uses a two-cycle EX1/EX2 datapath (four CRC steps per
stage) instead of one cycle; see [pipeline_accel_images.md](pipeline_accel_images.md).

### RTL files

| File | Change |
| --- | --- |
| `rtl/common/ares_pkg.sv` | add `OP_CRC8` |
| `rtl/backend/be_decode.sv` | decode custom-0 / funct3=0 / funct7=0 |
| `rtl/backend/fu_alu.sv` | add `crc8_step()` and the `OP_CRC8` result mux |
| `rtl/backend/test/unit/tb_decode.sv` | directed decode checks for the new opcode |

## 4. Verification

The dual-hart 100-iteration run passes all existing checks:

```text
L2 shadow check: rsp=2046 err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0
ALL TESTS PASSED: 9 checks - 2 harts + shared L2, two CoreMark instances
```

The nine checks include both harts reaching EBREAK with `a0=0` and the known
`crclist / crcmatrix / crcstate / crcfinal` values, so the instruction is
functionally equivalent to the reference CRC loop.

The backend unit tests, including the updated `tb_decode`, pass under
`make unit`.

## 5. Measured results

### 5.1 CRC-only

| Configuration | retires | cycles | IPC | CoreMark/MHz | vs baseline |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline, 100 iterations | 31,349,223 | 48,856,291 | 0.6417 | 2.0468 | 1.000x |
| CRC instruction, 4 iterations | 1,040,772 | 1,739,759 | 0.5982 | 2.299 | 1.149x |

The 4-iteration diagnostic image only changes `seed4_volatile` from 100 to 4
to shorten simulation. The 100-iteration baseline remains the official
repository baseline.

### 5.2 CRC plus compiler / ICache co-tuning

The CRC instruction removes most of the CRC instructions, but the remaining
image is dominated by list, state-machine and matrix code. A separate variant
uses `-O3 -funroll-loops` and a 32 KiB ICache
(`CONFIG_FE_ICACHE_NR_SETS=256`) because the unrolled text grows from
8,212 B to 16,980 B.

| Configuration | retires | cycles | IPC | CoreMark/MHz | vs baseline |
| --- | ---: | ---: | ---: | ---: | ---: |
| CRC + O3/unroll + 32 KiB ICache, 100 iterations | 24,055,220 | 38,266,627 | 0.6286 | **2.6132** | **1.277x** |

Dual-hart aggregate: `48,110,440 retires / 38,266,627 cycles / IPC=1.2572 /
5.2265 CoreMark/MHz`. This is a **27.7%** improvement over the
`2.0468 / 4.0935` baseline.

The 32 KiB ICache is a configuration co-tuning, not part of the CRC
instruction. The CRC-only result with the default 8 KiB ICache is the 1.149x
measurement above.

## 6. Remaining bottleneck

The 100-iteration combined run still spends most cycles waiting for operands:

| Metric | Share of cycles |
| --- | ---: |
| No issue | 64.75% |
| Operand dependency | 61.52% |
| Waiting on a load | **49.18%** |
| Waiting on an ALU result | 12.33% |
| LSU credit / port | 2.17% |
| IQ empty / fetch starvation | 0.98% |

CRC removed 19% of the dynamic instructions, but the next largest lever is not
another function-specific unit: it is **load-slip / ready-based issue** and a
**2-cycle load-use path**. Those changes also help the list, matrix and state
phases.

## 7. Boundaries

- **DFA / state machine**: a single-step DFA instruction is not enough; GCC
  already specializes the state loops. A worthwhile engine would be a
  token-scan unit with its own memory port and count writeback.
- **Linked list**: the find loop is limited by dependent load latency, not
  instruction count. A list walker needs a memory-side port; a compiler-only
  replacement cannot break the address dependency.
- **Matrix / GEMM**: miniTensor is a 4x4 INT8 systolic array and is not
  instantiated in the CoreMark L2 top; CoreMark matrices are signed 16-bit.
  It is therefore not used for this variant.

## 8. Reproduction

```bash
# Build the accelerated image (core_util.c untouched)
python3 scripts/build_coremark_crc.py --out build/coremark_crc --jobs 4

# Full dual-hart run on the default 8 KiB ICache
CCACHE_DIR=/tmp/ccache-ares CCACHE_TEMPDIR=/tmp/ccache-ares-tmp CXX=g++ \
  make unit-2core-coremark DMEM=build/coremark_crc/coremark_dmem.hex

# Optional 4-iteration diagnostic image
python3 - <<'EOF'
from pathlib import Path
src = Path('build/coremark_crc/coremark_dmem.hex').read_text().splitlines()
idx = 0x1003f0 // 16
src[idx] = '00000000000000660000000400000001'
Path('build/analysis/coremark_crc_4iter.hex').write_text('\n'.join(src) + '\n')
EOF
```

The generated images, ELF files, logs and the combined 32 KiB ICache
experiment are build artifacts and remain under `build/`; they are not
committed.
