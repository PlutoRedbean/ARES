"""L2b 实体层：姓名 / 地址（词典 + 上下文线索，规则式）。

与 rtl/l2/l2_entity.sv 同一套判定。目标不是"理解语义"，而是把最常见的两类
非结构化 PII（人名、地址）用可预测的规则抓出来；语义改写留给后面的模型路线。

规则（名字）：
  - 姓 来自姓氏表（100 个常见姓，UTF-8 3 字节）；
  - 姓后跟 1~2 个汉字（CJK）→ 候选；
  - 候选**被线索词**（先生/女士/老师/同学/经理/主任/医生/律师/总）**紧跟**，
    或者前面 12 字节内有线索（叫/姓名/联系人/收件人/户名/本人/给/找/致）→ 命中。

规则（地址）：
  - 从线索词（地址/住址/住在/位于/收货地址）之后，或直接从 省/市/区/县 开头；
  - 累积 CJK/数字 与 号/室/栋/楼/层/单元/小区/路/街/巷/镇/乡/村/省/市/区/县；
  - 结束条件：遇到上述"地址后缀字"之一后，下一个字节不是 CJK/数字 → 收尾；
  - 长度 6..48 字节，且必须含至少一个 省/市/区/县/路/街/号 → 命中。
"""

from __future__ import annotations

SURNAMES = (
    "王李张刘陈杨黄赵周吴徐孙朱马胡郭林何高梁郑罗宋谢唐韩曹许邓萧冯曾程蔡彭潘袁于董余苏叶"
    "吕魏蒋田杜丁沈姜范江傅钟卢汪戴崔任陆廖姚方金邱夏谭韦贾邹石熊孟秦阎薛侯雷白龙段郝孔邵"
    "史毛常万顾赖武康贺严尹钱施牛洪龚"
)

NAME_SUFFIX = ("先生", "女士", "老师", "同学", "经理", "主任", "医生", "律师")
NAME_CUE = ("叫", "姓名", "联系人", "收件人", "户名", "本人", "给", "找", "致")
ADDR_CUE = ("地址", "住址", "住在", "位于", "收货地址")
ADDR_TAIL = ("省", "市", "区", "县", "镇", "乡", "村", "路", "街", "巷",
             "号", "室", "栋", "楼", "层", "单元", "小区")
ADDR_ANCHOR = ("省", "市", "区", "县", "路", "街", "号")

CTX_WINDOW = 12
NAME_MIN, NAME_MAX = 6, 12      # 姓 + 1~2 个汉字 → 6~12 字节
ADDR_MIN, ADDR_MAX = 6, 48


def _is_cjk(b: bytes, i: int) -> bool:
    """i 处是否是一个 CJK 字符（UTF-8 三字节 E4..E9 开头）。"""
    return i + 2 < len(b) and 0xE4 <= b[i] <= 0xE9 and 0x80 <= b[i + 1] <= 0xBF and 0x80 <= b[i + 2] <= 0xBF


def _cjk_at(data: bytes, i: int) -> str | None:
    if _is_cjk(data, i):
        try:
            return data[i:i + 3].decode("utf-8")
        except UnicodeDecodeError:
            return None
    return None


def _cue_before(data: bytes, i: int, cues, window: int = CTX_WINDOW) -> bool:
    lo = max(0, i - window)
    seg = data[lo:i]
    return any(c.encode() in seg for c in cues)


PUNCT = "，。！？、；：,.!?;:"

def _is_digit(b: bytes, i: int) -> bool:
    return i < len(b) and 0x30 <= b[i] <= 0x39


def find_names(data: bytes) -> list[tuple[int, int]]:
    """返回 (start, len) 名字 span。"""
    out: list[tuple[int, int]] = []
    i, n = 0, len(data)
    while i < n:
        ch = _cjk_at(data, i)
        if ch is None or ch not in SURNAMES:
            i += 1
            continue

        # 姓 + 职务（"王经理""李老师"）：整个都遮
        hit = 0
        for sfx in NAME_SUFFIX:
            sb = sfx.encode()
            if data[i + 3:i + 3 + len(sb)] == sb:
                hit = 3 + len(sb)
                break
        if hit:
            out.append((i, hit))
            i += hit
            continue

        # 姓 + 1~2 个汉字：要有线索/后缀/边界，避免"王家村"这类误报
        for extra in (2, 1):
            ln = 3 * (1 + extra)
            if i + ln > n:
                continue
            if not all(_cjk_at(data, i + 3 * k) is not None for k in range(1, 1 + extra)):
                continue
            tail = data[i + ln:]
            suffix_ok = any(tail.startswith(s.encode()) for s in NAME_SUFFIX)
            # 只认"线索词在前"或"职务在后"：光靠标点边界会把"金额 88"这类吞进来
            if suffix_ok or _cue_before(data, i, NAME_CUE):
                out.append((i, ln))
                i += ln
                break
        else:
            i += 3
    return out


def find_addresses(data: bytes) -> list[tuple[int, int]]:
    """返回 (start, len) 地址 span。"""
    out: list[tuple[int, int]] = []
    i, n = 0, len(data)
    while i < n:
        ch = _cjk_at(data, i)
        starts = ch is not None and (ch in ADDR_ANCHOR or _cue_before(data, i, ADDR_CUE))
        if not starts:
            i += 1
            continue
        j = i
        while j < n:
            if _cjk_at(data, j) is not None:
                j += 3
            elif _is_digit(data, j):          # 门牌号
                j += 1
            else:
                break
        ln = j - i
        if ADDR_MIN <= ln <= ADDR_MAX:
            seg = data[i:i + ln]
            if any(a.encode() in seg for a in ADDR_ANCHOR):
                out.append((i, ln))
        i = j if j > i else i + 3
    return out


def scan_entities(data: bytes) -> list[tuple[int, int, int]]:
    """(type, start, len)；type 9 = name, 10 = address（与 RTL 的 a_type 一致）。"""
    spans = [(9, s, ln) for s, ln in find_names(data)]
    spans += [(10, s, ln) for s, ln in find_addresses(data)]
    spans.sort(key=lambda x: x[1])
    return spans

TYPE_NAME = 9
TYPE_ADDR = 10
ENTITY_NAMES = {TYPE_NAME: "name", TYPE_ADDR: "addr"}


def mask_entities(data: bytes, spans: list[tuple[int, int, int]]) -> bytes:
    """把人名/地址**整段**换成 '*'（不留后缀：留 4 位会把名字泄露一半）。"""
    out = bytearray(data)
    for _ty, s, ln in spans:
        for k in range(s, min(s + ln, len(out))):
            out[k] = 0x2A
    return bytes(out)


def scan_with_entities(data: bytes):
    """L1 规则 + L2b 实体（host 侧用；RTL 目前只有 L1）。"""
    from host.golden.pii_rules import scan as scan_l1

    spans = [(sp.type, sp.start, sp.length) for sp in scan_l1(data)]
    ent = scan_entities(data)
    # 实体不覆盖已经命中的结构化 PII（避免把号码的一部分当名字）
    kept = []
    for ty, s, ln in ent:
        if any(s < es + el and es < s + ln for et, es, el in spans):
            continue
        kept.append((ty, s, ln))
    return spans, kept