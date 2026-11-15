"""合成 PII 语料生成器（不依赖任何第三方库）。

用途：
  * `tools/gen_vectors.py` 生成 RTL 一致性向量；
  * 后续 M2 端到端演示、M6 评估都可以复用。
"""

from __future__ import annotations

import random

from host.golden.pii_rules import id18_check_digit

SURNAMES = "赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜"
GIVEN = ["伟", "芳", "娜", "敏", "静", "磊", "洋", "艳", "勇", "军", "杰", "娟"]
CITIES = ["北京", "上海", "广州", "深圳", "杭州", "成都", "武汉", "西安", "南京"]
DISTRICTS = ["朝阳区", "海淀区", "浦东新区", "天河区", "西湖区", "武侯区"]
STREETS = ["建国路", "中关村大街", "人民路", "科技园路", "解放大道"]
COMPANIES = ["鼎新科技有限公司", "云栖数据服务有限公司", "恒远贸易有限公司", "北辰信息技术有限公司"]
FILLERS = ["请把资料发给", "合同联系人写", "备注里留了", "快递寄到", "开票信息是", "客服登记的是"]
SUFFIXES = ["。", "，谢谢。", "（工作日联系）。", ""]


def _digits(rng: random.Random, n: int) -> str:
    return "".join(rng.choice("0123456789") for _ in range(n))


def make_id18(
    rng: random.Random,
    *,
    invalid_check: bool = False,
    invalid_date: bool = False,
) -> str:
    region = rng.choice(["110105", "310115", "440106", "330106", "510107"])
    year = rng.randint(1940, 2010)
    month = 13 if invalid_date else rng.randint(1, 12)
    day = rng.randint(1, 28)
    seq = _digits(rng, 3)
    first17 = f"{region}{year:04d}{month:02d}{day:02d}{seq}"
    check = id18_check_digit(first17)
    if invalid_check:
        check = "0" if check != "0" else "1"
    return first17 + check


def make_id15(rng: random.Random, *, invalid_date: bool = False) -> str:
    region = rng.choice(["110105", "310115", "440106"])
    yy = rng.randint(40, 99)
    month = 13 if invalid_date else rng.randint(1, 12)
    day = rng.randint(1, 28)
    seq = _digits(rng, 3)
    return f"{region}{yy:02d}{month:02d}{day:02d}{seq}"


def make_phone(rng: random.Random, *, bad_prefix: bool = False) -> str:
    return ("12" if bad_prefix else rng.choice(["13", "15", "18", "19"])) + _digits(rng, 9)


def _luhn_complete(body: str) -> str:
    total = 0
    for i, ch in enumerate(reversed(body)):
        d = int(ch)
        if i % 2 == 0:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return body + str((10 - total % 10) % 10)


def make_bank(rng: random.Random, *, bad_check: bool = False, length: int = 16) -> str:
    body = _digits(rng, length - 1)
    card = _luhn_complete(body)
    if bad_check:
        card = card[:-1] + str((int(card[-1]) + 1) % 10)
    return card


def _group(num: str, rng: random.Random, sep: str = " ") -> str:
    """把数字按 3–4 位切段插入分隔符，保持原来的数字顺序。"""
    out, i = [], 0
    while i < len(num):
        n = rng.choice([3, 4, 4])
        out.append(num[i : i + n])
        i += n
    return sep.join(out)


def render_scene(rng: random.Random) -> str:
    """拼一段"真实"的聊天/邮件文本，随机塞入 PII 与干扰项。"""
    parts: list[str] = []
    if rng.random() < 0.8:
        parts.append(f"联系人：{rng.choice(SURNAMES)}{rng.choice(GIVEN)}")
    if rng.random() < 0.8:
        phone = make_phone(rng, bad_prefix=rng.random() < 0.2)
        if rng.random() < 0.4:
            phone = _group(phone, rng, rng.choice([" ", "-"]))
        parts.append(f"手机 {phone}")
    if rng.random() < 0.7:
        kind = rng.random()
        if kind < 0.5:
            num = make_id18(
                rng,
                invalid_check=rng.random() < 0.25,
                invalid_date=rng.random() < 0.15,
            )
        elif kind < 0.7:
            num = make_id15(rng, invalid_date=rng.random() < 0.15)
        else:
            num = _digits(rng, rng.choice([18, 20]))
        parts.append(f"身份证 {num}")
    if rng.random() < 0.6:
        card = make_bank(
            rng,
            bad_check=rng.random() < 0.25,
            length=rng.choice([16, 19, 13]),
        )
        if rng.random() < 0.5:
            card = _group(card, rng, rng.choice([" ", "-"]))
        parts.append(f"卡号 {card}")
    if rng.random() < 0.4:
        parts.append(
            f"地址：{rng.choice(CITIES)}{rng.choice(DISTRICTS)}{rng.choice(STREETS)}"
            f"{rng.randint(1, 99)}号"
        )
    if rng.random() < 0.3:
        parts.append(f"公司：{rng.choice(COMPANIES)}")
    if rng.random() < 0.5:
        parts.append(f"邮箱 user{rng.randint(1, 99)}@example.com")

    rng.shuffle(parts)
    lead = rng.choice(FILLERS)
    return lead + "，" + "；".join(parts) + rng.choice(SUFFIXES)


def build_case(rng: random.Random) -> bytes:
    return render_scene(rng).encode("utf-8")
