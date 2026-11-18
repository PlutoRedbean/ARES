"""L2b 实体层：人名 / 地址（词典 + 线索），**流式语义**（与 RTL 逐字节一致）。

规则（必须能在 1 字节/拍的硬件里实现，所以没有回溯）：

  线索检测：把线索词当多字节模式，在窗口内匹配；记录"线索结束位置"。
  名字：CJK 字符出发，且
        (a) 该字符是一个姓，且 12 字节内出现过名字线索（叫/姓名/联系人/收件人/
            户名/本人/给/找/致）；
        (b) 或者该字符是姓、紧跟的下一串是职务（先生/女士/老师/同学/经理/主任/
            医生/律师）。
        名字长度 = 姓 + 1 或 2 个 CJK 字符（6 或 9 字节）；遇到非 CJK 或凑满 3 个
        字符就收尾（凑满 3 个直接收，需先满足 (a) 或 (b)）。

  地址：从"地址线索结束处"或"锚点字（省/市/区/县/路/街/号）"开始；
        累积 CJK 与数字；遇到其它字节收尾；
        6..48 字节且含锚点字才算命中。

类型：9 = name，10 = addr（与 RTL 的 a_type 一致）。
"""

from __future__ import annotations

SURNAMES = (
    "王李张刘陈杨黄赵周吴徐孙朱马胡郭林何高梁郑罗宋谢唐韩曹许邓冯曾程蔡彭潘袁于董余苏叶"
    "吕魏蒋田杜丁沈姜范江傅钟卢汪戴崔任陆廖姚方金邱夏谭韦贾邹石熊孟秦阎薛侯雷白龙段郝孔邵"
    "史毛常万顾赖武康贺严尹钱施牛洪龚")[:64]

NAME_CUES = ("叫", "姓名", "联系人", "收件人", "户名", "本人", "给", "找", "致")
NAME_TITLES = ("先生", "女士", "老师", "同学", "经理", "主任", "医生", "律师")
ADDR_CUES = ("地址", "住址", "住在", "位于", "收货地址")
ADDR_ANCHORS = ("省", "市", "区", "县", "路", "街", "号")
ADDR_TAILS = ("省", "市", "区", "县", "镇", "乡", "村", "路", "街", "巷",
              "号", "室", "栋", "楼", "层")

CTX_WINDOW = 12
ADDR_MIN, ADDR_MAX = 6, 48


def _cjk_len(data: bytes, i: int) -> int:
    if i + 2 < len(data) and 0xE4 <= data[i] <= 0xE9 and 0x80 <= data[i + 1] <= 0xBF and 0x80 <= data[i + 2] <= 0xBF:
        return 3
    return 0


def _char(data: bytes, i: int) -> str:
    return data[i:i + 3].decode("utf-8", "replace")


def _cue_ends(data: bytes, cues) -> list[int]:
    """所有线索出现的结束位置（不含）。"""
    ends = []
    for cue in cues:
        cb = cue.encode()
        start = 0
        while True:
            k = data.find(cb, start)
            if k < 0:
                break
            ends.append(k + len(cb))
            start = k + 1
    return sorted(ends)


def find_names(data: bytes) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    cue_ends = _cue_ends(data, NAME_CUES)
    i, n = 0, len(data)
    while i < n:
        cl = _cjk_len(data, i)
        if cl == 0 or _char(data, i) not in SURNAMES:
            i += 1
            continue
        # "姓 + 职务"（王经理/李老师）：不需要线索，两个职务字直接判
        title_ok = i + 9 <= n and _char(data, i + 3) + _char(data, i + 6) in NAME_TITLES
        cued = any(0 <= i - e <= CTX_WINDOW for e in cue_ends)
        if not (cued or title_ok):
            i += 3
            continue
        # 姓 + 1~2 个 CJK
        ln = 3
        while ln < 9 and i + ln + 2 < n and _cjk_len(data, i + ln):
            ln += 3
        if 6 <= ln <= 9:
            out.append((i, ln))
            i += ln
        else:
            i += 3
    return out


def find_addresses(data: bytes) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    cue_ends = _cue_ends(data, ADDR_CUES)
    anchors = [a.encode() for a in ADDR_ANCHORS]
    i, n = 0, len(data)
    while i < n:
        cl = _cjk_len(data, i)
        start = cl and (_char(data, i) in ADDR_ANCHORS or any(0 <= i - e <= CTX_WINDOW for e in cue_ends))
        if not start:
            i += 1
            continue
        j = i
        while j < n:
            if _cjk_len(data, j):
                j += 3
            elif 0x30 <= data[j] <= 0x39:
                j += 1
            else:
                break
        ln = j - i
        if ADDR_MIN <= ln <= ADDR_MAX:
            seg = data[i:j]
            if any(a in seg for a in anchors):
                out.append((i, ln))
        i = j if j > i else i + 3
    return out


TYPE_NAME, TYPE_ADDR = 9, 10
ENTITY_NAMES = {TYPE_NAME: "name", TYPE_ADDR: "addr"}


def scan_entities(data: bytes) -> list[tuple[int, int, int]]:
    spans = [(TYPE_NAME, s, ln) for s, ln in find_names(data)]
    spans += [(TYPE_ADDR, s, ln) for s, ln in find_addresses(data)]
    spans.sort(key=lambda x: x[1])
    return spans


def mask_entities(data: bytes, spans: list[tuple[int, int, int]]) -> bytes:
    out = bytearray(data)
    for _ty, s, ln in spans:
        for k in range(s, min(s + ln, len(out))):
            out[k] = 0x2A
    return bytes(out)


def scan_with_entities(data: bytes):
    from host.golden.pii_rules import scan as scan_l1

    spans = [(sp.type, sp.start, sp.length) for sp in scan_l1(data)]
    ents = [e for e in scan_entities(data)
            if not any(s < e[1] + e[2] and e[1] < s + ln for _t, s, ln in spans)]
    return spans, ents