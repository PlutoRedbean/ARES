# CoreMark UART output and 100 MHz simulation timing

CoreMark's own `ee_printf` output is enabled. The ARES software uses klib
`printf` -> `putch` -> an MMIO byte store at `0xA00003F8`. Each hart has an
`ares_benchmark_io` device that feeds the existing `ares_uart` RTL transmitter
at 100 MHz / 115200 baud / 8N1. The testbench decodes the actual TX waveform
and prints complete lines with `[hart0]` or `[hart1]` prefixes. It waits for
the final frame before finishing. The console is not a direct MMIO `$write`.

## Benchmark scoring

Rebuild the software image; old images have printf and real timing disabled.
Keep the existing 32 KiB ICache configuration from the accelerated build guide.

```bash
make coremark-full-image
make unit-2core-coremark \
    DMEM="$PWD/build/coremark_full/coremark_dmem.hex" \
    ARES_CFG_INC="+incdir+$PWD/build/coremark_32k/include" \
    SIM_HEAVY_CHECKS=0 SIM_INFO=0
```

For scoring, explicitly set both `SIM_HEAVY_CHECKS=0 SIM_INFO=0` on the
simulation run command, not the image build command. This compiles out heavy
invariant scans and hides routine harness diagnostics; UART reports and error
diagnostics remain visible. Protocol assertions and the dual-hart L2 shadow
checker still run. These settings affect host simulation cost and logging,
not the RTL clock frequency. Both CoreMark benches explicitly
generate a 10 ns clock period. The software clock constant is frozen at
100,000,000 Hz by the image builder and recorded in `inputs.json`.

## Simulation testing and debugging

Keep `SIM_HEAVY_CHECKS` and `SIM_INFO` at their defaults of `1` for simulation
testing and debugging. Omit the overrides from the scoring command:

```bash
make unit-2core-coremark \
    DMEM="$PWD/build/coremark_full/coremark_dmem.hex" \
    ARES_CFG_INC="+incdir+$PWD/build/coremark_32k/include"
```

This enables heavy invariant checks and routine harness diagnostics. If the
shell or an outer Make invocation sets either option to `0`, explicitly pass
`SIM_HEAVY_CHECKS=1 SIM_INFO=1` to restore debug behavior. The same policy
applies to `unit-coremark`. Full-check and light-check simulator builds use
separate directories, so switching modes does not require a manual clean.

### Simulation diagnostic output

Both CoreMark run targets accept `SIM_INFO=1` (default) to display harness
diagnostics: clock/check settings, periodic `T=...` progress, L2 shadow summary,
pass message and retire/cycle/IPC/L2 statistics. These lines are cyan; the pass
message is green. Failing checks and timeout diagnostics are red and remain
visible with `SIM_INFO=0`. The switch controls printing only, not checking.
Decoded UART lines, including their `[hart0]` / `[hart1]` routing prefixes,
retain their original terminal color and are always displayed.

For CoreMark serial output without routine harness information:

```bash
make unit-2core-coremark \
    DMEM="$PWD/build/coremark_full/coremark_dmem.hex" \
    ARES_CFG_INC="+incdir+$PWD/build/coremark_32k/include" \
    SIM_HEAVY_CHECKS=0 SIM_INFO=0
```

`SIM_COLOR=0` disables ANSI colors while retaining diagnostics. Both switches
are runtime settings and do not require a different simulator binary. For
direct execution, use `+SIM_INFO=0` / `+SIM_COLOR=0`; add `+verilator+quiet` to
hide Verilator's final performance report, as the Make targets do automatically
for `SIM_INFO=0`. Build-tool output and Verilator's `$finish` location line
are outside the testbench logging switch.

## Timing and score

The 64-bit counter advances once per RTL clock edge and is read at
`0xA0000050` (low) / `0xA0000054` (high). Software reads high/low/high until the
high word is stable, so a low-word carry cannot produce a torn timestamp.
`0xA00003FC` bit 0 reports UART busy. Startup output is drained before the
initial timestamp; timing fences bracket `iterate()`. Result printing, CRC
diagnostic text and final EBREAK occur after the end timestamp.

For measured cycles `C`, actual iterations `N`, and `F = 100,000,000 Hz`:

- elapsed seconds = `C / F`;
- Iterations/Sec (CoreMark throughput) = `N * F / C`;
- CoreMark/MHz = `N * 1,000,000 / C`.

The program prints total ticks, fractional seconds, actual iterations, CPU
MHz, Iterations/Sec, CoreMark/MHz, compiler version, the seed/list/matrix/state/
final CRCs, and its pass/fail result. Fixed-point arithmetic preserves six
decimal places without requiring a floating-point printf. The inherited
relative-i7 Marks calculation and fake start=0/stop=1 timer have been removed.
The timing boundary includes the small fixed cost of the timestamp/fence
sequence, but excludes the potentially long UART transfer time.

TB retire/cycle/IPC/L2 summaries still describe the entire program, including
printing. Their old hardcoded `100e6 / total_program_cycles` score is removed.
Read the score from each hart's UART report. Two independent instances are
run; the per-hart numbers are not an EEMBC multithreaded result. Accelerated
variants and short simulation runs are local performance estimates, rather
than an official report meeting EEMBC's minimum-duration rules.

## Verified 100-iteration example

On 2026-10-29, the full accelerated image with the existing 32 KiB ICache
configuration and `SIM_HEAVY_CHECKS=0` produced the following UART results:

| Field | hart0 | hart1 |
| --- | --- | --- |
| CPU clock | 100 MHz | 100 MHz |
| Timed cycles | 14,204,416 | 14,204,416 |
| Iterations | 100 | 100 |
| Iterations/Sec | 704.006416 | 704.006416 |
| CoreMark/MHz | 7.040064 | 7.040064 |
| seed / list / matrix / state / final CRC | e9f5 / e714 / 1fd7 / 8e3a / 988c | e9f5 / e714 / 1fd7 / 8e3a / 988c |

Both programs printed `CoreMark PASS`, all nine dual-hart harness checks passed,
and all five L2 shadow error counters were zero. The final whole-program
cycle counts were 17,944,380 / 17,944,394, illustrating why startup and serial
printing must be excluded from the benchmark score. The full console log is
generated at `build/verification/coremark-uart/coremark-full-100.log`.

## Focused validation

```bash
make unit-benchmark-io
make test-coremark-image
make build-coremark-sim build-2core-coremark-sim
make test-coremark-harness test-coremark-output
```

The device test checks 100 MHz counter advancement, 64-bit carry, response
backpressure, UART write backpressure, byte strobes and decoding from TX.
The output smoke test uses the production CoreMark port and printf to check
both single/dual-hart serial reports and all score formulas. It also checks
that console printf emits no NUL while sprintf still terminates its output.
Smoke images are not CoreMark benchmark runs. Logs and smoke images are
written under `build/verification/coremark-uart/`. Keep the default checks and
information enabled for these debug/regression commands; the harness and
output tests also exercise the runtime information/color switches internally.
