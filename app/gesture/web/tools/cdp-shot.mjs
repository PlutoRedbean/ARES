/**
 * 极简 CDP 截图工具（仅用于本地视觉验收，不参与构建）。
 * 用法：node tools/cdp-shot.mjs <url> <out.png> <waitMs> [--hide-start]
 * 需要先启动：chrome --headless=new --remote-debugging-port=9222 about:blank
 */
import { writeFileSync } from 'node:fs';

const [url, out, waitArg, ...flags] = process.argv.slice(2);
const waitMs = Number(waitArg ?? 5000);
const hideStart = flags.includes('--hide-start');

const cdpPort = process.env.ARES_CDP_PORT ?? '9222';
const versionResponse = await fetch(`http://127.0.0.1:${cdpPort}/json/list`);
const targets = await versionResponse.json();
const page = targets.find((target) => target.type === 'page');
if (!page) throw new Error('没有可用的 page target');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, { once: true });
  ws.addEventListener('error', reject, { once: true });
});

let nextId = 0;
const pending = new Map();
const events = [];
const consoleLines = [];
const listeners = new Set();

ws.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  if (message.id !== undefined) {
    const entry = pending.get(message.id);
    if (entry) {
      pending.delete(message.id);
      if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
      else entry.resolve(message.result);
    }
    return;
  }
  if (message.method === 'Runtime.consoleAPICalled') {
    const text = message.params.args
      .map((arg) => arg.value ?? arg.description ?? arg.type)
      .join(' ');
    consoleLines.push(`[console.${message.params.type}] ${text}`);
  } else if (message.method === 'Runtime.exceptionThrown') {
    const detail = message.params.exceptionDetails;
    consoleLines.push(
      `[exception] ${detail.text} ${detail.exception?.description ?? detail.exception?.value ?? ''}`,
    );
  } else if (message.method === 'Log.entryAdded') {
    consoleLines.push(`[log.${message.params.entry.level}] ${message.params.entry.text}`);
  }
  events.push(message);
  for (const listener of listeners) listener(message);
});

function send(method, params = {}) {
  const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

function waitForEvent(method, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      listeners.delete(listener);
      reject(new Error(`timeout waiting ${method}`));
    }, timeoutMs);
    const listener = (message) => {
      if (message.method === method) {
        clearTimeout(timer);
        listeners.delete(listener);
        resolve(message);
      }
    };
    listeners.add(listener);
  });
}

try {
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Log.enable');
  await send('Emulation.setDeviceMetricsOverride', {
    width: Number(process.env.ARES_WIDTH ?? 1600),
    height: Number(process.env.ARES_HEIGHT ?? 900),
    deviceScaleFactor: Number(process.env.ARES_DPR ?? 1),
    mobile: false,
  });

  const loaded = waitForEvent('Page.loadEventFired');
  await send('Page.navigate', { url });
  await loaded;

  if (hideStart) {
    await send('Runtime.evaluate', {
      expression: "document.getElementById('start-screen').style.display='none'",
    });
  }

  await new Promise((resolve) => setTimeout(resolve, waitMs));

  const state = await send('Runtime.evaluate', {
    expression: `(() => {
      try {
        const app = window.__ARES__;
        const canvas = document.getElementById('stage');
        const gl = canvas.getContext('webgl2');
        const ext = gl && gl.getExtension('WEBGL_debug_renderer_info');
        return JSON.stringify({
          hasApp: !!app,
          snapshot: app ? app.snapshot : null,
          fps: app ? app.currentFps : null,
          quality: app ? app.qualityLabel : null,
          serial: app ? app.serialState : null,
          renderer: ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : 'unknown',
          bodyStarted: document.body.classList.contains('started'),
          startHidden: document.getElementById('start-screen').classList.contains('hidden'),
          hudBase: document.getElementById('base-state').textContent,
          hudOverlay: document.getElementById('overlay-state').textContent,
        });
      } catch (error) {
        return JSON.stringify({ error: String(error) });
      }
    })()`,
    returnByValue: true,
  });
  console.log('STATE', state.result.value);

  const screenshot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
  writeFileSync(out, Buffer.from(screenshot.data, 'base64'));
  console.log('WROTE', out);
  if (consoleLines.length > 0) {
    console.log('CONSOLE');
    for (const line of consoleLines) console.log(' ', line);
  }
} finally {
  ws.close();
}
