"""Exercise the NER-enabled hart0 firmware over the simulated board UART."""
from pathlib import Path
import os
import re
import selectors
import subprocess
import time

root = Path(__file__).resolve().parents[1]
out = root / "build/rtos_amp"
log = out / "guard_uart.log"
received = bytearray()
consumed = 0

with subprocess.Popen([out / "model/run", "--burst", "--max-ms", "4000"], cwd=root,
                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.STDOUT) as sim, selectors.DefaultSelector() as selector, log.open("wb", buffering=0) as transcript:
    selector.register(sim.stdout, selectors.EVENT_READ)

    def until(marker, timeout=180):
        global consumed
        deadline = time.monotonic() + timeout
        while (end := received.find(marker, consumed)) < 0:
            if not selector.select(max(0, deadline - time.monotonic())):
                raise TimeoutError(f"waiting for {marker!r}, see {log}")
            chunk = os.read(sim.stdout.fileno(), 4096)
            if not chunk:
                raise ValueError(f"simulation ended waiting for {marker!r}, see {log}")
            received.extend(chunk)
            transcript.write(chunk)
        end += len(marker)
        result = bytes(received[consumed:end])
        consumed = end
        return result

    def send(data):
        sim.stdin.write(data)
        sim.stdin.flush()

    def frame(data, body, field=None, timeout=180):
        send(data)
        packet = until(b"mode=1\r\n", timeout)
        actual, report = packet.split(b"[guard] ", 1)
        if actual != body or b"ovf=000" not in report:
            raise ValueError(f"unexpected redacted body or audit for {data!r}: {packet!r}")
        if field and not re.search(rb"\b" + field + rb"=00[1-9]\b", report):
            raise ValueError(f"missing {field!r} in {report!r}")

    try:
        until(b"msh >")
        send(b"guard status\nguard selftest\nguard start\n")
        setup = until(b"at frame boundary exits)\r\n")
        assert b"Guard ready, NER=1" in setup and b"Guard selftest PASS" in setup
        frame(b"13800138000\n", b"*******8000\r\n", b"mobile")
        frame("请把文件发给杨帆\n".encode(), "请把文件发给杨***\r\n".encode(), b"name")
        address = "北京市朝阳区建国路88号".encode()
        frame("地址：".encode() + address + b"\n", "地址：".encode() + b"*" * len(address) + b"\r\n", b"addr")
        for size in (63, 64, 65):
            prefix = b"." * (size - 12)
            frame(prefix + b"13800138000\n", prefix + b"*******8000\r\n", b"mobile")
        send(b"\x1d")
        assert b"GUARD EXIT" in until(b"msh >")
        send(b"guard status\nguard start\n")
        assert b"frames=6 errors=0" in until(b"at frame boundary exits)\r\n")
        frame(b"13800138000", b"*******8000\r\n", b"mobile", timeout=1200)
        send(b"\x1d")
        until(b"msh >")
        send(b"ai selftest\n")
        until(b"golden diff 0")
        send(b"guard status\nquit\n")
        assert b"frames=7 errors=0" in until(b"ARES SHELL EXIT")
        assert sim.wait(timeout=10) == 0
    finally:
        if sim.poll() is None:
            sim.terminate()

print(f"Guard RTT PASS: NER, byte masks, frame boundaries, idle flush, MSH restore, AI. UART log: {log}")
