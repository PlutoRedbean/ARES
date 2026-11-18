"""生成字符级 人名/地址 标注数据（JSONL，字节偏移）。

    python3 tools/gen_ner_data.py --out data/ner --seed 20261118

输出（所有句子 <= 64 字节，正好一个 64B 窗口）：
    train.jsonl     >= 15000 句，负样本 >= 40%，含难样本（无线索裸名字 / 口语地址）
    heldout.jsonl   >= 2000 句，同分布留出集
    hard.jsonl      >= 1000 句，只用于评估（绝不进训练）：无线索裸名字、口语地址、
                    名字紧邻数字、中英混排、含姓氏但不是人名的难负样本
    manifest.json   规模 / 负样本比例 / 硬样本比例 / 字符覆盖

每行: {"text": "...", "spans": [[start_byte, len_bytes, label], ...]}
label: 1=name, 2=addr, 0=其它 PII（只当负样本，训练时一律视为 0）。

设计原则：
  * 姓氏表直接复用 host.golden.entities.SURNAMES（64 个）；
  * 名字 = 姓 + 1~2 个常见名字用字（GIVEN）；
  * 地址 = 省/市/区 + 街/路 + 门牌 + 号/栋/室，另有口语地址；
  * 负样本刻意包含“含姓氏但不是人名”的词（王家村/方向/金额…），
    逼模型看第二个字，而不是见姓就报。
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.entities import SURNAMES  # noqa: E402

# --------------------------------------------------------------------------- 词表
GIVEN = (
    "伟芳娜秀英敏静丽强磊军洋勇艳杰娟涛明超霞平刚桂兰玉华建国文武志成红梅海波宁欣宇晨阳雪婷倩楠凯鹏辉峰亮飞云天昊睿哲涵轩然佳怡梦瑶琳珊慧颖洁莉萍燕玲丹青春秋冬夏"
    "雨露霜山川河江湖森木石银民生才学德义礼信忠孝仁爱和安康健泰福禄寿喜乐欢笑歌舞琴棋书画诗词章经典传承创新兴旺富贵荣昌盛隆悦晗曦璇璐瑾瑜珂玥淇萱蕾薇蓉蕊荷莲菊竹松柏桐柳桦枫榕楷樾奕"
)

PROVINCES = (
    "北京市 上海市 天津市 重庆市 河北省 山西省 辽宁省 吉林省 黑龙江省 江苏省 浙江省 "
    "安徽省 福建省 江西省 山东省 河南省 湖北省 湖南省 广东省 海南省 四川省 贵州省 "
    "云南省 陕西省 甘肃省 青海省 台湾省 内蒙古自治区 广西壮族自治区 西藏自治区 "
    "宁夏回族自治区 新疆维吾尔自治区 香港特别行政区 澳门特别行政区"
).split()

CITIES = (
    "石家庄 唐山 秦皇岛 邯郸 太原 大同 呼和浩特 包头 沈阳 大连 鞍山 长春 吉林 哈尔滨 "
    "大庆 南京 无锡 徐州 常州 苏州 南通 连云港 杭州 宁波 温州 嘉兴 绍兴 金华 合肥 芜湖 "
    "蚌埠 福州 厦门 泉州 南昌 九江 济南 青岛 淄博 烟台 潍坊 郑州 洛阳 开封 武汉 宜昌 "
    "襄阳 长沙 株洲 湘潭 广州 深圳 珠海 佛山 东莞 中山 惠州 南宁 桂林 海口 三亚 成都 "
    "绵阳 德阳 贵阳 遵义 昆明 大理 拉萨 西安 宝鸡 咸阳 兰州 西宁 银川 乌鲁木齐 克拉玛依"
).split()

DISTRICTS = (
    "朝阳区 海淀区 东城区 西城区 丰台区 石景山区 浦东新区 黄浦区 徐汇区 静安区 天河区 "
    "越秀区 海珠区 番禺区 南山区 福田区 宝安区 龙岗区 罗湖区 西湖区 上城区 拱墅区 "
    "滨江区 鼓楼区 玄武区 秦淮区 建邺区 武侯区 锦江区 青羊区 金牛区 江岸区 武昌区 "
    "洪山区 汉阳区 雁塔区 未央区 碑林区 莲湖区 雨花区 岳麓区 芙蓉区 开福区 金水区 "
    "中原区 二七区 历下区 市南区 和平区 河西区 南开区 江北区 渝中区 沙坪坝区 盘龙区 "
    "五华区 观山湖区 云岩区 新城区 回民区 城关区"
).split()

STREETS = (
    "中山路 人民路 解放路 建设路 长江路 黄河路 文化路 新华路 幸福路 光明路 科技大道 "
    "创业路 世纪大道 长安街 南京路 淮海路 春熙路 珠江路 环城北路 青年路 和平路 东风路 "
    "胜利街 民主路 复兴路 建国路 文三路 学院路 中关村大街 金融街 望京街 天府大道 "
    "星湖街 工业园路 科技园路 火车站前街"
).split()

BLOCKS = ["", "", "", "3栋502室", "2单元301室", "5号楼", "8层", "B座1201",
          "1栋101室", "6栋2单元", "12号院", "4号楼"]

COLL_START = ["那条街", "这条路", "那条巷子", "老城区", "村口", "桥头", "山脚下",
              "河边", "镇上的", "学校对面", "医院旁边", "菜市场后面", "地铁站",
              "火车站", "公园门口", "小区西门", "老街"]
COLL_DIR = ["东边", "西边", "南边", "北边", "对面", "旁边", "后面", "前面",
            "左手边", "右手边", "往里走"]
COLL_DIST = ["第三个路口", "第二个路口", "走两百米", "往北走三百米", "最里面那栋",
             "第三排", "拐两个弯", "第一个红绿灯"]

NAME_CUES = ["联系人：", "姓名：", "我叫", "收件人：", "户名：", "本人", "找", "给",
             "致", "让", "通知", "联系", "客户"]
NAME_TITLES = ["先生", "女士", "老师", "同学", "经理", "主任", "医生", "律师"]
ADDR_CUES = ["地址：", "住址：", "住在", "位于", "收货地址：", "寄到", "送到",
             "搬到", "户口在", "老家在", "公司在"]

# 含姓氏但不是人名 —— 第二/第三个字刻意避开 GIVEN
NEG_SURNAME_WORDS = [
    "王家村", "李家庄", "张家界", "石家庄", "陈家沟", "刘家峡", "周口店", "马路边",
    "黄牛票", "高家庄", "赵家楼", "孙家屯", "钱家店", "吴家堡", "郑家屯", "冯家沟",
    "朱家角", "何家村", "吕梁山", "魏家桥", "蒋家村", "田家湾", "杜家坎", "丁家山",
    "沈家营", "姜家寨", "范家屯", "江家湾", "傅家村", "钟家岭", "卢家沟", "汪家畈",
    "戴家村", "崔家峪", "任家台", "陆家嘴", "廖家村", "姚家坝", "方家胡同", "金家岭",
    "邱家村", "夏家河", "谭家湾", "韦家沟", "贾家村", "邹家坪", "石家村", "熊家岭",
    "孟家坳", "秦家村", "阎家沟", "薛家店", "侯家营", "雷家村", "白家沟", "龙家湾",
    "段家村", "郝家屯", "孔家村", "邵家营", "史家村", "毛家岭", "常家湾", "万家村",
    "顾家沟", "赖家村", "武家村", "康家村", "贺家村", "严家村", "钱家村", "施家村",
    "牛家村", "洪家村",
]

# 含地址锚点字但不是地址
NEG_ADDR_WORDS = [
    "小区门口", "城市大脑", "省点钱", "街道办", "号码簿", "三楼会议室",
    "东边那家店", "前面路口左转", "这条路在修", "区里开会", "市中心很堵",
    "楼道里很黑", "号子喊得响", "市面上的货",
]

SURNAME_WORD_NEG = NEG_SURNAME_WORDS

# 难负样本的句式：出现姓氏/地址锚点字，但**不是**人名或地址
HARD_NEG_FRAMES = [
    "{w}今年的收成不错", "{w}有集市", "{w}风景很好", "{w}今天下雨",
    "{w}离这儿不远", "路过{w}", "{w}那边在修路", "听说{w}要拆迁",
    "{w}开了家农家乐", "从{w}坐车过去", "{w}的柿子熟了", "地图上找不到{w}",
    "{w}门口有棵老槐树", "周末去{w}钓鱼", "{w}的人很热情", "{w}以前叫别的名字",
]
HARD_ADDR_NEG_FRAMES = [
    "{w}人很多", "{w}今天关门", "先去{w}看看", "别在{w}停",
    "{w}那边堵车", "{w}新开了家店", "{w}的灯坏了", "从{w}绕过去",
    "{w}排了好长的队", "{w}不让进", "去{w}问一下", "{w}今天没开",
]


# --------------------------------------------------------------------------- 文档
def blen(s: str) -> int:
    return len(s.encode("utf-8"))


class Doc:
    """按“片段 + 标签”拼一句话，自动算字节 span。"""

    def __init__(self) -> None:
        self.parts: list[tuple[str, int]] = []
        self.n = 0
        self.pii: list[tuple[int, int]] = []

    def add(self, text: str, label: int = 0, pii: bool = False) -> "Doc":
        if not text:
            return self
        if pii:
            self.pii.append((self.n, self.n + len(text)))
        self.parts.append((text, label))
        self.n += len(text)
        return self

    def text(self) -> str:
        return "".join(t for t, _ in self.parts)

    def labels(self) -> list[int]:
        out: list[int] = []
        for t, l in self.parts:
            out.extend([l] * len(t))
        return out

    def spans(self) -> list[list[int]]:
        text = self.text()
        labels = self.labels()
        spans: list[list[int]] = []
        i = 0
        while i < len(text):
            if labels[i] == 0:
                i += 1
                continue
            j = i + 1
            while j < len(text) and labels[j] == labels[i]:
                j += 1
            spans.append([blen(text[:i]), blen(text[i:j]), labels[i]])
            i = j
        for a, b in self.pii:
            spans.append([blen(text[:a]), blen(text[a:b]), 0])
        spans.sort(key=lambda s: (s[0], s[1], s[2]))
        return spans


# --------------------------------------------------------------------------- 原子
def make_name(rng: random.Random) -> str:
    s = rng.choice(SURNAMES)
    k = 1 if rng.random() < 0.28 else 2
    return s + "".join(rng.sample(GIVEN, k))


def make_phone(rng: random.Random) -> str:
    return "1" + rng.choice("35789") + "".join(rng.choice("0123456789") for _ in range(9))


def make_order(rng: random.Random) -> str:
    return f"{rng.randint(2020, 2025)}{rng.randint(1, 12):02d}{rng.randint(1, 28):02d}{rng.randint(1000, 9999)}"


def make_amount(rng: random.Random) -> str:
    return f"{rng.randint(1, 99999)}.{rng.randint(0, 99):02d}"


def make_addr(rng: random.Random) -> str:
    t = rng.random()
    num = str(rng.randint(1, 999)) + "号"
    if t < 0.30:
        return (rng.choice(PROVINCES) + rng.choice(CITIES) + rng.choice(DISTRICTS)
                + rng.choice(STREETS) + num + rng.choice(BLOCKS))
    if t < 0.58:
        return (rng.choice(CITIES) + rng.choice(DISTRICTS) + rng.choice(STREETS)
                + num + rng.choice(BLOCKS))
    if t < 0.72:
        return rng.choice(PROVINCES) + rng.choice(CITIES)
    if t < 0.86:
        return rng.choice(DISTRICTS) + rng.choice(STREETS) + num + rng.choice(BLOCKS)
    return rng.choice(PROVINCES) + rng.choice(DISTRICTS) + rng.choice(STREETS) + num


def make_coll(rng: random.Random) -> str:
    t = rng.random()
    if t < 0.42:
        return rng.choice(COLL_START) + rng.choice(COLL_DIR)
    if t < 0.74:
        return rng.choice(COLL_START) + rng.choice(COLL_DIST)
    return rng.choice(COLL_DIST) + rng.choice(COLL_DIR)


# --------------------------------------------------------------------------- 正样本
def pos_name(rng: random.Random, hard: bool = False) -> Doc:
    d = Doc()
    name = make_name(rng)
    if hard:
        t = rng.random()
        if t < 0.35:                                    # 裸名字 + 动词（无线索）
            d.add(name, 1)
            d.add(rng.choice(["来了", "刚走", "今天请假", "说下午开会", "在楼下等你"]), 0)
            return d
        if t < 0.55:                                    # 两个裸名字
            other = make_name(rng)
            while other == name:
                other = make_name(rng)
            d.add(name, 1).add("和", 0).add(other, 1).add(rng.choice(["都到了", "都在会议室", "一起过来"]))
            return d
        if t < 0.75:                                    # 名字紧邻数字
            d.add(name, 1).add(make_phone(rng), 0, pii=True)
            if rng.random() < 0.5:
                d.add(rng.choice([" 麻烦回电", " 请查收", " 是他的号"]))
            return d
        if t < 0.90:                                    # 中英混排
            d.add(rng.choice(["Alice的同事", "找Tom要", "Lucy说", "Kevin和"]) , 0)
            d.add(name, 1)
            d.add(rng.choice(["在北京CBD工作", "的电话", "明天到上海", "一起开会"]), 0)
            return d
        # 名字 + 弱线索（客户/朋友…）
        d.add(rng.choice(["客户", "朋友", "同事", "邻居", "同学"]), 0).add(name, 1)
        d.add(rng.choice(["到了", "在门口", "已经走了", "在等你"]), 0)
        return d

    t = rng.random()
    if t < 0.55:                                        # 强线索
        d.add(rng.choice(NAME_CUES)).add(name, 1)
        r = rng.random()
        if r < 0.35:
            d.add("，电话 ").add(make_phone(rng), 0, pii=True)
        elif r < 0.5:
            d.add(rng.choice(NAME_TITLES), 0)
        elif r < 0.6:
            d.add("，地址：").add(make_addr(rng), 2)
        return d
    if t < 0.78:                                        # 裸名字 + 常见句
        d.add(name, 1)
        d.add(rng.choice(["来了", "在楼下等你", "刚走", "说下午开会", "今天请假",
                          "的电话是", "找过你", "已经签收了"]), 0)
        if d.parts[-1][0] == "的电话是":
            d.add(make_phone(rng), 0, pii=True)
        return d
    if t < 0.9:
        d.add("把材料交给").add(name, 1)
        return d
    d.add(rng.choice(["麻烦", "请", "让"])).add(name, 1)
    d.add(rng.choice(["看一下", "回复邮件", "签个字", "过来一趟"]))
    return d


def pos_addr(rng: random.Random, hard: bool = False) -> Doc:
    d = Doc()
    if hard:
        t = rng.random()
        coll = make_coll(rng)
        if t < 0.5:
            d.add(rng.choice(["我家在", "就在", "你到", "定位在", "送货到"]))
            d.add(coll, 2)
            d.add(rng.choice(["，你过来吧", "，很好找", "等我", "那栋楼"]))
        elif t < 0.8:
            d.add(coll, 2)
            d.add(rng.choice(["有家小超市", "那栋是仓库", "拐进去就到", "新开了家店"]))
        else:
            d.add("地址在").add(coll, 2).add("，别走错了")
        return d
    addr = make_addr(rng)
    t = rng.random()
    if t < 0.72:
        d.add(rng.choice(ADDR_CUES)).add(addr, 2)
        if rng.random() < 0.18:
            d.add("，联系人").add(make_name(rng), 1)
        return d
    if t < 0.88:
        d.add(addr, 2).add(rng.choice(["是收货地址", "附近有地铁站", "那一片我熟"]))
        return d
    d.add("我要去").add(addr, 2)
    return d


def pos_mixed(rng: random.Random, hard: bool = False) -> Doc:
    d = Doc()
    name, addr, phone = make_name(rng), make_addr(rng), make_phone(rng)
    t = rng.random()
    if hard:
        if t < 0.4:
            d.add(name, 1).add("住在").add(make_coll(rng), 2)
        elif t < 0.7:
            d.add(rng.choice(["Alice说", "Tom和", "Lucy找"])).add(name, 1)
            d.add("在").add(make_coll(rng), 2)
        else:
            d.add(name, 1).add(make_phone(rng), 0, pii=True).add("，在").add(make_coll(rng), 2)
        return d
    if t < 0.35:
        # 64 字节窗口放不下“姓名+电话+完整地址”，这一支只放姓名+电话
        d.add("收件人：").add(name, 1).add("，电话").add(phone, 0, pii=True)
    elif t < 0.65:
        d.add("联系人").add(name, 1).add("，住在").add(addr, 2)
    elif t < 0.85:
        d.add(name, 1).add("的收货地址是").add(addr, 2)
    else:
        d.add("我叫").add(name, 1).add("，住在").add(addr, 2)
    return d


# --------------------------------------------------------------------------- 负样本
def neg_sentence(rng: random.Random, hard: bool = False) -> Doc:
    d = Doc()
    if hard:
        t = rng.random()
        if t < 0.55:
            w = rng.choice(SURNAME_WORD_NEG)
            d.add(rng.choice(HARD_NEG_FRAMES).format(w=w))
            return d
        w = rng.choice(NEG_ADDR_WORDS)
        d.add(rng.choice(HARD_ADDR_NEG_FRAMES).format(w=w))
        return d

    t = rng.random()
    if t < 0.14:
        d.add("订单号").add(make_order(rng), 0, pii=True)
        d.add(" 已发货，金额 ").add(make_amount(rng), 0, pii=True).add(" 元")
        return d
    if t < 0.26:
        d.add("订单 ").add(make_order(rng), 0, pii=True)
        d.add(" 金额：").add(make_amount(rng), 0, pii=True).add(" 元")
        return d
    if t < 0.36:
        d.add(f"{rng.randint(2023, 2026)}年{rng.randint(1, 12)}月{rng.randint(1, 28)}日")
        d.add(f" {rng.randint(8, 20)}:{rng.randint(0, 59):02d} 开会")
        return d
    if t < 0.44:
        d.add(f"第{rng.randint(1, 300)}页 共{rng.randint(1, 500)}页")
        return d
    if t < 0.52:
        d.add("".join(rng.choice("0123456789") for _ in range(rng.randint(6, 20))))
        return d
    if t < 0.60:
        d.add("手机 ").add(make_phone(rng), 0, pii=True)
        return d
    if t < 0.68:
        d.add("身份证 ").add("".join(rng.choice("0123456789") for _ in range(18)), 0, pii=True)
        return d
    if t < 0.76:
        d.add("银行卡 ").add("".join(rng.choice("0123456789") for _ in range(16)), 0, pii=True)
        d.add(" 转账 ").add(make_amount(rng), 0, pii=True).add(" 元")
        return d
    if t < 0.84:
        d.add("工号 ").add(str(rng.randint(10000, 999999)), 0, pii=True)
        d.add(f"，部门 {rng.choice(['研发', '市场', '财务', '人事', '运营'])}，第{rng.randint(1, 9)}组")
        return d
    if t < 0.92:
        d.add("验证码 ").add(str(rng.randint(100000, 999999)), 0, pii=True)
        d.add("，5分钟内有效")
        return d
    if rng.random() < 0.5:
        w = rng.choice(SURNAME_WORD_NEG)
        d.add(rng.choice(HARD_NEG_FRAMES).format(w=w))
    else:
        w = rng.choice(NEG_ADDR_WORDS)
        d.add(rng.choice(HARD_ADDR_NEG_FRAMES).format(w=w))
    return d


# --------------------------------------------------------------------------- 生成
def build_one(rng: random.Random, cat: str) -> Doc:
    if cat == "name":
        return pos_name(rng, hard=False)
    if cat == "addr":
        return pos_addr(rng, hard=False)
    if cat == "mixed":
        return pos_mixed(rng, hard=False)
    if cat == "neg":
        return neg_sentence(rng, hard=False)
    if cat == "hard_name":
        return pos_name(rng, hard=True)
    if cat == "hard_addr":
        return pos_addr(rng, hard=True)
    if cat == "hard_mixed":
        return pos_mixed(rng, hard=True)
    if cat == "hard_neg":
        return neg_sentence(rng, hard=True)
    raise ValueError(cat)


def gen_split(rng: random.Random, spec: list[tuple[str, int]], seen: set[str],
              limit: int = 64) -> tuple[list[dict], dict[str, int]]:
    rows: list[dict] = []
    cat_counts: dict[str, int] = {}
    for cat, n in spec:
        made = 0
        guard = 0
        while made < n:
            guard += 1
            if guard > n * 50 + 1000:
                raise RuntimeError(f"cannot generate enough unique {cat}")
            d = build_one(rng, cat)
            text = d.text()
            if len(text.encode("utf-8")) > limit:      # 64 **字节**窗口（字符对齐）
                continue
            if text in seen:
                continue
            spans = d.spans()
            seen.add(text)
            rows.append({"text": text, "spans": spans})
            made += 1
        cat_counts[cat] = n
    rng.shuffle(rows)
    return rows, cat_counts


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def stats(rows: list[dict]) -> dict:
    n = len(rows)
    neg = sum(1 for r in rows if not any(s[2] in (1, 2) for s in r["spans"]))
    return {"n": n, "neg": neg, "neg_ratio": round(neg / max(n, 1), 4)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/ner")
    ap.add_argument("--seed", type=int, default=20261118)
    ap.add_argument("--train", type=int, default=15000)
    ap.add_argument("--heldout", type=int, default=2000)
    ap.add_argument("--hard", type=int, default=1000)
    args = ap.parse_args()

    out = Path(args.out)
    if not out.is_absolute():
        out = (ROOT / out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    # 目标配比：
    #   train   负样本 40.7%，难样本（无线索/口语/中英/难负）30%；
    #           注意 train 的难样本是**另外随机生成**的，和评估 hard.jsonl 不重叠。
    #   heldout 同正常分布，负样本 40%。
    #   hard    只评估：裸名字 55% / 口语地址 25% / 中英混排 10% / 难负 10%。
    def scale_spec(base: list[tuple[str, int]], total: int) -> list[tuple[str, int]]:
        base_total = sum(n for _, n in base)
        out = [(c, n * total // base_total) for c, n in base]
        out[-1] = (out[-1][0], out[-1][1] + total - sum(n for _, n in out))
        return out

    train_spec = scale_spec([
        ("name", 2900), ("addr", 2100), ("mixed", 500),
        ("hard_name", 2100), ("hard_addr", 1000), ("hard_mixed", 300),
        ("neg", 5500), ("hard_neg", 600),
    ], args.train)
    held_spec = scale_spec([
        ("name", 624), ("addr", 480), ("mixed", 96), ("neg", 800),
    ], args.heldout)
    hard_spec = scale_spec([
        ("hard_name", 550), ("hard_addr", 250), ("hard_mixed", 100), ("hard_neg", 100),
    ], args.hard)

    seen: set[str] = set()
    train_rows, train_cat = gen_split(random.Random(args.seed), train_spec, seen)
    held_rows, held_cat = gen_split(random.Random(args.seed + 1), held_spec, seen)
    hard_rows, hard_cat = gen_split(random.Random(args.seed + 2), hard_spec, seen)

    write_jsonl(out / "train.jsonl", train_rows)
    write_jsonl(out / "heldout.jsonl", held_rows)
    write_jsonl(out / "hard.jsonl", hard_rows)

    # 字符覆盖：训练集没见过的字符（heldout/hard 里）
    train_chars = {c for r in train_rows for c in r["text"]}
    held_chars = {c for r in held_rows for c in r["text"]}
    hard_chars = {c for r in hard_rows for c in r["text"]}
    oov_held = sorted(held_chars - train_chars)
    oov_hard = sorted(hard_chars - train_chars)

    def ratio_hard(rows: list[dict], cat: dict[str, int]) -> float:
        h = sum(v for k, v in cat.items() if k.startswith("hard"))
        return round(h / max(len(rows), 1), 4)

    manifest = {
        "seed": args.seed,
        "counts": {"train": len(train_rows), "heldout": len(held_rows), "hard": len(hard_rows)},
        "categories": {"train": train_cat, "heldout": held_cat, "hard": hard_cat},
        "neg_ratio": {
            "train": stats(train_rows)["neg_ratio"],
            "heldout": stats(held_rows)["neg_ratio"],
            "hard": stats(hard_rows)["neg_ratio"],
        },
        "hard_ratio": {
            "train": ratio_hard(train_rows, train_cat),
            "heldout": ratio_hard(held_rows, held_cat),
            "hard": ratio_hard(hard_rows, hard_cat),
        },
        "chars": {"train": len(train_chars), "heldout": len(held_chars), "hard": len(hard_chars)},
        "oov": {"heldout": oov_held, "hard": oov_hard},
        "max_chars": max(len(r["text"]) for r in train_rows + held_rows + hard_rows),
        "max_bytes": max(len(r["text"].encode("utf-8")) for r in train_rows + held_rows + hard_rows),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                                       encoding="utf-8")

    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
