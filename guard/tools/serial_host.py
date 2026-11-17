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
                        f"等回读超时（已写 {i}/{len(data)} B，收到 {reader.count()} B，"
                        f"门槛 {gates[i]} B）。板子在正常跑吗？串口/波特率对吗？"
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
def show(raw: bytes, *, quiet: bool = False, as_json: str | None = None) -> int:
    text, reports = split_stream(raw)
    if not quiet:
        print("── 板子回显（脱敏后）" + "─" * 40)
        sys.stdout.write(text.decode("utf-8", "replace").rstrip("\r\n") + "\n")
        print("\n── 审计行（板子发的）" + "─" * 38)
        if reports:
            print(f"{'#':>2}  {'n':>4}  {'id18':>4} {'id15':>4} {'mob':>4} {'bank':>4} "
                  f"{'mail':>4} {'ipv4':>4} {'uscc':>4} {'plate':>5}  {'kw':>3} {'kwm':>3} ovf mode")
            for i, r in enumerate(reports, 1):
                print(f"{i:>2}  {r['n']:>4}  {r.get('id18',0):>4} {r.get('id15',0):>4} "
                      f"{r.get('mobile',0):>4} {r.get('bank',0):>4} {r.get('email',0):>4} "
                      f"{r.get('ipv4',0):>4} {r.get('uscc',0):>4} {r.get('plate',0):>5}  "
                      f"{r.get('kw',0):>3} {r.get('kwm',0):>3}  {r['ovf']:>3} {r.get('mode',1):>4}")
        else:
            print("(没有收到审计行)")
        flags = [i for i, r in enumerate(reports, 1) if r.get("ovf")]
        if flags:
            print(f"\n⚠ 第 {flags} 行 ovf=1：板子报过错（RX FIFO 溢出 / 输出丢字节）。"
                  "多半是上位机发太快，去掉 --no-pace 再试。")
    else:
        sys.stdout.buffer.write(text)

    if as_json:
        Path(as_json).write_text(json.dumps(reports, ensure_ascii=False, indent=2) + "\n",
                                 encoding="utf-8")
        print(f"\n审计行已写入 {as_json}")
    return 0 if not any(r.get("ovf") for r in reports) else 1


def cmd_ports() -> int:
    _, list_ports = _import_serial()
    ports = list(list_ports.comports())
    if not ports:
        print("没有发现串口。")
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
        raise SystemExit(f"串口打开/读写失败：{exc}") from exc

    rc = show(raw, quiet=args.raw and args.quiet, as_json=args.json)
    if args.raw:
        print("── 原始字节 " + "─" * 46)
        print(raw.hex(" "))

    if expect is not None:
        ok = raw == expect
        print(f"\n── 校验 " + "─" * 48)
        print(f"{'PASS' if ok else 'FAIL'}  收到 {len(raw)} B，期望 {len(expect)} B")
        if not ok:
            n = min(len(raw), len(expect))
            bad = next((i for i in range(n) if raw[i] != expect[i]), n)
            print(f"  第一个不同：偏移 {bad}")
            print(f"  期望: {expect[max(0,bad-16):bad+16]!r}")
            print(f"  收到: {raw[max(0,bad-16):bad+16]!r}")
            return 1
    return rc


SHELLISH = ("python", "python3", "powershell", "pwsh", "cmd", "cd", "dir", "ls",
            "git", "pip", "make", "wsl")


def _looks_like_shell(line: str) -> bool:
    """粗略识别"把 shell 命令打进 repl 了"的情况，省得把命令当文本发给板子。"""
    head = line.strip().split(" ", 1)[0]
    return head in SHELLISH or line.strip().startswith((".\\", "./", "--"))


def cmd_repl(args) -> int:
    serial, _ = _import_serial()
    bar = "─" * 62
    print(bar)
    print(f" guard 板级交互 —— {args.port} @ {args.baud} 8N1（输入的是**文本**，不是 shell 命令）")
    print(" · 直接键入文字，按回车发送 → 板子回显脱敏结果 + 一行审计")
    print(" · 退出：单独的 :q（或 Ctrl-C / Ctrl-D）；空行 = 发一个空帧")
    print(" · 中文按 UTF-8 发，逐字节进 L1；板子按回车（LF）切帧")
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
                print("（空行退出）")
                break
            if _looks_like_shell(line):
                print("  这看起来是 shell 命令 —— 你现在在 guard 的交互里，"
                      "板子只会把它当文本发出去。")
                print("  先 :q 退出，再在 PowerShell 里运行它。")
                continue
            data = (line + "\n").encode("utf-8")
            raw = send_and_collect(ser, data, baud=args.baud, pace=True, expect=None)
            if not raw:
                print("  （没收到任何回读：板子上电了吗？位流烧了吗？COM 口对吗？）")
            else:
                show(raw)
                print()
    print("已断开。")
    return 0


def main(argv: list[str] | None = None) -> int:
    _stdout_utf8()
    ap = argparse.ArgumentParser(
        prog="serial_host", description="guard 板级串口上位机（发文本、收脱敏结果与审计行）"
    )
    ap.add_argument("-p", "--port", help="串口号，如 COM3 / /dev/ttyUSB0")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="波特率（默认 115200）")
    ap.add_argument("--text", help="发一行文本（自动补换行）")
    ap.add_argument("--file", help="发一个文件的全部内容（每行一帧）")
    ap.add_argument("--repl", action="store_true", help="交互模式")
    ap.add_argument("--check", action="store_true", help="和板级金标逐字节比对")
    ap.add_argument("--json", help="把审计行写成 JSON")
    ap.add_argument("--raw", action="store_true", help="打印原始字节（hex）")
    ap.add_argument("-q", "--quiet", action="store_true", help="只打印脱敏文本")
    ap.add_argument("--no-pace", action="store_true", help="不按回读节奏发（可能溢出）")
    ap.add_argument("--ports", action="store_true", help="列出串口后退出")
    args = ap.parse_args(argv)

    if args.ports:
        return cmd_ports()
    if not args.port:
        ap.error("需要 --port（或用 --ports 看有哪些串口）")
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