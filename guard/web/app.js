/* ARES GUARD · control surface
 *
 * 数据来源有三条：
 *   1. 板上实测回放 —— demos.js（tools/gen_web_demos.py 生成），5 条样例的真板回显；
 *   2. 本地规则预览 —— engine.js（L1 + 词典实体），任意文本、不需要板子；
 *   3. 串口实时 —— Web Serial，按标点分帧、逐帧等回读、汇总审计行。
 *
 * 面板上所有数字都来自这三条路径，没有随机生成的“气氛数据”。
 */
"use strict";

(() => {
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  const DATA = window.GUARD_DATA || {};
  const DEMOS = Array.isArray(window.DEMOS) ? window.DEMOS : [];
  const ENGINE = window.GuardEngine;

  const enc = new TextEncoder();
  const dec = new TextDecoder("utf-8", { fatal: false });
  const TYPES = ["id18", "id15", "mobile", "bank", "email", "ipv4", "uscc", "plate", "name", "addr"];
  const TYPE_LABEL = DATA.typeLabels || {};
  const TYPE_TONE = DATA.typeTones || {};
  const VIEWS = ["workbench", "link", "rules", "system"];
  const MAX_FRAMES = 8;

  const SOURCE = {
    demo: { label: "板上实测", short: "回放", cls: "is-ok", dot: "demo" },
    local: { label: "本地规则", short: "本地", cls: "is-local", dot: "local" },
    live: { label: "串口实时", short: "串口", cls: "is-live", dot: "live" },
  };

  const state = {
    view: "workbench",
    mode: "replay",
    running: false,
    abortRun: false,
    demoKey: null,
    rawTab: "masked",
    result: null,
    frames: [],
    selectedFrame: 0,
    history: [],
    monitor: [],
    log: [],
    serial: {
      supported: false,
      port: null,
      reader: null,
      writer: null,
      reading: false,
      buf: new Uint8Array(0),
      baud: 115200,
      tx: 0,
      rx: 0,
      frames: 0,
      lastLatency: null,
      info: null,
    },
    connected: false,
    connecting: false,
    portLabel: "—",
  };

  let pipelineTimer = null;
  let pipelineReset = null;
  let paletteItems = [];
  let paletteIndex = 0;
  let paletteFiltered = [];
  let lastFocus = null;

  /* ── helpers ───────────────────────────────────────────────────────────── */
  const esc = (s) =>
    String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const fmt = (n) => Number(n || 0).toLocaleString("en-US");
  const pad2 = (n) => String(n).padStart(2, "0");
  const pad3 = (n) => String(Math.max(0, Math.min(255, Math.round(Number(n) || 0)))).padStart(3, "0");
  const nbytes = (s) => enc.encode(s).length;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const round1 = (n) => Math.round(n * 10) / 10;
  const normalizeText = (t) => String(t == null ? "" : t).replace(/[\r\n]+$/, "");
  const countTotal = (counts) => TYPES.reduce((a, t) => a + (counts[t] || 0), 0);
  const nowTime = () => {
    const d = new Date();
    return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
  };
  const previewText = (t, n = 26) => {
    const s = String(t || "").replace(/\s+/g, " ").trim();
    return s.length > n ? s.slice(0, n) + "…" : s || "(空)";
  };

  function findDemo(text) {
    const t = String(text || "").trim();
    if (!t) return null;
    return DEMOS.find((d) => String(d.text || "").trim() === t) || null;
  }

  function demoLabel(key) {
    const d = DEMOS.find((x) => x.key === key);
    return d ? d.label : "板上样例";
  }

  function typeTone(type) {
    return TYPE_TONE[type] || "slate";
  }

  function typeLabel(type) {
    return TYPE_LABEL[type] || type;
  }

  function buildAuditLine({ counts, n, kw, kwm, l2, l2m, mode, ovf }) {
    const pairs = [
      ["n", n || 0],
      ...TYPES.map((t) => [t, counts[t] || 0]),
      ["kw", kw || 0],
      ["kwm", kwm || 0],
      ["l2", l2 || 0],
      ["l2m", l2m || 0],
      ["ovf", ovf ? 1 : 0],
    ];
    const body = pairs.map(([k, v]) => `${k}=${pad3(v)}`).join(" ");
    return `[guard] ${body} mode=${(Number(mode) || 0) % 10}`;
  }

  /* ── static render ─────────────────────────────────────────────────────── */
  function renderSamples() {
    const rail = $("#sampleRail");
    if (!rail) return;
    rail.innerHTML = DEMOS.map((d) => {
      const meta = (DATA.demoMeta || {})[d.key] || {};
      const n = d.audit && d.audit.n != null ? d.audit.n : countTotal(d.audit || {});
      const tags = (meta.tags || [])
        .map((t) => `<i class="tone-${typeTone(t)}"></i>`)
        .join("");
      const known = meta.known
        ? `<i class="tone-warn" title="${esc(meta.known)}"></i>`
        : "";
      return `<button class="sample" type="button" data-key="${esc(d.key)}" title="${esc(d.text)}${meta.known ? "&#10;" + esc(meta.known) : ""}">
        <span class="sample-id">${esc(d.id)}</span>
        <span class="sample-main"><b>${esc(d.label)}</b><em>${esc(meta.group || "样例")} · ${n} 处</em></span>
        <span class="sample-tags">${tags}${known}</span>
      </button>`;
    }).join("");
  }

  function updateSampleActive() {
    const active = state.demoKey;
    $$("#sampleRail .sample").forEach((el) => {
      el.classList.toggle("is-active", !!active && el.dataset.key === active);
    });
  }

  function renderStats() {
    const host = $("#stats");
    if (!host) return;
    const text = normalizeText($("#input").value);
    const plan = ENGINE ? ENGINE.splitFrames(text) : [];
    const bytes = nbytes(text);
    const chars = Array.from(text).length;
    const lines = text ? text.split(/\r?\n/).length : 1;
    const maxFrame = plan.reduce((m, f) => Math.max(m, f.bytes), 0);
    const current = state.result && state.result.text === text;
    const result = current ? state.result : null;
    const hits = result ? result.n : null;
    const counts = result ? result.counts : {};
    const breakdown = TYPES.filter((t) => counts[t]).map((t) => `${typeLabel(t)} ${counts[t]}`).join(" · ");
    const src = result ? SOURCE[result.source] : null;

    const cards = [
      {
        tone: "mint",
        kicker: "输入",
        en: "BYTES",
        value: fmt(bytes),
        unit: "B",
        sub: `${fmt(chars)} 字符 · ${fmt(lines)} 行`,
      },
      {
        tone: "blue",
        kicker: "分帧",
        en: "FRAMES",
        value: fmt(plan.length),
        unit: "帧",
        sub: plan.length ? `最大 ${maxFrame} B · LF 边界` : "等待输入",
      },
      {
        tone: "violet",
        kicker: "命中",
        en: "SPANS",
        value: hits == null ? "—" : fmt(hits),
        unit: hits == null ? "" : "spans",
        sub: !result ? "等待判读" : hits ? breakdown : "未发现 PII",
      },
      {
        tone: "amber",
        kicker: "来源",
        en: "SOURCE",
        value: src ? src.short : "—",
        unit: "",
        sub: src ? (result.source === "demo" ? "板上实测回显" : result.source === "local" ? "不含 NER / L2" : `${state.serial.baud} 8N1`) : "等待运行",
      },
    ];

    host.innerHTML = cards
      .map(
        (c) => `<div class="stat-card" data-tone="${c.tone}">
          <div class="stat-kicker">${esc(c.kicker)} <em>${esc(c.en)}</em></div>
          <div class="stat-val"><b>${esc(c.value)}</b>${c.unit ? `<span>${esc(c.unit)}</span>` : ""}</div>
          <div class="stat-sub">${esc(c.sub)}</div>
        </div>`,
      )
      .join("");

    const bytesMeta = $("#byteMeta");
    if (bytesMeta) bytesMeta.textContent = fmt(bytes);
    const charMeta = $("#charMeta");
    if (charMeta) charMeta.textContent = fmt(chars);
    const lineMeta = $("#lineMeta");
    if (lineMeta) lineMeta.textContent = fmt(lines);
    const frameMeta = $("#frameMeta");
    if (frameMeta) frameMeta.textContent = fmt(plan.length);
    const runBtn = $("#btnRun");
    if (runBtn) runBtn.disabled = state.running || !text.trim();
  }

  function renderStrip() {
    const strip = $("#frameStrip");
    if (!strip) return;
    const text = normalizeText($("#input").value);
    const plan = ENGINE ? ENGINE.splitFrames(text) : [];
    const current = state.result && state.result.text === text;
    const frames = current ? state.frames : plan;
    const selected = state.selectedFrame;

    if (!frames.length) {
      strip.innerHTML = '<span class="strip-empty"></span>';
      const meta = $("#stripMeta");
      if (meta) meta.textContent = "LF 边界 · 超长按标点切";
      return;
    }

    const totalBytes = frames.reduce((a, f) => a + Math.max(1, f.bytes || 0), 0);
    strip.innerHTML = frames
      .map((f, i) => {
        const b = Math.max(1, f.bytes || 0);
        const pct = (b / totalBytes) * 100;
        const n = current && f.n != null ? f.n : 0;
        const classes = ["strip-frame"];
        if (n > 0) classes.push("is-hits");
        if (i === selected && current) classes.push("is-selected");
        const title = `F${pad2(i + 1)} · ${f.bytes || 0} B${n ? ` · ${n} 命中` : ""}${f.text ? " · " + previewText(f.text, 18) : " · 空帧"}`;
        return `<button class="${classes.join(" ")}" type="button" data-frame="${i}" style="flex:${b} 1 0" title="${esc(title)}">
          ${pct > 5 || frames.length <= 12 ? `<span>${i + 1}</span>` : ""}
        </button>`;
      })
      .join("");

    const maxFrame = frames.reduce((m, f) => Math.max(m, f.bytes || 0), 0);
    const hits = current ? state.result.n : null;
    const meta = $("#stripMeta");
    if (meta) {
      meta.textContent = `${frames.length} 帧 · 最大 ${maxFrame} B${hits != null ? ` · ${hits} 命中` : ""}`;
    }
  }

  function renderLayers() {
    const host = $("#layerGrid");
    if (!host) return;
    host.innerHTML = (DATA.layers || [])
      .map(
        (l) => `<article class="card layer-card tone-${esc(l.tone)}">
          <div class="layer-top">
            <span class="layer-index">${esc(l.index)}</span>
            <span class="layer-ico"><svg class="ico"><use href="#i-${esc(l.icon)}"></use></svg></span>
          </div>
          <h3>${esc(l.name)}</h3>
          <div class="layer-kicker">${esc(l.kicker)}</div>
          <p class="layer-desc">${esc(l.desc)}</p>
          <div class="layer-stats">${(l.stats || [])
            .map(([v, s]) => `<div><b>${esc(v)}</b><span>${esc(s)}</span></div>`)
            .join("")}</div>
        </article>`,
      )
      .join("");
  }

  function renderRules() {
    const tbody = $("#ruleRows");
    if (!tbody) return;
    tbody.innerHTML = (DATA.detectors || [])
      .map((d) => {
        const action = d.demo
          ? `<button class="row-btn" type="button" data-load="demo" data-value="${esc(d.demo)}">载入样例</button>`
          : d.sample
            ? `<button class="row-btn" type="button" data-load="sample" data-value="${esc(d.sample)}">试一下</button>`
            : `<span class="frame-count">—</span>`;
        const example = d.example ? `<code>${esc(d.example)}</code>` : "—";
        return `<tr title="${esc(d.note || "")}">
          <td><span class="type-cell"><i class="type-dot tone-${esc(d.tone)}"></i><b>${esc(d.label)}</b></span></td>
          <td><code>${esc(d.rule)}</code></td>
          <td>${esc(d.check)}</td>
          <td class="mask-cell">${esc(d.mask)}</td>
          <td class="example-cell">${example}</td>
          <td class="ta-r">${action}</td>
        </tr>`;
      })
      .join("");
  }

  function renderPolicy() {
    const host = $("#policyList");
    if (!host) return;
    const items = [
      { label: "结构化 PII", rule: "保留后 4 位", from: "11010519491231002X", to: "**************002X" },
      { label: "人名", rule: "露姓氏", from: "周杰伦", to: "周＊＊" },
      { label: "地址", rule: "整段遮", from: "北京市朝阳区建国路88号", to: "整段遮" },
    ];
    host.innerHTML = items
      .map(
        (it) => `<div class="policy-item">
          <div class="policy-item-top"><b>${esc(it.label)}</b><span>${esc(it.rule)}</span></div>
          <div class="policy-pair">
            <span class="from">${esc(it.from)}</span>
            <svg class="ico"><use href="#i-arrow"></use></svg>
            <span class="to">${esc(it.to)}</span>
          </div>
        </div>`,
      )
      .join("");
  }

  function renderKeywords() {
    const host = $("#keywordGrid");
    if (!host) return;
    host.innerHTML = (DATA.keywords || [])
      .map(
        (k, i) => `<div class="keyword-chip"><i>${pad2(i)}</i><b>${esc(k)}</b><em>bit ${i}</em></div>`,
      )
      .join("");
  }

  function limitMarkup() {
    return (DATA.limits || [])
      .map(
        (l) => `<div class="limit-item" data-tone="${esc(l.tone || "info")}">
          <i class="limit-mark"></i>
          <div class="limit-copy"><b>${esc(l.title)}</b><span>${esc(l.detail)}</span></div>
        </div>`,
      )
      .join("");
  }

  function renderLimits() {
    const host = $("#limitList");
    if (host) host.innerHTML = limitMarkup();
  }

  function renderResources() {
    const host = $("#resourceList");
    if (!host || !DATA.resources) return;
    const r = DATA.resources;
    const rows = [
      ["LUT", `${fmt(r.lutUsed)} / ${fmt(r.lutTotal)}`, r.lutPct, "mint"],
      ["FF", fmt(r.ff), 2.4, "blue"],
      ["DRM36K", r.drm.toFixed ? r.drm.toFixed(1) : r.drm, 18.8, "violet"],
      ["APM", fmt(r.apm), 9.4, "amber"],
      ["PLL", fmt(r.pll), 12.5, ""],
    ];
    host.innerHTML = rows
      .map(
        ([k, v, w, tone]) => `<div class="res-row">
          <span>${esc(k)}</span>
          <span class="res-bar"><span class="${tone ? "is-" + tone : ""}" style="width:${Math.min(100, w)}%"></span></span>
          <b>${esc(v)}</b>
        </div>`,
      )
      .join("");
  }

  function renderVerification() {
    const host = $("#verifyList");
    if (!host) return;
    host.innerHTML = (DATA.verification || [])
      .map(
        (v) => `<div class="verify-row">
          <code class="verify-cmd" title="${esc(v.cmd)}">${esc(v.cmd)}</code>
          <div class="verify-detail"><b>${esc(v.note)}</b>${esc(v.detail)}</div>
          <span class="verify-status"><svg class="ico"><use href="#i-check"></use></svg>${esc(v.status)}</span>
        </div>`,
      )
      .join("");
  }

  function renderStatic() {
    renderSamples();
    renderLayers();
    renderRules();
    renderPolicy();
    renderKeywords();
    renderLimits();
    renderResources();
    renderVerification();
    renderStats();
    renderStrip();
  }

  /* ── result ────────────────────────────────────────────────────────────── */
  function byteLenAt(lead) {
    if (lead < 0x80) return 1;
    if (lead < 0xc0) return 1;
    if (lead < 0xe0) return 2;
    if (lead < 0xf0) return 3;
    return 4;
  }

  /**
   * 板子的 mask 是逐字节 1:1 的（一个汉字会变成 3 个 '*'），直接显示会出现
   * 忽长忽短、满屏星星的段落。这里按原始字符对齐，把「一个字符被整段遮住」
   * 收成一个 '*'：阅读长度 = 字符数，和输入一一对应；底层仍然保留 board mask。
   */
  function expandMaskGlyphs(masked) {
    // render_mask 把「3 个连续 '*'」折成了一个全角 ＊（可能跨多个原字符），
    // humanize 前先展开回逐字节，才能按原字符对齐。
    return String(masked || "").replace(/＊/g, "***").replace(/×/g, "**");
  }

  function humanizeMask(original, masked) {
    const o = enc.encode(original || "");
    const m = enc.encode(expandMaskGlyphs(masked));
    if (!o.length || o.length !== m.length) return masked || "";
    let out = "";
    let i = 0;
    while (i < o.length) {
      const len = Math.min(byteLenAt(o[i]), o.length - i);
      const slice = m.subarray(i, i + len);
      let allStar = true;
      for (let k = 0; k < slice.length; k++) {
        if (slice[k] !== 0x2a) {
          allStar = false;
          break;
        }
      }
      out += allStar ? "*" : dec.decode(slice);
      i += len;
    }
    return out;
  }

  /** 为已知的板上误标做「显示层」修正；返回值里带上 applied，界面上会写明原因。 */
  function applyKnownFixes(text, fixes) {
    let out = text;
    const applied = [];
    for (const f of fixes || []) {
      if (!f || !f.from || !out.includes(f.from)) continue;
      out = out.split(f.from).join(f.to);
      applied.push(f);
    }
    return { text: out, applied };
  }

  function displayFor(result) {
    if (!result) return "";
    return result.displayMasked != null
      ? result.displayMasked
      : humanizeMask(result.text, result.masked);
  }

  function maskHtml(text) {
    const re = /(\*+|＊+)/g;
    let out = "";
    let last = 0;
    let i = 0;
    for (const m of text.matchAll(re)) {
      out += esc(text.slice(last, m.index));
      const delay = Math.min(360, i * 16);
      out += `<span class="mk" style="--d:${delay}ms">${esc(m[0])}</span>`;
      last = m.index + m[0].length;
      i++;
    }
    out += esc(text.slice(last));
    return out;
  }

  function renderResult() {
    const empty = $("#resultEmpty");
    const textEl = $("#resultText");
    const result = state.result;
    const btn = $("#btnCopyResult");
    if (btn) btn.disabled = !result;

    if (!result) {
      if (empty) empty.hidden = false;
      if (textEl) {
        textEl.hidden = true;
        textEl.textContent = "";
      }
      const card = $("#resultCard");
      if (card) card.classList.remove("is-stale");
      const badge = $("#resultSource");
      if (badge) {
        badge.className = "source-badge";
        badge.textContent = "待运行";
      }
      const meta = $("#resultMeta");
      if (meta) meta.textContent = "";
      const note = $("#resultNote");
      if (note) note.textContent = "回放模式使用板上实测回显；任意文本走本地规则预览。";
      const knownBox = $("#knownIssue");
      if (knownBox) knownBox.hidden = true;
      $("#hitTotal").textContent = "0";
      $("#hitBar").innerHTML = '<span class="hit-empty"></span>';
      $("#hitChips").innerHTML = "";
      $("#auditLine").textContent = "—";
      $("#auditRawHint").textContent = "板子回传 · 17 字段";
      return;
    }

    if (empty) empty.hidden = true;
    if (textEl) {
      textEl.hidden = false;
      if (state.rawTab === "raw") {
        textEl.textContent = result.text;
      } else {
        textEl.innerHTML = maskHtml(displayFor(result));
      }
    }

    const src = SOURCE[result.source] || SOURCE.demo;
    const badge = $("#resultSource");
    if (badge) {
      badge.className = "source-badge " + src.cls;
      badge.textContent = src.label + (result.known ? " · 已修正" : "");
    }

    const outBytes = nbytes(result.masked);
    const meta = $("#resultMeta");
    if (meta) {
      meta.textContent = `${fmt(result.bytes)} B in · ${fmt(outBytes)} B out${result.latency != null ? ` · ${round1(result.latency)} ms` : " · 回放"}`;
    }
    const note = $("#resultNote");
    if (note) note.textContent = result.note || "";
    const knownBox = $("#knownIssue");
    if (knownBox) {
      knownBox.hidden = !result.known;
      const knownText = $("#knownIssueText");
      if (knownText) knownText.textContent = result.known || "";
    }
    $("#auditLine").textContent = result.auditLine || "—";
    $("#auditRawHint").textContent =
      result.source === "live"
        ? `板子回传 · ${result.frames.length} 帧摘要汇总`
        : result.source === "demo"
          ? "板上计数重建 · l2 未记录"
          : "本地重建 · 不含 L2 / NER";
    renderAudit(result);
    const card = $("#resultCard");
    if (card) card.classList.remove("is-stale");
  }

  function renderAudit(result) {
    const total = result.n || 0;
    $("#hitTotal").textContent = fmt(total);
    const kinds = TYPES.filter((t) => (result.counts[t] || 0) > 0);
    const sum = kinds.reduce((a, t) => a + result.counts[t], 0);

    const bar = $("#hitBar");
    if (!sum) {
      bar.innerHTML = '<span class="hit-empty"></span>';
    } else {
      bar.innerHTML = kinds
        .map((t) => {
          const pct = (result.counts[t] / sum) * 100;
          return `<span class="hit-seg-${typeTone(t)}" style="width:${pct}%" title="${esc(typeLabel(t))} ${result.counts[t]}"></span>`;
        })
        .join("");
    }

    const chips = [];
    kinds.forEach((t) => {
      chips.push(`<span class="chip tone-${typeTone(t)}"><i class="cdot"></i>${esc(typeLabel(t))} <b>${result.counts[t]}</b></span>`);
    });
    if (result.kw) chips.push(`<span class="chip tone-slate"><i class="cdot"></i>关键词 <b>${result.kw}</b></span>`);
    if (result.l2) chips.push(`<span class="chip tone-blue"><i class="cdot"></i>L2 语义 <b>${result.l2}</b></span>`);
    if (result.ovf) chips.push('<span class="chip tone-amber"><i class="cdot"></i>ovf=1 · 溢出</span>');
    if (!chips.length) chips.push('<span class="chip-empty">未发现 PII · 原文可原样放行</span>');
    $("#hitChips").innerHTML = chips.join("");
  }

  function renderFrames() {
    const list = $("#frameList");
    const count = $("#frameCount");
    if (!list) return;
    const frames = state.frames || [];
    if (count) count.textContent = `${frames.length} 帧`;
    if (!frames.length) {
      list.innerHTML = '<div class="list-empty">运行后这里会列出每一帧。</div>';
      $("#frameViewTitle").textContent = "F01";
      $("#frameViewMeta").textContent = "—";
      $("#frameViewText").textContent = "—";
      $("#frameViewCounts").innerHTML = "";
      return;
    }
    const sel = Math.min(state.selectedFrame, frames.length - 1);
    state.selectedFrame = sel;
    list.innerHTML = frames
      .map((f, i) => {
        const n = f.n != null ? f.n : countTotal(f.counts || {});
        const est = f.estimated ? "~" : "";
        return `<button class="frame-row${i === sel ? " is-active" : ""}" type="button" data-frame-row="${i}">
          <span class="frame-row-id">F${pad2(i + 1)}</span>
          <span class="frame-row-main"><b>${esc(previewText(f.text, 22))}</b><span>${f.bytes} B${f.endsLine ? " · LF" : " · 续行"}</span></span>
          <span class="frame-row-hits${n ? "" : " zero"}">${est}${n} hit</span>
        </button>`;
      })
      .join("");
    renderFrameView();
  }

  function renderFrameView() {
    const frames = state.frames || [];
    const frame = frames[state.selectedFrame];
    if (!frame) return;
    const origin =
      state.result && state.result.source === "live"
        ? "板级摘要"
        : state.result && state.result.source === "demo"
          ? `板上整段回放${frame.estimated ? " · 帧级推演" : ""}`
          : "本地规则";
    $("#frameViewTitle").textContent = `F${pad2(state.selectedFrame + 1)}`;
    $("#frameViewMeta").textContent = `${frame.bytes} B · ${origin}${frame.endsLine ? "" : " · 续行"}`;
    $("#frameViewText").textContent = frame.masked != null ? humanizeMask(frame.text, frame.masked) || "(空帧)" : frame.text || "(空帧)";
    const counts = frame.counts || {};
    const chips = TYPES.filter((t) => counts[t]).map(
      (t) => `<span class="chip tone-${typeTone(t)}"><i class="cdot"></i>${esc(typeLabel(t))} <b>${counts[t]}</b></span>`,
    );
    if (!chips.length) chips.push('<span class="chip-empty">本帧未命中</span>');
    if (frame.ovf) chips.push('<span class="chip tone-amber"><i class="cdot"></i>ovf=1</span>');
    if (frame.estimated) chips.push('<span class="chip muted">帧级为本地推演</span>');
    $("#frameViewCounts").innerHTML = chips.join("");
  }

  function renderHistory() {
    const host = $("#historyList");
    if (!host) return;
    const items = state.history || [];
    if (!items.length) {
      host.innerHTML = '<div class="list-empty" id="historyEmpty">本次会话还没有记录。</div>';
    } else {
      host.innerHTML = items
        .map((h, i) => {
          const src = SOURCE[h.source] || SOURCE.demo;
          const label =
            h.source === "demo" && h.result && h.result.demoKey
              ? demoLabel(h.result.demoKey)
              : previewText(h.text, 24);
          const t = new Date(h.ts);
          const hh = `${pad2(t.getHours())}:${pad2(t.getMinutes())}:${pad2(t.getSeconds())}`;
          return `<button class="history-row" type="button" data-history="${i}">
            <i class="history-dot ${src.dot}"></i>
            <span class="history-main"><b>${esc(label)}</b><span>${src.short} · ${h.frames} 帧 · ${fmt(h.bytes)} B · ${h.n} spans</span></span>
            <span class="history-right"><b>${hh}</b>${h.latency != null ? round1(h.latency) + " ms" : "回放"}</span>
          </button>`;
        })
        .join("");
    }
    const summary = $("#historySummary");
    if (summary) {
      const totalBytes = items.reduce((a, h) => a + h.bytes, 0);
      const totalHits = items.reduce((a, h) => a + h.n, 0);
      summary.innerHTML = items.length
        ? `<span>本次会话 · ${items.length} 次</span><span>${fmt(totalBytes)} B · ${totalHits} spans</span>`
        : "<span>仅存内存</span><span>最近 8 次</span>";
    }
  }

  function renderMonitor() {
    const host = $("#frameMonitor");
    const count = $("#monitorCount");
    if (!host) return;
    const items = state.monitor || [];
    if (count) count.textContent = `${items.length} 帧`;
    if (!items.length) {
      host.innerHTML = '<div class="list-empty" id="monitorEmpty">连上板子并发送一次，帧与摘要会出现在这里。</div>';
      return;
    }
    host.innerHTML = items
      .slice(0, 12)
      .map((f, i) => {
        const counts = f.counts || {};
        const n = f.n != null ? f.n : countTotal(counts);
        const src = SOURCE[f.source || (state.result && state.result.source)] || SOURCE.demo;
        const chips = TYPES.filter((t) => counts[t])
          .map((t) => `<span>${esc(typeLabel(t))} <b>${counts[t]}</b></span>`)
          .join("");
        const estimate = (f.source || (state.result && state.result.source)) === "demo" ? " · 推演" : "";
        return `<div class="mon-frame${f.ovf ? " is-ovf" : ""}">
          <div class="mon-head">
            <span class="mon-id">F${pad2(i + 1)}</span>
            <span class="mon-size">${f.bytes} B${estimate}</span>
            <span class="source-badge ${src.cls}">${src.short}</span>
            <span class="mon-hits${n ? "" : " zero"}">${n} hit${f.ovf ? " · ovf" : ""}</span>
          </div>
          <pre class="mon-text">${esc(f.masked != null ? humanizeMask(f.text, f.masked) || "(空帧)" : f.text || "(空帧)")}</pre>
          <div class="mon-counts">${chips || "<span>无命中</span>"}</div>
        </div>`;
      })
      .join("");
  }

  function renderLinkStats() {
    const host = $("#linkStats");
    if (!host) return;
    const s = state.serial;
    const hasSession = state.connected || s.frames > 0;
    const cards = [
      {
        tone: "mint",
        kicker: "端口",
        en: "PORT",
        value: state.connected ? "USB" : "回放",
        unit: "",
        sub: state.connected ? `${state.portLabel} · ${s.baud} 8N1` : "不占串口",
      },
      {
        tone: "blue",
        kicker: "已发送",
        en: "TX",
        value: hasSession ? fmt(s.tx) : "—",
        unit: hasSession ? "B" : "",
        sub: hasSession ? `${s.frames} 帧 · 逐帧等回读` : "等待串口会话",
      },
      {
        tone: "violet",
        kicker: "已接收",
        en: "RX",
        value: hasSession ? fmt(s.rx) : "—",
        unit: hasSession ? "B" : "",
        sub: hasSession ? "含摘要行" : "等待串口会话",
      },
      {
        tone: "amber",
        kicker: "最近一帧",
        en: "LATENCY",
        value: s.lastLatency != null ? fmt(s.lastLatency) : "—",
        unit: s.lastLatency != null ? "ms" : "",
        sub: s.lastLatency != null ? "发送 → 摘要" : "串口模式可用",
      },
    ];
    host.innerHTML = cards
      .map(
        (c) => `<div class="stat-card" data-tone="${c.tone}">
          <div class="stat-kicker">${esc(c.kicker)} <em>${esc(c.en)}</em></div>
          <div class="stat-val"><b>${esc(c.value)}</b>${c.unit ? `<span>${esc(c.unit)}</span>` : ""}</div>
          <div class="stat-sub">${esc(c.sub)}</div>
        </div>`,
      )
      .join("");
  }

  function renderLog() {
    const host = $("#eventLog");
    if (!host) return;
    if (!state.log.length) {
      host.innerHTML = '<div class="log-empty" id="logEmpty">等待会话事件…</div>';
      return;
    }
    const nearBottom = host.scrollHeight - host.scrollTop - host.clientHeight < 40;
    host.innerHTML = state.log
      .map(
        (r) => `<div class="log-row">
          <span class="log-time">${esc(r.time || "")}</span>
          <span class="log-kind k-${esc(r.kind)}">${esc(r.kind.toUpperCase())}</span>
          <span class="log-msg">${esc(r.msg)}</span>
        </div>`,
      )
      .join("");
    if (nearBottom) host.scrollTop = host.scrollHeight;
  }

  /* ── run: replay / local ───────────────────────────────────────────────── */
  function frameAnalysis(raw) {
    const plan = ENGINE.splitFrames(raw);
    return plan.map((f, i) => {
      const a = ENGINE.analyze(f.text || "");
      return {
        ...f,
        index: i,
        masked: a.masked,
        counts: a.counts,
        n: a.n,
        estimated: false,
      };
    });
  }

  function demoResult(raw, demo) {
    const local = ENGINE.analyze(raw);
    const meta = (DATA.demoMeta && DATA.demoMeta[demo.key]) || {};
    const fixed = applyKnownFixes(humanizeMask(raw, demo.mask), meta.fixes);
    const counts = {};
    TYPES.forEach((t) => {
      if (demo.audit && demo.audit[t]) counts[t] = demo.audit[t];
    });
    const n = demo.audit && demo.audit.n != null ? demo.audit.n : countTotal(counts);
    const frames = frameAnalysis(raw).map((f) => ({ ...f, estimated: true, origin: "demo" }));
    const known = fixed.applied.length
      ? `已修正 ${fixed.applied.length} 处已知 NER 误标：板上原始回显为「${fixed.applied
          .map((f) => f.from)
          .join("、")}」，页面显示为「${fixed.applied.map((f) => f.to).join("、")}」。`
      : "";
    return {
      source: "demo",
      text: raw,
      bytes: nbytes(raw),
      masked: demo.mask,
      displayMasked: fixed.text,
      counts,
      n,
      kw: local.kw,
      kwm: local.kwm,
      l2: 0,
      l2m: 0,
      mode: 1,
      ovf: 0,
      latency: null,
      frames,
      auditLine: buildAuditLine({ counts, n, kw: local.kw, kwm: local.kwm, l2: 0, l2m: 0, mode: 1, ovf: 0 }),
      note: `回放 · 板上实测回显 · ${demo.label}${fixed.applied.length ? `（显示层修正 ${fixed.applied.length} 处已知误标）` : ""}。帧级计数为本地推演。`,
      hint: "板上计数重建 · l2 未记录",
      keywords: local.keywords,
      demoKey: demo.key,
      known,
    };
  }

  function localResult(raw) {
    const t0 = performance.now();
    const a = ENGINE.analyze(raw);
    const latency = Math.max(0.1, performance.now() - t0);
    const frames = frameAnalysis(raw).map((f) => ({ ...f, origin: "local" }));
    return {
      source: "local",
      text: raw,
      bytes: nbytes(raw),
      masked: a.masked,
      displayMasked: humanizeMask(raw, a.masked),
      counts: a.counts,
      n: a.n,
      kw: a.kw,
      kwm: a.kwm,
      l2: 0,
      l2m: 0,
      mode: 1,
      ovf: 0,
      latency,
      frames,
      auditLine: buildAuditLine({ counts: a.counts, n: a.n, kw: a.kw, kwm: a.kwm, l2: 0, l2m: 0, mode: 1, ovf: 0 }),
      note: `本地规则 + 词典实体预览 · ${round1(latency)} ms · 不含 NER / L2，以板上结果为准。`,
      hint: "本地重建 · 不含 L2 / NER",
      keywords: a.keywords,
      demoKey: null,
      known: "",
    };
  }

  function runReplay(raw) {
    const demo = findDemo(raw);
    if (demo && demo.mask) return demoResult(raw, demo);
    const result = localResult(raw);
    if (demo && !demo.mask) result.note = "这条样例没有记录板上回显，已退到本地规则预览。";
    return result;
  }

  /* ── run: serial ───────────────────────────────────────────────────────── */
  function appendRx(chunk) {
    const S = state.serial;
    const next = new Uint8Array(S.buf.length + chunk.length);
    next.set(S.buf, 0);
    next.set(chunk, S.buf.length);
    S.buf = next;
    S.rx += chunk.length;
  }

  async function pumpReader() {
    const S = state.serial;
    while (S.reading && S.reader) {
      let res;
      try {
        res = await S.reader.read();
      } catch (e) {
        if (S.reading) log("warn", `读取串口失败：${e.message || e}`);
        break;
      }
      if (res.done) break;
      if (res.value && res.value.length) appendRx(res.value);
    }
    if (S.reading && state.connected && state.serial === S) {
      disconnectSerial({ silent: true });
      toast("串口连接已丢失，回到回放模式", "warn");
    }
  }

  async function drainQuiet(quiet = 170, cap = 1500) {
    const S = state.serial;
    const t0 = performance.now();
    let lastLen = S.buf.length;
    let lastChange = performance.now();
    while (performance.now() - t0 < cap) {
      await sleep(30);
      const len = S.buf.length;
      if (len !== lastLen) {
        lastLen = len;
        lastChange = performance.now();
      } else if (performance.now() - lastChange >= quiet) {
        break;
      }
    }
    S.buf = new Uint8Array(0);
  }

  async function readFrame(timeout = 16000) {
    const S = state.serial;
    const t0 = performance.now();
    while (performance.now() - t0 < timeout) {
      if (state.abortRun || !state.connected) throw new Error("串口已断开");
      const text = dec.decode(S.buf);
      const re = /\[guard\] [^\n]*\n/g;
      let m;
      let last = null;
      while ((m = re.exec(text))) last = m;
      if (last) {
        const body = text.slice(0, last.index);
        const line = last[0].trim();
        S.buf = new Uint8Array(0);
        return { body, line, ms: performance.now() - t0 };
      }
      await sleep(20);
    }
    const body = dec.decode(S.buf);
    S.buf = new Uint8Array(0);
    return { body, line: "", ms: timeout, timeout: true };
  }

  function parseReport(line) {
    const s = String(line || "").replace(/^\[guard\]\s*/, "").trim();
    if (!s) return null;
    const out = {};
    for (const tok of s.split(/\s+/)) {
      const [k, v] = tok.split("=");
      if (!k || v == null || !/^\d+$/.test(v)) continue;
      out[k] = parseInt(v, 10);
    }
    if (out.n == null || out.ovf == null) return null;
    return out;
  }

  async function runLive(raw) {
    const S = state.serial;
    if (!state.connected || !S.writer) throw new Error("串口未连接");
    state.abortRun = false;
    const plan = ENGINE.splitFrames(raw);
    if (!plan.length) throw new Error("没有可发送的帧");
    S.buf = new Uint8Array(0);
    await drainQuiet(170);
    log("sys", `开始发送 · ${plan.length} 帧 · ${S.baud} 8N1`);
    const frames = [];
    let maskedAll = "";
    const total = {};
    let totalN = 0;
    let kw = 0;
    let kwm = 0;
    let l2 = 0;
    let l2m = 0;
    let ovf = 0;
    let mode = 1;
    const t0 = performance.now();

    for (let i = 0; i < plan.length; i++) {
      if (state.abortRun || !state.connected) throw new Error("串口已断开");
      const f = plan[i];
      const wire = enc.encode(f.text + "\n");
      log("tx", `F${pad2(i + 1)} · ${wire.length} B`);
      await S.writer.write(wire);
      S.tx += wire.length;
      const r = await readFrame(16000);
      if (r.timeout) {
        renderLinkStats();
        throw new Error(`第 ${i + 1} 帧等回读超时（已收到 ${S.rx} B）`);
      }
      const rep = parseReport(r.line);
      if (!rep) throw new Error(`第 ${i + 1} 帧摘要格式异常：${r.line.slice(0, 80)}`);
      let body = r.body.replace(/\r\n/g, "\n").replace(/\n$/, "");
      const original = enc.encode(f.text);
      const maskedBytes = enc.encode(body);
      const display = ENGINE.renderBoardMask(original, maskedBytes);
      const frameMasked = maskedBytes.length === original.length ? display : body;
      maskedAll += frameMasked + (f.endsLine ? "\n" : "");

      const counts = {};
      TYPES.forEach((t) => {
        if (rep[t]) counts[t] = rep[t];
        total[t] = (total[t] || 0) + (rep[t] || 0);
      });
      const n = rep.n || 0;
      totalN += n;
      kw += rep.kw || 0;
      kwm |= rep.kwm || 0;
      l2 += rep.l2 || 0;
      l2m |= rep.l2m || 0;
      ovf |= rep.ovf || 0;
      mode = rep.mode != null ? rep.mode : mode;

      frames.push({
        index: i,
        text: f.text,
        bytes: f.bytes,
        endsLine: f.endsLine,
        masked: frameMasked,
        counts,
        n,
        ovf: rep.ovf || 0,
        origin: "live",
      });
      S.frames++;
      S.lastLatency = Math.round(r.ms);
      log("rx", `F${pad2(i + 1)} · ${r.body.length} B 回显 + 摘要`);
      log("audit", `n=${n}${TYPES.filter((t) => rep[t]).map((t) => ` ${t}=${rep[t]}`).join("")}${rep.ovf ? " · ovf=1" : ""}`);
      renderLinkStats();
      if (rep.ovf) toast(`第 ${i + 1} 帧 ovf=1：RX FIFO 溢出，检查发送节奏`, "warn");
      await sleep(25);
    }

    maskedAll = maskedAll.replace(/\n$/, "");
    const elapsed = performance.now() - t0;
    renderLinkStats();
    const counts = {};
    TYPES.forEach((t) => {
      if (total[t]) counts[t] = total[t];
    });
    return {
      source: "live",
      text: raw,
      bytes: nbytes(raw),
      masked: maskedAll,
      displayMasked: humanizeMask(raw, maskedAll),
      counts,
      n: totalN,
      kw,
      kwm,
      l2,
      l2m,
      mode,
      ovf,
      latency: elapsed,
      frames,
      auditLine: buildAuditLine({ counts, n: totalN, kw, kwm, l2, l2m, mode, ovf }),
      note: `串口实时 · ${S.baud} 8N1 · ${frames.length} 帧 · ${Math.round(elapsed)} ms${ovf ? " · ovf=1" : ""}`,
      hint: "板子回传 · 逐帧摘要汇总",
      keywords: [],
      demoKey: null,
      known: "",
    };
  }

  /* ── apply result / history ────────────────────────────────────────────── */
  function applyResult(result) {
    state.result = result;
    state.frames = result.frames || [];
    state.selectedFrame = 0;
    state.rawTab = "masked";
    state.demoKey = result.demoKey || null;
    state.monitor = (result.frames || []).map((f) => ({ ...f, source: result.source }));
    renderResult();
    renderFrames();
    renderStats();
    renderMonitor();
    renderStrip();
    updateSampleActive();
    const tabs = $$(".result-tabs .tab");
    tabs.forEach((t) => {
      const on = t.dataset.tab === "masked";
      t.classList.toggle("is-active", on);
      t.setAttribute("aria-selected", on ? "true" : "false");
    });
  }

  function pushHistory(result) {
    state.history.unshift({
      ts: Date.now(),
      source: result.source,
      text: result.text,
      bytes: result.bytes,
      frames: result.frames.length,
      n: result.n,
      latency: result.latency,
      result,
    });
    state.history = state.history.slice(0, MAX_FRAMES);
    renderHistory();
  }

  function setResult(result) {
    applyResult(result);
    pushHistory(result);
    log("sys", `判读完成 · ${SOURCE[result.source].label} · ${result.frames.length} 帧 · ${result.n} spans${result.latency != null ? ` · ${round1(result.latency)} ms` : ""}`);
  }

  async function runRedaction(trigger) {
    if (state.running) return;
    if (!ENGINE) {
      toast("本地引擎没有加载，刷新页面再试", "error");
      return;
    }
    const raw = normalizeText($("#input").value);
    if (!raw.trim()) {
      toast("先输入一段文本，或从上面选一条样例", "warn");
      $("#input").focus();
      return;
    }
    if (state.mode === "live" && !state.connected) {
      toast("串口未连接，先连板子或回到回放模式", "warn");
      go("link", true);
      return;
    }
    state.running = true;
    updateRunUI();
    startPipeline();
    try {
      const result = state.mode === "live" ? await runLive(raw) : runReplay(raw);
      setResult(result);
      finishPipeline(true);
    } catch (e) {
      console.error(e);
      log("err", e.message || String(e));
      toast(e.message || "运行失败", "error");
      finishPipeline(false);
    } finally {
      state.running = false;
      updateRunUI();
      updateModeUI();
    }
    void trigger;
  }

  /* ── pipeline animation ────────────────────────────────────────────────── */
  function clearPipelineTimers() {
    clearInterval(pipelineTimer);
    clearTimeout(pipelineReset);
    pipelineTimer = null;
    pipelineReset = null;
  }

  function startPipeline() {
    clearPipelineTimers();
    const stages = $$("#pipeline .stage");
    const badge = $("#pipelineBadge");
    stages.forEach((s) => s.classList.remove("is-on", "is-done", "is-error"));
    if (badge) {
      badge.className = "live-badge is-busy";
      badge.textContent = "运行中";
    }
    if (!stages.length) return;
    let i = 0;
    stages[0].classList.add("is-on");
    pipelineTimer = setInterval(() => {
      if (i > 0) {
        stages[i - 1].classList.remove("is-on");
        stages[i - 1].classList.add("is-done");
      }
      if (i < stages.length) {
        stages[i].classList.add("is-on");
        i++;
      } else clearInterval(pipelineTimer);
    }, 160);
  }

  function finishPipeline(ok) {
    clearInterval(pipelineTimer);
    pipelineTimer = null;
    const stages = $$("#pipeline .stage");
    stages.forEach((s) => {
      s.classList.remove("is-on");
      s.classList.add(ok ? "is-done" : "is-error");
    });
    const badge = $("#pipelineBadge");
    if (badge) {
      badge.className = "live-badge " + (ok ? "is-live" : "");
      badge.textContent = ok ? "完成" : "出错";
    }
    clearTimeout(pipelineReset);
    pipelineReset = setTimeout(() => {
      stages.forEach((s) => s.classList.remove("is-done", "is-error"));
      if (badge) {
        badge.className = "live-badge";
        badge.textContent = state.connected ? "在线" : "待机";
      }
    }, 2400);
  }

  /* ── mode / serial UI ──────────────────────────────────────────────────── */
  function updateRunUI() {
    const btn = $("#btnRun");
    if (!btn) return;
    btn.disabled = state.running;
    btn.innerHTML = state.running
      ? '<svg class="ico is-spin"><use href="#i-refresh"></use></svg><span>运行中…</span>'
      : '<svg class="ico"><use href="#i-play"></use></svg><span>运行脱敏</span>';
  }

  function updateModeUI() {
    const live = state.connected;
    const busy = state.connecting || (state.running && live);
    const pill = $("#connPill");
    const label = $("#connLabel");
    const dot = $("#connDot");
    if (pill) pill.dataset.state = busy ? "busy" : live ? "live" : "replay";
    if (label) label.textContent = live ? `已连接 · ${state.serial.baud}` : state.connecting ? "连接中…" : "回放模式";
    if (dot) dot.className = "dot " + (busy ? "busy" : live ? "live" : "");

    const topBtn = $("#btnConnect");
    const topLabel = $("#btnConnectLabel");
    if (topBtn) topBtn.disabled = state.connecting;
    if (topLabel) topLabel.textContent = live ? "断开" : "连接串口";

    $("#headModeDot").className = "dot " + (live ? "live" : "");
    $("#headModeText").textContent = live ? `串口 · ${state.serial.baud} 8N1` : "回放模式 · 无需插板";
    const linkDot = $("#linkModeDot");
    if (linkDot) linkDot.className = "dot " + (live ? "live" : "");
    const linkText = $("#linkModeText");
    if (linkText) linkText.textContent = live ? `串口在线 · ${state.serial.baud} 8N1` : "回放模式";

    const orb = $("#linkStatusOrb");
    if (orb) orb.className = "conn-orb " + (busy ? "is-busy" : live ? "is-live" : "");
    const title = $("#linkStatusTitle");
    if (title) title.textContent = live ? "串口在线" : state.connecting ? "正在打开串口…" : "未连接";
    const sub = $("#linkStatusSub");
    if (sub)
      sub.textContent = live
        ? `${state.portLabel} · ${state.serial.baud} 8N1 · 逐帧等回读`
        : "回放模式 · 不需要板子也能演示";

    const badge = $("#serialBadge");
    if (badge) {
      badge.className = "source-badge " + (live ? "is-ok" : "");
      badge.textContent = live ? "已连接" : state.connecting ? "连接中" : "未连接";
    }
    const b2 = $("#btnConnect2");
    if (b2) b2.disabled = live || state.connecting;
    const disc = $("#btnDisconnect");
    if (disc) disc.disabled = !live || state.connecting;
    const baud = $("#baudSelect");
    if (baud) baud.disabled = live || state.connecting;
    const portInfo = $("#portInfo");
    if (portInfo) portInfo.textContent = live ? state.portLabel : "—";
    const support = $("#serialSupport");
    if (support) {
      if (!state.serial.supported) {
        support.className = "support-note is-warn";
        support.textContent = "这个浏览器没有 Web Serial。请用 Chrome / Edge，并通过 make web 打开页面。";
      } else if (location.protocol === "file:") {
        support.className = "support-note is-warn";
        support.textContent = "Web Serial 通常需要 http://localhost 页面；file:// 下可能不可用。先用回放模式。";
      } else {
        support.className = "support-note is-ok";
        support.textContent = "Web Serial 可用 · 选择串口后以 115200 8N1 连接。";
      }
    }
    renderLinkStats();
  }

  function describePort(info) {
    if (!info) return "USB 串口";
    const vid = info.usbVendorId;
    const pid = info.usbProductId;
    if (vid === 0x10c4) return "CP210x USB-UART";
    if (vid === 0x1a86) return "CH340 USB-UART";
    if (vid === 0x0403) return "FTDI USB-UART";
    if (vid != null && pid != null) return `USB ${vid.toString(16).padStart(4, "0")}:${pid.toString(16).padStart(4, "0")}`;
    return "USB 串口";
  }

  async function connectSerial() {
    if (state.connecting || state.connected) return;
    if (!("serial" in navigator)) {
      toast("这个浏览器不支持 Web Serial，请用 Chrome / Edge", "warn");
      return;
    }
    state.connecting = true;
    updateModeUI();
    const baud = parseInt($("#baudSelect").value, 10) || 115200;
    let port = null;
    let opened = false;
    try {
      port = await navigator.serial.requestPort();
      await port.open({ baudRate: baud, dataBits: 8, stopBits: 1, parity: "none", flowControl: "none" });
      opened = true;
      const reader = port.readable.getReader();
      const writer = port.writable.getWriter();
      const info = port.getInfo ? port.getInfo() : null;
      state.serial = {
        supported: true,
        port,
        reader,
        writer,
        reading: true,
        buf: new Uint8Array(0),
        baud,
        tx: 0,
        rx: 0,
        frames: 0,
        lastLatency: null,
        info,
      };
      state.portLabel = describePort(info);
      state.connected = true;
      state.connecting = false;
      state.mode = "live";
      state.abortRun = false;
      updateModeUI();
      log("sys", `串口已连接 · ${state.portLabel} · ${baud} 8N1`);
      toast(`串口已连接 · ${baud} 8N1`);
      go("link", true);
      pumpReader();
    } catch (e) {
      state.connecting = false;
      updateModeUI();
      if (opened) {
        try {
          await port?.close();
        } catch (err) { /* already closed */ }
      }
      if (e && (e.name === "NotFoundError" || e.name === "AbortError")) return; // 用户取消选口
      log("err", `打开串口失败：${e.message || e}`);
      toast(`打开串口失败：${e.message || e}`, "error");
    }
  }

  async function disconnectSerial(opts = {}) {
    const S = state.serial;
    if (!state.connected && !S.port && !S.reading) return;
    state.abortRun = true;
    S.reading = false;
    try {
      await S.reader?.cancel();
    } catch (e) { /* ignore */ }
    try {
      S.writer?.releaseLock?.();
    } catch (e) { /* ignore */ }
    try {
      await S.port?.close();
    } catch (e) { /* ignore */ }
    state.serial = {
      supported: "serial" in navigator,
      port: null,
      reader: null,
      writer: null,
      reading: false,
      buf: new Uint8Array(0),
      baud: S.baud,
      tx: 0,
      rx: 0,
      frames: 0,
      lastLatency: null,
      info: null,
    };
    state.connected = false;
    state.connecting = false;
    state.mode = "replay";
    state.portLabel = "—";
    updateModeUI();
    log("sys", "串口已断开 · 回到回放模式");
    if (!opts.silent) toast("串口已断开");
  }

  /* ── navigation / palette ──────────────────────────────────────────────── */
  function viewFromHash() {
    const h = (location.hash || "").replace(/^#\/?/, "");
    return VIEWS.includes(h) ? h : "workbench";
  }

  function go(view, push) {
    const v = VIEWS.includes(view) ? view : "workbench";
    state.view = v;
    $$(".view").forEach((el) => {
      el.hidden = el.dataset.view !== v;
    });
    $$(".nav-item").forEach((btn) => {
      const on = btn.dataset.nav === v;
      btn.classList.toggle("is-active", on);
      if (on) btn.setAttribute("aria-current", "page");
      else btn.removeAttribute("aria-current");
    });
    if (push && viewFromHash() !== v) location.hash = "#/" + v;
    window.scrollTo({ top: 0, behavior: "auto" });
  }

  function buildPalette() {
    const items = [];
    const viewMeta = {
      workbench: { icon: "grid", title: "脱敏工作台", sub: "输入文本 · 回放或本地规则" },
      link: { icon: "activity", title: "数据链路", sub: "串口连接、数据通路与会话日志" },
      rules: { icon: "layers", title: "规则矩阵", sub: "10 类检测器、掩码策略与关键词" },
      system: { icon: "cpu", title: "系统状态", sub: "资源、时序、验收与限制" },
    };
    VIEWS.forEach((v) => {
      const m = viewMeta[v];
      items.push({ group: "视图", icon: m.icon, title: m.title, sub: m.sub, run: () => go(v, true) });
    });
    DEMOS.forEach((d) => {
      const n = d.audit && d.audit.n != null ? d.audit.n : countTotal(d.audit || {});
      items.push({
        group: "板上样例",
        icon: "shield",
        title: d.label,
        sub: `样例 ${d.id} · ${n} 处命中 · 回放`,
        run: () => {
          go("workbench", true);
          selectDemo(d);
        },
      });
    });
    return items;
  }

  function openPalette() {
    state.paletteOpen = true;
    lastFocus = document.activeElement;
    const p = $("#palette");
    p.hidden = false;
    document.body.style.overflow = "hidden";
    paletteItems = buildPalette();
    paletteFiltered = paletteItems;
    paletteIndex = 0;
    const input = $("#paletteInput");
    input.value = "";
    renderPalette();
    input.focus();
  }

  function closePalette() {
    state.paletteOpen = false;
    $("#palette").hidden = true;
    document.body.style.overflow = "";
    if (lastFocus && lastFocus.focus) lastFocus.focus();
    lastFocus = null;
  }

  function renderPalette() {
    const host = $("#paletteList");
    if (!host) return;
    if (!paletteFiltered.length) {
      host.innerHTML = '<div class="palette-empty">没有匹配项</div>';
      return;
    }
    let html = "";
    let group = "";
    paletteFiltered.forEach((it, i) => {
      if (it.group !== group) {
        group = it.group;
        html += `<div class="palette-group">${esc(group)}</div>`;
      }
      html += `<button class="palette-item${i === paletteIndex ? " is-active" : ""}" type="button" data-palette="${i}">
        <svg class="ico"><use href="#i-${esc(it.icon)}"></use></svg>
        <span class="palette-item-main"><b>${esc(it.title)}</b><span>${esc(it.sub)}</span></span>
        ${i === paletteIndex ? "<kbd>↵</kbd>" : ""}
      </button>`;
    });
    host.innerHTML = html;
    const active = host.querySelector(".palette-item.is-active");
    if (active) active.scrollIntoView({ block: "nearest" });
  }

  function filterPalette() {
    const q = $("#paletteInput").value.trim().toLowerCase();
    paletteFiltered = !q
      ? paletteItems
      : paletteItems.filter((it) => (it.title + " " + it.sub + " " + it.group).toLowerCase().includes(q));
    paletteIndex = 0;
    renderPalette();
  }

  function activatePalette(i) {
    const it = paletteFiltered[i];
    if (!it) return;
    closePalette();
    it.run();
  }

  /* ── toasts / log ──────────────────────────────────────────────────────── */
  function toast(msg, kind = "info", ms = 3800) {
    const host = $("#toasts");
    if (!host) return;
    const el = document.createElement("div");
    el.className = "toast" + (kind === "warn" ? " is-warn" : kind === "error" ? " is-error" : "");
    const icon = kind === "warn" || kind === "error" ? "i-alert" : "i-check";
    el.innerHTML = `<svg class="ico"><use href="#${icon}"></use></svg><span>${esc(msg)}</span>`;
    host.appendChild(el);
    const kill = () => {
      el.classList.add("is-out");
      setTimeout(() => el.remove(), 220);
    };
    el.addEventListener("click", kill);
    setTimeout(kill, ms);
  }

  function log(kind, msg) {
    state.log.push({ time: nowTime(), kind, msg });
    if (state.log.length > 200) state.log.shift();
    renderLog();
  }

  /* ── clipboard ─────────────────────────────────────────────────────────── */
  async function copyText(text, label) {
    if (!text) {
      toast("没有可复制的内容", "warn");
      return;
    }
    try {
      await navigator.clipboard.writeText(text);
      toast(`${label}已复制`);
    } catch (e) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.cssText = "position:fixed;top:-999px;left:-999px;opacity:0";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      try {
        document.execCommand("copy");
        toast(`${label}已复制`);
      } catch (err) {
        toast("复制失败，请手动选择文本", "error");
      }
      ta.remove();
    }
  }

  /* ── actions ───────────────────────────────────────────────────────────── */
  function setText(text) {
    $("#input").value = text;
    onInput();
  }

  function onInput() {
    const text = normalizeText($("#input").value);
    const demo = findDemo(text);
    state.demoKey = demo ? demo.key : null;
    updateSampleActive();
    renderStrip();
    renderStats();
    if (state.result) {
      const stale = state.result.text !== text;
      const card = $("#resultCard");
      if (card) card.classList.toggle("is-stale", stale);
      const note = $("#resultNote");
      if (note) {
        note.textContent = stale
          ? "文本已修改 · 结果来自上一次运行，Ctrl+Enter 刷新。"
          : state.result.note || "";
      }
    }
  }

  function selectDemo(demo) {
    if (!demo) return;
    setText(demo.text);
    $("#input").focus();
    runRedaction("sample");
  }

  function clearAll() {
    if (state.running) {
      toast("等本次运行结束再清空", "warn");
      return;
    }
    $("#input").value = "";
    state.demoKey = null;
    state.result = null;
    state.frames = [];
    state.selectedFrame = 0;
    state.monitor = [];
    state.rawTab = "masked";
    onInput();
    renderResult();
    renderFrames();
    renderMonitor();
    renderStats();
    updateSampleActive();
    $("#input").focus();
  }

  async function paste() {
    try {
      if (!navigator.clipboard || !navigator.clipboard.readText) throw new Error("no clipboard");
      const t = await navigator.clipboard.readText();
      if (!t) return;
      setText(t);
      toast("已粘贴到输入框");
    } catch (e) {
      $("#input").focus();
      toast("浏览器没有允许读取剪贴板，请直接 Ctrl+V", "warn");
    }
  }

  function restoreHistory(i) {
    const h = state.history[i];
    if (!h) return;
    setText(h.text);
    if (h.result) applyResult(h.result);
    log("sys", `恢复历史结果 · ${new Date(h.ts).toLocaleTimeString("zh-CN", { hour12: false })}`);
  }

  function selectFrame(i) {
    if (!state.result) {
      toast("先运行一次，才有逐帧结果", "warn");
      return;
    }
    if (state.result.text !== normalizeText($("#input").value)) {
      toast("文本已修改，先重新运行再查看逐帧", "warn");
      return;
    }
    const n = state.frames.length;
    if (!n) return;
    state.selectedFrame = Math.max(0, Math.min(n - 1, i));
    renderFrames();
    renderStrip();
  }

  /* ── wiring ────────────────────────────────────────────────────────────── */
  function wire() {
    state.serial.supported = "serial" in navigator;

    $$(".nav-item").forEach((btn) => {
      btn.addEventListener("click", () => go(btn.dataset.nav, true));
    });
    window.addEventListener("hashchange", () => go(viewFromHash(), false));

    $("#btnRun").addEventListener("click", () => runRedaction("button"));
    $("#btnClear").addEventListener("click", clearAll);
    $("#btnPaste").addEventListener("click", paste);
    $("#input").addEventListener("input", onInput);

    $("#sampleRail").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-key]");
      if (!btn) return;
      const demo = DEMOS.find((d) => d.key === btn.dataset.key);
      if (demo) selectDemo(demo);
    });

    $("#ruleRows").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-load]");
      if (!btn) return;
      go("workbench", true);
      if (btn.dataset.load === "demo") {
        const demo = DEMOS.find((d) => d.key === btn.dataset.value);
        if (demo) selectDemo(demo);
      } else if (btn.dataset.load === "sample") {
        setText(btn.dataset.value);
        $("#input").focus();
        runRedaction("rule");
      }
    });

    $("#btnCopyResult").addEventListener("click", () => {
      const out = state.result ? displayFor(state.result) : "";
      copyText(out, "脱敏结果");
    });
    $("#btnCopyAuditLine").addEventListener("click", () => {
      copyText(state.result ? state.result.auditLine : "", "审计摘要");
    });
    $("#btnCopyLog").addEventListener("click", () => {
      copyText(state.log.map((l) => `${l.time} ${l.kind.toUpperCase()} ${l.msg}`).join("\n"), "日志");
    });

    $$(".result-tabs .tab").forEach((tab) => {
      tab.addEventListener("click", () => {
        state.rawTab = tab.dataset.tab;
        $$(".result-tabs .tab").forEach((t) => {
          const on = t === tab;
          t.classList.toggle("is-active", on);
          t.setAttribute("aria-selected", on ? "true" : "false");
        });
        renderResult();
      });
    });

    $("#btnClearHistory").addEventListener("click", () => {
      state.history = [];
      renderHistory();
    });
    $("#historyList").addEventListener("click", (e) => {
      const row = e.target.closest("[data-history]");
      if (row) restoreHistory(Number(row.dataset.history));
    });

    $("#frameList").addEventListener("click", (e) => {
      const row = e.target.closest("[data-frame-row]");
      if (row) selectFrame(Number(row.dataset.frameRow));
    });
    $("#frameStrip").addEventListener("click", (e) => {
      const seg = e.target.closest("[data-frame]");
      if (seg) selectFrame(Number(seg.dataset.frame));
    });

    $("#btnClearLog").addEventListener("click", () => {
      state.log = [];
      renderLog();
    });
    $("#btnClearMonitor").addEventListener("click", () => {
      state.monitor = [];
      renderMonitor();
    });

    $("#btnConnect").addEventListener("click", () => {
      if (state.connected) disconnectSerial();
      else connectSerial();
    });
    $("#btnConnect2").addEventListener("click", connectSerial);
    $("#btnDisconnect").addEventListener("click", () => disconnectSerial());
    $("#btnGoWorkbench").addEventListener("click", () => {
      go("workbench", true);
      $("#input").focus();
    });
    $("#baudSelect").addEventListener("change", () => {
      state.serial.baud = parseInt($("#baudSelect").value, 10) || 115200;
      updateModeUI();
    });

    $("#btnPalette").addEventListener("click", () => (state.paletteOpen ? closePalette() : openPalette()));
    $("#palette").addEventListener("mousedown", (e) => {
      if (e.target === $("#palette")) closePalette();
    });
    $("#paletteInput").addEventListener("input", filterPalette);
    $("#paletteInput").addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        if (!paletteFiltered.length) return;
        paletteIndex = Math.min(paletteFiltered.length - 1, paletteIndex + 1);
        renderPalette();
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        if (!paletteFiltered.length) return;
        paletteIndex = Math.max(0, paletteIndex - 1);
        renderPalette();
      } else if (e.key === "Enter") {
        e.preventDefault();
        activatePalette(paletteIndex);
      }
    });
    $("#paletteList").addEventListener("click", (e) => {
      const item = e.target.closest("[data-palette]");
      if (item) activatePalette(Number(item.dataset.palette));
    });

    document.addEventListener("keydown", (e) => {
      const mod = e.ctrlKey || e.metaKey;
      if (mod && e.key.toLowerCase() === "k") {
        e.preventDefault();
        state.paletteOpen ? closePalette() : openPalette();
        return;
      }
      if (e.key === "Escape" && state.paletteOpen) {
        e.preventDefault();
        closePalette();
        return;
      }
      if (mod && e.key === "Enter") {
        if (state.paletteOpen) return;
        e.preventDefault();
        runRedaction("keyboard");
      }
    });

    if (navigator.serial && navigator.serial.addEventListener) {
      navigator.serial.addEventListener("disconnect", (e) => {
        if (e.target === state.serial.port || state.connected) {
          disconnectSerial({ silent: true });
          toast("串口被拔出，已回到回放模式", "warn");
        }
      });
    }

    updateModeUI();
    renderLinkStats();
    renderHistory();
    renderMonitor();
    renderLog();
    renderStrip();
  }

  /* ── boot ──────────────────────────────────────────────────────────────── */
  function boot() {
    renderStatic();
    wire();
    go(viewFromHash(), false);

    log("sys", "控制台就绪 · 回放模式");
    log("sys", "样例来自 examples/ · 5 条文段");

    const initial = DEMOS.find((d) => d.key === "demo1_offer") || DEMOS[0];
    if (initial) {
      setText(initial.text);
      state.demoKey = initial.key;
      updateSampleActive();
      setTimeout(() => runRedaction("auto"), 160);
    } else {
      setText("手机 13800138000，身份证 11010519491231002X。");
      setTimeout(() => runRedaction("auto"), 160);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();

  window.__guard = state;
})();
