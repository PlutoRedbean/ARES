"""关键词提示（给 L2 做上下文先验）。

RTL 侧 `rtl/l1/l1_keyword_match.sv` 用同一份关键词表（由 tools/gen_keywords.py
生成 `build/gen/l1_keywords_pkg.sv`），两边必须同源。
"""

from __future__ import annotations

from dataclasses import dataclass

# 顺序即 kid（0 起）；RTL 侧按同样的顺序生成常量
KEYWORDS: list[str] = [
    "身份证",
    "银行卡",
    "手机号",
    "邮箱",
    "密码",
    "账号",
    "地址",
    "姓名",
]

# RTL 窗口按最长关键词的字节数确定（当前每个都是 3 个汉字 = 9 字节）
MAX_KEYWORD_BYTES = max(len(k.encode("utf-8")) for k in KEYWORDS)


@dataclass(frozen=True)
class KeywordHit:
    kid: int
    start: int
    length: int


def find_keywords(data: bytes) -> list[KeywordHit]:
    """按出现位置返回关键词命中（同一结束位置最多一个，见 RTL 约定）。"""
    hits: list[KeywordHit] = []
    kws = [(i, k.encode("utf-8")) for i, k in enumerate(KEYWORDS)]
    for pos in range(len(data)):
        for kid, kb in kws:
            if data[pos : pos + len(kb)] == kb:
                hits.append(KeywordHit(kid, pos, len(kb)))
                break
    return hits
