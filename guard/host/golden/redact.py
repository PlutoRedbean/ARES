"""红action（脱敏）参考实现：合并重叠命中 → 替换 → 审计记录。

合并规则（RTL 侧按同一规则实现）：
  1. 按 (start 升序, 类型优先级升序, 长度降序) 排序；
  2. 从左到右贪心保留，与已保留区间重叠的丢弃（"左端点优先"）。

这保证了 `1.2.3.4@x.com` 里邮箱（start 0）优先于内部的 IPv4（start 0，但优先级低）。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, asdict

from host.golden.pii_rules import PRIORITY, TYPE_NAMES, TYPE_PLATE, Span, scan

RULE_IDS = {
    1: "iso7064.mod11_2",
    2: "date.yymmdd",
    3: "prefix.mobile",
    4: "luhn.bank",
    5: "syntax.email",
    6: "syntax.ipv4",
    7: "gb32100.mod31",
    8: "syntax.plate",
}

# 用于 token 策略的短名（与 RTL 的常量表一致）
TOKEN_NAMES = {
    1: "ID18",
    2: "ID15",
    3: "MOBILE",
    4: "BANK",
    5: "EMAIL",
    6: "IPV4",
    7: "USCC",
    8: "PLATE",
}


@dataclass(frozen=True)
class Audit:
    index: int
    type: str
    type_id: int
    rule: str
    start: int
    length: int
    action: str
    replacement: str

    def to_json(self) -> dict:
        d = asdict(self)
        return d


def merge(spans: list[Span]) -> list[Span]:
    ordered = sorted(spans, key=lambda s: (s.start, PRIORITY[s.type], -s.length))
    out: list[Span] = []
    last_end = 0
    for s in ordered:
        if s.start >= last_end:
            out.append(s)
            last_end = s.start + s.length
    return out


def _mask(data: bytes, s: Span) -> bytes:
    keep = min(4, s.length)
    return b"*" * (s.length - keep) + data[s.start + s.length - keep : s.start + s.length]


def redact(
    data: bytes,
    policy: str = "token",
    *,
    keep_spans: list[Span] | None = None,
) -> tuple[bytes, list[Audit]]:
    """返回 (脱敏后的字节, 审计列表)。policy: token | mask。"""
    if policy not in ("token", "mask"):
        raise ValueError(f"unknown policy: {policy}")
    spans = merge(scan(data) if keep_spans is None else keep_spans)

    out = bytearray()
    cur = 0
    counters: dict[int, int] = {}
    audits: list[Audit] = []

    for i, s in enumerate(spans, 1):
        out += data[cur : s.start]
        counters[s.type] = counters.get(s.type, 0) + 1
        if policy == "token":
            tok = f"[{TOKEN_NAMES[s.type]}_{counters[s.type]}]".encode()
        else:
            tok = _mask(data, s)
        out += tok
        audits.append(
            Audit(
                index=i,
                type=TYPE_NAMES[s.type],
                type_id=s.type,
                rule=RULE_IDS[s.type],
                start=s.start,
                length=s.length,
                action="replace" if policy == "token" else "mask",
                replacement=tok.decode("utf-8", "replace"),
            )
        )
        cur = s.start + s.length

    out += data[cur:]
    return bytes(out), audits


def audit_json(audits: list[Audit]) -> str:
    return json.dumps([a.to_json() for a in audits], ensure_ascii=False, indent=2)


def summarize(audits: list[Audit]) -> str:
    if not audits:
        return "(no PII)"
    return ", ".join(f"{a.type}#{a.index}@{a.start}+{a.length}" for a in audits)
