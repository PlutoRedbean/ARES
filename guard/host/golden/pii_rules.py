"""L1 规则层金标模型。

与 `rtl/l1/l1_digit_engine.sv` 逐条对齐；两边任何一侧改判定，另一侧必须同步。

坐标约定：输入一律按 **UTF-8 字节** 处理，span 的 start/len 是字节偏移，
这样 RTL 的字符流与 Python 的结果可以直接对比。
"""

from __future__ import annotations

from dataclasses import dataclass

TYPE_ID18 = 1
TYPE_ID15 = 2
TYPE_MOBILE = 3
TYPE_BANK = 4

TYPE_NAMES = {
    TYPE_ID18: "id18",
    TYPE_ID15: "id15",
    TYPE_MOBILE: "mobile",
    TYPE_BANK: "bank",
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


def scan(data: bytes) -> list[Span]:
    """扫描字节流，返回按出现顺序排列的命中 span。"""
    spans: list[Span] = []

    active = False
    run_start = 0
    last_digit = 0
    digits: list[int] = []  # digits[0] 是最右
    has_x = False
    too_long = False

    def close() -> None:
        nonlocal active, digits, has_x, too_long
        if active:
            t = _classify(digits, has_x, too_long)
            if t:
                spans.append(Span(t, run_start, last_digit - run_start + 1))
        active = False
        digits = []
        has_x = False
        too_long = False

    for pos, ch in enumerate(data):
        if 0x30 <= ch <= 0x39:
            if not active:
                active = True
                run_start = pos
                digits = [ch - 0x30]
                has_x = False
                too_long = False
            elif too_long:
                pass
            elif len(digits) < 19:
                digits.insert(0, ch - 0x30)
            else:
                too_long = True
            last_digit = pos
        elif ch in (SEP_SPACE, SEP_DASH):
            pass  # 游程内透明
        elif ch in (CH_X_UPPER, CH_X_LOWER) and active and not too_long and len(digits) == 17:
            digits.insert(0, 10)
            has_x = True
            last_digit = pos
        else:
            close()

    close()
    return spans


def summarize(spans: list[Span]) -> str:
    return ", ".join(f"{s.name}@{s.start}+{s.length}" for s in spans)
