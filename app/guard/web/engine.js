/* ARES GUARD · 本地判读引擎
 *
 * 把 host/golden 的 L1 规则层 + L2b 词典实体层搬到浏览器里，用来：
 *   1) 没有板子 / 没连串口时，对任意文本给出即时预览；
 *   2) 给板上回放补出「帧级」的估算计数。
 *
 * 与 host/golden/pii_rules.py、entities.py、redact.py 逐条对齐；
 * 唯一有意缺的一层是 NER v4（字符级 INT8 CNN，跑不动也不想在浏览器里假装跑得动）。
 * 因此裸人名 / 裸地址的召回会低于板子，界面上会明确写「本地规则预览」。
 *
 * 坐标一律是 UTF-8 字节：span = { type, start, length }。
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.GuardEngine = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const enc = new TextEncoder();
  const dec = new TextDecoder("utf-8", { fatal: false });

  /* ------------------------------------------------------------ 类型与优先级 */
  const T = {
    NAME: 9,
    ADDR: 10,
    ID18: 1,
    ID15: 2,
    MOBILE: 3,
    BANK: 4,
    EMAIL: 5,
    IPV4: 6,
    USCC: 7,
    PLATE: 8,
  };

  const TYPE_NAMES = {
    1: "id18",
    2: "id15",
    3: "mobile",
    4: "bank",
    5: "email",
    6: "ipv4",
    7: "uscc",
    8: "plate",
    9: "name",
    10: "addr",
  };

  const PRIORITY = {
    9: 10, // 实体层让位给结构化 PII
    10: 9,
    5: 1,
    8: 2,
    7: 3,
    6: 4,
    1: 5,
    2: 6,
    3: 7,
    4: 8,
  };

  const RULE_IDS = {
    9: "lexicon.name",
    10: "lexicon.addr",
    1: "iso7064.mod11_2",
    2: "date.yymmdd",
    3: "prefix.mobile",
    4: "luhn.bank",
    5: "syntax.email",
    6: "syntax.ipv4",
    7: "gb32100.mod31",
    8: "syntax.plate",
  };

  const TOKEN_NAMES = {
    9: "NAME",
    10: "ADDR",
    1: "ID18",
    2: "ID15",
    3: "MOBILE",
    4: "BANK",
    5: "EMAIL",
    6: "IPV4",
    7: "USCC",
    8: "PLATE",
  };

  /* ------------------------------------------------------------ L1：数字引擎 */
  const ID_WEIGHTS = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  const SEP_SPACE = 0x20;
  const SEP_DASH = 0x2d;
  const CH_X_UPPER = 0x58;
  const CH_X_LOWER = 0x78;

  const CTX_WINDOW = 8;
  const CTX_KID_TYPE = { 0: T.ID18, 1: T.BANK, 2: T.MOBILE };

  function luhnDouble(d) {
    const t = d * 2;
    return t > 9 ? t - 9 : t;
  }

  function luhnOk(digits) {
    // digits[0] 是最右一位
    let total = 0;
    for (let i = 0; i < digits.length; i++) {
      total += i % 2 === 1 ? luhnDouble(digits[i]) : digits[i];
    }
    return total % 10 === 0;
  }

  function leap(year) {
    return year % 4 === 0;
  }

  function dateOk(year, month, day) {
    if (!(month >= 1 && month <= 12) || !(day >= 1 && day <= 31)) return false;
    if (month === 4 || month === 6 || month === 9 || month === 11) return day <= 30;
    if (month === 2) return day <= (leap(year) ? 29 : 28);
    return true;
  }

  function id18Ok(digits) {
    let total = 0;
    for (let k = 0; k < 17; k++) total += ID_WEIGHTS[k] * digits[17 - k];
    return (total % 11 + digits[0]) % 11 === 1;
  }

  function classify(digits, hasX, tooLong) {
    const n = digits.length;
    if (tooLong || n < 11) return 0;
    const d = (k) => digits[n - 1 - k];
    if (n === 18) {
      const year = d(6) * 1000 + d(7) * 100 + d(8) * 10 + d(9);
      const month = d(10) * 10 + d(11);
      const day = d(12) * 10 + d(13);
      if (!dateOk(year, month, day)) return 0;
      return id18Ok(digits) ? T.ID18 : 0;
    }
    if (n === 15) {
      const year = 2000 + d(6) * 10 + d(7);
      const month = d(8) * 10 + d(9);
      const day = d(10) * 10 + d(11);
      return dateOk(year, month, day) ? T.ID15 : 0;
    }
    if (n === 11) {
      return d(0) === 1 && d(1) >= 3 && d(1) <= 9 ? T.MOBILE : 0;
    }
    if (n >= 13 && n <= 19 && !hasX && luhnOk(digits)) return T.BANK;
    return 0;
  }

  function looseType(ndigits, kid) {
    if (kid === 0) return ndigits === 15 ? T.ID15 : T.ID18;
    return CTX_KID_TYPE[kid] || 0;
  }

  /* ------------------------------------------------------------ L1：文本引擎 */
  const EMAIL_CHARS = new Set(toBytes("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._%+-@"));
  const IPV4_CHARS = new Set(toBytes("0123456789."));
  const USCC_CHARS = "0123456789ABCDEFGHJKLMNPQRTUWXY";
  const USCC_WEIGHTS = [1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28];
  const PLATE_LETTERS = new Set(toBytes("ABCDEFGHJKLMNPQRSTUVWXYZ")); // 无 I / O
  const PLATE_TAIL = new Set(toBytes("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"));
  const UPPER = new Set(toBytes("ABCDEFGHIJKLMNOPQRSTUVWXYZ"));
  const LOWER = new Set(toBytes("abcdefghijklmnopqrstuvwxyz"));
  const DIGIT = new Set(toBytes("0123456789"));
  const ALNUM = new Set([...UPPER, ...LOWER, ...DIGIT]);

  function toBytes(s) {
    return enc.encode(s);
  }

  function ascii(run) {
    let s = "";
    for (let i = 0; i < run.length; i++) s += String.fromCharCode(run[i]);
    return s;
  }

  function indexOfBytes(hay, needle) {
    const n = hay.length;
    const m = needle.length;
    if (m === 0) return 0;
    outer: for (let i = 0; i + m <= n; i++) {
      for (let k = 0; k < m; k++) if (hay[i + k] !== needle[k]) continue outer;
      return i;
    }
    return -1;
  }

  function emailOk(run) {
    let at = -1;
    for (let i = 0; i < run.length; i++) {
      if (run[i] === 0x40) {
        if (at >= 0) return false;
        at = i;
      }
    }
    if (at < 0) return false;
    const local = run.slice(0, at);
    const domain = run.slice(at + 1);
    if (!(local.length >= 1 && local.length <= 32)) return false;
    if (local[0] === 0x2e || local[local.length - 1] === 0x2e) return false;
    if (indexOfBytes(local, toBytes("..")) >= 0) return false;
    const labels = [];
    let start = 0;
    for (let i = 0; i <= domain.length; i++) {
      if (i === domain.length || domain[i] === 0x2e) {
        labels.push(domain.slice(start, i));
        start = i + 1;
      }
    }
    if (labels.length < 2) return false;
    for (let k = 0; k < labels.length - 1; k++) {
      const lab = labels[k];
      if (!(lab.length >= 1 && lab.length <= 63)) return false;
      if (lab[0] === 0x2d || lab[lab.length - 1] === 0x2d) return false;
      for (let i = 0; i < lab.length; i++) {
        if (!ALNUM.has(lab[i]) && lab[i] !== 0x2d) return false;
      }
    }
    const tld = labels[labels.length - 1];
    if (!(tld.length >= 2 && tld.length <= 24)) return false;
    for (let i = 0; i < tld.length; i++) if (!UPPER.has(tld[i]) && !LOWER.has(tld[i])) return false;
    return true;
  }

  function ipv4Ok(run) {
    const parts = [];
    let start = 0;
    for (let i = 0; i <= run.length; i++) {
      if (i === run.length || run[i] === 0x2e) {
        parts.push(run.slice(start, i));
        start = i + 1;
      }
    }
    if (parts.length !== 4) return false;
    for (const p of parts) {
      if (!(p.length >= 1 && p.length <= 3)) return false;
      for (let i = 0; i < p.length; i++) if (!DIGIT.has(p[i])) return false;
      if (p.length > 1 && p[0] === 0x30) return false;
      if (parseInt(ascii(p), 10) > 255) return false;
    }
    return true;
  }

  function usccOk(run) {
    if (run.length !== 18) return false;
    const text = ascii(run);
    for (const ch of text) if (USCC_CHARS.indexOf(ch) < 0) return false;
    let allDigits = true;
    for (let i = 0; i < run.length; i++) if (!DIGIT.has(run[i])) { allDigits = false; break; }
    if (allDigits) return false;
    const idx = [];
    for (const ch of text) idx.push(USCC_CHARS.indexOf(ch));
    let total = 0;
    for (let k = 0; k < 17; k++) total += USCC_WEIGHTS[k] * idx[k];
    return idx[17] === (31 - (total % 31)) % 31;
  }

  function plateAt(data, pos) {
    if (pos + 8 >= data.length) return 0;
    const lead = data[pos];
    if (!(lead >= 0xe4 && lead <= 0xe9)) return 0;
    if (!(data[pos + 1] >= 0x80 && data[pos + 1] <= 0xbf)) return 0;
    if (!(data[pos + 2] >= 0x80 && data[pos + 2] <= 0xbf)) return 0;
    if (!PLATE_LETTERS.has(data[pos + 3])) return 0;
    for (let k = 1; k <= 5; k++) if (!PLATE_TAIL.has(data[pos + 3 + k])) return 0;
    if (pos + 9 < data.length && ALNUM.has(data[pos + 9])) return 0;
    return 9;
  }

  function scanText(data) {
    const out = [];
    const n = data.length;

    // 邮箱
    let i = 0;
    while (i < n) {
      if (EMAIL_CHARS.has(data[i])) {
        let j = i;
        while (j < n && EMAIL_CHARS.has(data[j])) j++;
        const run = data.slice(i, j);
        let k = run.length;
        while (k > 0 && run[k - 1] === 0x2e) k--;
        if (k > 0 && k <= 64 && emailOk(run.slice(0, k))) out.push([T.EMAIL, i, k]);
        i = j;
      } else i++;
    }

    // IPv4
    i = 0;
    while (i < n) {
      if (IPV4_CHARS.has(data[i])) {
        let j = i;
        while (j < n && IPV4_CHARS.has(data[j])) j++;
        const run = data.slice(i, j);
        let k = run.length;
        while (k > 0 && run[k - 1] === 0x2e) k--;
        if (k > 0 && k <= 15 && ipv4Ok(run.slice(0, k))) out.push([T.IPV4, i, k]);
        i = j;
      } else i++;
    }

    // 统一社会信用代码
    i = 0;
    while (i < n) {
      const ch = String.fromCharCode(data[i]);
      if (USCC_CHARS.indexOf(ch) >= 0) {
        let j = i;
        while (j < n && USCC_CHARS.indexOf(String.fromCharCode(data[j])) >= 0) j++;
        const run = data.slice(i, j);
        if (run.length === 18 && usccOk(run)) out.push([T.USCC, i, 18]);
        i = j;
      } else i++;
    }

    // 车牌
    i = 0;
    while (i < n) {
      const ln = plateAt(data, i);
      if (ln) {
        out.push([T.PLATE, i, ln]);
        i += ln;
      } else i++;
    }

    return out;
  }

  /* ------------------------------------------------------------ 关键词 */
  const KEYWORDS = ["身份证", "银行卡", "手机号", "邮箱", "密码", "账号", "地址", "姓名"];

  function findKeywords(data) {
    const kbs = KEYWORDS.map((k) => toBytes(k));
    const hits = [];
    for (let pos = 0; pos < data.length; pos++) {
      for (let kid = 0; kid < kbs.length; kid++) {
        const kb = kbs[kid];
        if (pos + kb.length > data.length) continue;
        let ok = true;
        for (let k = 0; k < kb.length; k++) {
          if (data[pos + k] !== kb[k]) { ok = false; break; }
        }
        if (ok) {
          hits.push({ kid, start: pos, length: kb.length, end: pos + kb.length });
          break;
        }
      }
    }
    return hits;
  }

  /* ------------------------------------------------------------ 数字游程扫描 */
  function scanDigits(data, kws) {
    const spans = [];
    let active = false;
    let runStart = 0;
    let lastDigit = 0;
    let P = [];
    let P_hasx = false;
    let P_over = false;
    let S = [];
    let S_hasx = false;
    let S_over = false;
    let S_start = 0;
    let snap_valid = false;
    let snap_type = 0;
    let snap_start = 0;
    let snap_last = 0;

    function ctxHit(start) {
      if (!kws || !kws.length) return -1;
      let bestKid = -1;
      let bestEnd = -1;
      for (const kw of kws) {
        if (kw.kid > 2) continue;
        if (kw.end > start || start - kw.end > CTX_WINDOW) continue;
        if (kw.end > bestEnd) {
          bestKid = kw.kid;
          bestEnd = kw.end;
        }
      }
      return bestKid;
    }

    function close() {
      if (active && !P_over) {
        let t = classify(P, P_hasx, false);
        if (t === 0 && P.length >= 11 && P.length <= 19) {
          const kid = ctxHit(runStart);
          if (kid >= 0) t = looseType(P.length, kid);
        }
        if (t) spans.push({ type: t, start: runStart, length: lastDigit - runStart + 1 });
      }
      active = false;
      P = [];
      P_hasx = false;
      P_over = false;
      S = [];
      S_hasx = false;
      S_over = false;
      snap_valid = false;
    }

    for (let pos = 0; pos < data.length; pos++) {
      const ch = data[pos];
      if (ch >= 0x30 && ch <= 0x39) {
        const d = ch - 0x30;
        if (!active) {
          active = true;
          runStart = pos;
          P = [d];
          P_hasx = false;
          P_over = false;
          S = [d];
          S_hasx = false;
          S_over = false;
          S_start = pos;
          snap_valid = false;
        } else {
          // 影子游程
          if (!S_over) {
            if (!S.length) {
              S = [d];
              S_start = pos;
            } else if (S.length < 19) S.unshift(d);
            else S_over = true;
          }
          // 主游程
          if (!P_over) {
            if (P.length < 19) P.unshift(d);
            else {
              if (snap_valid) {
                spans.push({ type: snap_type, start: snap_start, length: snap_last - snap_start + 1 });
              }
              if (S_over) P_over = true;
              else {
                P = S.slice();
                runStart = S_start;
                P_hasx = S_hasx;
              }
              S = [d];
              S_hasx = false;
              S_over = false;
              S_start = pos;
              snap_valid = false;
            }
          }
        }
        lastDigit = pos;
      } else if (ch === SEP_SPACE || ch === SEP_DASH) {
        if (active) {
          const t = classify(P, P_hasx, P_over);
          snap_valid = t !== 0;
          snap_type = t;
          snap_start = runStart;
          snap_last = lastDigit;
          S = [];
          S_hasx = false;
          S_over = false;
        }
      } else if ((ch === CH_X_UPPER || ch === CH_X_LOWER) && active && !P_over && P.length === 17) {
        P.unshift(10);
        P_hasx = true;
        lastDigit = pos;
        if (!S_over && S.length === 17) {
          S.unshift(10);
          S_hasx = true;
        }
      } else {
        close();
      }
    }
    close();
    return spans;
  }

  /* ------------------------------------------------------------ L2b：词典实体层 */
  // 与 host/golden/entities.py 一致：硬截前 64 个姓（RTL 的姓氏表也是 64 项）
  const SURNAMES = (
    "王李张刘陈杨黄赵周吴徐孙朱马胡郭林何高梁郑罗宋谢唐韩曹许邓冯曾程蔡彭潘袁于董余苏叶" +
    "吕魏蒋田杜丁沈姜范江傅钟卢汪戴崔任陆廖姚方金邱夏谭韦贾邹石熊孟秦阎薛侯雷白龙段郝孔邵" +
    "史毛常万顾赖武康贺严尹钱施牛洪龚"
  ).slice(0, 64);
  const NAME_CUES = ["叫", "姓名", "联系人", "收件人", "户名", "本人", "给", "找", "致"];
  const NAME_TITLES = ["先生", "女士", "老师", "同学", "经理", "主任", "医生", "律师"];
  const ADDR_CUES = ["地址", "住址", "住在", "位于", "收货地址"];
  const ADDR_ANCHORS = ["省", "市", "区", "县", "路", "街", "号"];
  const ENTITY_CTX = 12;
  const ADDR_MIN = 6;
  const ADDR_MAX = 48;

  function cjkLen(data, i) {
    if (
      i + 2 < data.length &&
      data[i] >= 0xe4 && data[i] <= 0xe9 &&
      data[i + 1] >= 0x80 && data[i + 1] <= 0xbf &&
      data[i + 2] >= 0x80 && data[i + 2] <= 0xbf
    ) return 3;
    return 0;
  }

  function charAt(data, i) {
    return dec.decode(data.slice(i, i + 3));
  }

  function cueEnds(data, cues) {
    const ends = [];
    for (const cue of cues) {
      const cb = toBytes(cue);
      let start = 0;
      for (;;) {
        const k = indexOfBytesFrom(data, cb, start);
        if (k < 0) break;
        ends.push(k + cb.length);
        start = k + 1;
      }
    }
    return ends.sort((a, b) => a - b);
  }

  function indexOfBytesFrom(hay, needle, from) {
    outer: for (let i = from; i + needle.length <= hay.length; i++) {
      for (let k = 0; k < needle.length; k++) if (hay[i + k] !== needle[k]) continue outer;
      return i;
    }
    return -1;
  }

  function findNames(data) {
    const out = [];
    const cue = cueEnds(data, NAME_CUES);
    const n = data.length;
    let i = 0;
    while (i < n) {
      const cl = cjkLen(data, i);
      if (cl === 0 || SURNAMES.indexOf(charAt(data, i)) < 0) {
        i += 1;
        continue;
      }
      const titleOk =
        i + 9 <= n && NAME_TITLES.indexOf(charAt(data, i + 3) + charAt(data, i + 6)) >= 0;
      let cued = false;
      for (const e of cue) {
        if (e <= i && i - e <= ENTITY_CTX) { cued = true; break; }
      }
      if (!(cued || titleOk)) {
        i += 3;
        continue;
      }
      let ln = 3;
      while (ln < 9 && i + ln + 2 < n && cjkLen(data, i + ln)) ln += 3;
      if (ln >= 6 && ln <= 9) {
        out.push([i, ln]);
        i += ln;
      } else i += 3;
    }
    return out;
  }

  function findAddresses(data) {
    const out = [];
    const cue = cueEnds(data, ADDR_CUES);
    const anchors = ADDR_ANCHORS.map(toBytes);
    const n = data.length;
    let i = 0;
    while (i < n) {
      const cl = cjkLen(data, i);
      let start = false;
      if (cl) {
        if (ADDR_ANCHORS.indexOf(charAt(data, i)) >= 0) start = true;
        else {
          for (const e of cue) {
            if (e <= i && i - e <= ENTITY_CTX) { start = true; break; }
          }
        }
      }
      if (!start) {
        i += 1;
        continue;
      }
      let j = i;
      while (j < n) {
        if (cjkLen(data, j)) j += 3;
        else if (data[j] >= 0x30 && data[j] <= 0x39) j += 1;
        else break;
      }
      const ln = j - i;
      if (ln >= ADDR_MIN && ln <= ADDR_MAX) {
        const seg = data.slice(i, j);
        let hasAnchor = false;
        for (const a of anchors) if (indexOfBytes(seg, a) >= 0) { hasAnchor = true; break; }
        if (hasAnchor) out.push([i, ln]);
      }
      i = j > i ? j : i + 3;
    }
    return out;
  }

  /* ------------------------------------------------------------ 汇总与合并 */
  function scan(data) {
    const kws = findKeywords(data);
    const hits = [];
    for (const s of scanDigits(data, kws)) {
      hits.push({ end: s.start + s.length, pri: PRIORITY[s.type], span: s });
    }
    for (const [t, start, ln] of scanText(data)) {
      hits.push({ end: start + ln, pri: PRIORITY[t], span: { type: t, start, length: ln } });
    }
    hits.sort((a, b) => a.end - b.end || a.pri - b.pri);
    return hits.map((h) => h.span);
  }

  function scanWithEntities(data) {
    const l1 = scan(data);
    const ents = [];
    for (const [s, ln] of findNames(data)) ents.push({ type: T.NAME, start: s, length: ln });
    for (const [s, ln] of findAddresses(data)) ents.push({ type: T.ADDR, start: s, length: ln });
    const out = ents.filter((e) =>
      !l1.some((s) => s.start < e.start + e.length && e.start < s.start + s.length)
    );
    return l1.concat(out);
  }

  function merge(spans) {
    const ordered = spans
      .slice()
      .sort((a, b) => a.start - b.start || PRIORITY[a.type] - PRIORITY[b.type] || b.length - a.length);
    const out = [];
    let lastEnd = 0;
    for (const s of ordered) {
      if (s.start >= lastEnd) {
        out.push(s);
        lastEnd = s.start + s.length;
      }
    }
    return out;
  }

  function maskSpan(data, span) {
    const out = new Uint8Array(span.length);
    if (span.type === T.NAME) {
      const first = data[span.start];
      const lead = first >= 0xe0 ? 3 : first >= 0xc0 ? 2 : 1;
      const head = Math.min(lead, span.length);
      for (let i = 0; i < span.length; i++) out[i] = i < head ? data[span.start + i] : 0x2a;
      return out;
    }
    if (span.type === T.ADDR) {
      out.fill(0x2a);
      return out;
    }
    const keep = Math.min(4, span.length);
    for (let i = 0; i < span.length; i++) {
      const fromEnd = span.length - i;
      out[i] = fromEnd <= keep ? data[span.start + i] : 0x2a;
    }
    return out;
  }

  function redact(data, spans) {
    const merged = merge(spans);
    const masked = data.slice();
    const audits = [];
    const counters = {};
    merged.forEach((s, idx) => {
      const repl = maskSpan(data, s);
      masked.set(repl, s.start);
      counters[s.type] = (counters[s.type] || 0) + 1;
      audits.push({
        index: idx + 1,
        type: TYPE_NAMES[s.type],
        type_id: s.type,
        rule: RULE_IDS[s.type],
        token: TOKEN_NAMES[s.type],
        start: s.start,
        length: s.length,
        action: "mask",
        replacement: dec.decode(repl),
      });
    });
    return { masked, audits, merged };
  }

  /* 与 tools/serial_host.py:render_mask 一致：把逐字节掩码还原成"一个字符一个星"。 */
  function renderBoardMask(original, masked) {
    if (!original) return dec.decode(masked);
    const out = [];
    const star3 = toBytes("＊");
    const star2 = toBytes("×");
    const n = masked.length;
    let i = 0;
    while (i < n) {
      if (masked[i] !== 0x2a) {
        out.push(masked[i]);
        i += 1;
        continue;
      }
      let j = i;
      while (j < n && masked[j] === 0x2a) j++;
      const run = j - i;
      const lead = i < original.length ? original[i] : 0;
      if (lead >= 0xe0 && run % 3 === 0) {
        for (let k = 0; k < run / 3; k++) for (const b of star3) out.push(b);
      } else if (lead >= 0xc0 && lead < 0xe0 && run % 2 === 0) {
        for (let k = 0; k < run / 2; k++) for (const b of star2) out.push(b);
      } else {
        for (let k = 0; k < run; k++) out.push(0x2a);
      }
      i = j;
    }
    return dec.decode(new Uint8Array(out));
  }

  function countByType(audits) {
    const counts = {};
    for (const a of audits) counts[a.type] = (counts[a.type] || 0) + 1;
    return counts;
  }

  function analyze(text) {
    const data = toBytes(text);
    const spans = scanWithEntities(data);
    const { masked, audits, merged } = redact(data, spans);
    const counts = countByType(audits);
    const kws = findKeywords(data);
    let kwm = 0;
    for (const k of kws) kwm |= 1 << k.kid;
    return {
      bytes: data.length,
      maskedBytes: masked,
      masked: renderBoardMask(data, masked),
      spans: merged,
      audits,
      counts,
      n: audits.length,
      keywords: kws.map((k) => ({ kid: k.kid, name: KEYWORDS[k.kid], start: k.start })),
      kw: kws.length,
      kwm,
      source: "local",
    };
  }

  /* ------------------------------------------------------------ 分帧（与 serial_host 同步） */
  const FRAME_LIMIT = 56;
  const SENT_END = "。！？；!?;\n";
  const SOFT_END = "，,、：:）)";

  function nbytes(s) {
    return enc.encode(s).length;
  }

  function utf8Len(ch) {
    const cp = ch.codePointAt(0);
    return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
  }

  function splitLine(line, limit) {
    const pieces = [];
    let cur = "";
    let curBytes = 0;
    for (const ch of line) {
      cur += ch;
      curBytes += utf8Len(ch);
      if (SENT_END.indexOf(ch) >= 0 && curBytes >= limit / 2) {
        pieces.push(cur);
        cur = "";
        curBytes = 0;
      }
    }
    if (cur) pieces.push(cur);

    const out = [];
    for (const piece of pieces) {
      if (nbytes(piece) <= limit) {
        out.push(piece);
        continue;
      }
      let c = "";
      let cb = 0;
      for (const ch of piece) {
        const bl = utf8Len(ch);
        if (cb + bl > limit) {
          if (c) out.push(c);
          c = ch;
          cb = bl;
        } else {
          c += ch;
          cb += bl;
        }
        if (SOFT_END.indexOf(ch) >= 0 && cb >= limit / 2) {
          out.push(c);
          c = "";
          cb = 0;
        }
      }
      if (c) out.push(c);
    }
    return out;
  }

  /**
   * 把输入排成板子能吃的帧：每行一条自然帧（LF 边界），超长行按标点切到 <= 56 B。
   * endsLine 表示这一片是该行的最后一片（发送时补 LF）。
   */
  function splitFrames(text, limit) {
    const lim = limit || FRAME_LIMIT;
    const lines = String(text).split(/\r?\n/);
    const frames = [];
    for (let li = 0; li < lines.length; li++) {
      const line = lines[li];
      if (!line.length) {
        if (li < lines.length - 1) frames.push({ text: "", bytes: 0, endsLine: true, line: li });
        continue;
      }
      const pieces = splitLine(line, lim);
      pieces.forEach((p, pi) => {
        frames.push({ text: p, bytes: nbytes(p), endsLine: pi === pieces.length - 1, line: li });
      });
    }
    return frames;
  }

  return {
    analyze,
    splitFrames,
    renderBoardMask,
    scan,
    scanWithEntities,
    findKeywords,
    KEYWORDS,
    TYPE_NAMES,
    RULE_IDS,
    TOKEN_NAMES,
    PRIORITY,
    TYPE: T,
    FRAME_LIMIT,
  };
});
