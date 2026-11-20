/* =========================================================================
   ARES GUARD · fx
   纯视觉增强：粒子背景、指针光斑、滚动进度、入场揭示、按钮涟漪、
   数字滚动、结果闪烁。不读写任何业务状态，也不改变 DOM 结构语义。
   ========================================================================= */
"use strict";

(() => {
  const root = document.documentElement;
  const body = document.body;
  const reduceMQ = window.matchMedia("(prefers-reduced-motion: reduce)");
  const fineMQ = window.matchMedia("(pointer: fine)");
  const $ = (sel, scope = document) => scope.querySelector(sel);
  const $$ = (sel, scope = document) => Array.from(scope.querySelectorAll(sel));
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const rand = (a, b) => a + Math.random() * (b - a);

  let reduce = reduceMQ.matches;

  /* ── curtain ───────────────────────────────────────────────────────────── */
  function initCurtain() {
    const curtain = $("#fxCurtain");
    if (!curtain) return;
    window.setTimeout(() => curtain.remove(), 1500);
  }

  /* ── canvas backdrop ───────────────────────────────────────────────────── */
  function initCanvas() {
    const canvas = $("#fxCanvas");
    if (!canvas) return;
    if (reduce) {
      canvas.style.display = "none";
      return;
    }
    const ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) return;

    const COLORS = [
      [60, 242, 178],
      [104, 231, 245],
      [122, 184, 255],
      [184, 156, 255],
    ];
    const sprites = COLORS.map(([r, g, b]) => {
      const c = document.createElement("canvas");
      c.width = c.height = 64;
      const g2 = c.getContext("2d");
      const grd = g2.createRadialGradient(32, 32, 0, 32, 32, 32);
      grd.addColorStop(0, `rgba(${r},${g},${b},1)`);
      grd.addColorStop(0.18, `rgba(${r},${g},${b},.85)`);
      grd.addColorStop(0.45, `rgba(${r},${g},${b},.22)`);
      grd.addColorStop(1, `rgba(${r},${g},${b},0)`);
      g2.fillStyle = grd;
      g2.fillRect(0, 0, 64, 64);
      return c;
    });

    let W = 0;
    let H = 0;
    let dpr = 1;
    let parts = [];
    let rings = [];
    let traces = [];
    let raf = 0;
    let last = 0;
    let lastRing = 0;
    let running = false;
    const mouse = { x: -999, y: -999, active: false };

    function buildTraces() {
      traces = [];
      const count = W > 1100 ? 6 : 3;
      for (let i = 0; i < count; i++) {
        const pts = [];
        let x = -60;
        let y = rand(H * 0.08, H * 0.92);
        pts.push({ x, y });
        const steps = 4;
        for (let k = 0; k < steps; k++) {
          x += rand(W * 0.16, W * 0.34);
          pts.push({ x, y });
          if (k < steps - 1) {
            y += (Math.random() < 0.5 ? -1 : 1) * rand(42, 118);
            pts.push({ x, y });
          }
        }
        const segs = [];
        let len = 0;
        for (let k = 1; k < pts.length; k++) {
          const a = pts[k - 1];
          const b = pts[k];
          const d = Math.hypot(b.x - a.x, b.y - a.y);
          segs.push({ a, b, d, at: len });
          len += d;
        }
        traces.push({ pts, segs, len, speed: rand(0.000018, 0.000042), phase: Math.random() });
      }
    }

    function tracePoint(tr, t) {
      const d = ((t % 1) + 1) % 1 * tr.len;
      for (const s of tr.segs) {
        if (d <= s.at + s.d) {
          const k = s.d ? (d - s.at) / s.d : 0;
          return { x: s.a.x + (s.b.x - s.a.x) * k, y: s.a.y + (s.b.y - s.a.y) * k };
        }
      }
      const lastSeg = tr.segs[tr.segs.length - 1];
      return lastSeg ? lastSeg.b : { x: 0, y: 0 };
    }

    function makeParticle() {
      const ci = Math.floor(Math.random() * COLORS.length);
      return {
        x: rand(0, W),
        y: rand(0, H),
        vx: rand(-0.16, 0.16),
        vy: rand(-0.12, 0.12),
        r: rand(0.7, 2.3),
        a: rand(0.18, 0.62),
        ci,
        ph: rand(0, Math.PI * 2),
        tw: rand(0.4, 1.3),
      };
    }

    function resize() {
      dpr = Math.min(1.6, window.devicePixelRatio || 1);
      W = window.innerWidth;
      H = window.innerHeight;
      canvas.width = Math.floor(W * dpr);
      canvas.height = Math.floor(H * dpr);
      canvas.style.width = W + "px";
      canvas.style.height = H + "px";
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const count = clamp(Math.round((W * H) / 26000), 24, 84);
      if (parts.length > count) parts.length = count;
      while (parts.length < count) parts.push(makeParticle());
      buildTraces();
    }

    function frame(now) {
      if (!running) return;
      const dt = clamp((now - last) / 16.67, 0.2, 2.4);
      last = now;
      ctx.clearRect(0, 0, W, H);
      ctx.globalCompositeOperation = "lighter";

      // faint circuit traces with travelling data pulses
      for (const tr of traces) {
        ctx.strokeStyle = "rgba(70, 205, 175, .045)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        tr.pts.forEach((p, i) => (i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)));
        ctx.stroke();
        ctx.fillStyle = "rgba(90, 230, 200, .12)";
        for (const p of tr.pts) {
          if (p.x > -10 && p.x < W + 10) ctx.fillRect(p.x - 1, p.y - 1, 2, 2);
        }
        tr.phase = (tr.phase + tr.speed * dt * 16.67) % 1;
        const pp = tracePoint(tr, tr.phase);
        if (pp.x > -10 && pp.x < W + 10) {
          ctx.globalAlpha = 0.55;
          ctx.drawImage(sprites[0], pp.x - 5, pp.y - 5, 10, 10);
          ctx.globalAlpha = 1;
        }
      }

      // connection paths, bucketed by distance to avoid per-pair strokes
      const buckets = [new Path2D(), new Path2D(), new Path2D()];
      const maxD = 128;
      for (let i = 0; i < parts.length; i++) {
        const p = parts[i];
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        if (p.x < -24) p.x = W + 24;
        else if (p.x > W + 24) p.x = -24;
        if (p.y < -24) p.y = H + 24;
        else if (p.y > H + 24) p.y = -24;
        for (let j = i + 1; j < parts.length; j++) {
          const q = parts[j];
          const dx = p.x - q.x;
          const dy = p.y - q.y;
          const d2 = dx * dx + dy * dy;
          if (d2 > maxD * maxD) continue;
          const d = Math.sqrt(d2);
          const b = d < 44 ? 2 : d < 86 ? 1 : 0;
          buckets[b].moveTo(p.x, p.y);
          buckets[b].lineTo(q.x, q.y);
        }
      }
      const lineAlpha = [0.035, 0.06, 0.095];
      for (let b = 0; b < 3; b++) {
        ctx.strokeStyle = `rgba(78, 220, 195, ${lineAlpha[b]})`;
        ctx.lineWidth = 0.65;
        ctx.stroke(buckets[b]);
      }

      if (mouse.active) {
        const near = new Path2D();
        for (const p of parts) {
          const dx = p.x - mouse.x;
          const dy = p.y - mouse.y;
          const d2 = dx * dx + dy * dy;
          if (d2 < 190 * 190) {
            near.moveTo(p.x, p.y);
            near.lineTo(mouse.x, mouse.y);
          }
        }
        ctx.strokeStyle = "rgba(80, 255, 215, .075)";
        ctx.lineWidth = 0.7;
        ctx.stroke(near);
      }

      for (const p of parts) {
        const tw = 0.55 + 0.45 * Math.sin(now * 0.0012 * p.tw + p.ph);
        ctx.globalAlpha = p.a * tw;
        const s = p.r * 7;
        ctx.drawImage(sprites[p.ci], p.x - s / 2, p.y - s / 2, s, s);
      }

      // data pulses
      if (now - lastRing > 2600 && rings.length < 4) {
        lastRing = now;
        rings.push({ x: rand(W * 0.08, W * 0.92), y: rand(H * 0.1, H * 0.9), r: 4, max: rand(90, 210), a: rand(0.12, 0.24) });
      }
      for (let i = rings.length - 1; i >= 0; i--) {
        const ring = rings[i];
        ring.r += 0.55 * dt;
        const k = 1 - ring.r / ring.max;
        if (k <= 0) {
          rings.splice(i, 1);
          continue;
        }
        ctx.globalAlpha = ring.a * k;
        ctx.strokeStyle = "rgba(80, 240, 200, 1)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(ring.x, ring.y, ring.r, 0, Math.PI * 2);
        ctx.stroke();
      }

      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = "source-over";
      raf = window.requestAnimationFrame(frame);
    }

    function play() {
      if (running || reduce) return;
      running = true;
      last = performance.now();
      raf = window.requestAnimationFrame(frame);
    }

    function stop() {
      running = false;
      window.cancelAnimationFrame(raf);
    }

    resize();
    play();

    let resizeTimer = 0;
    window.addEventListener("resize", () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        const oldW = W;
        const oldH = H;
        resize();
        if (Math.abs(W - oldW) + Math.abs(H - oldH) > 2) {
          for (const p of parts) {
            p.x = clamp(p.x, 0, W);
            p.y = clamp(p.y, 0, H);
          }
        }
      }, 140);
    });

    window.addEventListener("pointermove", (e) => {
      if (!fineMQ.matches) return;
      mouse.x = e.clientX;
      mouse.y = e.clientY;
      mouse.active = true;
    }, { passive: true });
    window.addEventListener("pointerleave", () => { mouse.active = false; }, { passive: true });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) stop();
      else play();
    });
    reduceMQ.addEventListener?.("change", (e) => {
      reduce = e.matches;
      if (reduce) {
        stop();
        canvas.style.display = "none";
      } else {
        canvas.style.display = "";
        play();
      }
    });
  }

  /* ── pointer spotlight / card border tracking ──────────────────────────── */
  function initPointer() {
    if (reduce) return;
    const spot = $("#fxSpotlight");
    if (!spot) return;
    if (!fineMQ.matches) {
      spot.style.display = "none";
      return;
    }

    let tx = window.innerWidth / 2;
    let ty = window.innerHeight * 0.3;
    let cx = tx;
    let cy = ty;
    let raf = null;
    let shown = false;

    function tick() {
      cx += (tx - cx) * 0.12;
      cy += (ty - cy) * 0.12;
      spot.style.transform = `translate3d(${cx}px, ${cy}px, 0)`;
      if (Math.abs(tx - cx) + Math.abs(ty - cy) > 0.4) raf = window.requestAnimationFrame(tick);
      else raf = null;
    }

    window.addEventListener("pointermove", (e) => {
      tx = e.clientX;
      ty = e.clientY;
      if (!shown) {
        shown = true;
        body.classList.add("fx-pointer");
        cx = tx;
        cy = ty;
      }
      if (!raf) raf = window.requestAnimationFrame(tick);
    }, { passive: true });

    // per-card radial border
    let hoverCard = null;
    let rect = null;
    let pending = null;
    let cardRaf = null;

    function flushCard() {
      cardRaf = null;
      const e = pending;
      pending = null;
      if (!e || !hoverCard || !rect) return;
      hoverCard.style.setProperty("--mx", (e.clientX - rect.left) + "px");
      hoverCard.style.setProperty("--my", (e.clientY - rect.top) + "px");
    }

    window.addEventListener("pointerover", (e) => {
      const card = e.target.closest?.(".card, .stat-card, .sample");
      if (!card || card === hoverCard) return;
      if (hoverCard) {
        hoverCard.style.removeProperty("--mx");
        hoverCard.style.removeProperty("--my");
      }
      hoverCard = card;
      rect = card.getBoundingClientRect();
    }, { passive: true });

    window.addEventListener("pointerout", (e) => {
      if (!hoverCard) return;
      if (e.relatedTarget && hoverCard.contains(e.relatedTarget)) return;
      hoverCard.style.removeProperty("--mx");
      hoverCard.style.removeProperty("--my");
      hoverCard = null;
      rect = null;
    }, { passive: true });

    window.addEventListener("pointermove", (e) => {
      if (!hoverCard) return;
      pending = e;
      if (!cardRaf) cardRaf = window.requestAnimationFrame(flushCard);
    }, { passive: true });

    window.addEventListener("scroll", () => {
      if (!hoverCard) return;
      hoverCard.style.removeProperty("--mx");
      hoverCard.style.removeProperty("--my");
      hoverCard = null;
      rect = null;
    }, { passive: true });
  }

  /* ── scroll progress ───────────────────────────────────────────────────── */
  function initScrollProgress() {
    const bar = $("#fxProgress");
    if (!bar) return;
    let raf = null;

    function update() {
      raf = null;
      const doc = document.documentElement;
      const max = doc.scrollHeight - window.innerHeight;
      const y = window.scrollY || doc.scrollTop || 0;
      bar.style.width = max > 4 ? ((y / max) * 100).toFixed(2) + "%" : "0%";
      body.classList.toggle("is-scrolled", y > 8);
    }

    function queue() {
      if (!raf) raf = window.requestAnimationFrame(update);
    }

    window.addEventListener("scroll", queue, { passive: true });
    window.addEventListener("resize", queue);
    update();
  }

  /* ── reveal on entry ───────────────────────────────────────────────────── */
  function initReveal() {
    const items = $$(".fx-reveal");
    if (!items.length) return;

    items.forEach((el) => {
      const siblings = el.parentElement
        ? Array.from(el.parentElement.children).filter((c) => c.classList && c.classList.contains("fx-reveal"))
        : [];
      const i = Math.max(0, siblings.indexOf(el));
      el.style.setProperty("--fx-delay", Math.min(360, i * 70) + "ms");
    });

    if (reduce) {
      items.forEach((el) => el.classList.add("is-visible"));
      return;
    }
    if (!("IntersectionObserver" in window)) {
      items.forEach((el) => el.classList.add("is-visible"));
      return;
    }

    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          entry.target.classList.add("is-visible");
          io.unobserve(entry.target);
        }
      },
      { rootMargin: "0px 0px -6% 0px", threshold: 0.04 },
    );
    items.forEach((el) => io.observe(el));

    // A hidden view cannot intersect. When it becomes visible, reveal what is
    // already on screen and leave the rest to the observer.
    function prime(view) {
      if (!view) return;
      window.setTimeout(() => {
        $$(".fx-reveal", view).forEach((el) => {
          const r = el.getBoundingClientRect();
          if (r.top < window.innerHeight * 1.12 && r.bottom > 0) el.classList.add("is-visible");
        });
      }, 24);
    }

    const mo = new MutationObserver(() => {
      const active = $$(".view").find((v) => !v.hidden);
      prime(active);
    });
    $$(".view").forEach((v) => mo.observe(v, { attributes: true, attributeFilter: ["hidden"] }));

    // Initial load: the app has already rendered and switched to a view before
    // this file runs, so no hidden-attribute mutation will fire for it.
    const initial = $$(".view").find((v) => !v.hidden);
    window.setTimeout(() => prime(initial), 60);
  }

  /* ── view bookkeeping ──────────────────────────────────────────────────── */
  function initViewState() {
    function sync() {
      const active = $$(".view").find((v) => !v.hidden);
      if (active) body.dataset.fxView = active.dataset.view || "";
    }
    sync();
    const mo = new MutationObserver(sync);
    $$(".view").forEach((v) => mo.observe(v, { attributes: true, attributeFilter: ["hidden"] }));
    window.addEventListener("hashchange", () => window.requestAnimationFrame(sync));
  }

  /* ── ripple ────────────────────────────────────────────────────────────── */
  function initRipple() {
    if (reduce) return;
    const hostSel = ".btn, .icon-btn, .nav-item, .sample, .row-btn, .palette-item";
    document.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const host = e.target.closest?.(hostSel);
      if (!host || host.disabled || host.getAttribute("aria-disabled") === "true") return;
      const r = host.getBoundingClientRect();
      if (!r.width || !r.height) return;
      const size = Math.max(r.width, r.height) * 1.9;
      const span = document.createElement("span");
      span.className = "fx-ripple";
      span.style.width = size + "px";
      span.style.height = size + "px";
      span.style.left = e.clientX - r.left - size / 2 + "px";
      span.style.top = e.clientY - r.top - size / 2 + "px";
      host.appendChild(span);
      span.addEventListener("animationend", () => span.remove(), { once: true });
    }, { passive: true });
  }

  /* ── animated stat values ──────────────────────────────────────────────── */
  function initStats() {
    const hosts = [$("#stats"), $("#linkStats"), $("#imuStats")].filter(Boolean);
    if (!hosts.length) return;

    const parse = (s) => {
      const t = String(s || "").replace(/,/g, "").trim();
      if (!/^-?\d+(\.\d+)?$/.test(t)) return null;
      return Number(t);
    };
    const ease = (t) => 1 - Math.pow(1 - t, 3);

    function animate(el, from, to, finalText) {
      if (el.__fxRaf) window.cancelAnimationFrame(el.__fxRaf);
      const dur = clamp(240 + Math.abs(to - from) * 1.8, 260, 700);
      const t0 = performance.now();
      function step(now) {
        if (!el.isConnected) return;
        const p = clamp((now - t0) / dur, 0, 1);
        const v = Math.round(from + (to - from) * ease(p));
        el.textContent = v.toLocaleString("en-US");
        if (p < 1) {
          el.__fxRaf = window.requestAnimationFrame(step);
        } else {
          el.textContent = finalText;
          el.__fxRaf = null;
        }
      }
      el.__fxRaf = window.requestAnimationFrame(step);
    }

    hosts.forEach((host) => {
      const targets = [];
      let queued = false;

      function sync() {
        queued = false;
        const nodes = $$(".stat-val b", host);
        nodes.forEach((el, i) => {
          const finalText = el.textContent.trim();
          const to = parse(finalText);
          if (to == null) {
            targets[i] = finalText;
            return;
          }
          const prev = targets[i];
          const from = parse(prev);
          targets[i] = finalText;
          if (reduce) return;
          const start = from == null ? 0 : from;
          if (Math.abs(to - start) < 3 && start !== 0) return;
          animate(el, start, to, finalText);
        });
        targets.length = nodes.length;
      }

      const mo = new MutationObserver(() => {
        if (queued) return;
        queued = true;
        window.requestAnimationFrame(sync);
      });
      mo.observe(host, { childList: true });
      window.requestAnimationFrame(sync);
    });
  }

  /* ── result flash ──────────────────────────────────────────────────────── */
  function initResultFlash() {
    const textEl = $("#resultText");
    const card = $("#resultCard");
    if (!textEl || !card || reduce) return;
    let timer = 0;
    const mo = new MutationObserver(() => {
      if (textEl.hidden || !textEl.textContent.trim()) return;
      card.classList.remove("is-fresh");
      void card.offsetWidth;
      card.classList.add("is-fresh");
      window.clearTimeout(timer);
      timer = window.setTimeout(() => card.classList.remove("is-fresh"), 1100);
    });
    mo.observe(textEl, { childList: true, characterData: true, subtree: true });
  }

  /* ── typewriter result ─────────────────────────────────────────────────── */
  function initTypewriter() {
    const targets = [
      { el: $("#resultText"), fast: false },
      { el: $("#frameViewText"), fast: true },
    ].filter((t) => t.el);
    if (!targets.length) return;

    function makeCaret() {
      const caret = document.createElement("span");
      caret.className = "fx-caret";
      caret.setAttribute("aria-hidden", "true");
      document.body.appendChild(caret);
      return caret;
    }

    function stop(state, el) {
      if (!state) return;
      state.cancelled = true;
      if (state.raf) window.cancelAnimationFrame(state.raf);
      window.clearTimeout(state.safety);
      if (state.caret) state.caret.remove();
      el.classList.remove("fx-typing");
      if (el.__fxType === state) el.__fxType = null;
    }

    function finish(el, state) {
      if (!state || state.done || state.cancelled) return;
      state.done = true;
      if (state.raf) window.cancelAnimationFrame(state.raf);
      window.clearTimeout(state.safety);
      for (const c of state.chars) c.el.classList.add("is-on");
      if (state.caret) state.caret.remove();
      el.classList.remove("fx-typing");
      if (el.__fxType === state) el.__fxType = null;
    }

    function placeCaret(caret, el, box, rect) {
      const b = box.getBoundingClientRect();
      const inside = rect.bottom > b.top + 1 && rect.top < b.bottom - 1 && rect.right > b.left - 2;
      if (!inside) {
        caret.style.display = "none";
        return;
      }
      const h = Math.max(12, Math.round((rect.height || 17) * 0.96));      caret.style.display = "block";
      caret.style.height = h + "px";
      caret.style.transform =
        `translate3d(${rect.right + 1}px, ${rect.top + Math.max(0, (rect.height - h) / 2)}px, 0)`;
    }

    function build(el) {
      const chars = [];
      const frag = document.createDocumentFragment();
      const push = (ch, extra) => {
        const span = document.createElement("span");
        span.className = "fx-char" + (extra ? " " + extra : "");
        span.textContent = ch;
        frag.appendChild(span);
        chars.push({ el: span, ch });
      };
      const walk = (node) => {
        if (node.nodeType === 3) {
          for (const ch of Array.from(node.data)) push(ch, "");
          return;
        }
        if (node.nodeType !== 1) return;
        if (node.classList.contains("mk")) {
          const extra = Array.from(node.classList).filter((c) => c !== "mk").join(" ");
          for (const ch of Array.from(node.textContent || "")) push(ch, "mk " + extra);
        } else {
          Array.from(node.childNodes).forEach(walk);
        }
      };
      Array.from(el.childNodes).forEach(walk);
      el.replaceChildren(frag);
      return chars;
    }

    function type(el, opts) {
      if (reduce || !el || el.hidden) return;
      if (el.__fxType) {
        // 自己的 build 会再触发一次 observer；字符还在就说明这次是重复通知，
        // 继续当前动画，不能把它停掉。
        if (el.querySelector(".fx-char")) return;
        stop(el.__fxType, el);
      }
      if (el.querySelector(".fx-char")) return;
      const text = el.textContent;
      if (!text || !text.trim() || text.length > 1600) return;

      el.__fxTransforming = true;
      let chars;
      try {
        chars = build(el);
      } finally {
        window.setTimeout(() => {
          el.__fxTransforming = false;
        }, 0);
      }
      if (chars.length < 2) return;

      let weight = 0;
      const weights = chars.map(({ ch }) => {
        let w = 1;
        if (ch === "\n") w = 6;
        else if ("。！？；".includes(ch)) w = 4;
        else if ("，、：".includes(ch)) w = 2;
        else if (ch === " ") w = 0.5;
        weight += w;
        return w;
      });
      if (!weight) return;

      const target = opts.fast
        ? Math.min(3000, 650 + weight * 7)
        : Math.min(7600, 1100 + weight * 13);
      let unit = clamp(target / weight, 4, opts.fast ? 32 : 42);
      let total = unit * weight;
      const maxTotal = opts.fast ? 3400 : 8500;
      if (total > maxTotal) {
        total = maxTotal;
        unit = total / weight;
      }
      let acc = 0;
      const times = weights.map((w) => (acc += w * unit));

      const box = el.closest(".result-box") || el;
      box.scrollTop = 0;
      const state = {
        chars,
        times,
        next: 0,
        start: 0,
        raf: 0,
        caret: makeCaret(),
        safety: 0,
        done: false,
        cancelled: false,
      };
      el.__fxType = state;
      el.classList.add("fx-typing");
      placeCaret(state.caret, el, box, chars[0].el.getBoundingClientRect());

      function keepVisible(rect) {
        const b = box.getBoundingClientRect();
        if (b.height < 12) return;
        const pad = 7;
        if (rect.bottom > b.bottom - pad) box.scrollTop += rect.bottom - (b.bottom - pad);
        else if (rect.top < b.top + pad) box.scrollTop -= b.top + pad - rect.top;
      }

      function tick(now) {
        if (state.cancelled) return;
        if (!state.start) state.start = now;
        const elapsed = now - state.start;
        while (state.next < chars.length && times[state.next] <= elapsed) {
          chars[state.next].el.classList.add("is-on");
          state.next++;
        }
        let idx = state.next - 1;
        while (idx > 0 && !chars[idx].el.getBoundingClientRect().width) idx--;
        const anchor = chars[Math.max(0, idx)].el;
        keepVisible(anchor.getBoundingClientRect());
        placeCaret(state.caret, el, box, anchor.getBoundingClientRect());
        if (state.next < chars.length) {
          state.raf = window.requestAnimationFrame(tick);
        } else {
          finish(el, state);
        }
      }
      state.raf = window.requestAnimationFrame(tick);
      state.safety = window.setTimeout(() => finish(el, state), total + 1500);
    }

    targets.forEach(({ el, fast }) => {
      const mo = new MutationObserver(() => {
        if (el.__fxTransforming) return;
        if (el.hidden) {
          stop(el.__fxType, el);
          return;
        }
        type(el, { fast });
      });
      mo.observe(el, { childList: true, characterData: true, subtree: true });

      el.addEventListener("pointerdown", () => {
        if (el.__fxType) finish(el, el.__fxType);
      });

      // The app may already have rendered before this file runs.
      if (!reduce && !el.hidden && el.textContent.trim()) type(el, { fast });
    });
  }

  /* ── boot ──────────────────────────────────────────────────────────────── */
  function boot() {
    initCurtain();
    initCanvas();
    initPointer();
    initScrollProgress();
    initReveal();
    initViewState();
    initRipple();
    initStats();
    initResultFlash();
    initTypewriter();
    window.__fxReady = true;
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
