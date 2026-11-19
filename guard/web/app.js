// ARES GUARD · 浏览器端演示（Web Serial）
// 协议：发一段 UTF-8 + LF；板子回显脱敏正文 + CRLF + "[guard] n=..." 审计行。
// 板子对 >64 字节的帧会提前收帧，所以按标点分帧、逐帧发送（与 tools/serial_host.py 一致）。
"use strict";

const $ = (id) => document.getElementById(id);
const FRAME_LIMIT = 56;
const SENT_END = "。！？；!?;\n";
const SOFT_END = "，,、：:）)";
const AUDIT_KEYS = ["id18","id15","mobile","bank","email","ipv4","uscc","plate","name","addr","kw","kwm","l2","l2m"];
const STAGES = ["UART RX", "L1 规则", "miniTensor", "NER", "merge", "mask", "UART TX"];

let port = null, reader = null, writer = null, connected = false, simMode = false;
let rxBuf = [];
let stageTimer = 0, stageIdx = 0;

/* ---------------- 样例 ---------------- */
function renderDemos() {
  const ul = $("demos");
  ul.innerHTML = "";
  (window.DEMOS || []).forEach((d) => {
    const li = document.createElement("li");
    li.innerHTML = "<b>" + d.id + "</b><span>" + d.label + "</span>";
    li.title = d.text;
    li.onclick = () => { $("input").value = d.text; updateMeta(); $("input").focus(); };
    ul.appendChild(li);
  });
}
function updateMeta() {
  const n = new TextEncoder().encode($("input").value).length;
  $("inMeta").textContent = n + " B";
  const bar = $("inBar");
  const pct = Math.min(100, (n / 400) * 100);
  bar.style.width = pct + "%";
  bar.classList.toggle("warn", n > FRAME_LIMIT);
}

/* ---------------- 分帧 ---------------- */
const nbytes = (s) => new TextEncoder().encode(s).length;

function splitFrames(text, limit = FRAME_LIMIT) {
  const chars = Array.from(text.replace(/[\r\n]+$/, ""));
  const pieces = [];
  let cur = "";
  for (const ch of chars) {
    cur += ch;
    if (SENT_END.includes(ch) && nbytes(cur) >= limit / 2) { pieces.push(cur); cur = ""; }
  }
  if (cur) pieces.push(cur);
  const out = [];
  for (const p of pieces) {
    if (nbytes(p) <= limit) { out.push(p); continue; }
    let c = "";
    for (const ch of p) {
      if (nbytes(c + ch) > limit) { if (c) out.push(c); c = ch; }
      else c += ch;
      if (SOFT_END.includes(ch) && nbytes(c) >= limit / 2) { out.push(c); c = ""; }
    }
    if (c) out.push(c);
  }
  return out;
}

/* ---------------- 串口 ---------------- */
async function connect() {
  if (!("serial" in navigator)) { toast("这个浏览器不支持 Web Serial，请用 Chrome / Edge"); return; }
  try {
    port = await navigator.serial.requestPort();
    await port.open({ baudRate: 115200 });
    writer = port.writable.getWriter();
    reader = port.readable.getReader();
    connected = true; simMode = false;
    setLed("on"); $("connText").textContent = "已连接";
    $("btnConnect").textContent = "断开";
    pump();
  } catch (e) { toast("打开串口失败：" + e.message); }
}

function setLed(cls) {
  $("led").className = "led " + (cls || "");
}

async function pump() {
  try {
    while (connected && reader) {
      const { value, done } = await reader.read();
      if (done) break;
      for (const b of value) rxBuf.push(b);
    }
  } catch (e) { /* 断开时正常抛 */ }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const decode = (buf) => new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(buf));

async function readFrame(timeoutMs = 9000) {
  const t0 = performance.now();
  let last = 0;
  while (performance.now() - t0 < timeoutMs) {
    const text = decode(rxBuf);
    const idx = text.indexOf("[guard] ");
    if (idx >= 0) {
      const lineEnd = text.indexOf("\n", idx);
      if (lineEnd > 0) {
        const body = text.slice(0, idx).replace(/\r?\n$/, "");
        const line = text.slice(idx, lineEnd).trim();
        rxBuf = [];
        return { body, line, ms: Math.round(performance.now() - t0) };
      }
    }
    if (rxBuf.length) last = performance.now();
    else if (last && performance.now() - last > 700) {
      const body = decode(rxBuf).replace(/\r?\n$/, "");
      rxBuf = []; last = 0;
      return { body, line: "", ms: Math.round(performance.now() - t0) };
    }
    await sleep(18);
  }
  const body = decode(rxBuf); rxBuf = [];
  return { body, line: "", ms: timeoutMs, timeout: true };
}

function parseAudit(line) {
  const o = {};
  for (const k of AUDIT_KEYS) {
    const r = new RegExp(k + "=(\\d+)").exec(line);
    if (r) o[k] = +r[1];
  }
  const m = /n=(\d+)/.exec(line);
  if (m) o.n = +m[1];
  return o;
}

/* ---------------- 动画：板卡 / 流水线 ---------------- */
function setThinking(on) {
  $("board").classList.toggle("thinking", on);
  $("boardState").textContent = on ? "推理中" : (connected ? "已连接" : (simMode ? "模拟" : "待机"));
  setLed(on ? "busy" : (connected ? "on" : ""));
  ["blk-ares", "blk-mt", "blk-ner", "blk-l1"].forEach((id) => $(id).classList.remove("active"));
  document.querySelectorAll(".stage-chip").forEach((c) => c.classList.remove("on"));
  clearInterval(stageTimer);
  if (!on) { stageIdx = 0; return; }
  stageIdx = 0;
  stageTimer = setInterval(() => {
    const chips = document.querySelectorAll(".stage-chip");
    chips.forEach((c, i) => c.classList.toggle("on", i === stageIdx % chips.length));
    const s = stageIdx % 7;
    $("blk-ares").classList.toggle("active", s === 1 || s === 2);
    $("blk-l1").classList.toggle("active", s === 1);
    $("blk-mt").classList.toggle("active", s === 2);
    $("blk-ner").classList.toggle("active", s === 3);
    stageIdx++;
  }, 190);
}

/* ---------------- 渲染 ---------------- */
function reveal(src, masked, ms) {
  const el = $("out");
  const chars = Array.from(masked);
  let i = 0;
  const step = Math.max(3, Math.min(18, Math.round(500 / Math.max(1, chars.length))));
  const timer = setInterval(() => {
    if (i >= chars.length) { clearInterval(timer); return; }
    const frag = document.createDocumentFragment();
    for (let k = 0; k < step && i < chars.length; k++, i++) {
      const c = chars[i];
      const s = document.createElement("span");
      s.textContent = c;
      if (c === "*") s.className = "star reveal";
      else if (c === "＊") { s.textContent = "*"; s.className = "star reveal"; }
      else s.className = "reveal";
      frag.appendChild(s);
    }
    el.appendChild(frag);
    el.scrollTop = el.scrollHeight;
    $("outCount").textContent = i + " / " + chars.length;
  }, 16);
}

const SHOW = [["id18","身份证18"],["id15","身份证15"],["mobile","手机"],["bank","银行卡"],
              ["email","邮箱"],["name","人名"],["addr","地址"],["l2","L2"],["kw","关键词"]];

function renderAudit(sums) {
  const el = $("audit");
  el.innerHTML = "";
  for (const [k, label] of SHOW) {
    const v = sums[k] || 0;
    const d = document.createElement("span");
    d.className = "chiplet" + (v ? " hit" : " zero");
    d.innerHTML = label + " <b>" + v + "</b>";
    el.appendChild(d);
  }
}

/* ---------------- 主流程 ---------------- */
function findDemo(text) {
  const norm = (s) => s.replace(/\s+/g, "");
  return (window.DEMOS || []).find((d) => norm(d.text) === norm(text));
}

async function send() {
  const raw = $("input").value.trim();
  if (!raw) return;
  $("btnSend").disabled = true;
  $("out").textContent = "";
  $("outCount").textContent = "";
  $("audit").innerHTML = "";
  $("lat").textContent = "—";
  $("rate").textContent = "—";
  setThinking(true);

  if (simMode) {
    const demo = findDemo(raw);
    const ms = 480 + Math.min(1400, nbytes(raw) * 6);
    const t0 = performance.now();
    await sleep(ms);
    reveal(raw, (demo && demo.mask) || raw, ms);
    renderAudit((demo && demo.audit) || {});
    const dt = Math.round(performance.now() - t0);
    $("lat").textContent = dt + " ms";
    $("rate").textContent = (nbytes(raw) / (dt / 1000) / 1024).toFixed(1) + " KB/s";
    setThinking(false);
    $("btnSend").disabled = false;
    return;
  }

  if (!connected) {
    toast("先连接串口，或点“模拟模式”");
    setThinking(false); $("btnSend").disabled = false;
    return;
  }

  const frames = splitFrames(raw);
  const sums = {};
  let total = 0, spans = 0;
  const t0 = performance.now();
  for (const piece of frames) {
    await writer.write(new TextEncoder().encode(piece + "\n"));
    const r = await readFrame();
    total += r.ms;
    const a = parseAudit(r.line);
    spans += a.n || 0;
    for (const k of AUDIT_KEYS) sums[k] = (sums[k] || 0) + (a[k] || 0);
    reveal(piece, r.body, r.ms);
  }
  renderAudit(sums);
  const dt = Math.round(performance.now() - t0);
  $("lat").textContent = dt + " ms";
  $("rate").textContent = (nbytes(raw) / (dt / 1000) / 1024).toFixed(1) + " KB/s";
  setThinking(false);
  $("btnSend").disabled = false;
}

let toastT = 0;
function toast(msg) {
  clearTimeout(toastT);
  let el = $("toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "toast";
    el.style.cssText = "position:fixed;left:50%;bottom:34px;transform:translateX(-50%);" +
      "background:rgba(255,93,154,.14);border:1px solid rgba(255,93,154,.5);color:#ffd9e6;" +
      "padding:11px 18px;border-radius:12px;font-size:13px;z-index:20;backdrop-filter:blur(8px);" +
      "transition:opacity .3s;box-shadow:0 10px 30px rgba(0,0,0,.4)";
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.style.opacity = "1";
  toastT = setTimeout(() => { el.style.opacity = "0"; }, 3800);
}

/* ---------------- 事件 ---------------- */
$("btnConnect").onclick = async () => {
  if (connected) {
    try { connected = false; await reader?.cancel(); await port?.close(); } catch (e) {}
    connected = false; setLed(""); $("connText").textContent = "未连接";
    $("btnConnect").textContent = "连接串口";
    return;
  }
  await connect();
};
$("btnSend").onclick = send;
$("btnClear").onclick = () => {
  $("input").value = ""; updateMeta();
  $("out").textContent = ""; $("audit").innerHTML = ""; $("outCount").textContent = "";
};
$("input").addEventListener("input", updateMeta);
$("btnSim").onclick = () => {
  simMode = true; connected = false;
  setLed(""); $("connText").textContent = "模拟模式";
  $("boardState").textContent = "模拟";
  toast("模拟模式：不连板子，用板上实测回显演示动画");
};
document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") send();
});

renderDemos();
updateMeta();