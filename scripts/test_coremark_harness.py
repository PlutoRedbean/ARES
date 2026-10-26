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
        for label, binary in (("single", args.single), ("dual", args.dual)):
            output = run(binary, f"{label}: a0 update before EBREAK", [f"+DMEM={good}"], True, "ALL TESTS PASSED")
            retired = [int(value) for value in re.findall(r"retires=(\d+)", output)]
            assert retired == ([3] if label == "single" else [3, 3, 6]), output
            run(binary, f"{label}: nonzero return", [f"+DMEM={bad}"], False, "CoreMark failed")
            run(binary, f"{label}: missing argument", [], False, "is required")
            run(binary, f"{label}: missing file", [f"+DMEM={directory / 'missing.hex'}"], False, "Cannot open DMEM")
            run(binary, f"{label}: timeout", [f"+DMEM={loop}", "+TIMEOUT_NS=10000"], False, "CoreMark timeout")
        output = run(args.dual, "dual: disabled hart1", [f"+DMEM={good}", "+H1EN=0"], True, "ALL TESTS PASSED")
        assert [int(value) for value in re.findall(r"retires=(\d+)", output)] == [3, 0, 3], output
        hart0_score = re.search(r"hart0:.*CM/MHz=(\S+)", output).group(1)
        aggregate_score = re.search(r"aggregate:.*CM/MHz=(\S+)", output).group(1)
        assert aggregate_score == hart0_score, output
        run(args.dual, "dual: hart1 failure is fatal", [f"+DMEM={asymmetric}"], False, "CoreMark failed")
        run(args.dual, "dual: hart0 success waits for hart1", [f"+DMEM={waiting}", "+TIMEOUT_NS=10000"], False, "CoreMark timeout")
    print(f"ALL TESTS PASSED: CoreMark harness {checks} checks")


if __name__ == "__main__":
    main()
