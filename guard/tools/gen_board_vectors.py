"""生成板级 UART 端到端向量（sim/tb_guard_uart.sv 回放）。

每个用例两个文件：
  case_NNNN.in   —— 上位机要发的字节（可多帧，帧以 LF 结尾）
  case_NNNN.exp  —— 期望从 UART TX 收到的完整字节流（脱敏文本 + 审计行）
外加 manifest.txt：每行一个用例序号。

期望值全部来自 host/golden/board_proto.py（与 RTL 同一份规则），所以 TB 是
字节级端到端：UART 位定时、FIFO 流控、帧冲刷、摘要格式全在环。

用法：python3 tools/gen_board_vectors.py --out build/board
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.corpus.synth import build_case, render_scene  # noqa: E402
from host.golden.board_proto import expected_stream, output_thresholds  # noqa: E402
from host.golden.pii_rules import scan  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def cases(rng: random.Random) -> list[tuple[str, bytes]]:
    out: list[tuple[str, bytes]] = []

    sample = (ROOT / "examples" / "sample.txt").read_bytes()
    clean = (ROOT / "examples" / "clean.txt").read_bytes()

    # 1. 仓库自带样例（多行 = 多帧）
    out.append(("sample.txt", sample))
    # 2. 无 PII 文件必须原样透传
    out.append(("clean.txt", clean))
    # 3. 结尾没有换行：靠空闲冲刷（IDLE_BITS）
    out.append(("no-trailing-lf", sample.rstrip(b"\n")))
    # 4. 帧首就是 PII（回归：帧尾 span 提交晚于泄流的漏脱敏）
    out.append(("pii-at-frame-start", b"13800138000\n"))
    out.append(("id18-at-frame-start", b"11010519491231002X\n"))
    # 5. 连续空行：空帧不产生摘要
    out.append(("empty-lines", b"a\n\n\nb\n"))
    # 6. CRLF 行尾
    out.append(("crlf", "手机 13800138000，邮箱 a@b.co\r\n".encode()))
    # 7. 单帧、无换行、以 PII 结尾
    out.append(("pii-at-ends-no-lf", b"watch 13800138000"))

    # 8. 每帧一行的场景文本
    scenes: list[bytes] = []
    for _ in range(8):
        line = render_scene(rng).encode("utf-8") + b"\n"
        scenes.append(line)
        out.append(("scene", line))

    # 9. 多帧串联（同一次会话里连续处理很多行）
    out.append(("scenes-joined", b"".join(scenes)))

    # 10. 长流：流控与 FIFO 深度（~6 KB 输入 / ~6 KB 输出）
    long_line = b"\xe8\x81\x94\xe7\xb3\xbb\xe4\xba\xba\xef\xbc\x9a\xe5\xbc\xa0\xe4\xbc\x9f\xef\xbc\x8c\xe6\x89\x8b\xe6\x9c\xba 13800138000\xef\xbc\x8c\xe9\x82\xae\xe7\xae\xb1 a@b.co\n"
    out.append(("long-stream", long_line * 128))

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/board")
    ap.add_argument("--seed", type=int, default=20261115)
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)

    items = cases(rng)
    total_spans = 0
    total_bytes = 0
    manifest = out / "manifest.txt"
    with manifest.open("w", encoding="utf-8") as mf:
        for i, (name, data) in enumerate(items):
            total_spans += len(scan(data))
            total_bytes += len(data)
            (out / f"case_{i:04d}.in").write_bytes(data)
            (out / f"case_{i:04d}.exp").write_bytes(expected_stream(data))
            # 发送门槛：TB/上位机都按这个节奏发，别把 256 字节的 RX FIFO 灌爆
            pace = output_thresholds(data)
            (out / f"case_{i:04d}.pace").write_text(
                "".join(f"{v}\n" for v in pace), encoding="ascii"
            )
            mf.write(f"{i}\n")
            print(f"  {i:04d} {name:22s} in={len(data):5d} B")
    print(
        f"board vectors: {len(items)} cases, {total_bytes} B input, "
        f"{total_spans} spans -> {out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
