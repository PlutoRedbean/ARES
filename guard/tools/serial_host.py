#!/usr/bin/env python3
"""guard 板级上位机：把文本从串口发给盘古 200Pro+，读回脱敏文本 + 审计行。

板子上的逻辑见 rtl/board/guard_uart_core.sv；协议只有一条：
    发文本 → 回 mask 脱敏后的文本（1:1 长度）→ 一帧结束时回一行
    [guard] n=NNN id18=NNN ... plate=NNN ovf=NNN

用法（先烧好 guard_board_top.sbit）：

    python3 tools/serial_host.py --ports                    # 列出串口
    python3 tools/serial_host.py -p COM3 --text "手机 13800138000"
    python3 tools/serial_host.py -p COM3 --file examples/sample.txt --check
    python3 tools/serial_host.py -p COM3 --file examples/sample.txt --check --json audit.json
    python3 tools/serial_host.py -p COM3 --repl              # 交互（Ctrl-D 退出）
    python3 tools/serial_host.py -p COM3 --text "..." --raw  # 打印原始字节

--check 会把收到的字节流和 host/golden/board_proto.py 算出的期望流逐字节比对
（和仿真是同一份期望，所以板上跑通 ≈ sim/tb_guard_uart.sv 跑通）。

为什么要"跟着回读发"（--pace，默认开）：摘要行让输出字节数 > 输入字节数，
板子的输入消费速度被回读速率卡住；照线速猛灌会把 256 字节的 RX FIFO 灌爆
（板子会回 ovf=001、LED2 亮）。门槛算法在 host/golden/board_proto.py。
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.board_proto import (  # noqa: E402
    expected_stream,
    output_thresholds,
    split_stream,
)

CHUNK = 64            # 每次最多写多少字节，然后等回读追上
DRAIN_EXTRA = 0.35    # 发完之后再多等这么久，收干净空闲冲刷


def _stdout_utf8() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001 - 老 Python / 被重定向时忽略
            pass


def _import_serial():
    try:
        import serial  # noqa: PLC0415
        from serial.tools import list_ports  # noqa: PLC0415
    except ImportError as exc:  # noqa: BLE001
        raise SystemExit(
            "缺少 pyserial：pip install pyserial\n"
            f"（原始错误：{exc}）"
        ) from exc
    return serial, list_ports


class Reader(threading.Thread):
    """后台收字节，放到 self.buf 里。"""

    def __init__(self, ser) -> None:
        super().__init__(daemon=True)
        self.ser = ser
        self.buf = bytearray()
        self.lock = threading.Lock()
        self.stop_flag = False

    def run(self) -> None:
        while not self.stop_flag:
            try:
                n = self.ser.in_waiting
                data = self.ser.read(n if n else 1)
            except Exception:  # noqa: BLE001 - 拔线就退出
                return
            if data:
                with self.lock:
                    self.buf += data

    def count(self) -> int:
        with self.lock:
            return len(self.buf)

    def data(self) -> bytes:
        with self.lock:
            return bytes(self.buf)

    def clear(self) -> None:
        with self.lock:
            self.buf.clear()

    def stop(self) -> None:
        self.stop_flag = True


def _wait_for(pred, deadline: float, step: float = 0.002) -> bool:
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(step)
    return pred()


def next_chunk_end(gates: list[int], i: int, avail: int, chunk: int = CHUNK) -> int:
    """从第 i 个字节开始，能立刻写出的结束下标（左闭右开）。

    `gates[k]` = "发第 k 个字节之前，至少要收到多少字节"。写的时候不能越过
    放行范围，否则会把板上 RX FIFO 灌爆。返回 `i` 表示一个都放行不了（要等）。

    这个函数单独拎出来是为了可测：真实板的第一次上板就是栽在这里——原来按
    "这一块最后一个字节的门槛"等，第一块还没发出去就要求已经收到回读，直接
    死等到超时（已写 0/375 B）。仿真 TB 用自己的 .pace 逻辑，绕过了这段代码，
    所以只有上板才能暴露。
    """
    n = len(gates) - 1                      # gates 末尾多一个，对应"发完"
    j = i
    while j < n and (j - i) < chunk and gates[j] <= avail:
        j += 1
    return j


def send_and_collect(ser, data: bytes, *, baud: int, pace: bool, expect: bytes | None) -> bytes:
    """按回读节奏把 data 发出去，返回收到的字节流。"""
    reader = Reader(ser)
    reader.start()
    try:
        reader.clear()
        gates = output_thresholds(data) if pace else [0] * (len(data) + 1)
        deadline = time.monotonic() + len(data) * 10.0 / baud + 30.0

        i = 0
        while i < len(data):
            # 门槛是"发第 k 个字节之前至少要收到多少字节"。按当前回读量
            # 能放行多少就写多少（最多 CHUNK），不要写超过放行范围的字节——
            # 否则会把板上 RX FIFO 灌爆（ovf=1）。
            j = next_chunk_end(gates, i, reader.count())
            if j == i:
                # 一个都放行不了：等这个字节的门槛
                if not _wait_for(lambda g=gates[i]: reader.count() >= g, deadline):
                    raise SystemExit(
                        f"Read-back timeout (wrote {i}/{len(data)} B, received {reader.count()} B, "
                        f"gate {gates[i]} B). Is the board alive? Right port/baud?"
                    )
                continue
            ser.write(data[i:j])
            ser.flush()
            i = j

        # 等收齐：有期望就等期望长度，否则等到空闲
        if expect is not None:
            _wait_for(lambda: reader.count() >= len(expect), deadline)
            time.sleep(DRAIN_EXTRA)
        else:
            last = -1
            while time.monotonic() < deadline:
                now = reader.count()
                if now == last and now > 0:
                    break
                last = now
                time.sleep(DRAIN_EXTRA / 2)
        return reader.data()
    finally:
        reader.stop()
        time.sleep(0.05)
        reader.join(timeout=0.2)


# --------------------------------------------------------------------- 展示
STAR = "\uff0a"     # ＊：板上按字节给 '*'(1 字节 1 个)，这里按"字符"显示成一个


def render_mask(masked: bytes, original: bytes | None) -> str:
    """把板子的逐字节掩码渲染成"一个字符一个星"（只影响显示，字节流不变）。

    板子的掩码是 1:1 的：一个 3 字节汉字变成三个 '*'。这里按**连续星号段**处理：
    段首在原文里是多字节字符（>= 0xE0）且段长能被 3 整除 -> 每 3 个换一个 '＊'；
    其它（号码、ASCII）保持原样。段边界对齐可靠，不需要逐字节同步。
    """
    if original is None:
        return masked.decode("utf-8", "replace")
    out = bytearray()
    star3 = "\uff0a".encode("utf-8")
    star2 = "\u00d7".encode("utf-8")
    i, n = 0, len(masked)
    while i < n:
        if masked[i] != 0x2A:
            out += masked[i:i + 1]
            i += 1
            continue
        j = i
        while j < n and masked[j] == 0x2A:
            j += 1
        run = j - i
        lead = original[i] if i < len(original) else 0
        if lead >= 0xE0 and run % 3 == 0:
            out += star3 * (run // 3)
        elif 0xC0 <= lead < 0xE0 and run % 2 == 0:
            out += star2 * (run // 2)
        else:
            out += b"*" * run
        i = j
    return out.decode("utf-8", "replace")


def show(raw: bytes, *, quiet: bool = False, as_json: str | None = None,
         sent: bytes | None = None) -> int:
    text, reports = split_stream(raw)
    if not quiet:
        print("── masked echo from the board " + "─" * 36)
        sys.stdout.write(render_mask(text, sent).rstrip("\r\n") + "\n")
        print("\n── audit line(s) from the board " + "─" * 34)
        if reports:
            print(f"{'#':>2}  {'n':>4}  {'id18':>4} {'id15':>4} {'mob':>4} {'bank':>4} "
                  f"{'mail':>4} {'ipv4':>4} {'uscc':>4} {'plate':>5} {'name':>5} {'addr':>5} "
                  f"{'kw':>3} {'kwm':>3} {'l2':>3} {'l2m':>3} ovf mode")
            for i, r in enumerate(reports, 1):
                print(f"{i:>2}  {r['n']:>4}  {r.get('id18',0):>4} {r.get('id15',0):>4} "
                      f"{r.get('mobile',0):>4} {r.get('bank',0):>4} {r.get('email',0):>4} "
                      f"{r.get('ipv4',0):>4} {r.get('uscc',0):>4} {r.get('plate',0):>5} "
                      f"{r.get('name',0):>5} {r.get('addr',0):>5} "
                      f"{r.get('kw',0):>3} {r.get('kwm',0):>3} "
                      f"{r.get('l2',0):>3} {r.get('l2m',0):>3}  {r['ovf']:>3} {r.get('mode',1):>4}")
        else:
            print("(no audit line received)")
        flags = [i for i, r in enumerate(reports, 1) if r.get("ovf")]
        if flags:
            print(f"\n!! audit line(s) {flags} report ovf=1 (RX FIFO overflow / dropped bytes)."
                  " The host probably sent too fast; drop --no-pace and retry.")
    else:
        sys.stdout.buffer.write(text)

    if as_json:
        Path(as_json).write_text(json.dumps(reports, ensure_ascii=False, indent=2) + "\n",
                                 encoding="utf-8")
        print(f"\nAudit written to {as_json}")
    return 0 if not any(r.get("ovf") for r in reports) else 1


def cmd_ports() -> int:
    _, list_ports = _import_serial()
    ports = list(list_ports.comports())
    if not ports:
        print("No serial port found.")
        return 1
    for p in ports:
        print(f"{p.device:12s} {p.description}")
    return 0


def run_text(args, data: bytes) -> int:
    serial, _ = _import_serial()
    expect = expected_stream(data) if args.check else None
    try:
        with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=5) as ser:
            raw = send_and_collect(ser, data, baud=args.baud, pace=not args.no_pace, expect=expect)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"Cannot open/read serial port: {exc}") from exc

    rc = show(raw, quiet=args.raw and args.quiet, as_json=args.json, sent=data)
    if args.raw:
        print("── raw bytes " + "─" * 49)
        print(raw.hex(" "))

    if expect is not None:
        ok = raw == expect
        print(f"\n── verify " + "─" * 52)
        print(f"{'PASS' if ok else 'FAIL'}  received {len(raw)} B, expected {len(expect)} B")
        if not ok:
            n = min(len(raw), len(expect))
            bad = next((i for i in range(n) if raw[i] != expect[i]), n)
            print(f"  first difference at offset {bad}")
            print(f"  expected: {expect[max(0,bad-16):bad+16]!r}")
            print(f"  received: {raw[max(0,bad-16):bad+16]!r}")
            return 1
    return rc


LOGO = r"""
    _    ____  _____ ____     ____ _   _    _    ____  ____
   / \  |  _ \| ____/ ___|   / ___| | | |  / \  |  _ \|  _ \
  / _ \ | |_) |  _| \___ \  | |  _| | | | / _ \ | |_) | | | |
 / ___ \|  _ <| |___ ___) | | |_| | |_| |/ ___ \|  _ <| |_| |
/_/   \_\_| \_\_____|____/   \____|\___//_/   \_\_| \_\____/
"""

TAGLINE = "  PII redaction, on the wire - UART in, masked text + audit out"


def print_logo(out=None) -> None:
    """Demo splash. Pure ASCII so it renders in any terminal or log file."""
    stream = out or sys.stdout
    stream.write("\n" + LOGO.lstrip("\n") + TAGLINE + "\n\n")

SHELLISH = ("python", "python3", "powershell", "pwsh", "cmd", "cd", "dir", "ls",
            "git", "pip", "make", "wsl")


def _looks_like_shell(line: str) -> bool:
    """粗略识别"把 shell 命令打进 repl 了"的情况，省得把命令当文本发给板子。"""
    head = line.strip().split(" ", 1)[0]
    return head in SHELLISH or line.strip().startswith((".\\", "./", "--"))


def cmd_repl(args) -> int:
    serial, _ = _import_serial()
    bar = "─" * 66
    print_logo()
    print(bar)
    print(f" interactive mode - {args.port} @ {args.baud} 8N1  (you type TEXT, not shell commands)")
    print(" - type a line, press Enter -> the board echoes masked text + one audit line")
    print(" - quit: :q (also Ctrl-C / Ctrl-D); an empty line sends an empty frame")
    print(" - UTF-8 goes in byte by byte; the board frames on Enter (LF)")
    print(bar)
    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=5) as ser:
        while True:
            try:
                line = input("文本> ")
            except (EOFError, KeyboardInterrupt):
                print()
                break
            s = line.strip()
            if s in (":q", "quit", "exit"):
                break
            if not s:
                print("(empty line - bye)")
                break
            if _looks_like_shell(line):
                print("  That looks like a shell command. You are inside the guard REPL;")
                print("  the board would just receive it as text. Type :q first, then run it.")
                continue
            data = (line + "\n").encode("utf-8")
            raw = send_and_collect(ser, data, baud=args.baud, pace=True, expect=None)
            if not raw:
                print("  (no read-back: board powered? bitstream loaded? right COM port?)")
            else:
                show(raw, sent=data)
                print()
    print("Disconnected.")
    return 0


def main(argv: list[str] | None = None) -> int:
    _stdout_utf8()
    ap = argparse.ArgumentParser(
        prog="serial_host", description="ARES GUARD host tool: send text, read masked text + audit"
    )
    ap.add_argument("-p", "--port", help="serial port, e.g. COM9 / /dev/ttyUSB0")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="baud rate (default 115200)")
    ap.add_argument("--text", help="send one line of text (newline appended)")
    ap.add_argument("--file", help="send a whole file (one frame per line)")
    ap.add_argument("--repl", action="store_true", help="interactive mode")
    ap.add_argument("--check", action="store_true", help="compare byte for byte with the golden model")
    ap.add_argument("--json", help="write the audit lines as JSON")
    ap.add_argument("--raw", action="store_true", help="also dump raw bytes (hex)")
    ap.add_argument("-q", "--quiet", action="store_true", help="print masked text only")
    ap.add_argument("--no-pace", action="store_true", help="do not pace by read-back (may overflow)")
    ap.add_argument("--ports", action="store_true", help="list serial ports and exit")
    args = ap.parse_args(argv)

    if args.ports:
        return cmd_ports()
    if not args.port:
        ap.error("need --port (or --ports to list them)")
    if args.repl:
        return cmd_repl(args)
    if args.file:
        data = Path(args.file).read_bytes()
    elif args.text is not None:
        data = args.text.encode("utf-8")
        if not data.endswith(b"\n"):
            data += b"\n"
    else:
        ap.error("需要 --text / --file / --repl 之一")
    return run_text(args, data)


if __name__ == "__main__":
    raise SystemExit(main())