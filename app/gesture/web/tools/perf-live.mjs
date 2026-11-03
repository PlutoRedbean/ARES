/**
 * 在已打开的可见 Chrome（远程调试 9223）里测量真实 rAF 帧间隔。
 * 用法：先启动 chrome --remote-debugging-port=9223 --app="http://127.0.0.1:4173/?scene=planet"
 *      node tools/perf-live.mjs [sampleMs]
 */
const list = await (await fetch('http://127.0.0.1:9223/json/list')).json();
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

function send(method, params = {}) {
  const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

const sampleMs = Number(process.argv[2] ?? 5000);
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

await send('Runtime.enable');
await wait(2500);

const expression = `new Promise((resolve) => {
  const start = performance.now();
  let last = start;
  let frames = 0;
  const gaps = [];
  function tick(t) {
    frames += 1;
    gaps.push(t - last);
    last = t;
    if (t - start < ${sampleMs}) {
      requestAnimationFrame(tick);
    } else {
      gaps.sort((a, b) => a - b);
      const canvas = document.getElementById('stage');
      resolve(JSON.stringify({
        fps: frames / ((performance.now() - start) / 1000),
        p50: gaps[Math.floor(gaps.length * 0.5)],
        p95: gaps[Math.floor(gaps.length * 0.95)],
        max: gaps[gaps.length - 1],
        dpr: devicePixelRatio,
        inner: [innerWidth, innerHeight],
        canvas: canvas ? [canvas.width, canvas.height] : null,
        quality: window.__ARES__ ? window.__ARES__.qualityLabel : null,
        appFps: window.__ARES__ ? window.__ARES__.currentFps : null,
        hidden: document.hidden,
      }));
    }
  }
  requestAnimationFrame(tick);
})`;

const result = await send('Runtime.evaluate', {
  expression,
  awaitPromise: true,
  returnByValue: true,
});
console.log(result.result.value ?? JSON.stringify(result));
ws.close();
