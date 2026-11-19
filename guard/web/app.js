// ARES GUARD · 浏览器端演示（Web Serial）
// 协议：发一段 UTF-8 + LF；板子回显脱敏正文 + CRLF + "[guard] n=..." 审计行。
// 板子对 >64 字节的帧会提前收帧，所以按标点分帧、逐帧发送（和 tools/serial_host.py 一致）。
"use strict";

const $ = (id) => document.getElementById(id);
const FRAME_LIMIT = 56;
const SENT_END = "。！？；!?;\n";
const SOFT_END = "，,、：:）)";
const AUDIT_KEYS = ["id18","id15","mobile","bank","email","ipv4","uscc","plate","name","addr","kw","kwm","l2","l2m"];

let port = null, reader = null, writer = null, connected = false;
let simMode = false;
let simulating = false;

/* ---------------- demos ---------------- */
function renderDemos() {
  const ul = $("demos");
  ul.innerHTML = "";
  (window.DEMOS || []).forEach((d) => {
    const li = document.createElement("li");
    li.innerHTML = "<b>" + d.id + "</b>" + d.label;
    li.title = d.text;
    li.onclick = () => {
      $("input").value = d.text;
      updateMeta();
      $("input").focus();
    };
    ul.appendChild(li);
  });
}
function updateMeta() {
  const n = new TextEncoder().encode($("input").value).length;
  $("inMeta").textContent = n + " B";
}

/* ---------------- 分帧 ---------------- */
function splitFrames(text, limit = FRAME_LIMIT) {
  const chars = Array.from(text.replace(/[\r\n]+$/,""));
  const pieces = [];
  let cur = "";
  const bytes = (s) => new TextEncoder().encode(s).length;
  for (const ch of chars) {
    cur += ch;
    if (SENT_END.includes(ch) && bytes(cur) >= limit / 2) { pieces.push(cur); cur = ""; }
  }
  if (cur) pieces.push(cur);
  const out = [];
  for (const p of pieces) {
    if (bytes(p) <= limit) { out.push(p); continue; }
    let c = "";
    for (const ch of p) {
      if (bytes(c + ch) > limit) { if (c) out.push(c); c = ch; }
      else c += ch;
      if (SOFT_END.includes(ch) && bytes(c) >= limit / 2) { out.push(c); c = ""; }
    }
    if (c) out.push(c);
  }
  return out;
}

/* ---------------- 串口 ---------------- */
async function connect() {
  if (!("serial" in navigator)) {
    toast("这个浏览器不支持 Web Serial，请用 Chrome / Edge 打开本页");
    return;
  }
  try {
    port = await navigator.serial.requestPort();
    await port.open({ baudRate: 115200 });
    writer = port.writable.getWriter();
    reader = port.readable.getReader();
    connected = true; simMode = false;
    setConn(true);
    pump();
  } catch (e) {
    toast("打开串口失败：" + e.message);
  }
}

function setConn(on, busy = false) {
  const dot = $("conn");
  dot.className = "dot " + (on ? (busy ? "busy" : "on") : "off");
  $("connText").textContent = on ? (busy ? "处理中" : "已连接") : (simMode ? "模拟模式" : "未连接");
  $("btnConnect").textContent = on ? "断开" : "连接串口";
}

let rxBuf = [];
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

function decode(buf) { return new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(buf)); }

/* 等一帧：正文 + 审计行 */
async function readFrame(timeoutMs = 8000) {
  const t0 = performance.now();
  let quietSince = 0;
  while (performance.now() - t0 < timeoutMs) {
    const text = decode(rxBuf);
    const idx = text.indexOf("[guard] ");
    if (idx >= 0) {
      const lineEnd = text.indexOf("\n", idx);
      if (lineEnd > 0) {
        const bodyRaw = text.slice(0, idx).replace(/\r?\n$/, "");
        const line = text.slice(idx, lineEnd + 1);
        rxBuf = [];
        return { body: bodyRaw, line: line.trim(), ms: Math.round(performance.now() - t0) };
      }
    }
    if (rxBuf.length && decode(rxBuf).length > 0) quietSince = performance.now();
    if (quietSince && performance.now() - quietSince > 600 && rxBuf.length) {
      const body = decode(rxBuf).replace(/\r?\n$/, "");
      rxBuf = [];
      return { body, line: "", ms: Math.round(performance.now() - t0) };
    }
    await sleep(20);
  }
  const body = decode(rxBuf); rxBuf = [];
  return { body, line: "", ms: timeoutMs, timeout: true };
}

function parseAudit(line) {
  const o = {};
  const m = line.match(/n=(\d+)/); if (m) o.n = +m[1];
  for (const k of AUDIT_KEYS) {
    const r = new RegExp(k + "=(\\d+)").exec(line);
    if (r) o[k] = +r[1];
  }
  return o;
}

/* ---------------- 主流程 ---------------- */
async function send() {
  const raw = $("input").value.trim();
  if (!raw) return;

  $("btnSend").disabled = true;
  $("out").textContent = "";
  $("audit").innerHTML = "";
  setThinking(true);

  if (simMode) {
    const demo = findDemo(raw) || {};
    const ms = 420 + Math.min(1200, raw.length * 7);
    await sleep(ms);
    reveal(raw, demo.mask || raw, ms);
    renderAudit(demo.audit || {});
    $("lat").textContent = ms + " ms";
    $("stats").textContent = "模拟 · 1 帧 · " + ms + " ms · " + (demo.audit ? demo.audit.n : 0) + " 段命中";
    setThinking(false);
    $("btnSend").disabled = false;
    return;
  }

  if (!connected) {
    toast("先连接串口，或点“模拟模式”");
    setThinking(false);
    $("btnSend").disabled = false;
    return;
  }

  const frames = splitFrames(raw);
  const sums = {};
  let total = 0, spans = 0;
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
  $("lat").textContent = total + " ms";
  $("stats").textContent = frames.length + " 帧 · " + total + " ms · " + spans + " 段命中";
  setThinking(false);
  $("btnSend").disabled = false;
}

function findDemo(text) {
  const t = text.replace(/\s+/g, "");
  return (window.DEMOS || []).find((d) => d.text.replace(/\s+/g, "") === t ||
                                          d.text.startsWith(text.slice(0, 8)));
}

/* 逐字揭示，星号高亮 */
function reveal(src, masked, ms) {
  const el = $("out");
  const frag = document.createDocumentFragment();
  let i = 0;
  const chars = Array.from(masked);
  const timer = setInterval(() => {
    if (i >= chars.length) { clearInterval(timer); return; }
    for (let k = 0; k < 3 && i < chars.length; k++, i++) {
      const c = chars[i];
      const s = document.createElement("span");
      s.textContent = c;
      s.className = c === "*" || c === "＊" ? "star reveal" : "reveal";
      frag.appendChild(s);
    }
    el.appendChild(frag);
    el.scrollTop = el.scrollHeight;
  }, Math.max(4, Math.min(14, 400 / Math.max(1, chars.length))));
}

function renderAudit(sums) {
  const el = $("audit");
  el.innerHTML = "";
  const show = [["id18","身份证18"],["id15","身份证15"],["mobile","手机"],["bank","银行卡"],
                ["email","邮箱"],["name","人名"],["addr","地址"],["l2","L2语义"],["kw","关键词"]];
  for (const [k, label] of show) {
    const v = sums[k] || 0;
    const d = document.createElement("span");
    d.className = "chiplet" + (v ? "" : " zero");
    d.innerHTML = label + " <b>" + v + "</b>";
    el.appendChild(d);
  }
}

function setThinking(on) {
  $("stage").classList.toggle("thinking", on);
  $("conn").className = "dot " + (on ? "busy" : (connected ? "on" : "off"));
}

let toastT = 0;
function toast(msg) {
  clearTimeout(toastT);
  let el = $("toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "toast";
    el.style.cssText = "position:fixed;left:50%;bottom:28px;transform:translateX(-50%);" +
      "background:rgba(255,93,122,.14);border:1px solid rgba(255,93,122,.5);color:#ffd7de;" +
      "padding:10px 16px;border-radius:10px;font-size:13px;z-index:9;backdrop-filter:blur(6px)";
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.style.opacity = "1";
  toastT = setTimeout(() => { el.style.opacity = "0"; }, 3600);
}

/* ---------------- 事件 ---------------- */
$("btnConnect").onclick = async () => {
  if (connected) {
    try { connected = false; await reader?.cancel(); await port?.close(); } catch (e) {}
    connected = false; setConn(false);
    return;
  }
  await connect();
};
$("btnSend").onclick = send;
$("btnClear").onclick = () => { $("input").value = ""; updateMeta(); $("out").textContent = ""; $("audit").innerHTML = ""; };
$("input").addEventListener("input", updateMeta);
$("btnSim").onclick = () => {
  simMode = true; simulating = true; connected = false;
  setConn(false); $("connText").textContent = "模拟模式";
  toast("模拟模式：不连板子，用预置结果演示动画");
};
document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") send();
});

renderDemos();
updateMeta();