"""板级串口协议（UART 数据面）的参考实现。

与 rtl/board/guard_uart_core.sv + rtl/board/guard_report.sv 逐条对齐：

1. 帧边界：收到 LF（0x0A）立即结束当前帧；没有 LF 时，空闲超过 IDLE_BITS 个
   位时间也结束当前帧。**空帧不产生摘要**（一个字节都没进流水线就不报）。
2. 每帧输出：先输出本帧的 mask 脱敏结果（1:1 长度），LF 补成 CRLF。
3. 再输出一行审计摘要：

       [guard] n=NNN id18=NNN id15=NNN mobile=NNN bank=NNN email=NNN
               ipv4=NNN uscc=NNN plate=NNN kw=NNN kwm=NNN ovf=NNN mode=N

   数字一律 3 位零填充（mode 是 1 位）；若上一个输出字节不是 LF，行首补 CRLF。
   kw = 关键词命中次数；kwm = 命中的关键词位图（bit k = kid k，见 keywords.py）；
   mode = 降级档位（1 = T1 规则层生效，0 = T0 直通）。
4. 计数超过 255 截到 255（RTL 的计数器是 8 位）。

这是唯一实现：tools/gen_board_vectors.py（生成 TB 期望）与 tools/serial_host.py
（上位机校验）都从这里取。
"""

from __future__ import annotations

from host.golden.keywords import find_keywords
from host.golden.l2_int4 import semantic_scan
from host.golden.redact import redact

# 与 rtl/board/guard_report.sv 的字段顺序一致（type_id, 字段名）
BOARD_FIELDS = (
    (1, "id18"),
    (2, "id15"),
    (3, "mobile"),
    (4, "bank"),
    (5, "email"),
    (6, "ipv4"),
    (7, "uscc"),
    (8, "plate"),
)

MAX_COUNT = 255
REPORT_PREFIX = b"[guard] "
LF = 0x0A


def _clamp(v: int) -> int:
    return min(max(int(v), 0), MAX_COUNT)


def report_line(
    counts: dict[int, int],
    err: int = 0,
    *,
    kw: int = 0,
    kwm: int = 0,
    l2: int = 0,
    l2m: int = 0,
    mode: int = 1,
) -> bytes:
    """一行审计摘要（不含行尾 LF）。counts 按 type_id 计数。

    kw / kwm / mode 与 RTL（rtl/board/guard_report.sv）字段顺序一致：
    kw = 关键词命中次数，kwm = 命中的关键词位图，mode = 档位（1 位十进制）。
    """
    n = sum(counts.values())
    fields = [("n", n)]
    fields += [(name, counts.get(t, 0)) for t, name in BOARD_FIELDS]
    fields += [("kw", kw), ("kwm", kwm), ("l2", l2), ("l2m", l2m), ("ovf", 1 if err else 0)]
    body = " ".join(f"{name}={_clamp(v):03d}" for name, v in fields)
    body += f" mode={_clamp(mode) % 10:d}"
    return REPORT_PREFIX + body.encode("ascii")


def expand_lf(data: bytes) -> bytes:
    """LF → CRLF（板级 LF_TO_CRLF=1）。"""
    return data.replace(b"\n", b"\r\n")


def split_frames(data: bytes) -> list[bytes]:
    """按板子的规则切帧：每个 LF 结束一帧，末尾残余算最后一帧。"""
    frames: list[bytes] = []
    cur = bytearray()
    for b in data:
        cur.append(b)
        if b == LF:
            frames.append(bytes(cur))
            cur = bytearray()
    if cur:
        frames.append(bytes(cur))
    return frames


def kw_stats(frame: bytes) -> tuple[int, int]:
    """本帧的关键词提示：(命中次数, 位图)。位图 bit k = 关键词 kid k。

    与 RTL（l1_keyword_match）逐条对齐：同一结束位置最多一个命中、按 kid 升序
    取第一个（见 host/golden/keywords.find_keywords）。
    """
    hits = find_keywords(frame)
    mask = 0
    for h in hits:
        mask |= 1 << h.kid
    return min(len(hits), MAX_COUNT), min(mask, MAX_COUNT)


def l2_stats(frame: bytes) -> tuple[int, int]:
    """本帧 L2 语义层的结果：(判成 PII 的游程数, 类别位图)。

    与 RTL（l2_semantic_top + guard_uart_core 的 c_l2/c_l2m）逐条对齐：
    class 0 = none 不计；位图 bit(1..3) 对应 id18/bank/mobile。
    """
    n = 0
    mask = 0
    for _start, _ln, cls, _scores in semantic_scan(frame):
        if cls:
            n += 1
            mask |= 1 << cls
    return min(n, MAX_COUNT), min(mask, MAX_COUNT)


def type_counts(audits) -> dict[int, int]:
    counts: dict[int, int] = {}
    for a in audits:
        counts[a.type_id] = counts.get(a.type_id, 0) + 1
    return counts


def frame_stream(frame: bytes, policy: str = "mask", at_line_start: bool = True) -> bytes:
    """一帧的完整输出：脱敏文本 + 摘要行（已做 LF→CRLF）。"""
    red, audits = redact(frame, policy=policy)
    kw, kwm = kw_stats(frame)
    l2n, l2m = l2_stats(frame)
    out = bytearray(red)
    if not at_line_start:
        out += b"\n"
    out += report_line(type_counts(audits), kw=kw, kwm=kwm, l2=l2n, l2m=l2m) + b"\n"
    return expand_lf(bytes(out))


def expected_stream(data: bytes, policy: str = "mask") -> bytes:
    """整段输入（可含多帧）对应的完整 TX 字节流。

    注意：摘要行在模型里也只写 LF，最后统一 expand_lf —— 与 RTL 一致
    （CR 由 core 的 LF→CRLF 整形补，RTL 侧自己再写 CR 会变成 \r\r\n）。
    """
    out = bytearray()
    for frame in split_frames(data):
        red, audits = redact(frame, policy=policy)
        kw, kwm = kw_stats(frame)
        l2n, l2m = l2_stats(frame)
        out += red
        if out and out[-1:] != b"\n":
            out += b"\n"
        out += report_line(type_counts(audits), kw=kw, kwm=kwm, l2=l2n, l2m=l2m) + b"\n"
    return expand_lf(bytes(out))


# 脱敏器输出滞后输入的字节数（l1_redactor: WINDOW+2 = 66）
ECHO_LAG = 66


def output_thresholds(data: bytes, slack: int = 32, lag: int = ECHO_LAG) -> list[int]:
    """每个输入字节的"发送门槛"：已经收到这么多**输出**字节，才能发第 i 个。

    为什么需要：摘要行让输出字节数 > 输入字节数（一帧 130 字节的文本会多出
    ~100 字节摘要），板上只有 256+256 字节的两级 FIFO。板子的输入消费速度被
    回读速率卡住，上位机照线速猛灌就会把 RX FIFO 灌爆（ovf=001、LED2 亮）。

    门槛 = 已完成帧的**全部**输出（文本 + 摘要 + LF→CRLF） + 本帧已回显的文本，
    再减掉 slack。帧内用 acc[j - lag] 是因为脱敏器的回声比输入滞后 66 字节
    （l1_redactor 的 64+2 窗口）；不减这个 lag 会把自己锁死（等不到回声）。
    帧尾把摘要也计入，于是"发下一帧之前先把上一帧的回读收干净"。
    """
    n = len(data)
    out = [0] * (n + 1)
    done = 0            # 已完成帧的输出字节数（已做 LF→CRLF）
    at_ls = True        # 行首状态（第一个字节前当作行首）
    k = 0
    for frame in split_frames(data):
        red, audits = redact(frame, policy="mask")
        prefix = b"" if at_ls else b"\n"
        report = expand_lf(prefix + report_line(type_counts(audits)) + b"\n")
        m = len(frame)
        acc = [0] * (m + 1)
        for j in range(m):
            acc[j + 1] = acc[j] + (2 if red[j] == 0x0A else 1)
        for j in range(m + 1):
            out[k + j] = max(0, done + acc[max(0, j - lag)] - slack)
        k += m
        done += acc[m] + len(report)
        at_ls = True
    return out


def parse_report(line: bytes) -> dict[str, int] | None:
    """解析一行 [guard] ...；不是摘要行或格式不对时返回 None。"""
    s = line.strip(b"\r\n")
    if not s.startswith(REPORT_PREFIX):
        return None
    out: dict[str, int] = {}
    for tok in s[len(REPORT_PREFIX):].split(b" "):
        if not tok:
            continue
        key, sep, val = tok.partition(b"=")
        if not sep or not val.isdigit():
            return None
        out[key.decode("ascii")] = int(val)
    if "n" not in out or "ovf" not in out:
        return None
    return out


def split_stream(raw: bytes) -> tuple[bytes, list[dict[str, int]]]:
    """把板子回来的字节流拆成（文本, 审计行列表）。"""
    text = bytearray()
    reports: list[dict[str, int]] = []
    for line in raw.splitlines(keepends=True):
        parsed = parse_report(line)
        if parsed is not None:
            reports.append(parsed)
            continue
        text += line
    return bytes(text), reports