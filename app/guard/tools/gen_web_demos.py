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
    "demo1_offer": "求职信（长文）",
    "demo2_hr": "入职通知",
    "demo3_ticket": "客服工单",
    "demo4_finance": "财务寄件",
    "demo5_mail": "工作邮件",
}

# 2026-11-19 在盘古 200Pro+ 上逐条实测得到的回显（模拟模式直接放这个）
BOARD_MASK = {
    "demo1_offer": "我是上周在＊＊＊＊＊＊人才市场投递简历的李＊（手机：*******4589，邮箱：***************.com）。经沟通，我拟于2026年12月1日到贵公司（明远科技有限公司，地址：＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊）办理入职手续。金额还需复核，方向明天再确认。",
    "demo2_hr": "人事部通知：新员工赵＊（手机 *******5678，身份证 **************002X 已备案）请在月底前到公司报到，报到地址：＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊。请携带学历证书原件。",
    "demo3_ticket": "客户孙＊＊来电反馈，收货地址是＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊，联系电话 *******4567，邮箱 *****************.com，请尽快安排回访。",
    "demo4_finance": "请把这张发票寄到公司财务部，收件人林＊＊，地址：*****************************************，手机 *******8888，银行卡 ***************0001。",
    "demo5_mail": "王＊＊您好，本周五下午三点在会议室开会，讨论与深科技的合作。我的邮箱 *************.com，备用手机 *******4589，身份证 **************002X 已备案。",
}


# 板上实测的命中数（模拟模式展示；规则/NER 各层合计）
BOARD_AUDIT = {
    "demo1_offer": {"n": 5, "name": 1, "mobile": 1, "email": 1, "addr": 2},
    "demo2_hr": {"n": 4, "name": 1, "mobile": 1, "id18": 1, "addr": 1},
    "demo3_ticket": {"n": 4, "name": 1, "addr": 1, "mobile": 1, "email": 1},
    "demo4_finance": {"n": 4, "name": 1, "addr": 1, "mobile": 1, "bank": 1},
    "demo5_mail": {"n": 4, "name": 1, "email": 1, "mobile": 1, "id18": 1},
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