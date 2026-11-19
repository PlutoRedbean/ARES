#!/usr/bin/env python3
"""guard 的本地可跑入口：文本进 → 脱敏文本 + 审计表（默认走全 RTL）。

用法：
    ./run.sh demo                     # examples/sample.txt，全 RTL mask
    ./run.sh text "手机 13800138000"   # 一行文本
    ./run.sh file 某些.txt            # 文件
    ./run.sh file 某些.txt --json a.json --policy token
    ./run.sh repl                     # 交互（Ctrl-D 退出）
    ./run.sh report 某些.txt          # 只统计，不打印全文
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.keywords import KEYWORDS, find_keywords  # noqa: E402
from host.golden.pii_rules import TYPE_NAMES, scan  # noqa: E402
from host.golden.redact import Audit, audit_json  # noqa: E402
from host.golden.pipeline import run_golden, run_rtl_mask  # noqa: E402

RED_BIN = ROOT / "build" / "obj_redtop" / "Vredact"
MASK = 1  # 显示用


# 检测/脱敏实现在 host/golden/pipeline.py（CLI、demo、server 共用）


# --------------------------------------------------------------------- 展示
def render(data: bytes, out: bytes, audits: list[Audit], mode: str, quiet: bool = False) -> None:
    if quiet:
        sys.stdout.buffer.write(out + b"\n")
        return

    kw = find_keywords(data)
    print("\n── 脱敏结果 " + "─" * 46)
    sys.stdout.write(out.decode("utf-8", "replace").rstrip("\n") + "\n")

    print(f"\n── 审计 ({len(audits)}) " + "─" * 44)
    if audits:
        print(f"{'#':>2}  {'type':<7}{'span':<12}{'rule':<18}{'action':<7}replacement")
        for a in audits:
            print(f"{a.index:>2}  {a.type:<7}{f'{a.start}+{a.length}':<12}{a.rule:<18}{a.action:<8}{a.replacement}")
    else:
        print("(未发现 PII)")

    print(f"\n── 关键词提示 " + "─" * 42)
    if kw:
        seen = []
        for h in kw:
            name = KEYWORDS[h.kid]
            if name not in seen:
                seen.append(name)
        print("、".join(seen))
    else:
        print("(无)")

    kinds: dict[str, int] = {}
    for a in audits:
        kinds[a.type] = kinds.get(a.type, 0) + 1
    stats = " ".join(f"{k}={v}" for k, v in sorted(kinds.items())) or "-"
    print(f"\n── 统计 " + "─" * 48)
    print(f"mode={mode}  in={len(data)}B  out={len(out)}B  spans={len(audits)}  {stats}\n")


def run_bytes(data: bytes, policy: str, json_path: str | None, out_path: str | None, quiet: bool) -> None:
    if policy == "token":
        out, audits = run_golden(data, "token")
        mode = "golden-token"
    else:
        out, audits = run_rtl_mask(data)
        mode = "rtl-mask"

    if out_path:
        Path(out_path).write_bytes(out)
    if json_path:
        Path(json_path).write_text(audit_json(audits) + "\n", encoding="utf-8")
    render(data, out, audits, mode, quiet)


# --------------------------------------------------------------------- 命令
def cmd_demo(args) -> int:
    path = ROOT / "examples" / "sample.txt"
    run_bytes(path.read_bytes(), args.policy, args.json, args.out, args.quiet)
    return 0


def cmd_text(args) -> int:
    run_bytes(" ".join(args.words).encode("utf-8"), args.policy, args.json, args.out, args.quiet)
    return 0


def cmd_file(args) -> int:
    data = Path(args.path).read_bytes()
    run_bytes(data, args.policy, args.json, args.out, args.quiet)
    return 0


def cmd_report(args) -> int:
    data = Path(args.path).read_bytes()
    out, audits = run_rtl_mask(data)
    kinds: dict[str, int] = {}
    for a in audits:
        kinds[a.type] = kinds.get(a.type, 0) + 1
    kw = sorted({KEYWORDS[h.kid] for h in find_keywords(data)})
    print(f"file={args.path} in={len(data)}B out={len(out)}B spans={len(audits)}")
    print("  types:", ", ".join(f"{k}={v}" for k, v in sorted(kinds.items())) or "-")
    print("  keywords:", "、".join(kw) or "-")
    return 0


def cmd_repl(args) -> int:
    if sys.stdin.isatty():
        print("guard repl —— 输入文本回车脱敏；:policy token|mask 切换；:q 退出")
    policy = args.policy
    while True:
        if sys.stdin.isatty():
            sys.stdout.write(f"guard[{policy}]> ")
            sys.stdout.flush()
        line = sys.stdin.buffer.readline()
        if not line:
            break
        text = line.decode("utf-8", "replace").rstrip("\n")
        if text.strip() in (":q", ":quit", "exit"):
            break
        if text.startswith(":policy "):
            p = text.split(maxsplit=1)[1].strip()
            if p in ("token", "mask"):
                policy = p
                print(f"(policy -> {policy})")
            else:
                print("(用法: :policy token|mask)")
            continue
        if not text:
            continue
        run_bytes(text.encode("utf-8"), policy, None, None, False)
    return 0


def cmd_serve(args) -> int:
    from tools.guard_server import main as serve_main  # noqa: PLC0415

    return serve_main(["--port", str(args.port), "--host", args.host])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="guard", description="PII 脱敏网关本地 demo")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--policy", choices=["mask", "token"], default="mask")
        p.add_argument("--json", help="审计 JSON 输出路径")
        p.add_argument("--out", help="脱敏文本输出路径")
        p.add_argument("-q", "--quiet", action="store_true", help="只输出脱敏文本（管道用）")

    p = sub.add_parser("demo", help="跑 examples/sample.txt")
    common(p)
    p.set_defaults(func=cmd_demo)

    p = sub.add_parser("text", help="脱敏一段文本")
    p.add_argument("words", nargs="+")
    common(p)
    p.set_defaults(func=cmd_text)

    p = sub.add_parser("file", help="脱敏一个文件")
    p.add_argument("path")
    common(p)
    p.set_defaults(func=cmd_file)

    p = sub.add_parser("report", help="只统计")
    p.add_argument("path")
    p.set_defaults(func=cmd_report)

    p = sub.add_parser("serve", help="本地工作台（网页，实时脱敏）")
    p.add_argument("--port", type=int, default=8766)
    p.add_argument("--host", default="127.0.0.1")
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("repl", help="交互模式")
    p.add_argument("--policy", choices=["mask", "token"], default="mask")
    p.set_defaults(func=cmd_repl)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
