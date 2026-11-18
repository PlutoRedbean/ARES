"""生成字符级 人名/地址 标注数据（JSONL，字节偏移）—— v3。

    python3 tools/gen_ner_data.py --out data/ner --seed 20261118

输出（所有句子/窗口 <= 64 字节）：
    train.jsonl     >= 25000 句；散文负样本 >= 35%；含边界/复姓/称谓/地址尾巴
    heldout.jsonl   >= 2000 句，同分布留出集
    hard.jsonl      >= 1500 句，只用于评估（绝不进训练）
    unseen_names.jsonl  >=500 个训练没出现过的全名（评估）
    addr_digits.jsonl   >=500 条含门牌号的地址（评估）
    name_chars.txt      3000 字名字用字表
    manifest.json       规模 / 比例 / 字符覆盖 / OOV

每行: {"text": "...", "spans": [[start_byte, len_bytes, label], ...]}
label: 1=name, 2=addr, 0=其它 PII（只当负样本，训练时一律视为 0）。

v3（docs §12）新增：3000 字名字用字表、12 万不同全名、2000 个真人风格名、
unseen_names.jsonl、addr_digits.jsonl，以及带门牌号的地址训练/评估集。

v2 相对 v1 的改动（对应 docs/ubuntu-ner.md 第 10/11 节）：
  * 散文负样本：新闻/说明书/对话体，不含 PII，但刻意塞入 金额/方向/王家村/张数/
    周报/李树/陈设/吴用 等“像人名”的词；训练集占比 >= 35%；
  * 边界样本：名字后紧接 说/打/了/的/是/和/今天/已经...，只标姓名；
  * 复姓：欧阳/司马/诸葛/上官/东方/皇甫/尉迟/公孙/慕容/长孙/宇文/司徒（各 >= 200 例）；
  * 称谓：王经理/张总/李老师/刘主任/陈医生，整个“姓+称谓”标 name（与 l2_entity 一致）；
  * 地址尾巴：X号楼X单元X室 / X栋X号 / X层；
  * 线索词：叫/叫作/名叫/署名/签字/发件人/收件人/户主；
  * 难集 >= 1500 句，单独文件，只评估。
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from host.golden.entities import SURNAMES  # noqa: E402
from name_chars import NAME_CHARS, NAME_CORE  # noqa: E402
from gen_prose import (  # noqa: E402
    OBJECTS as PROSE_OBJECTS,
    SUBJECTS as PROSE_SUBJECTS,
    TAILS as PROSE_TAILS,
    TRAPS as PROSE_TRAPS,
    VERBS as PROSE_VERBS,
    sentence as prose_sentence,
)

# --------------------------------------------------------------------------- 词表
# 去掉“和”：它是连词，训练集里不能再把它当名字用字，否则 李雷和韩梅梅 会被并成一个名字。
GIVEN = (
    "伟芳娜秀英敏静丽强磊军洋勇艳杰娟涛明超霞平刚桂兰玉华建国文武志成红梅海波宁欣宇晨阳雪婷倩楠凯鹏辉峰亮飞云天昊睿哲涵轩然佳怡梦瑶琳珊慧颖洁莉萍燕玲丹青春秋冬夏"
    "雨露霜山川河江湖森木石银民生才学德义礼信忠孝仁爱和安康健泰福禄寿喜乐欢笑歌舞琴棋书画诗词章经典传承创新兴旺富贵荣昌盛隆悦晗曦璇璐瑾瑜珂玥淇萱蕾薇蓉蕊荷莲菊竹松柏桐柳桦枫榕楷樾奕"
).replace("和", "").replace("笑", "") + "帆三"

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
# 石家庄同时是固定 prose 里的姓氏陷阱（必须全 0）。本地 5 字感受野无法在“石”处
# 同时判断“石家庄市…”地址和“石家庄的柿子”陷阱；地址侧去掉它，陷阱侧保留。
CITIES = [c for c in CITIES if c != "石家庄"]

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

COLL_START = ["那条街", "这条路", "那条巷子", "老城区", "村口", "桥头", "山脚下",
              "河边", "镇上的", "学校对面", "医院旁边", "菜市场后面", "地铁站",
              "火车站", "公园门口", "小区西门", "老街"]
COLL_DIR = ["东边", "西边", "南边", "北边", "对面", "旁边", "后面", "前面",
            "左手边", "右手边", "往里走"]
COLL_DIST = ["第三个路口", "第二个路口", "走两百米", "往北走三百米", "最里面那栋",
             "第三排", "拐两个弯", "第一个红绿灯"]

# 复姓（要求 >=12 个，每个 >=200 例）
COMPOUND = ["欧阳", "司马", "诸葛", "上官", "东方", "皇甫", "尉迟", "公孙",
            "慕容", "长孙", "宇文", "司徒"]

# 姓 + 称谓：整个 span 标 name（证据集 王经理您好 要求 0..9 全标）
TITLES = ["经理", "先生", "女士", "老师", "同学", "主任", "医生", "律师",
          "总", "工", "姐", "哥", "部长", "处长", "科长", "队长", "老板", "师傅"]

NAME_CUES = [
    "联系人：", "姓名：", "我叫", "叫", "叫作", "名叫", "署名：", "签字：",
    "发件人：", "收件人：", "户主：", "户名：", "本人", "找", "给", "致",
    "让", "通知", "联系", "客户",
]
ADDR_CUES = ["地址：", "住址：", "住在", "位于", "收货地址：", "寄到", "送到",
             "搬到", "户口在", "老家在", "公司在"]

# 名字后面紧跟的动词/副词/助词：只标名字，后面全部 0
BOUNDARY_AFTER = [
    "说", "讲", "问", "答", "笑", "哭", "走", "来", "去", "回", "打",
    "打电话", "打了个电话", "发了消息", "给了回复", "在楼下", "已经走了",
    "今天请假", "刚才来过", "现在开会", "也要参加", "还没有回复", "很忙",
    "不太舒服", "可以帮忙", "负责这个项目", "提交了材料", "确认过了",
    "参加了会议", "看到我了", "找到你了", "收到了", "签字了", "同意了",
]
BOUNDARY_PARTICLE = [
    "的", "是", "和", "与", "跟", "在", "已经", "今天", "明天", "昨天",
    "刚才", "现在", "也", "都", "还", "就", "又", "很", "太", "真", "不",
    "没", "要", "会", "能", "可以", "觉得", "认为", "表示", "希望", "要求",
]
BOUNDARY_NOUN = ["同事", "同学", "朋友", "老师", "经理", "项目", "电话", "材料",
                 "会议", "方案", "问题", "事情", "地址", "文件", "客户"]
PUNCT = ["，", "。", "！", "？", "、", "；", "："]

# 这些字既能做名字末字，又能做边界副词/名词的开头；是 v2 剩余错误的主因。
AMBIG_LAST = "刚才明天新山文生平安同成华中"
AMBIG_AFTER = ["一起过来", "开会", "说", "走", "在楼下", "已经走了",
               "提交了材料", "签字", "同意", "联系一下", "没来", "到了"]
BOUNDARY_WORDS = ["刚才来过", "才到", "明天开会", "今天请假", "在楼下",
                  "同学到了", "文件已交", "先生您好", "平安到达", "同时处理",
                  "成天开会", "中间休息", "新华书店", "山水不错", "文化路",
                  "生活很好"]

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

NEG_ADDR_WORDS = [
    "小区门口", "城市大脑", "省点钱", "街道办", "号码簿", "三楼会议室",
    "东边那家店", "前面路口左转", "这条路在修", "区里开会", "市中心很堵",
    "楼道里很黑", "号子喊得响", "市面上的货",
]

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

# 额外的散文陷阱（不改变 fixed prose 评测集，只是让训练集覆盖更多“像人名”的词）
EXTRA_TRAPS = [
    "谢绝", "张罗", "陈述", "周旋", "朱红", "秦腔", "许配", "何苦", "高攀",
    "罗盘", "宋词", "唐装", "曹营", "邓氏", "冯妇", "曾几何时", "程门立雪",
    "蔡侯纸", "赵钱孙李", "周吴郑王", "马虎", "张口", "徐缓", "孙山", "梁上",
]

# 独立的“像人名/像地址”的陷阱词：所有词都在多种句式里标 0
TRAP_WORDS = PROSE_TRAPS + EXTRA_TRAPS + NEG_SURNAME_WORDS + NEG_ADDR_WORDS
TRAP_FRAMES = [
    "{w}没对上，{tail}",
    "{w}的柿子熟了",
    "{w}新开了家店",
    "关于{w}，{tail}",
    "{w}还需复核，{tail}",
    "本周{w}比较多，{tail}",
    "{w}今年收成不错",
    "听说{w}要拆迁",
    "路过{w}",
    "别在{w}停",
    "先去{w}看看",
    "{w}这次先放着",
    "{w}还没确定",
    "{w}和这件事没关系",
    "别把{w}弄混了",
    "先核对{w}的字段",
    "{w}只是代号",
]


# --------------------------------------------------------------------------- 文档
def blen(s: str) -> int:
    return len(s.encode("utf-8"))


class Doc:
    """按片段 + 标签拼一句话，自动算字节 span。"""

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
def make_name(rng: random.Random, compound: bool = False) -> str:
    s = rng.choice(COMPOUND) if compound else rng.choice(SURNAMES)
    k = 1 if rng.random() < 0.25 else 2
    return s + "".join(rng.sample(GIVEN, k))


def make_phone(rng: random.Random) -> str:
    return "1" + rng.choice("35789") + "".join(rng.choice("0123456789") for _ in range(9))


def make_order(rng: random.Random) -> str:
    return f"{rng.randint(2020, 2025)}{rng.randint(1, 12):02d}{rng.randint(1, 28):02d}{rng.randint(1000, 9999)}"


def make_amount(rng: random.Random) -> str:
    return f"{rng.randint(1, 99999)}.{rng.randint(0, 99):02d}"


def make_block(rng: random.Random) -> str:
    t = rng.random()
    if t < 0.22:
        return f"{rng.randint(1, 20)}号楼{rng.randint(1, 6)}单元{rng.randint(101, 2500)}室"
    if t < 0.42:
        return f"{rng.randint(1, 20)}栋{rng.randint(1, 999)}号"
    if t < 0.55:
        return f"{rng.randint(1, 30)}层"
    if t < 0.68:
        return f"{rng.randint(1, 12)}号楼{rng.randint(101, 1200)}室"
    if t < 0.8:
        return f"{rng.randint(1, 9)}单元{rng.randint(101, 900)}室"
    if t < 0.9:
        return f"{rng.randint(1, 20)}号楼"
    return f"{rng.randint(1, 30)}层{rng.choice(['东', '西', '南', '北'])}区"


def make_addr(rng: random.Random) -> str:
    t = rng.random()
    num = str(rng.randint(1, 999)) + "号"
    if t < 0.26:
        return (rng.choice(CITIES) + rng.choice(DISTRICTS) + rng.choice(STREETS)
                + num + make_block(rng))
    if t < 0.48:
        return (rng.choice(PROVINCES) + rng.choice(CITIES) + rng.choice(DISTRICTS)
                + rng.choice(STREETS) + num + make_block(rng))
    if t < 0.62:
        return rng.choice(PROVINCES) + rng.choice(CITIES)
    if t < 0.78:
        return (rng.choice(DISTRICTS) + rng.choice(STREETS) + num + make_block(rng))
    if t < 0.9:
        return (rng.choice(PROVINCES) + rng.choice(DISTRICTS) + rng.choice(STREETS) + num)
    return (rng.choice(CITIES) + rng.choice(STREETS) + num
            + f"{rng.randint(1, 20)}号楼{rng.randint(1, 6)}单元{rng.randint(101, 2500)}室")


def make_coll(rng: random.Random) -> str:
    t = rng.random()
    if t < 0.42:
        return rng.choice(COLL_START) + rng.choice(COLL_DIR)
    if t < 0.74:
        return rng.choice(COLL_START) + rng.choice(COLL_DIST)
    return rng.choice(COLL_DIST) + rng.choice(COLL_DIR)


def make_title_name(rng: random.Random) -> str:
    return rng.choice(SURNAMES) + rng.choice(TITLES)


# --------------------------------------------------------------------------- v3 名字
# 真人风格的名字用字（来自公开常见姓名统计的“名字部分”，不是具体个人）
REALISTIC_GIVEN = [
    "伟", "芳", "娜", "秀英", "敏", "静", "丽", "强", "磊", "军", "洋", "勇", "艳",
    "杰", "娟", "涛", "明", "超", "霞", "平", "刚", "桂英", "建华", "文博", "雨欣",
    "欣怡", "子涵", "浩然", "宇轩", "梓涵", "一诺", "思远", "嘉怡", "诗涵", "俊杰",
    "佳琪", "明轩", "晨阳", "志强", "海燕", "晓明", "小燕", "建国", "秀兰", "桂兰",
    "玉梅", "春梅", "红梅", "冬梅", "雪梅", "慧敏", "慧娟", "丽娟", "丽华", "丽娜",
    "丽萍", "芳芳", "婷婷", "倩倩", "娜娜", "敏敏", "静静", "莉莉", "萍萍", "燕燕",
    "玲玲", "丹丹", "青青", "春燕", "秋燕", "海英", "海霞", "海波", "海涛", "海峰",
    "海龙", "海生", "海林", "文静", "文婷", "文杰", "文涛", "文斌", "文军", "文华",
    "志明", "志刚", "志伟", "志远", "志强", "国华", "国庆", "国强", "国平", "国民",
    "永强", "永刚", "永明", "永华", "永平", "家豪", "家明", "家伟", "家强", "家怡",
    "嘉琪", "嘉欣", "嘉宁", "嘉豪", "嘉伟", "嘉明", "嘉慧", "嘉丽", "嘉敏", "嘉文",
    "子轩", "子豪", "子墨", "子涵", "子怡", "子萱", "子琪", "子宁", "子晴", "子月",
    "雨涵", "雨轩", "雨泽", "雨桐", "雨晴", "雨欣", "雨嘉", "雨婷", "雨菲", "雨晨",
    "欣妍", "欣怡", "欣悦", "欣雨", "欣彤", "欣蕾", "欣怡", "欣妍", "欣悦", "欣雨",
    "梓萱", "梓涵", "梓琪", "梓宁", "梓晴", "梓月", "梓欣", "梓妍", "梓悦", "梓雨",
    "浩然", "浩宇", "浩轩", "浩宇", "浩明", "浩文", "浩杰", "浩峰", "浩洋", "浩东",
    "宇轩", "宇航", "宇浩", "宇杰", "宇文", "宇明", "宇峰", "宇洋", "宇辰", "宇翔",
    "一鸣", "一诺", "一凡", "一帆", "一航", "一鸣", "一诺", "一凡", "一帆", "一航",
]


def make_bulk_name(rng: random.Random) -> str:
    """v3 大数据量名字：姓 + 1~2 个名；三字名占多数。核心 2270 字为主。"""
    pool = NAME_CORE if rng.random() < 0.85 else NAME_CHARS
    if rng.random() < 0.05:
        s = rng.choice(COMPOUND)
        k = 1 if rng.random() < 0.5 else 2
        return s + "".join(rng.sample(pool, k))
    s = rng.choice(SURNAMES)
    k = 2 if rng.random() < 0.72 else 1
    return s + "".join(rng.sample(pool, k))


def make_core_name(rng: random.Random) -> str:
    if rng.random() < 0.05:
        return rng.choice(COMPOUND) + "".join(rng.sample(NAME_CORE, 2))
    s = rng.choice(SURNAMES)
    k = 2 if rng.random() < 0.72 else 1
    return s + "".join(rng.sample(NAME_CORE, k))


def make_realistic_name(rng: random.Random) -> str:
    if rng.random() < 0.02:
        return rng.choice(COMPOUND) + rng.choice(REALISTIC_GIVEN)
    return rng.choice(SURNAMES) + rng.choice(REALISTIC_GIVEN)


def make_digit_addr(rng: random.Random) -> str:
    """一定含门牌号的地址；整段（含数字/栋/单元/室）作为一个连续 span。"""
    prefix = rng.choice([
        rng.choice(CITIES) + rng.choice(DISTRICTS),
        rng.choice(PROVINCES) + rng.choice(CITIES),
        rng.choice(DISTRICTS),
        rng.choice(CITIES) + rng.choice(DISTRICTS) + rng.choice(STREETS),
    ])
    if not any(prefix.endswith(x) for x in ("路", "街", "道")):
        prefix += rng.choice(STREETS)
    num = str(rng.randint(1, 999)) + "号"
    block = rng.choice([
        "",
        f"{rng.randint(1, 20)}栋{rng.randint(1, 999)}号",
        f"{rng.randint(1, 20)}号楼{rng.randint(1, 6)}单元{rng.randint(101, 2500)}室",
        f"{rng.randint(1, 30)}层",
    ])
    return prefix + num + block


def pos_addr_digits(rng: random.Random) -> Doc:
    d = Doc()
    addr = make_digit_addr(rng)
    t = rng.random()
    if t < 0.55:
        d.add("地址：").add(addr, 2)
    elif t < 0.85:
        d.add(make_name(rng), 1).add("住在", 0).add(addr, 2)
    else:
        d.add(addr, 2).add("是收货地址", 0)
    return d


def gen_bulk_rows(n_rows: int, rng: random.Random, seen: set[str],
                  used: set[str], realistic: bool = False) -> list[dict]:
    """每行 5 个名字；共 n_rows*5 个不同全名。"""
    rows: list[dict] = []
    while len(rows) < n_rows:
        names: list[str] = []
        guard = 0
        while len(names) < 5:
            guard += 1
            if guard > 500:
                break
            name = make_realistic_name(rng) if realistic else make_bulk_name(rng)
            if name in used or name in names:
                continue
            names.append(name)
        if len(names) < 5:
            continue
        d = Doc()
        for i, name in enumerate(names):
            if i:
                d.add("、", 0)
            d.add(name, 1)
        text = d.text()
        if blen(text) > 64 or text in seen:
            continue
        seen.add(text)
        used.update(names)
        rows.append({"text": text, "spans": d.spans()})
    return rows


def gen_unseen_rows(n: int, rng: random.Random, used: set[str],
                    seen: set[str]) -> list[dict]:
    """训练时没出现过的全名；多种无线索/弱线索上下文。"""
    rows: list[dict] = []
    local: set[str] = set()
    while len(rows) < n:
        name = make_core_name(rng)
        if name in used or name in local:
            continue
        d = Doc()
        t = rng.random()
        if t < 0.5:
            d.add(name, 1).add("的演唱会在上海", 0)
        elif t < 0.75:
            d.add("请把文件发给").add(name, 1)
        else:
            d.add(name, 1).add("说下午开会", 0)
        text = d.text()
        if blen(text) > 64 or text in seen:
            continue
        seen.add(text)
        local.add(name)
        rows.append({"text": text, "spans": d.spans()})
    return rows


def gen_addr_digit_rows(n: int, rng: random.Random, seen: set[str]) -> list[dict]:
    rows: list[dict] = []
    while len(rows) < n:
        d = pos_addr_digits(rng)
        text = d.text()
        if blen(text) > 64 or text in seen:
            continue
        seen.add(text)
        rows.append({"text": text, "spans": d.spans()})
    return rows


# --------------------------------------------------------------------------- 散文负样本
def prose_text(rng: random.Random) -> str:
    if rng.random() < 0.78:
        return prose_sentence(rng)
    sub = rng.choice(PROSE_SUBJECTS)
    verb = rng.choice(PROSE_VERBS)
    obj = rng.choice(PROSE_OBJECTS + ["演唱会", "音乐会", "话剧", "展览", "演讲", "唱歌"])
    trap = rng.choice(PROSE_TRAPS + EXTRA_TRAPS)
    tail = rng.choice(PROSE_TAILS)
    t = rng.random()
    if t < 0.25:
        return f"{sub}{verb}了{obj}{tail}"
    if t < 0.5:
        return f"{trap}需要{verb}，{obj}{tail}"
    if t < 0.7:
        return f"{sub}把{trap}和{obj}一起{verb}了{tail}"
    if t < 0.85:
        return f"关于{obj}，{trap}还要再{verb}一遍{tail}"
    return f"{sub}{verb}{obj}时发现{trap}没对上{tail}"


def trap_doc(rng: random.Random) -> Doc:
    """含姓氏/地址锚点字、但语法上不是人名/地址的词，标 0。"""
    d = Doc()
    w = rng.choice(TRAP_WORDS)
    d.add(rng.choice(TRAP_FRAMES).format(w=w, tail=rng.choice(PROSE_TAILS)))
    return d


def prose_doc(rng: random.Random) -> Doc:
    """整句 <=64B 就整句；否则取一个 64B 字符窗口（和推理时的切窗一致）。"""
    text = prose_text(rng)
    d = Doc()
    if blen(text) <= 64:
        d.add(text)
        return d
    chars = list(text)
    if rng.random() < 0.7:                     # 顺序窗口（0,64,128...）
        starts = [0]
        acc = 0
        for i, ch in enumerate(chars):
            acc += len(ch.encode("utf-8"))
            if acc >= 64:
                starts.append(i + 1)
                acc = 0
        start = rng.choice([s for s in starts if s < len(chars)] or [0])
    else:
        start = rng.randrange(len(chars))
    out: list[str] = []
    used = 0
    for ch in chars[start:]:
        cb = len(ch.encode("utf-8"))
        if used + cb > 64:
            break
        out.append(ch)
        used += cb
    if not out:
        out = [chars[start]]
    d.add("".join(out))
    return d


# --------------------------------------------------------------------------- 正样本
def pos_name(rng: random.Random) -> Doc:
    d = Doc()
    name = make_name(rng)
    t = rng.random()
    if t < 0.5:
        d.add(rng.choice(NAME_CUES)).add(name, 1)
        r = rng.random()
        if r < 0.25:
            d.add("，电话 ").add(make_phone(rng), 0, pii=True)
        return d
    if t < 0.78:
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


def pos_boundary(rng: random.Random, compound: bool = False, hard: bool = False) -> Doc:
    """名字后紧跟动词/副词/助词/另一个名字；span 只覆盖姓名。"""
    d = Doc()
    name = make_name(rng, compound=compound)
    t = rng.random()
    if t < 0.20:                                    # 两个 / 三个名字用 和/、 连接
        other = make_name(rng, compound=(not compound and rng.random() < 0.15))
        while other == name:
            other = make_name(rng, compound=(not compound and rng.random() < 0.15))
        d.add(name, 1).add(rng.choice(["和", "与", "跟"]), 0).add(other, 1)
        if rng.random() < 0.5:
            third = make_name(rng, compound=(not compound and rng.random() < 0.1))
            while third in (name, other):
                third = make_name(rng, compound=False)
            d.add("、").add(third, 1)
        d.add(rng.choice(["都到了", "是同学", "一起过来", "在开会", "已经走了", "都在会议室"]), 0)
        return d
    if t < 0.36:                                    # 名字 + 动词短语
        d.add(name, 1).add(rng.choice(BOUNDARY_AFTER), 0)
        return d
    if t < 0.52:                                    # 名字 + 助词/副词 + 名词
        d.add(name, 1).add(rng.choice(BOUNDARY_PARTICLE), 0)
        d.add(rng.choice(BOUNDARY_NOUN), 0)
        return d
    if t < 0.64:                                    # 名字 + 标点
        d.add(name, 1).add(rng.choice(PUNCT), 0)
        d.add(rng.choice(["我下午到", "材料已经交了", "你联系一下", "他明天来", "请回电"]), 0)
        return d
    if t < 0.78:                                    # 线索 + 名字 + 动作
        d.add(rng.choice(NAME_CUES), 0).add(name, 1)
        d.add(rng.choice(["一下", "过来", "确认", "签字", "回电", "开会", "看一下"]), 0)
        return d
    if t < 0.9:                                     # 名字紧邻数字
        d.add(name, 1).add(make_phone(rng), 0, pii=True)
        if rng.random() < 0.4:
            d.add(rng.choice([" 麻烦回电", " 请查收", " 是他的号"]), 0)
        return d
    d.add("客户").add(name, 1).add(rng.choice(["到了", "在门口", "已经走了", "在等你"]), 0)
    return d


def pos_compound(rng: random.Random, hard: bool = False) -> Doc:
    d = Doc()
    name = make_name(rng, compound=True)
    t = rng.random()
    if t < 0.35:
        d.add(rng.choice(NAME_CUES)).add(name, 1)
    elif t < 0.65:
        d.add(name, 1).add(rng.choice(BOUNDARY_AFTER), 0)
    elif t < 0.85:
        d.add(name, 1).add(rng.choice(PUNCT), 0).add(rng.choice(["你好", "请进", "请回电", "在开会"]), 0)
    else:
        other = make_name(rng)
        d.add(name, 1).add("和").add(other, 1).add(rng.choice(["都到了", "一起开会", "是同事"]), 0)
    return d


def pos_title(rng: random.Random, hard: bool = False) -> Doc:
    """姓 + 称谓，整个“王经理/张总/李老师”标 name。"""
    d = Doc()
    title = make_title_name(rng)
    t = rng.random()
    if t < 0.30:
        d.add(rng.choice(NAME_CUES)).add(title, 1)
    elif t < 0.62:
        d.add(title, 1).add(rng.choice(["您好", "今天不在", "来了", "已经走了", "在开会", "请回电"]), 0)
    elif t < 0.82:
        d.add(title, 1).add(rng.choice(BOUNDARY_PARTICLE), 0)
        d.add(rng.choice(BOUNDARY_NOUN), 0)
    else:
        d.add(title, 1).add(rng.choice(PUNCT), 0).add(rng.choice(["请进", "这边请", "你找谁"]), 0)
    return d


def pos_addr(rng: random.Random, hard: bool = False) -> Doc:
    d = Doc()
    if hard:
        t = rng.random()
        coll = make_coll(rng)
        if t < 0.5:
            d.add(rng.choice(["我家在", "就在", "你到", "定位在", "送货到"])).add(coll, 2)
            d.add(rng.choice(["，你过来吧", "，很好找", "等我", "那栋楼"]))
        elif t < 0.8:
            d.add(coll, 2).add(rng.choice(["有家小超市", "那栋是仓库", "拐进去就到", "新开了家店"]))
        else:
            d.add("地址在").add(coll, 2).add("，别走错了")
        return d
    addr = make_addr(rng)
    t = rng.random()
    if t < 0.7:
        d.add(rng.choice(ADDR_CUES)).add(addr, 2)
        if rng.random() < 0.15:
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
    if t < 0.3:
        d.add("收件人：").add(name, 1).add("，电话").add(phone, 0, pii=True)
    elif t < 0.55:
        d.add("联系人").add(name, 1).add("，住在").add(addr, 2)
    elif t < 0.78:
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
            w = rng.choice(NEG_SURNAME_WORDS)
            d.add(rng.choice(HARD_NEG_FRAMES).format(w=w))
            return d
        w = rng.choice(NEG_ADDR_WORDS)
        d.add(rng.choice(HARD_ADDR_NEG_FRAMES).format(w=w))
        return d

    t = rng.random()
    if t < 0.12:
        d.add("订单号").add(make_order(rng), 0, pii=True)
        d.add(" 已发货，金额 ").add(make_amount(rng), 0, pii=True).add(" 元")
        return d
    if t < 0.22:
        d.add("订单 ").add(make_order(rng), 0, pii=True)
        d.add(" 金额：").add(make_amount(rng), 0, pii=True).add(" 元")
        return d
    if t < 0.32:
        d.add(f"{rng.randint(2023, 2026)}年{rng.randint(1, 12)}月{rng.randint(1, 28)}日")
        d.add(f" {rng.randint(8, 20)}:{rng.randint(0, 59):02d} 开会")
        return d
    if t < 0.40:
        d.add(f"第{rng.randint(1, 300)}页 共{rng.randint(1, 500)}页")
        return d
    if t < 0.48:
        d.add("".join(rng.choice("0123456789") for _ in range(rng.randint(6, 20))))
        return d
    if t < 0.56:
        d.add("手机 ").add(make_phone(rng), 0, pii=True)
        return d
    if t < 0.64:
        d.add("身份证 ").add("".join(rng.choice("0123456789") for _ in range(18)), 0, pii=True)
        return d
    if t < 0.72:
        d.add("银行卡 ").add("".join(rng.choice("0123456789") for _ in range(16)), 0, pii=True)
        d.add(" 转账 ").add(make_amount(rng), 0, pii=True).add(" 元")
        return d
    if t < 0.80:
        d.add("工号 ").add(str(rng.randint(10000, 999999)), 0, pii=True)
        d.add(f"，部门 {rng.choice(['研发', '市场', '财务', '人事', '运营'])}，第{rng.randint(1, 9)}组")
        return d
    if t < 0.86:
        d.add("验证码 ").add(str(rng.randint(100000, 999999)), 0, pii=True)
        d.add("，5分钟内有效")
        return d
    if t < 0.93:
        d.add(rng.choice(["项目经理", "部门经理", "主任医师", "值班经理", "客户经理",
                          "技术支持", "文案", "文档", "实习生", "供应商"])
              + rng.choice(["到了", "在开会", "已经走了", "说下午再看", "确认过了"]))
        return d
    if rng.random() < 0.5:
        w = rng.choice(NEG_SURNAME_WORDS)
        d.add(rng.choice(HARD_NEG_FRAMES).format(w=w))
    else:
        w = rng.choice(NEG_ADDR_WORDS)
        d.add(rng.choice(HARD_ADDR_NEG_FRAMES).format(w=w))
    return d


# --------------------------------------------------------------------------- 生成
def make_ambig_name(rng: random.Random) -> str:
    s = rng.choice(SURNAMES)
    if rng.random() < 0.55:
        return s + rng.choice(GIVEN) + rng.choice(AMBIG_LAST)
    return s + rng.choice(AMBIG_LAST)


def pos_targeted(rng: random.Random) -> Doc:
    """专门补 v2 残余错误：名字首/尾边界、歧义末字、地址首字、姓氏陷阱。"""
    d = Doc()
    t = rng.random()
    if t < 0.18:                                     # 句首名字 + 标点
        name = make_name(rng, compound=(rng.random() < 0.12))
        d.add(name, 1).add(rng.choice(["，你联系一下", "，材料已经交了", "，请回电",
                                       "？你找谁", "！请进", "。"]), 0)
    elif t < 0.36:                                   # 歧义末字 + 动词
        name = make_ambig_name(rng)
        d.add(name, 1).add(rng.choice(AMBIG_AFTER), 0)
    elif t < 0.52:                                   # 名字 + 歧义边界词
        name = make_name(rng)
        d.add(name, 1).add(rng.choice(BOUNDARY_WORDS), 0)
    elif t < 0.68:                                   # 线索/和 之后的名字（防止丢姓）
        name = make_ambig_name(rng) if rng.random() < 0.5 else make_name(rng)
        if rng.random() < 0.55:
            d.add(rng.choice(NAME_CUES), 0).add(name, 1)
        else:
            other = make_name(rng)
            d.add(other, 1).add(rng.choice(["和", "与", "、"]), 0).add(name, 1)
        d.add(rng.choice(["在等你", "到了", "已经走了", "请回电", "一起过来", "是同事"]), 0)
    elif t < 0.82:                                   # 名字+电话，“，在”+口语地址（地址首字）
        name = make_name(rng)
        d.add(name, 1).add(make_phone(rng), 0, pii=True)
        d.add("，在").add(make_coll(rng), 2)
    elif t < 0.92:                                   # 地址首字（在/到/去 + 口语地址）
        d.add(rng.choice(["在", "到", "去", "住在", "送到", "地址在"]), 0)
        d.add(make_coll(rng), 2)
    else:                                            # 姓氏/地址陷阱
        w = rng.choice(NEG_SURNAME_WORDS + NEG_ADDR_WORDS + ["赵家楼", "石家庄"])
        d.add(rng.choice(["{w}门口有棵老槐树", "{w}门口人很多", "{w}的人很热情",
                          "路过{w}", "{w}那边在修路", "{w}这次先放着",
                          "{w}还没确定"]).format(w=w), 0)
    return d


BOUNDARY_LAST = [c for c in "问在回说去来好是时住活清边知友配成平很都" if c in NAME_CORE]


def make_ctx_name(rng: random.Random) -> str:
    """名字末字故意取“也像边界词”的字，用来教模型不要把 问/在/回/好 吃掉。"""
    if rng.random() < 0.06:
        return rng.choice(COMPOUND) + rng.choice(NAME_CORE) + rng.choice(BOUNDARY_LAST)
    s = rng.choice(SURNAMES)
    if rng.random() < 0.3:
        return s + rng.choice(BOUNDARY_LAST)
    return s + rng.choice(NAME_CORE) + rng.choice(BOUNDARY_LAST)


def pos_name_ctx(rng: random.Random) -> Doc:
    d = Doc()
    name = make_ctx_name(rng)
    t = rng.random()
    if t < 0.45:
        d.add(name, 1).add("的演唱会在上海", 0)
    elif t < 0.70:
        d.add(name, 1).add("说下午开会", 0)
    elif t < 0.85:
        d.add("请把文件发给").add(name, 1)
    else:
        d.add(name, 1).add(rng.choice(["问", "在楼下", "不太舒服", "很忙",
                                       "回电", "刚才来过", "走了", "都到了"]), 0)
    return d


def pos_addr_start(rng: random.Random) -> Doc:
    d = Doc()
    d.add(make_digit_addr(rng), 2).add("是收货地址", 0)
    return d


def pos_pairs(rng: random.Random) -> Doc:
    """两个 v3 名字用 与/和/跟/、 连接；只标姓名。"""
    d = Doc()
    a = make_core_name(rng)
    b = make_core_name(rng)
    while b == a:
        b = make_core_name(rng)
    d.add(a, 1).add(rng.choice(["与", "和", "跟", "、"]), 0).add(b, 1)
    d.add(rng.choice(["在开会", "都到了", "是同事", "一起过来", "已经走了",
                      "在楼下等你", "都参加"]), 0)
    return d


def pos_targeted3(rng: random.Random) -> Doc:
    """cue + 三字名（名里带 桂/林/山/江/海 这类也像地名的字）+ 回电/请查收。"""
    d = Doc()
    cue = rng.choice(["收件人：", "联系人：", "姓名：", "户主：", "发件人：", "签字：",
                      "叫", "名叫", "署名："])
    given = rng.choice(["桂阳", "桂英", "桂林", "桂芳", "桂华", "桂兰", "山阳", "林阳",
                        "江河", "海洋", "云山", "明阳", "华阳", "阳山", "柏阳", "桂明"])
    name = rng.choice(SURNAMES) + given
    d.add(cue, 0).add(name, 1)
    d.add(rng.choice(["回电", "请查收", "已确认", "到了", "在开会"]), 0)
    return d


def pos_targeted2(rng: random.Random) -> Doc:
    """只针对上一版残余的 4 类：称谓+明天/刚才、刚/才末字+电话、住在、刚才。"""
    d = Doc()
    t = rng.random()
    if t < 0.30:
        d.add(make_title_name(rng), 1)
        d.add(rng.choice(["明天电话", "今天不在", "刚才来电", "明天开会",
                          "刚才会议", "明天过来", "今天请假"]), 0)
    elif t < 0.55:
        name = rng.choice(SURNAMES) + (rng.choice(GIVEN) if rng.random() < 0.5 else "") + rng.choice("刚才")
        if rng.random() < 0.5:
            d.add(name, 1).add(make_phone(rng), 0, pii=True)
            d.add(rng.choice([" 请查收", " 麻烦回电", ""]), 0)
        else:
            d.add(name, 1).add("请查收", 0)
    elif t < 0.80:
        d.add(make_name(rng), 1).add("住在", 0).add(make_coll(rng), 2)
    else:
        d.add(make_name(rng), 1).add("刚才", 0).add(rng.choice(["会议", "电话", "来过", "开会"]), 0)
    return d


def pos_english(rng: random.Random) -> Doc:
    d = Doc()
    name = make_name(rng)
    d.add(rng.choice(["Alice的同事", "找Tom要", "Lucy说", "Kevin和", "ABC公司的", "email给"]), 0)
    d.add(name, 1)
    d.add(rng.choice(["在北京CBD工作", "的电话", "明天到上海", "一起开会", "已经确认"]), 0)
    return d


def build_one(rng: random.Random, cat: str) -> Doc:
    if cat == "prose":
        return prose_doc(rng)
    if cat == "targeted":
        return pos_targeted(rng)
    if cat == "pairs":
        return pos_pairs(rng)
    if cat == "name_ctx":
        return pos_name_ctx(rng)
    if cat == "addr_start":
        return pos_addr_start(rng)
    if cat == "targeted2":
        return pos_targeted2(rng)
    if cat == "targeted3":
        return pos_targeted3(rng)
    if cat == "trap":
        return trap_doc(rng)
    if cat == "name":
        return pos_name(rng)
    if cat == "boundary":
        return pos_boundary(rng)
    if cat == "compound":
        return pos_compound(rng)
    if cat == "title":
        return pos_title(rng)
    if cat == "addr":
        return pos_addr(rng)
    if cat == "addr_digits":
        return pos_addr_digits(rng)
    if cat == "mixed":
        return pos_mixed(rng)
    if cat == "english":
        return pos_english(rng)
    if cat == "colloc":
        return pos_addr(rng, hard=True)
    if cat == "neg":
        return neg_sentence(rng, hard=False)
    if cat == "neg_hard":
        return neg_sentence(rng, hard=True)
    if cat == "hard_name":
        return pos_boundary(rng, hard=True)
    if cat == "hard_boundary":
        return pos_boundary(rng, hard=True)
    if cat == "hard_compound":
        return pos_compound(rng, hard=True)
    if cat == "hard_title":
        return pos_title(rng, hard=True)
    if cat == "hard_addr":
        return pos_addr(rng, hard=True)
    if cat == "hard_mixed":
        return pos_mixed(rng, hard=True)
    if cat == "hard_trap":
        return trap_doc(rng)
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
            if guard > n * 80 + 2000:
                raise RuntimeError(f"cannot generate enough unique {cat}")
            d = build_one(rng, cat)
            text = d.text()
            if blen(text) > limit:                  # 64 字节窗口（字符对齐）
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


def coverage_rows(seen: set[str], forbidden: set[str]) -> list[dict]:
    """保证每个难负词/口语构件/英文名/地名 token 在训练集里至少出现一次（OOV=0）。"""
    rows: list[dict] = []

    def add(d: Doc) -> None:
        text = d.text()
        if blen(text) > 64 or text in seen or text in forbidden:
            return
        seen.add(text)
        rows.append({"text": text, "spans": d.spans()})

    for w in NEG_SURNAME_WORDS:
        d = Doc()
        d.add(HARD_NEG_FRAMES[0].format(w=w))
        add(d)
    for w in NEG_ADDR_WORDS:
        d = Doc()
        d.add(HARD_ADDR_NEG_FRAMES[0].format(w=w))
        add(d)
    for s in COLL_START:
        d = Doc()
        d.add("我家在").add(s + COLL_DIR[0], 2)
        add(d)
    for w in COLL_DIR:
        d = Doc()
        d.add("我家在").add(COLL_START[0] + w, 2)
        add(d)
    for w in COLL_DIST:
        d = Doc()
        d.add("我家在").add(COLL_START[0] + w, 2)
        add(d)
    for tok in PROVINCES + CITIES + DISTRICTS + STREETS:
        d = Doc()
        d.add("地址：").add(tok, 2)
        add(d)
    for s in SURNAMES:
        d = Doc()
        d.add("联系人").add(s + "伟", 1)
        add(d)
        d = Doc()
        d.add(s + "伟", 1).add("，你联系一下", 0)
        add(d)
        d = Doc()
        d.add("客户").add(s + "伟", 1).add("在等你", 0)
        add(d)
        d = Doc()
        d.add("联系人").add(s + "三", 1)
        add(d)
        d = Doc()
        d.add(s + "伟", 1).add("和", 0).add("李明", 1).add("是同事", 0)
        add(d)
    for s in SURNAMES:
        for ch in AMBIG_LAST[:6]:
            d = Doc()
            d.add(s + ch, 1).add("一起过来", 0)
            add(d)
    for w in TRAP_WORDS:
        d = Doc()
        d.add(TRAP_FRAMES[0].format(w=w, tail=PROSE_TAILS[0]))
        add(d)
    for t in ["周末的演唱会取消了。", "演唱会门票卖完了。", "他正在听音乐会。",
              "展览明天开幕。", "Alice和Tom一起开会", "Lucy找Kevin确认",
              "ABC公司的项目经理", "email发给Kevin"]:
        d = Doc()
        d.add(t)
        add(d)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/ner")
    ap.add_argument("--seed", type=int, default=20261118)
    ap.add_argument("--train", type=int, default=54500)
    ap.add_argument("--heldout", type=int, default=2600)
    ap.add_argument("--hard", type=int, default=1600)
    ap.add_argument("--bulk", type=int, default=24000, help="名字大类的行数（每行 5 个全名）")
    ap.add_argument("--realistic", type=int, default=400, help="真人风格名字行数（每行 5 个）")
    ap.add_argument("--unseen", type=int, default=600, help="unseen_names.jsonl 句数")
    ap.add_argument("--addr-digits", type=int, default=600, help="addr_digits.jsonl 句数")
    args = ap.parse_args()

    out = Path(args.out)
    if not out.is_absolute():
        out = (ROOT / out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    def scale_spec(base: list[tuple[str, int]], total: int) -> list[tuple[str, int]]:
        base_total = sum(n for _, n in base)
        spec = [(c, n * total // base_total) for c, n in base]
        spec[-1] = (spec[-1][0], spec[-1][1] + total - sum(n for _, n in spec))
        return spec

    # 训练：30.6k，散文 11k（35.9%），负样本 13.5k（44.1%），
    # 边界 3k + 复姓 3.6k（12 个复姓各约 300 例）=> 难样本 >= 21%。
    train_spec = scale_spec([
        ("prose", 28500), ("neg", 2000), ("neg_hard", 600), ("trap", 1500),
        ("targeted", 2000), ("targeted2", 300), ("targeted3", 200), ("pairs", 1500),
        ("name_ctx", 4000), ("addr_start", 1000),
        ("colloc", 800), ("english", 300),
        ("name", 1500), ("boundary", 2500), ("compound", 1500),
        ("title", 1000), ("addr", 2500), ("mixed", 800), ("addr_digits", 2000),
    ], args.train)
    # 留出：2.6k，负样本约 40%，覆盖所有新类别。
    held_spec = scale_spec([
        ("prose", 850), ("neg", 120), ("neg_hard", 40), ("trap", 80),
        ("targeted", 100), ("targeted2", 30), ("targeted3", 20), ("pairs", 80),
        ("name_ctx", 80), ("addr_start", 80), ("colloc", 100), ("english", 50),
        ("name", 300), ("boundary", 300), ("compound", 300),
        ("title", 150), ("addr", 350), ("mixed", 90), ("addr_digits", 100),
    ], args.heldout)
    # 难集：1.6k，只评估。
    hard_spec = scale_spec([
        ("hard_name", 350), ("hard_boundary", 350), ("hard_compound", 300),
        ("hard_title", 100), ("hard_addr", 250), ("hard_mixed", 100),
        ("hard_trap", 100), ("hard_neg", 150),
    ], args.hard)

    # 固定的散文评测集不能进训练：把它整句加入 forbidden。
    forbidden: set[str] = set()
    prose_path = out / "prose.jsonl"
    if prose_path.exists():
        for line in prose_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                forbidden.add(json.loads(line)["text"])
    seen: set[str] = set(forbidden)

    train_rows, train_cat = gen_split(random.Random(args.seed), train_spec, seen)
    cov = coverage_rows(seen, forbidden)
    train_rows.extend(cov)
    train_cat["coverage"] = len(cov)

    # v3：先把基础类别里出现过的全名收集起来，再补 12 万不同全名 + 2000 真人风格名
    used_names: set[str] = set()
    for r in train_rows:
        b = r["text"].encode("utf-8")
        for s, ln, y in r["spans"]:
            if y == 1:
                used_names.add(b[s:s + ln].decode("utf-8"))
    bulk_rows = gen_bulk_rows(args.bulk, random.Random(args.seed + 10), seen, used_names)
    real_rows = gen_bulk_rows(args.realistic, random.Random(args.seed + 11), seen,
                              used_names, realistic=True)
    train_rows.extend(bulk_rows)
    train_rows.extend(real_rows)
    train_cat["bulk_names"] = len(bulk_rows)
    train_cat["realistic_rows"] = len(real_rows)

    held_rows, held_cat = gen_split(random.Random(args.seed + 1), held_spec, seen)
    hard_rows, hard_cat = gen_split(random.Random(args.seed + 2), hard_spec, seen)

    # v3 评估集：训练时没出现过的全名；含数字的地址
    unseen_rows = gen_unseen_rows(args.unseen, random.Random(args.seed + 12), used_names, seen)
    addr_eval_rows = gen_addr_digit_rows(args.addr_digits, random.Random(args.seed + 13), seen)

    write_jsonl(out / "train.jsonl", train_rows)
    write_jsonl(out / "heldout.jsonl", held_rows)
    write_jsonl(out / "hard.jsonl", hard_rows)
    write_jsonl(out / "unseen_names.jsonl", unseen_rows)
    write_jsonl(out / "addr_digits.jsonl", addr_eval_rows)
    (out / "name_chars.txt").write_text("".join(NAME_CHARS) + "\n", encoding="utf-8")

    train_chars = {c for r in train_rows for c in r["text"]}
    held_chars = {c for r in held_rows for c in r["text"]}
    hard_chars = {c for r in hard_rows for c in r["text"]}
    prose_chars = set()
    prose_rows = []
    if prose_path.exists():
        prose_rows = [json.loads(l) for l in prose_path.read_text(encoding="utf-8").splitlines() if l.strip()]
        prose_chars = {c for r in prose_rows for c in r["text"]}

    def ratio_hard(cat: dict[str, int]) -> float:
        h = sum(v for k, v in cat.items()
                if k.startswith("hard") or k in ("boundary", "compound", "colloc",
                                                 "bulk_names", "realistic_rows"))
        return round(h / max(sum(cat.values()), 1), 4)

    addr_total = 0
    addr_with_digit = 0
    for r in train_rows:
        b = r["text"].encode("utf-8")
        for s, ln, y in r["spans"]:
            if y == 2:
                addr_total += 1
                if any(ch.isdigit() for ch in b[s:s + ln].decode("utf-8")):
                    addr_with_digit += 1

    def ratio_prose(cat: dict[str, int]) -> float:
        return round(cat.get("prose", 0) / max(sum(cat.values()), 1), 4)

    manifest = {
        "seed": args.seed,
        "counts": {"train": len(train_rows), "heldout": len(held_rows), "hard": len(hard_rows)},
        "categories": {"train": train_cat, "heldout": held_cat, "hard": hard_cat},
        "neg_ratio": {
            "train": stats(train_rows)["neg_ratio"],
            "heldout": stats(held_rows)["neg_ratio"],
            "hard": stats(hard_rows)["neg_ratio"],
        },
        "prose_ratio": {
            "train": ratio_prose(train_cat),
            "heldout": ratio_prose(held_cat),
            "hard": ratio_prose(hard_cat),
        },
        "hard_ratio": {
            "train": ratio_hard(train_cat),
            "heldout": ratio_hard(held_cat),
            "hard": ratio_hard(hard_cat),
        },
        "chars": {"train": len(train_chars), "heldout": len(held_chars), "hard": len(hard_chars)},
        "name_chars": len(NAME_CHARS),
        "distinct_train_names": len(used_names),
        "bulk_name_rows": len(bulk_rows),
        "realistic_name_rows": len(real_rows),
        "addr_digit_ratio": round(addr_with_digit / max(addr_total, 1), 4),
        "unseen_names": {"cases": len(unseen_rows)},
        "addr_digits": {"cases": len(addr_eval_rows)},
        "oov": {
            "heldout": sorted(held_chars - train_chars),
            "hard": sorted(hard_chars - train_chars),
            "prose": sorted(prose_chars - train_chars),
        },
        "max_chars": max(len(r["text"]) for r in train_rows + held_rows + hard_rows),
        "max_bytes": max(blen(r["text"]) for r in train_rows + held_rows + hard_rows),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                                       encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
