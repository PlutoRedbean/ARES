"""生成"无 PII 散文"评测集：给 NER 的误报门槛用（gate 7）。

刻意做成"含姓氏字但不是人名"的难负样本：金额、方向、王家村、张数、周报、李树、
陈设、吴用……这些词在语法上像人名，但没有一个是真名字。
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

TRAPS = [
    "金额", "方向", "周末", "刘量", "张数", "陈设", "李树", "吴用", "周报", "王家村",
    "徐缓", "孙山", "马虎", "张口", "何尝", "高见", "梁上", "罗列", "宋体", "唐突",
    "韩信", "曹营", "许愿", "邓氏", "冯妇", "曾几何时", "程门立雪", "蔡侯纸",
]

SUBJECTS = ["项目组", "研发部", "客服", "运维", "财务", "市场部", "测试组", "实习生", "值班同事", "供应商"]
VERBS = ["确认", "复核", "复现", "整理", "提交", "退回", "标注", "合并", "拆分", "补齐"]
OBJECTS = ["接口文档", "回归用例", "发布清单", "告警规则", "日志字段", "版本说明", "接口超时", "配置项", "优先级", "验收标准"]
TAILS = ["，明天上午再看。", "，下午三点前给回复。", "，先按旧版本跑一次。", "，有疑问在群里说。",
         "，别急着上线。", "，记得同步给测试。", "，我已经记录在案。", "，这周内完成。"]


def sentence(rng: random.Random) -> str:
    k = rng.random()
    sub = rng.choice(SUBJECTS)
    verb = rng.choice(VERBS)
    obj = rng.choice(OBJECTS)
    trap = rng.choice(TRAPS)
    tail = rng.choice(TAILS)
    if k < 0.3:
        return f"{sub}{verb}了{obj}{tail}"
    if k < 0.55:
        return f"{trap}还需{verb}，{obj}{tail}"
    if k < 0.75:
        return f"关于{obj}，{sub}建议先{verb}{tail}"
    if k < 0.9:
        return f"{sub}把{obj}和{trap}一起{verb}了{tail}"
    return f"本周{obj}比较多，{sub}{verb}不过来{tail}"


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "data/ner/prose.jsonl")
    if not out.is_absolute():
        out = ROOT / out
    out.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(4242)
    rows = []
    seen = set()
    while len(rows) < 400:
        s = sentence(rng)
        if s in seen:
            continue
        seen.add(s)
        rows.append({"text": s, "spans": []})
    out.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    print(f"prose: {len(rows)} sentences -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
