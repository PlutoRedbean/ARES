#!/usr/bin/env python3
"""guard 本地工作台：输入一段文本，实时（~5ms，全 RTL）看到脱敏结果。

    ./run.sh serve            # http://127.0.0.1:8766
    ./run.sh serve --port 9000
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from host.golden.keywords import KEYWORDS, find_keywords  # noqa: E402
from host.golden.pipeline import highlights, render_html, run_golden, run_rtl_mask  # noqa: E402

SAMPLE = """王经理您好：

订单联系人：李娜，手机 138 0013 8000，备用邮箱 lina@example.com。
身份证号 11010519491231002X，银行卡 4111 1111 1111 1111，开户行在北京市朝阳区建国路 88 号。
公司统一社会信用代码 91350100M000100Y43，服务器 10.0.0.21，车牌 京A12345。

请勿把密码和账号通过微信发给客户，谢谢。
"""


PAGE = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>guard · PII 脱敏工作台</title>
<style>
:root { --bg:#0f1216; --panel:#161b22; --line:#242c37; --fg:#e6edf3; --dim:#8b949e;
        --hit:#e5484d33; --hitline:#e5484d; --ok:#3fb950; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
       font:14px/1.6 -apple-system,"Segoe UI","Noto Sans CJK SC",sans-serif; }
header { display:flex; align-items:center; gap:14px; padding:14px 20px;
         border-bottom:1px solid var(--line); background:var(--panel); }
header h1 { font-size:15px; margin:0; font-weight:600; letter-spacing:.3px; }
header .sub { color:var(--dim); font-size:12px; }
header .right { margin-left:auto; display:flex; align-items:center; gap:12px; }
button, select { background:#21262d; color:var(--fg); border:1px solid var(--line);
                 border-radius:8px; padding:6px 12px; font-size:13px; cursor:pointer; }
button:hover { border-color:#3b4657; }
main { display:grid; grid-template-columns:1fr 1fr; gap:14px; padding:14px 20px; }
@media (max-width:900px){ main { grid-template-columns:1fr; } }
.panel { background:var(--panel); border:1px solid var(--line); border-radius:10px; overflow:hidden;
         display:flex; flex-direction:column; min-height:340px; }
.panel h2 { font-size:12px; text-transform:uppercase; letter-spacing:.8px; color:var(--dim);
            margin:0; padding:10px 14px; border-bottom:1px solid var(--line); font-weight:600; }
textarea { flex:1; width:100%; resize:none; border:0; outline:0; background:transparent;
           color:var(--fg); padding:14px; font:13px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace; }
pre#out { flex:1; margin:0; padding:14px; white-space:pre-wrap; word-break:break-word;
          font:13px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace; overflow:auto; }
mark.hit { background:var(--hit); border-bottom:2px solid var(--hitline); border-radius:3px;
           color:#ffd7d9; padding:0 1px; }
footer { padding:0 20px 20px; display:grid; grid-template-columns:1fr 1fr; gap:14px; }
@media (max-width:900px){ footer { grid-template-columns:1fr; } }
.card { background:var(--panel); border:1px solid var(--line); border-radius:10px; overflow:hidden; }
.card h2 { font-size:12px; text-transform:uppercase; letter-spacing:.8px; color:var(--dim);
           margin:0; padding:10px 14px; border-bottom:1px solid var(--line); font-weight:600; }
table { width:100%; border-collapse:collapse; font-size:12.5px; }
th, td { text-align:left; padding:6px 12px; border-bottom:1px solid var(--line); white-space:nowrap; }
th { color:var(--dim); font-weight:500; }
td.mono { font-family:ui-monospace,Menlo,monospace; }
.chips { padding:10px 14px; display:flex; flex-wrap:wrap; gap:8px; min-height:46px; }
.chip { border:1px solid var(--line); background:#1b222b; color:#c9d1d9; border-radius:999px;
        padding:2px 10px; font-size:12px; }
#badge { font-size:12px; color:var(--dim); font-family:ui-monospace,Menlo,monospace; }
#badge b { color:var(--ok); font-weight:600; }
.muted { color:var(--dim); padding:14px; }
</style></head><body>
<header>
  <h1>guard · PII 脱敏工作台</h1>
  <span class="sub">L1 规则层 · 全 RTL（Verilator）</span>
  <div class="right">
    <select id="policy">
      <option value="mask">mask（全 RTL）</option>
      <option value="token">token（金标渲染）</option>
    </select>
    <span id="badge">…</span>
  </div>
</header>

<main>
  <section class="panel">
    <h2>输入（边打边脱敏）</h2>
    <textarea id="in" spellcheck="false" placeholder="在这里输入或粘贴一段文本…"></textarea>
  </section>
  <section class="panel">
    <h2>脱敏输出</h2>
    <pre id="out"></pre>
  </section>
</main>

<footer>
  <section class="card">
    <h2>审计</h2>
    <table id="audit"><thead><tr><th>#</th><th>类型</th><th>位置</th><th>规则</th><th>动作</th><th>替换</th></tr></thead><tbody></tbody></table>
  </section>
  <section class="card">
    <h2>关键词提示</h2>
    <div class="chips" id="kw"></div>
  </section>
</footer>

<script>
const $ = (s) => document.querySelector(s);
let timer = null, seq = 0;

async function run() {
  const text = $("#in").value;
  const my = ++seq;
  const t0 = performance.now();
  const r = await fetch("/api/redact", {
    method: "POST", headers: {"content-type": "application/json"},
    body: JSON.stringify({text, policy: $("#policy").value})
  });
  const j = await r.json();
  if (my !== seq) return;                       // 丢弃过期响应
  $("#out").innerHTML = j.html || "";
  const tb = $("#audit tbody"); tb.innerHTML = "";
  for (const a of j.audits) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td class="mono">${a.index}</td><td>${a.type}</td>
      <td class="mono">${a.start}+${a.length}</td><td class="mono">${a.rule}</td>
      <td>${a.action}</td><td class="mono">${escapeHtml(a.replacement)}</td>`;
    tb.appendChild(tr);
  }
  if (!j.audits.length) tb.innerHTML = '<tr><td colspan="6" class="muted">未发现 PII</td></tr>';
  $("#kw").innerHTML = j.keywords.length
    ? j.keywords.map(k => `<span class="chip">${k}</span>`).join("")
    : '<span class="muted">无</span>';
  $("#badge").innerHTML = `<b>${j.mode}</b> · ${j.ms.toFixed(1)} ms · ${j.bytes} B · ${j.audits.length} hits`;
}

function escapeHtml(s){ return s.replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

$("#in").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(run, 120); });
$("#policy").addEventListener("change", run);
$("#in").value = __SAMPLE__;
run();
</script></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # 安静点
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path in ("/", "/index.html"):
            page = PAGE.replace("__SAMPLE__", json.dumps(SAMPLE))
            self._send(200, page.encode("utf-8"), "text/html; charset=utf-8")
        elif self.path == "/health":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
        else:
            self._send(404, b"not found\n", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        if self.path != "/api/redact":
            self._send(404, b"not found\n", "text/plain; charset=utf-8")
            return
        n = int(self.headers.get("content-length", "0"))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
            text = str(req.get("text", ""))
            policy = req.get("policy", "mask")
            if policy not in ("mask", "token"):
                raise ValueError("policy")
        except Exception as e:  # noqa: BLE001
            self._send(400, json.dumps({"error": str(e)}).encode(), "application/json")
            return

        data = text.encode("utf-8")
        t0 = time.perf_counter()
        try:
            if policy == "token":
                out, audits = run_golden(data, "token")
                mode = "golden-token"
            else:
                try:
                    out, audits = run_rtl_mask(data)
                    mode = "rtl-mask"
                except FileNotFoundError:
                    # 没建 Verilator harness（比如在 Windows 上看网页）时退回金标
                    # mask：判定同一套规则，只是跑在 Python 里。页面上会写明 mode。
                    out, audits = run_golden(data, "mask")
                    mode = "golden-mask"
        except FileNotFoundError:
            self._send(500, b'{"error":"Vredact not built; run make redact-harness"}',
                       "application/json")
            return
        ms = (time.perf_counter() - t0) * 1000

        hl = highlights(data, audits)
        kws = []
        for h in find_keywords(data):
            name = KEYWORDS[h.kid]
            if name not in kws:
                kws.append(name)

        resp = {
            "redacted": out.decode("utf-8", "replace"),
            "html": render_html(out, hl),
            "audits": [a.to_json() for a in audits],
            "keywords": kws,
            "mode": mode,
            "bytes": len(data),
            "out_bytes": len(out),
            "ms": round(ms, 2),
        }
        self._send(200, json.dumps(resp, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="guard 本地工作台")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args(argv)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}"
    print(f"guard workbench: {url}  (Ctrl-C 退出)")
    print("提示：输入框里直接打字/粘贴，右侧 ~5ms 出结果（全 RTL）")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())