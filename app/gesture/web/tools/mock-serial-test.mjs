/**
 * 用 CDP 注入一个假的 Web Serial 端口，端到端验证：
 * 串口字节 -> 行解析 -> 指令去重 -> 状态机 -> HUD/场景。
 * 仅用于本地联调，不参与构建。
 */
const list = await (await fetch('http://127.0.0.1:9222/json/list')).json();
const page = list.find((target) => target.type === 'page');
if (!page) throw new Error('没有 page target');

const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, { once: true });
  ws.addEventListener('error', reject, { once: true });
});

let nextId = 0;
const pending = new Map();
const consoleLines = [];
ws.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  if (message.id !== undefined) {
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
    else entry.resolve(message.result);
    return;
  }
  if (message.method === 'Runtime.consoleAPICalled') {
    consoleLines.push(
      `[${message.params.type}] ${message.params.args.map((a) => a.value ?? a.description ?? '').join(' ')}`,
    );
  }
  if (message.method === 'Runtime.exceptionThrown') {
    consoleLines.push(`[exception] ${message.params.exceptionDetails.text}`);
  }
});

function send(method, params = {}) {
  const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails) {
    throw new Error(`evaluate failed: ${result.exceptionDetails.text}`);
  }
  return result.result.value;
}

async function snapshot() {
  return JSON.parse(
    await evaluate(`JSON.stringify({
      snapshot: window.__ARES__?.snapshot,
      serial: window.__ARES__?.serialState,
      fps: Math.round(window.__ARES__?.currentFps ?? 0),
      hudBase: document.getElementById('base-state')?.textContent,
      hudGesture: document.getElementById('gesture-name')?.textContent
    })`),
  );
}

const mockSerial = `(() => {
  let controller = null;
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(c) { controller = c; },
  });
  const port = {
    readable: stream,
    writable: null,
    async open() { window.__mockSerialOpen = true; },
    async close() { window.__mockSerialOpen = false; },
    getInfo() { return { usbVendorId: 0x1234, usbProductId: 0x5678 }; },
  };
  const api = {
    async getPorts() { return [port]; },
    async requestPort() { return port; },
    addEventListener() {},
    removeEventListener() {},
  };
  Object.defineProperty(navigator, 'serial', { value: api, configurable: true });
  window.__feedSerial = (text) => controller.enqueue(encoder.encode(text));
})();`;

const assertions = [];
function check(name, actual, expected) {
  const ok = actual === expected;
  assertions.push({ name, ok, actual, expected });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
}

try {
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: mockSerial });

  const targetUrl = process.env.ARES_URL ?? 'http://127.0.0.1:5173/?debug=1';
  await send('Page.navigate', { url: targetUrl });
  await wait(1800);

  await evaluate('window.__ARES__.startShow(true)');
  await wait(600);
  let state = await snapshot();
  check('串口连接状态', state.serial, 'connected');
  check('START 后进入 BOOT', state.snapshot.overlay, 'BOOT');

  // BOOT 中发 FIST：暂存
  await evaluate("window.__feedSerial('FIST\\n')");
  await wait(300);
  state = await snapshot();
  check('BOOT 中 FIST 暂存', state.snapshot.pendingCommand, 'FIST');
  await wait(2800);
  state = await snapshot();
  check('BOOT 结束执行 FIST', state.snapshot.base, 'COMPRESS');

  // MODE：退出压缩进入星球
  await evaluate("window.__feedSerial('MODE\\n')");
  await wait(400);
  state = await snapshot();
  check('FIST 后 MODE', state.snapshot.base, 'MODE_PLANET');

  await wait(600);
  await evaluate("window.__feedSerial('MODE\\n')");
  await wait(400);
  state = await snapshot();
  check('再次 MODE 循环到 DNA', state.snapshot.base, 'MODE_DNA');

  // POINT -> TRACK
  await evaluate("window.__feedSerial('POINT\\n')");
  await wait(400);
  state = await snapshot();
  check('POINT 进入 TRACK', state.snapshot.base, 'TRACK');

  // CONFIRM 瞬时
  await evaluate("window.__feedSerial('CONFIRM\\n')");
  await wait(300);
  state = await snapshot();
  check('CONFIRM 叠加层', state.snapshot.overlay, 'CONFIRM');
  await wait(1700);
  state = await snapshot();
  check('CONFIRM 结束回 READY', state.snapshot.base, 'READY');

  // 未知指令忽略
  await evaluate("window.__feedSerial('HELLO\\n')");
  await wait(300);
  state = await snapshot();
  check('未知指令不影响状态', state.snapshot.base, 'READY');

  // ULTIMATE 与 RESET
  await evaluate("window.__feedSerial('ULTIMATE\\n')");
  await wait(400);
  state = await snapshot();
  check('ULTIMATE 叠加层', state.snapshot.overlay, 'ULTIMATE');
  await evaluate("window.__feedSerial('RESET\\n')");
  await wait(300);
  state = await snapshot();
  check('ULTIMATE 中 RESET', state.snapshot.base, 'IDLE');

  // 键盘调试：1 = START（先让调试输入框失焦）
  await evaluate("document.activeElement && document.activeElement.blur()");
  await send('Input.dispatchKeyEvent', {
    type: 'keyDown',
    key: '1',
    code: 'Digit1',
    windowsVirtualKeyCode: 49,
    nativeVirtualKeyCode: 49,
    text: '1',
  });
  await send('Input.dispatchKeyEvent', {
    type: 'keyUp',
    key: '1',
    code: 'Digit1',
    windowsVirtualKeyCode: 49,
    nativeVirtualKeyCode: 49,
  });
  await wait(300);
  state = await snapshot();
  check('键盘 1 触发 START', state.snapshot.overlay, 'BOOT');

  await wait(2700);
  await send('Input.dispatchKeyEvent', {
    type: 'keyDown',
    key: '2',
    code: 'Digit2',
    windowsVirtualKeyCode: 50,
    nativeVirtualKeyCode: 50,
    text: '2',
  });
  await wait(250);
  state = await snapshot();
  check('键盘 2 触发 FIST', state.snapshot.base, 'COMPRESS');
  check('HUD 手势同步', state.hudGesture, '握拳 · FIST');

  const screenshot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
  const { mkdirSync, writeFileSync } = await import('node:fs');
  mkdirSync('shots', { recursive: true });
  writeFileSync('shots/cdp-serial-test.png', Buffer.from(screenshot.data, 'base64'));

  const failed = assertions.filter((item) => !item.ok);
  console.log(`\n${assertions.length - failed.length}/${assertions.length} 通过`);
  if (consoleLines.length > 0) {
    console.log('CONSOLE');
    for (const line of consoleLines.slice(-30)) console.log(' ', line);
  }
  if (failed.length > 0) process.exitCode = 1;
} finally {
  ws.close();
}
