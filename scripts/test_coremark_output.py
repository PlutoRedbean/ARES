#!/usr/bin/env python3
"""Verify production printf and the software -> RTL UART/timer path with a short image."""
import argparse
from decimal import Decimal
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import elf_image

ROOT = Path(__file__).resolve().parents[1]
PORT = ROOT / "tests/benchmarks/coremark"


def test_printf(directory):
    headers = directory / "host"
    headers.mkdir()
    (headers / "am.h").write_text("void putch(char);\n")
    (headers / "klib.h").write_text("#include <stddef.h>\n#include <string.h>\n")
    (headers / "klib-macros.h").write_text(
        "#include <stdlib.h>\n#define panic(...) abort()\n")
    harness = headers / "test.c"
    harness.write_text(r'''
#include <assert.h>
#include <string.h>
int printf(const char *, ...);
int sprintf(char *, const char *, ...);
static char serial[128];
static int count;
void putch(char c) { assert(count < 128); serial[count++] = c; }
int main(void) {
    const char expected[] = "uart 0012 -7\n";
    assert(printf("uart %04x %d\n", 0x12, -7) == sizeof(expected)-1);
    assert(count == sizeof(expected)-1);
    assert(memcmp(serial, expected, count) == 0);
    char buffer[16];
    memset(buffer, 0x55, sizeof(buffer));
    assert(sprintf(buffer, "%d", 42) == 2);
    assert(buffer[0] == '4' && buffer[1] == '2' && buffer[2] == 0 && buffer[3] == 0x55);
    return 0;
}
''')
    binary = headers / "test"
    subprocess.run(["cc", "-O2", "-fno-builtin", f"-I{headers}", str(harness),
                    str(ROOT / "tests/abstract-machine/klib/src/stdio.c"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    print("PASS: printf emits no NUL; sprintf still terminates its string")


def build_smoke(directory, out):
    stage = directory / "port"
    (stage / "src").mkdir(parents=True)
    shutil.copytree(PORT / "include", stage / "include")
    shutil.copyfile(PORT / "src/core_portme.c", stage / "src/core_portme.c")
    shutil.copyfile(PORT / "test/output_smoke.c", stage / "src/output_smoke.c")
    (stage / "Makefile").write_text(
        "NAME = coremark-output-smoke\n"
        "SRCS = src/core_portme.c src/output_smoke.c\n"
        f"include {ROOT}/tests/abstract-machine/Makefile\n")
    env = dict(os.environ, CCACHE_DISABLE="1")
    result = subprocess.run(["make", "-C", str(stage), f"ARES_HOME={ROOT}",
                             "ARCH=riscv32-ares", "CROSS_COMPILE=riscv64-unknown-elf-",
                             "image"], capture_output=True, text=True, env=env)
    (out / "build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"smoke firmware build failed; see {out / 'build.log'}")
    elf = stage / "build/coremark-output-smoke-riscv32-ares.elf"
    image = out / "output_smoke.hex"
    elf_image.write_outputs(elf, out / "output_smoke.bin", image,
                            base=elf_image.DEFAULT_BASE, limit=elf_image.DEFAULT_LIMIT)
    return image


def check_output(binary, image, harts, out):
    result = subprocess.run([str(binary.resolve()), f"+DMEM={image}"],
                            capture_output=True, text=True, timeout=180)
    text = result.stdout + result.stderr
    (out / ("single.log" if harts == 1 else "dual.log")).write_text(text)
    assert result.returncode == 0 and "ALL TESTS PASSED" in text, text
    assert "CM/MHz=" not in text and "\x00" not in text, text
    for hart in range(harts):
        console = "\n".join(re.findall(rf"^\[hart{hart}\] (.*)$", text, re.MULTILINE))
        assert "UART smoke: 1234 42" in console and "UART smoke PASS" in console, console

        def field(label):
            return re.search(rf"^{re.escape(label)}\s*:\s*(\S+)", console, re.MULTILINE).group(1)

        ticks = int(field("Total ticks"))
        assert ticks > 0 and field("CPU clock (MHz)") == "100", console
        assert field("Iterations") == "4", console
        for label, numerator, denominator in [
            ("Total time (secs)", ticks, 100_000_000),
            ("Iterations/Sec", 4 * 100_000_000, ticks),
            ("CoreMark/MHz", 4 * 1_000_000, ticks),
        ]:
            expected = Decimal(numerator * 1_000_000 // denominator) / 1_000_000
            assert Decimal(field(label)) == expected, (label, console)
        print(f"PASS: {harts}-hart firmware, hart{hart}: RTL serial text and 100 MHz score arithmetic")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--single", type=Path, default=ROOT / "sim/build/unit/tb_ares_coremark/tb_ares_coremark")
    parser.add_argument("--dual", type=Path, default=ROOT / "sim/build/unit/tb_2core_coremark/tb_2core_coremark")
    parser.add_argument("--out", type=Path, default=ROOT / "build/verification/coremark-uart")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ares-coremark-output-") as temp:
        directory = Path(temp)
        test_printf(directory)
        image = build_smoke(directory, out)
        check_output(args.single, image, 1, out)
        check_output(args.dual, image, 2, out)
    print("ALL TESTS PASSED: CoreMark software output over RTL UART at 100 MHz")


if __name__ == "__main__":
    main()
