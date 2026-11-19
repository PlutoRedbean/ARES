"""检测 + 脱敏流水线的统一封装（CLI / demo / 本地服务共用）。"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from host.golden.pii_rules import TYPE_NAMES, scan
from host.golden.redact import RULE_IDS, Audit, redact

ROOT = Path(__file__).resolve().parents[2]
RED_BIN = ROOT / "build" / "obj_redtop" / "Vredact"


def _parse_audit(text: str) -> list[tuple[int, int, int]]:
    out = []
    for line in text.splitlines():
        p = line.split()
        if len(p) == 3:
            out.append((int(p[0]), int(p[1]), int(p[2])))
    return out


def run_rtl_mask(data: bytes) -> tuple[bytes, list[Audit]]:
    """全 RTL：检测 + 合并 + mask 替换。返回 (脱敏字节, 审计)。"""
    if not RED_BIN.exists():
        raise FileNotFoundError(str(RED_BIN))
    with tempfile.NamedTemporaryFile(suffix=".in", delete=False) as inf:
        inf.write(data)
        inp = Path(inf.name)
    with tempfile.NamedTemporaryFile(suffix=".mask", delete=False) as tf:
        tmp = Path(tf.name)
    try:
        proc = subprocess.run([str(RED_BIN), str(inp), str(tmp)], capture_output=True, check=True)
        out = tmp.read_bytes()
    finally:
        inp.unlink(missing_ok=True)
        tmp.unlink(missing_ok=True)

    audits = []
    for i, (st, ln, ty) in enumerate(_parse_audit(proc.stdout.decode()), 1):
        seg = data[st : st + ln]
        keep = min(4, ln)
        repl = b"*" * (ln - keep) + seg[ln - keep :]
        audits.append(
            Audit(i, TYPE_NAMES[ty], ty, RULE_IDS[ty], st, ln, "mask", repl.decode("utf-8", "replace"))
        )
    return out, audits


def run_golden(data: bytes, policy: str) -> tuple[bytes, list[Audit]]:
    spans = scan(data)
    return redact(data, policy=policy, keep_spans=spans)


def highlights(data: bytes, audits: list[Audit]) -> list[tuple[int, int, str]]:
    """审计记录 → 输出文本里的高亮区间（字节坐标）。"""
    res: list[tuple[int, int, str]] = []
    cur_in = 0
    cur_out = 0
    for a in audits:
        cur_out += max(0, a.start - cur_in)
        rl = len(a.replacement.encode("utf-8"))
        res.append((cur_out, rl, a.type))
        cur_out += rl
        cur_in = a.start + a.length
    return res


def render_html(text: bytes, spans: list[tuple[int, int, str]]) -> str:
    """把脱敏文本按高亮区间切成 HTML（服务端转义，前端直接插）。"""
    import html as _html

    pieces: list[str] = []
    cur = 0
    for start, ln, ty in spans:
        if start < cur:
            continue
        pieces.append(_html.escape(text[cur:start].decode("utf-8", "replace")))
        pieces.append(f'<mark class="hit {ty}">{_html.escape(text[start:start + ln].decode("utf-8", "replace"))}</mark>')
        cur = start + ln
    pieces.append(_html.escape(text[cur:].decode("utf-8", "replace")))
    return "".join(pieces)
