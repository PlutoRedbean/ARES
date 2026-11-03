/**
 * 手势桥接 -> 页面的端到端观察器。
 *
 * 用 CDP 打开页面，轮询 window.__ARES__.snapshot，记录状态时间线，并在关键状态截图。
 * 需要先起好：静态服务（dist）、tools/gesture-bridge、带调试端口的 Chrome。
 *
 *   node tools/gesture-e2e.mjs [url] [seconds]
 */
import { writeFileSync } from 'node:fs';

const url = process.argv[2] ?? 'http://127.0.0.1:4173/?quality=low';
const seconds = Number(process.argv[3] ?? 16);
const port = process.env.ARES_CDP_PORT ?? '9222';

const list = await (await fetch('http://127.0.0.1:' + port + '/json/list')).json();
const page = list.find((target) => target.type === 'page');
if (!page) throw new Error('没有 page target');

const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, { once: true });
  ws.addEventListener('error', reject, { once: true });
});

let nextId = 0;
const pending = new Map();
ws.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  if (message.id === undefined) return;
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
  else entry.resolve(message.result);
});

function send(method, params) {
  const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params: params ?? {} }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

const PROBE = [
  '(() => {',
  '  const app = window.__ARES__;',
  '  if (!app) return JSON.stringify({ hasApp: false });',
  '  const snap = app.snapshot || {};',
  '  return JSON.stringify({',
  '    hasApp: true,',
  '    base: snap.base || null,',
  '    overlay: snap.overlay || null,',
  '    bridge: app.bridgeState || null,',
  '    serial: app.serialState || null,',
  '    gesture: (document.getElementById("gesture-name") || {}).textContent || null,',
  '    started: document.body.classList.contains("started"),',
  '    holdActive: (document.getElementById("hold-panel") || { classList: { contains: () => false } }).classList.contains("active"),',
  '    holdWidth: (document.getElementById("hold-fill") || { style: {} }).style.width || "0%",',
  '    holdHint: (document.getElementById("hold-hint") || {}).textContent || "",',
  '  });',
  '})()',
].join('\n');

const shots = new Map([
  ['COMPRESS', 'e2e-compress.png'],
  ['MODE_PLANET', 'e2e-planet.png'],
  ['MODE_DNA', 'e2e-dna.png'],
]);

await send('Page.enable');
await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', {
  width: 960,
  height: 540,
  deviceScaleFactor: 1,
  mobile: false,
});

const loaded = new Promise((resolve) => {
  const listener = (event) => {
    const message = JSON.parse(event.data);
    if (message.method === 'Page.loadEventFired') {
      ws.removeEventListener('message', listener);
      resolve();
    }
  };
  ws.addEventListener('message', listener);
});

await send('Page.navigate', { url });
await loaded;

const t0 = Date.now();
const seen = new Set();
const timeline = [];
let last = '';
const written = new Set();

for (;;) {
  const elapsed = (Date.now() - t0) / 1000;
  if (elapsed > seconds) break;

  const probe = await send('Runtime.evaluate', { expression: PROBE, returnByValue: true });
  let info;
  try {
    info = JSON.parse(probe.result.value);
  } catch {
    info = { hasApp: false };
  }

  const key = info.base + '/' + info.overlay + '/' + info.bridge;
  if (key !== last) {
    last = key;
    const line = {
      t: Number(elapsed.toFixed(2)),
      base: info.base,
      overlay: info.overlay,
      bridge: info.bridge,
      gesture: info.gesture,
    };
    timeline.push(line);
    console.log('  t=' + line.t.toFixed(2) + 's base=' + line.base + ' overlay=' + line.overlay +
      ' bridge=' + line.bridge + ' gesture=' + line.gesture);

    if (info.base && info.base !== 'READY') seen.add(info.base);
  }

  // 进度条可能在某次状态变化之后才长起来，所以每轮都看一眼
  {
    if (info.holdActive) {
      console.log('  hold ' + info.holdWidth + ' ' + (info.holdHint || ''));
    }
    if (info.holdActive && !written.has('e2e-hold.png') && parseFloat(info.holdWidth) > 15) {
      written.add('e2e-hold.png');
      const shot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
      writeFileSync('e2e-hold.png', Buffer.from(shot.data, 'base64'));
      console.log('  shot e2e-hold.png  width=' + info.holdWidth + '  hint=' + info.holdHint);
    }

    let file = shots.get(info.base);
    if (info.base === 'READY' && seen.size > 0) file = 'e2e-ready.png';
    if (file && !written.has(file)) {
      written.add(file);
      const shot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
      writeFileSync(file, Buffer.from(shot.data, 'base64'));
      console.log('  shot ' + file);
    }
  }

  await new Promise((resolve) => setTimeout(resolve, 200));
}

console.log('TIMELINE ' + JSON.stringify(timeline));
ws.close();
