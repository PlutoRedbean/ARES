"""把 examples/demo*.txt 生成 web/demos.js。

- text：原文
- mask：**板上实测**的脱敏回显（模拟模式用；连线时不用它）
- audit：金标算出的每类命中数（模拟模式展示用）

用法：python tools/gen_web_demos.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EX = ROOT / "examples"
OUT = ROOT / "web" / "demos.js"

sys.path.insert(0, str(ROOT))

LABELS = {
    "demo01_name": "人名（无线索词）",
    "demo02_surname": "露姓氏",
    "demo03_mobile": "手机号",
    "demo04_id18": "身份证 18 位",
    "demo05_id15": "身份证 15 位",
    "demo06_bank": "银行卡",
    "demo07_email": "邮箱",
    "demo08_addr": "地址（含门牌）",
    "demo09_mixed": "混合短句",
    "demo10_long": "长段落（多帧）",
}

# 2026-11-19 在盘古 200Pro+ 上逐条实测得到的回显（模拟模式直接放这个）
BOARD_MASK = {
    "demo01_name": "刘＊＊的演唱会在上海。",
    "demo02_surname": "我是马＊＊，请多关照。",
    "demo03_mobile": "手机 *******8000，座机 057188888888。",
    "demo04_id18": "身份证 **************002X。",
    "demo05_id15": "身份证 ***********2240。",
    "demo06_bank": "银行卡 ***************0001。",
    "demo07_email": "邮箱 ***************.com。",
    "demo08_addr": "地址：*******************************************。",
    "demo09_mixed": "联系人王＊＊，手机 *******8000，地址：********************************。",
    "demo10_long": (
        "我是上周在＊＊＊＊＊＊人才市场投递简历的李＊（手机：*******4589，邮箱：***************.com）。"
        "经沟通，我拟于*026年12月1日到贵公司（深理工科技有限公司，地址：*******************************************）"
        "办理入职手续。金额还需复核，方向明天再确认。"
    ),
}


# 板上实测的命中数（模拟模式展示；规则/NER 各层合计）
BOARD_AUDIT = {
    "demo01_name": {"n": 1, "name": 1},
    "demo02_surname": {"n": 1, "name": 1},
    "demo03_mobile": {"n": 1, "mobile": 1},
    "demo04_id18": {"n": 1, "id18": 1},
    "demo05_id15": {"n": 1, "id15": 1},
    "demo06_bank": {"n": 1, "bank": 1},
    "demo07_email": {"n": 1, "email": 1},
    "demo08_addr": {"n": 1, "addr": 1},
    "demo09_mixed": {"n": 3, "name": 1, "mobile": 1, "addr": 1},
    "demo10_long": {"n": 6, "mobile": 1, "email": 1, "name": 2, "addr": 2},
}


def board_audit(stem: str) -> dict:
    return BOARD_AUDIT.get(stem, {})


def main() -> int:
    items = []
    for p in sorted(EX.glob("demo*.txt")):
        stem = p.stem
        text = p.read_text(encoding="utf-8").strip()
        m = re.search(r"demo(\d+)", stem)
        items.append({
            "id": m.group(1) if m else stem,
            "key": stem,
            "label": LABELS.get(stem, stem),
            "text": text,
            "mask": BOARD_MASK.get(stem, ""),
            "audit": board_audit(stem),
        })
    OUT.write_text("window.DEMOS = " + json.dumps(items, ensure_ascii=False, indent=2) + ";\n",
                   encoding="utf-8")
    print(f"demos.js: {len(items)} demos -> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())