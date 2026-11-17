"""L1 规则层金标模型。

与 `rtl/l1/l1_digit_engine.sv` 逐条对齐；两边任何一侧改判定，另一侧必须同步。

坐标约定：输入一律按 **UTF-8 字节** 处理，span 的 start/len 是字节偏移，
这样 RTL 的字符流与 Python 的结果可以直接对比。

两类判定：**精确**（校验位/结构通过）和**上下文兜底**（游程前 CTX_WINDOW 字节内
有"身份证/银行卡/手机号"关键词时，校验位不过也遮）。后者是隐私优先的取舍：
真板上 `身份证 330203300422240391`（年份 3004 + 校验位错）本该被遮。
"""

from __future__ import annotations

from dataclasses import dataclass

TYPE_ID18 = 1
TYPE_ID15 = 2
TYPE_MOBILE = 3
TYPE_BANK = 4
TYPE_EMAIL = 5
TYPE_IPV4 = 6
TYPE_USCC = 7
TYPE_PLATE = 8

TYPE_NAMES = {
    TYPE_ID18: "id18",
    TYPE_ID15: "id15",
    TYPE_MOBILE: "mobile",
    TYPE_BANK: "bank",
    TYPE_EMAIL: "email",
    TYPE_IPV4: "ipv4",
    TYPE_USCC: "uscc",
    TYPE_PLATE: "plate",
}

# 同一"终止位置"上的多个命中的输出顺序（RTL 侧同拍多引擎命中按此顺序排）
PRIORITY = {
    TYPE_EMAIL: 1,
    TYPE_PLATE: 2,
    TYPE_USCC: 3,
    TYPE_IPV4: 4,
    TYPE_ID18: 5,
    TYPE_ID15: 6,
    TYPE_MOBILE: 7,
    TYPE_BANK: 8,
}
NAME_TO_TYPE = {v: k for k, v in TYPE_NAMES.items()}

# ISO 7064 MOD 11-2 加权（身份证前 17 位）
ID_WEIGHTS = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)

SEP_SPACE = 0x20
SEP_DASH = 0x2D
CH_X_UPPER = 0x58
CH_X_LOWER = 0x78


@dataclass(frozen=True)
class Span:
    type: int
    start: int
    length: int

    @property
    def name(self) -> str:
        return TYPE_NAMES[self.type]


def _luhn_double(d: int) -> int:
    t = d * 2
    return t - 9 if t > 9 else t


def luhn_ok(digits: list[int]) -> bool:
    """digits[0] 是最右一位。"""
    total = 0
    for i, d in enumerate(digits):
        total += _luhn_double(d) if i % 2 == 1 else d
    return total % 10 == 0


def _leap(year: int) -> bool:
    return year % 4 == 0


def _date_ok(year: int, month: int, day: int) -> bool:
    if not 1 <= month <= 12 or not 1 <= day <= 31:
        return False
    if month in (4, 6, 9, 11):
        return day <= 30
    if month == 2:
        return day <= (29 if _leap(year) else 28)
    return True


def id18_ok(digits: list[int]) -> bool:
    """digits[0] 是最右（校验位，X=10）。"""
    total = sum(ID_WEIGHTS[k] * digits[17 - k] for k in range(17))
    return (total % 11 + digits[0]) % 11 == 1


def id18_check_digit(first17: str) -> str:
    """给前 17 位算校验位，返回 '0'..'9' 或 'X'。"""
    total = sum(ID_WEIGHTS[k] * int(first17[k]) for k in range(17))
    v = (1 - total % 11) % 11
    return "X" if v == 10 else str(v)


def _classify(digits: list[int], has_x: bool, too_long: bool) -> int:
    n = len(digits)
    if too_long or n < 11:
        return 0
    if n == 18:
        d = lambda k: digits[n - 1 - k]  # noqa: E731
        year = d(6) * 1000 + d(7) * 100 + d(8) * 10 + d(9)
        month = d(10) * 10 + d(11)
        day = d(12) * 10 + d(13)
        if not _date_ok(year, month, day):
            return 0
        if id18_ok(digits):
            return TYPE_ID18
        return 0
    if n == 15:
        d = lambda k: digits[n - 1 - k]  # noqa: E731
        year = 2000 + d(6) * 10 + d(7)
        month = d(8) * 10 + d(9)
        day = d(10) * 10 + d(11)
        if _date_ok(year, month, day):
            return TYPE_ID15
        return 0
    if n == 11:
        d = lambda k: digits[n - 1 - k]  # noqa: E731
        if d(0) == 1 and 3 <= d(1) <= 9:
            return TYPE_MOBILE
        return 0
    if 13 <= n <= 19 and not has_x and luhn_ok(digits):
        return TYPE_BANK
    return 0


# --------------------------------------------------------------------------
# 文本类（非纯数字）规则：邮箱、IPv4、统一社会信用代码、车牌
# --------------------------------------------------------------------------

EMAIL_CHARS = frozenset(
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._%+-@"
)
IPV4_CHARS = frozenset(b"0123456789.")
USCC_CHARS = "0123456789ABCDEFGHJKLMNPQRTUWXY"
USCC_WEIGHTS = (1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28)
PLATE_LETTERS = frozenset(b"ABCDEFGHJKLMNPQRSTUVWXYZ")  # 无 I / O
PLATE_TAIL = frozenset(b"0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")
_UPPER = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ")
_LOWER = frozenset(b"abcdefghijklmnopqrstuvwxyz")
_DIGIT = frozenset(b"0123456789")
_ALNUM = _UPPER | _LOWER | _DIGIT


def _email_ok(run: bytes) -> bool:
    if run.count(b"@") != 1:
        return False
    local, domain = run.split(b"@")
    if not (1 <= len(local) <= 32):
        return False
    if local[:1] == b"." or local[-1:] == b"." or b".." in local:
        return False
    labels = domain.split(b".")
    if len(labels) < 2:
        return False
    for lab in labels[:-1]:
        if not (1 <= len(lab) <= 63):
            return False
        if lab[:1] == b"-" or lab[-1:] == b"-":
            return False
        if any(ch not in _ALNUM and ch != 0x2D for ch in lab):
            return False
    tld = labels[-1]
    if not (2 <= len(tld) <= 24):
        return False
    return all(ch in _UPPER or ch in _LOWER for ch in tld)


def _ipv4_ok(run: bytes) -> bool:
    parts = run.split(b".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not (1 <= len(p) <= 3) or not p.isdigit():
            return False
        if len(p) > 1 and p[:1] == b"0":
            return False
        if int(p) > 255:
            return False
    return True


def _uscc_ok(run: bytes) -> bool:
    if len(run) != 18:
        return False
    text = run.decode("ascii", "replace")
    if any(ch not in USCC_CHARS for ch in text):
        return False
    if all(ch in _DIGIT for ch in run):  # 全数字交给身份证/银行卡规则
        return False
    idx = [USCC_CHARS.index(ch) for ch in text]
    total = sum(USCC_WEIGHTS[k] * idx[k] for k in range(17))
    return idx[17] == (31 - total % 31) % 31


def _plate_at(data: bytes, pos: int) -> int:
    """pos 处若是一个车牌，返回 9（3 字节汉字 + 字母 + 5 位），否则 0。"""
    if pos + 8 >= len(data):
        return 0
    lead = data[pos]
    if not (0xE4 <= lead <= 0xE9):
        return 0
    if not (0x80 <= data[pos + 1] <= 0xBF and 0x80 <= data[pos + 2] <= 0xBF):
        return 0
    if data[pos + 3] not in PLATE_LETTERS:
        return 0
    if any(data[pos + 3 + k] not in PLATE_TAIL for k in range(1, 6)):
        return 0
    if pos + 9 < len(data) and data[pos + 9] in _ALNUM:
        return 0
    return 9


def _scan_text(data: bytes) -> list[tuple[int, int]]:
    """返回 (type, start, len) 三元组列表（未排序）。"""
    out: list[tuple[int, int, int]] = []

    # 邮箱：EMAIL_CHARS 极大游程，去掉尾部 '.' 后校验
    i, n = 0, len(data)
    while i < n:
        if data[i] in EMAIL_CHARS:
            j = i
            while j < n and data[j] in EMAIL_CHARS:
                j += 1
            run = data[i:j]
            k = len(run)
            while k > 0 and run[k - 1] == 0x2E:
                k -= 1
            if 0 < k <= 64 and _email_ok(run[:k]):
                out.append((TYPE_EMAIL, i, k))
            i = j
        else:
            i += 1

    # IPv4：数字 + '.' 极大游程，去尾部 '.' 后校验
    i = 0
    while i < n:
        if data[i] in IPV4_CHARS:
            j = i
            while j < n and data[j] in IPV4_CHARS:
                j += 1
            run = data[i:j]
            k = len(run)
            while k > 0 and run[k - 1] == 0x2E:
                k -= 1
            if 0 < k <= 15 and _ipv4_ok(run[:k]):
                out.append((TYPE_IPV4, i, k))
            i = j
        else:
            i += 1

    # 统一社会信用代码：18 位 base31 游程
    i = 0
    while i < n:
        ch = chr(data[i])
        if ch in USCC_CHARS:
            j = i
            while j < n and chr(data[j]) in USCC_CHARS:
                j += 1
            run = data[i:j]
            if len(run) == 18 and _uscc_ok(run):
                out.append((TYPE_USCC, i, 18))
            i = j
        else:
            i += 1

    # 车牌：汉字 + 字母 + 5 位
    i = 0
    while i < n:
        ln = _plate_at(data, i)
        if ln:
            out.append((TYPE_PLATE, i, ln))
            i += ln
        else:
            i += 1

    return out


def scan(data: bytes) -> list[Span]:
    """扫描字节流，返回按 (终止位置, 类型优先级) 排序的命中 span。"""
    from host.golden.keywords import find_keywords

    kws = [(k.kid, k.start, k.start + k.length) for k in find_keywords(data)]
    hits: list[tuple[int, int, Span]] = []
    for s in _scan_digits(data, kws):
        hits.append((s.start + s.length, PRIORITY[s.type], s))
    for t, start, ln in _scan_text(data):
        hits.append((start + ln, PRIORITY[t], Span(t, start, ln)))
    hits.sort(key=lambda h: (h[0], h[1]))
    return [h[2] for h in hits]


# 上下文兜底：数字游程前面这么多个字节内出现过"身份证/银行卡/手机号"，
# 就算校验位不过也按该关键词的类型脱敏（隐私优先：宁可多遮）。
CTX_WINDOW = 8
CTX_KID_TYPE = {0: TYPE_ID18, 1: TYPE_BANK, 2: TYPE_MOBILE}


def _loose_type(ndigits: int, kid: int) -> int:
    """上下文兜底的类型：按关键词定，身份证再按位数分 15/18。"""
    if kid == 0:
        return TYPE_ID15 if ndigits == 15 else TYPE_ID18
    return CTX_KID_TYPE.get(kid, 0)


def _scan_digits(data: bytes, kws: list[tuple[int, int, int]] | None = None) -> list[Span]:
    """数字游程 → span。

    分隔符（空格/短横）在游程内透明，但"透明"有代价：`13800138000 13800138001`
    会被并成一个 22 位游程而整段丢弃。这里用"影子游程 + 分隔符快照"修掉：

    - P  = 主游程（从游程起点开始，分隔符透明）；
    - S  = 影子游程（最后一个分隔符之后的部分，分隔符处重置）；
    - 分隔符处把 P 的分类结果记成快照（只存 type/start/last，不存数字）；
    - P 满 19 位又来数字时：先把快照结算成一个 span，再用 S 顶替 P 继续走。
    """
    spans: list[Span] = []

    active = False
    run_start = 0
    last_digit = 0
    P: list[int] = []          # digits[0] 是最右（最新）一位
    P_hasx = False
    P_over = False
    S: list[int] = []
    S_hasx = False
    S_over = False
    S_start = 0
    snap_valid = False
    snap_type = 0
    snap_start = 0
    snap_last = 0

    def ctx_hit(start: int) -> int:
        """run_start 前面 CTX_WINDOW 字节内、最近的一个 PII 关键词 kid（没有则 -1）。"""
        if not kws:
            return -1
        best_kid, best_end = -1, -1
        for kid, _s, e in kws:
            if kid > 2 or e > start or (start - e) > CTX_WINDOW:
                continue
            if e > best_end:
                best_kid, best_end = kid, e
        return best_kid

    def close() -> None:
        nonlocal active, P, P_hasx, P_over, S, S_hasx, S_over, snap_valid
        if active and not P_over:
            t = _classify(P, P_hasx, False)
            if t == 0 and 11 <= len(P) <= 19:
                kid = ctx_hit(run_start)
                if kid >= 0:
                    t = _loose_type(len(P), kid)
            if t:
                spans.append(Span(t, run_start, last_digit - run_start + 1))
        active = False
        P = []
        P_hasx = False
        P_over = False
        S = []
        S_hasx = False
        S_over = False
        snap_valid = False

    for pos, ch in enumerate(data):
        if 0x30 <= ch <= 0x39:
            d = ch - 0x30
            if not active:
                active = True
                run_start = pos
                P = [d]
                P_hasx = False
                P_over = False
                S = [d]
                S_hasx = False
                S_over = False
                S_start = pos
                snap_valid = False
            else:
                # ---- 影子游程 ----
                if not S_over:
                    if not S:
                        S = [d]
                        S_start = pos
                    elif len(S) < 19:
                        S.insert(0, d)
                    else:
                        S_over = True
                # ---- 主游程 ----
                if not P_over:
                    if len(P) < 19:
                        P.insert(0, d)
                    else:
                        # 满 19：先结算快照（分隔符之前的那个号码）
                        if snap_valid:
                            spans.append(
                                Span(snap_type, snap_start, snap_last - snap_start + 1)
                            )
                        if S_over:
                            P_over = True          # 影子也溢出：整段作废
                        else:
                            P = list(S)            # 影子顶替主游程（已含 d）
                            run_start = S_start
                            P_hasx = S_hasx
                        S = [d]
                        S_hasx = False
                        S_over = False
                        S_start = pos
                        snap_valid = False
            last_digit = pos
        elif ch in (SEP_SPACE, SEP_DASH):
            if active:
                # 快照 = 目前这个前缀的分类结果（分隔符之后的数字另算）
                t = _classify(P, P_hasx, P_over)
                snap_valid = t != 0
                snap_type = t
                snap_start = run_start
                snap_last = last_digit
                S = []
                S_hasx = False
                S_over = False
        elif ch in (CH_X_UPPER, CH_X_LOWER) and active and not P_over and len(P) == 17:
            P.insert(0, 10)
            P_hasx = True
            last_digit = pos
            if not S_over and len(S) == 17:
                S.insert(0, 10)
                S_hasx = True
        else:
            close()

    close()
    return spans


def summarize(spans: list[Span]) -> str:
    return ", ".join(f"{s.name}@{s.start}+{s.length}" for s in spans)