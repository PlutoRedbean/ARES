"""把 NER 的 INT8 权重导出成 RTL 能吃的 ROM：.hex + l2_ner_rom.sv。

产物（都在 build/gen/ 下）：
  ner_emb.hex      703*32 字节，按 [vocab][32] 行序
  ner_conv1.hex    32*3*32 字节，按 [out][k][in] 行序（RTL 读的时候自己算下标）
  ner_conv1_b.hex  32 个 int32（写成 8 个 hex 字符/行）
  ner_conv2.hex / ner_conv2_b.hex
  ner_head.hex     3*32 字节
  ner_head_b.hex   3 个 int32
  l2_ner_rom.sv    ROM 模块（$readmemh 初始化）

同时把尺寸/量化参数写进 ner_config.svh，RTL 用 `include 引。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import struct
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "models" / "ner"


def read_npz(path: Path) -> dict[str, list[int]]:
    """最小的 .npz 读取器（不依赖 numpy）：只处理 int8 / int32 的 C 顺序数组。"""
    out: dict[str, list[int]] = {}
    with zipfile.ZipFile(path) as zf:
        for name in zf.namelist():
            if not name.endswith(".npy"):
                continue
            raw = zf.read(name)
            assert raw[:6] == b"\x93NUMPY", name
            major = raw[6]
            if major == 1:
                hlen = struct.unpack("<H", raw[8:10])[0]
                start = 10 + hlen
            else:
                hlen = struct.unpack("<I", raw[8:12])[0]
                start = 12 + hlen
            header = raw[start - hlen:start].decode("latin1")
            body = raw[start:]
            if "'i4'" in header or "i4" in header:
                vals = list(struct.unpack("<" + "i" * (len(body) // 4), body))
            elif "'i1'" in header or "i1" in header:
                vals = list(struct.unpack("<" + "b" * len(body), body))
            else:
                raise SystemExit(f"unsupported dtype in {name}: {header[:80]}")
            out[name[:-4]] = vals
    return out


def hex_bytes(vals: list[int], out: Path) -> None:
    out.write_text("\n".join(f"{v & 0xFF:02X}" for v in vals) + "\n", encoding="utf-8")


def hex_i32(vals: list[int], out: Path) -> None:
    out.write_text("\n".join(f"{v & 0xFFFFFFFF:08X}" for v in vals) + "\n", encoding="utf-8")


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/gen")
    if not out.is_absolute():
        out = ROOT / out
    out.mkdir(parents=True, exist_ok=True)

    w = read_npz(MODEL / "weights_int8.npz")
    cfg = json.loads((MODEL / "config.json").read_text(encoding="utf-8"))
    quant = json.loads((MODEL / "quant.json").read_text(encoding="utf-8"))

    hex_bytes(w["emb_w"], out / "ner_emb.hex")
    hex_bytes(w["conv1_w"], out / "ner_conv1.hex")
    hex_i32(w["conv1_b"], out / "ner_conv1_b.hex")
    hex_bytes(w["conv2_w"], out / "ner_conv2.hex")
    hex_i32(w["conv2_b"], out / "ner_conv2_b.hex")
    hex_bytes(w["head_w"], out / "ner_head.hex")
    hex_i32(w["head_b"], out / "ner_head_b.hex")

    vocab = json.loads((MODEL / "vocab.json").read_text(encoding="utf-8"))["tokens"]
    # 词表按 UTF-8 字节序排好，RTL 用二分查找
    entries = sorted((t.encode("utf-8"), i) for i, t in enumerate(vocab) if t not in ("<pad>", "<unk>"))
    with (out / "ner_vocab.hex").open("w", encoding="utf-8") as f:
        for key, idx in entries:
            # ASCII 的 key 用 0x01 补齐（RTL 里 {byte, 8'h01, 8'h01}）
            f.write(f"{int.from_bytes(key[:3].ljust(3, b'\x01'), 'big'):06X}{idx:04X}\n")

    rq = quant["requant"]
    lines = [
        "// 由 tools/gen_ner_rom.py 生成，请勿手改。",
        f"`define NER_WINDOW      {int(cfg['window_bytes'])}",
        f"`define NER_VOCAB       {len(vocab)}",
        f"`define NER_EMB         {int(cfg['emb_dim'])}",
        f"`define NER_CH          {int(cfg['channels'])}",
        f"`define NER_CLASSES     {int(cfg['num_classes'])}",
        f"`define NER_VOCAB_N     {len(entries)}",
        f"`define NER_CONV1_MUL   {float(rq['conv1']['mul']):.10e}",
        f"`define NER_CONV1_ZP    {int(rq['conv1']['zp'])}",
        f"`define NER_CONV2_MUL   {float(rq['conv2']['mul']):.10e}",
        f"`define NER_CONV2_ZP    {int(rq['conv2']['zp'])}",
        "",
    ]
    (out / "ner_config.svh").write_text("\n".join(lines), encoding="utf-8")

    rom = f"""// 由 tools/gen_ner_rom.py 生成，请勿手改。
// 纯 ROM（$readmemh 初始化），上层 l2_ner.sv 用。
`timescale 1ns/1ps

module l2_ner_rom #(
    parameter int EMB_DEPTH = {len(w['emb_w'])},
    parameter int CONV1_DEPTH = {len(w['conv1_w'])},
    parameter int CONV2_DEPTH = {len(w['conv2_w'])},
    parameter int HEAD_DEPTH = {len(w['head_w'])}
) (
    input  logic [15:0] emb_addr,
    output logic [7:0]  emb_data,

    input  logic [11:0] conv1_addr,
    output logic [7:0]  conv1_data,
    input  logic [4:0]  conv1_b_addr,
    output logic signed [31:0] conv1_b_data,

    input  logic [11:0] conv2_addr,
    output logic [7:0]  conv2_data,
    input  logic [4:0]  conv2_b_addr,
    output logic signed [31:0] conv2_b_data,

    input  logic [7:0]  head_addr,
    output logic [7:0]  head_data,
    input  logic [1:0]  head_b_addr,
    output logic signed [31:0] head_b_data
);

    logic [7:0] emb  [0:EMB_DEPTH-1];
    logic [7:0] c1w  [0:CONV1_DEPTH-1];
    logic signed [31:0] c1b [0:31];
    logic [7:0] c2w  [0:CONV2_DEPTH-1];
    logic signed [31:0] c2b [0:31];
    logic [7:0] hw   [0:HEAD_DEPTH-1];
    logic signed [31:0] hb [0:2];

    // 相对工程根目录（PDS 在 guard/ 下跑）
    initial begin
        $readmemh("build/gen/ner_emb.hex",   emb);
        $readmemh("build/gen/ner_conv1.hex", c1w);
        $readmemh("build/gen/ner_conv1_b.hex", c1b);
        $readmemh("build/gen/ner_conv2.hex", c2w);
        $readmemh("build/gen/ner_conv2_b.hex", c2b);
        $readmemh("build/gen/ner_head.hex",  hw);
        $readmemh("build/gen/ner_head_b.hex", hb);
    end

    assign emb_data     = emb[emb_addr];
    assign conv1_data   = c1w[conv1_addr];
    assign conv1_b_data = c1b[conv1_b_addr];
    assign conv2_data   = c2w[conv2_addr];
    assign conv2_b_data = c2b[conv2_b_addr];
    assign head_data    = hw[head_addr];
    assign head_b_data  = hb[head_b_addr];

endmodule
"""
    (out / "l2_ner_rom.sv").write_text(rom, encoding="utf-8")

    vocab = f"""// 由 tools/gen_ner_rom.py 生成，请勿手改。
// 词表 ROM：858 项，每项 {{key[23:0], id[9:0]}}，按 key 升序（RTL 线性扫描即可）。
`timescale 1ns/1ps

module l2_ner_vocab #(parameter int N = {len(entries)}) (
    input  logic [9:0]  addr,
    output logic [23:0] key,
    output logic [9:0]  id
);
    logic [39:0] rom [0:N-1];
    initial $readmemh("build/gen/ner_vocab.hex", rom);
    assign key = rom[addr][39:16];
    assign id  = rom[addr][9:0];
endmodule
"""
    (out / "l2_ner_vocab.sv").write_text(vocab, encoding="utf-8")
    print(f"ner rom: emb {len(w['emb_w'])} B, conv1 {len(w['conv1_w'])} B, conv2 {len(w['conv2_w'])} B, "
          f"head {len(w['head_w'])} B, vocab {len(entries)} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())