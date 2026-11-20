"""Optional UART debug input. Frame numbers belong to the camera clock."""
from dataclasses import dataclass
import re
import sys
from threading import Event, Thread
from time import monotonic

M1 = re.compile(rb"M1 ([0-9]{1,10}) ([01]) ([0-9]{1,3}) ([0-9]{1,3}) ([0-9A-Fa-f]{36})")


@dataclass(frozen=True)
class Summary:
    seq: int
    valid: int
    mean: int
    count: int
    mask: bytes

    def mirrored_tiles(self):
        for n in range(144):
            if self.mask[n // 8] & (1 << (n % 8)):
                yield 15 - n % 16, n // 16


def parse(line):
    match = M1.fullmatch(line.rstrip(b"\r\n"))
    if not match:
        return None
    seq, valid, mean, count = map(int, match.groups()[:4])
    mask = bytes.fromhex(match[5].decode("ascii"))
    if (seq > 0xffffffff or mean > 255 or count != sum(b.bit_count() for b in mask)
            or (not valid and (mean or count))):
        return None
    return Summary(seq, valid, mean, count, mask)


class MotionFeed:
    def __init__(self):
        self.latest = None
        self.last_seq = None
        self.stop = Event()

    def accept(self, summary, now):
        if summary.seq == self.last_seq:
            return
        gap = self.last_seq is not None and summary.seq != (self.last_seq + 1) % 2**32
        if gap:
            print(f"M1 sequence {self.last_seq} -> {summary.seq}", file=sys.stderr)
        self.last_seq = summary.seq
        self.latest = (now, summary) if summary.valid else None

    def current(self, now):
        latest = self.latest
        return latest[1] if latest and now - latest[0] < 0.5 else None

    def read_port(self, port):
        import serial
        try:
            with serial.Serial(port, 115200, timeout=0.1, write_timeout=0.5) as uart:
                uart.write(b"motion\r")
                pending = b""
                while not self.stop.is_set():
                    data = uart.read(uart.in_waiting or 1)
                    lines = (pending + data).split(b"\n")
                    pending = lines.pop()[-256:]
                    for line in lines:
                        summary = parse(line)
                        if summary:
                            self.accept(summary, monotonic())
                        elif line.startswith((b"MOTION", b"motion requires", b"Stop live AI")):
                            print(line.decode("ascii", errors="replace"), file=sys.stderr)
                uart.write(b"\x1d")
        except (serial.SerialException, OSError) as error:
            print(f"Motion UART {port}: {error}", file=sys.stderr)
        finally:
            self.latest = None

    def start(self, port):
        thread = Thread(target=self.read_port, args=(port,), daemon=True)
        thread.start()
        return thread
