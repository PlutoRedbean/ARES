#!/usr/bin/env python3
"""Check the real CoreMark harnesses with small RV32 images, without a benchmark input."""

import argparse
from pathlib import Path
import re
import resource
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--single", type=Path, default=root / "sim/build/unit/tb_ares_coremark/tb_ares_coremark")
    parser.add_argument("--dual", type=Path, default=root / "sim/build/unit/tb_2core_coremark/tb_2core_coremark")
    args = parser.parse_args()
    # Expected $fatal exits must not leave simulator core dumps in the checkout.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    checks = 0
    with tempfile.TemporaryDirectory(prefix="ares-coremark-harness-") as directory:
        directory = Path(directory)

        def image(name, words):
            data = b"".join(word.to_bytes(4, "little") for word in words)
            data += bytes(-len(data) % 16)
            path = directory / (name + ".hex")
            path.write_text("".join(f"{int.from_bytes(data[i:i+16], 'little'):032x}\n" for i in range(0, len(data), 16)))
            return path

        def run(binary, name, options, success, marker):
            nonlocal checks
            result = subprocess.run([str(binary.resolve()), *options], capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            if (result.returncode == 0) != success or marker not in output:
                raise AssertionError(f"{name}: exit={result.returncode}, expected success={success}\n{output}")
            checks += 1
            print(f"PASS: {name}")
            return output

        good = image("good", [0x00100513, 0x00000513, 0x00100073, 0x0000006F])
        bad = image("bad", [0x00100513, 0x00100073, 0x0000006F])
        loop = image("loop", [0x0000006F])
        # csrr a0,mhartid; ebreak: hart0 succeeds, hart1 fails.
        asymmetric = image("hart1-bad", [0xF1402573, 0x00100073, 0x0000006F])
        # hart0 exits; hart1 branches to a spin loop. The harness must wait for both.
        waiting = image("hart1-waits", [0xF14022F3, 0x00029663, 0x00000513, 0x00100073, 0x0000006F])
        # Eight instructions that issue four D-side loads: enough L2 read
        # responses for the shadow fault to be followed by correct ones.
        # Loads target 0x8010_0000: with the dual-core AMP offset this becomes
        # 0x8020_0000 on hart1, so both harts stay inside their own private
        # window (the TB flags hart1 reads below 0x8020_0000).
        multi = image("multi-read", [
            0x801002B7,  # lui   t0, 0x80100    (0x8010_0000)
            0x0002A303,  # lw    t1, 0(t0)
            0x0042A303,  # lw    t1, 4(t0)
            0x0082A303,  # lw    t1, 8(t0)
            0x00C2A303,  # lw    t1, 12(t0)
            0x00000513,  # addi  a0, x0, 0
            0x00100073,  # ebreak
        ])
        for label, binary in (("single", args.single), ("dual", args.dual)):
            output = run(binary, f"{label}: a0 update before EBREAK", [f"+DMEM={good}"], True, "ALL TESTS PASSED")
            assert "\x1b[36mBenchmark clock:" in output, output
            assert "\x1b[32mALL TESTS PASSED" in output, output
            retired = [int(value) for value in re.findall(r"retires=(\d+)", output)]
            assert retired == ([3] if label == "single" else [3, 3, 6]), output
            output = run(binary, f"{label}: color disabled",
                         [f"+DMEM={good}", "+SIM_COLOR=0"], True, "ALL TESTS PASSED")
            assert "\x1b[" not in output and "Benchmark clock:" in output, output
            output = run(binary, f"{label}: simulation information disabled",
                         [f"+DMEM={good}", "+SIM_INFO=0", "+verilator+quiet"], True, "")
            for message in ("Benchmark clock:", "Simulation heavy checks:", "T=", "ALL TESTS PASSED",
                            "retires=", "L2 shadow check:", "L2:", "Verilation Report"):
                assert message not in output, output
            assert "\x1b[" not in output, output
            output = run(binary, f"{label}: quiet mode retains errors",
                         [f"+DMEM={bad}", "+SIM_INFO=0"], False, "CoreMark failed")
            assert "\x1b[31mFAIL:" in output, output
            run(binary, f"{label}: quiet mode retains timeout context",
                [f"+DMEM={loop}", "+SIM_INFO=0", "+TIMEOUT_NS=10000"], False, "*** TIMEOUT:")
            run(binary, f"{label}: nonzero return", [f"+DMEM={bad}"], False, "CoreMark failed")
            run(binary, f"{label}: missing argument", [], False, "is required")
            run(binary, f"{label}: missing file", [f"+DMEM={directory / 'missing.hex'}"], False, "Cannot open DMEM")
            run(binary, f"{label}: timeout", [f"+DMEM={loop}", "+TIMEOUT_NS=10000"], False, "CoreMark timeout")
        # Completion-cycle bound (A1 item 6): a short image must finish inside a
        # generous bound, and a deliberately tight bound must fail loudly.
        for label, binary in (("single", args.single), ("dual", args.dual)):
            run(binary, f"{label}: completion cycle bound holds",
                [f"+DMEM={good}", "+MAX_CYCLES=100000"], True, "ALL TESTS PASSED")
            run(binary, f"{label}: completion cycle bound violated",
                [f"+DMEM={good}", "+MAX_CYCLES=1"], False, "MAX_CYCLES")
        output = run(args.dual, "dual: shadow checker fault is fatal",
                     [f"+DMEM={multi}", "+SHADOW_FAULT=1"], False, "CoreMark failed")
        responses = int(re.search(r"rsp=(\d+)", output).group(1))
        injected = sum(int(value) for value in
                       re.findall(r"err_(?:i0|i1|c0|c1)=(\d+)", output))
        assert responses >= 3 and injected == 1, (responses, injected, output)
        output = run(args.dual, "dual: quiet mode retains shadow errors",
                     [f"+DMEM={multi}", "+SHADOW_FAULT=1", "+SIM_INFO=0"], False, "CoreMark failed")
        assert "MISMATCH" in output and "\x1b[31m" in output, output
        output = run(args.dual, "dual: shadow checker clean run is quiet",
                     [f"+DMEM={multi}"], True, "ALL TESTS PASSED")
        assert re.search(r"err_i0=0 err_i1=0 err_c0=0 err_c1=0 err_wb=0", output), output
        output = run(args.dual, "dual: disabled hart1", [f"+DMEM={good}", "+H1EN=0"], True, "ALL TESTS PASSED")
        assert [int(value) for value in re.findall(r"retires=(\d+)", output)] == [3, 0, 3], output
        hart0_cycles = re.search(r"hart0:.*cycles=(\d+)", output).group(1)
        aggregate_cycles = re.search(r"aggregate:.*max_cycles=(\d+)", output).group(1)
        assert aggregate_cycles == hart0_cycles, output
        assert "CM/MHz=" not in output, output  # synthetic images have no score
        run(args.dual, "dual: hart1 failure is fatal", [f"+DMEM={asymmetric}"], False, "CoreMark failed")
        run(args.dual, "dual: hart0 success waits for hart1", [f"+DMEM={waiting}", "+TIMEOUT_NS=10000"], False, "CoreMark timeout")
    print(f"ALL TESTS PASSED: CoreMark harness {checks} checks")


if __name__ == "__main__":
    main()
