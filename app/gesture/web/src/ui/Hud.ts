import { COMMAND_META, MODE_LABELS, type Command } from '../app/commands';
import type { StateSnapshot } from '../app/stateMachine';
import type { SerialState } from '../serial/WebSerialLink';
import { getSerialApi } from '../serial/serialTypes';

export interface HoldState {
  /** 手势对应的状态名，例如「蓄力」 */
  state: string;
  /** 短按（进状态）触发的指令 */
  short: Command | null;
  /** 长按（第二招）触发的指令 */
  long: Command | null;
  elapsed: number;
  shortMs: number;
  longMs: number;
}

/** 基础状态的中文名：HUD 上不再直接显示 COMPRESS 这种内部枚举 */
const BASE_LABELS: Record<string, string> = {
  IDLE: '待机',
  READY: '就绪',
  COMPRESS: '蓄力',
  TRACK: '追踪',
  MODE_PLANET: '星球',
  MODE_DNA: '双螺旋',
  MODE_SOC: '芯片',
};

export interface HudCallbacks {
  onStart(connectSerial: boolean, lowQuality: boolean): void;
  onConnect(): void;
  onFullscreen(): void;
  onMute(): void;
  onToggleDebug(): void;
}

function byId<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`HUD 缺少元素 #${id}`);
  return node as T;
}

const OVERLAY_LABELS: Record<string, string> = {
  NONE: '—',
  BOOT: 'BOOT',
  CONFIRM: 'CONFIRM',
  ULTIMATE: 'ULTIMATE',
};

const SERIAL_LABELS: Record<SerialState, string> = {
  unsupported: '不支持 Web Serial',
  disconnected: '串口未连接',
  connecting: '连接中…',
  connected: '串口已连接',
  error: '串口异常',
};

export class Hud {
  private readonly startScreen = byId<HTMLElement>('start-screen');
  private readonly startButton = byId<HTMLButtonElement>('btn-start');
  private readonly plainButton = byId<HTMLButtonElement>('btn-start-plain');
  private readonly lowButton = byId<HTMLButtonElement>('btn-start-low');
  private readonly connectButton = byId<HTMLButtonElement>('btn-connect');
  private readonly fullscreenButton = byId<HTMLButtonElement>('btn-fullscreen');
  private readonly muteButton = byId<HTMLButtonElement>('btn-mute');
  private readonly debugButton = byId<HTMLButtonElement>('btn-debug');
  private readonly serialPill = byId<HTMLElement>('serial-pill');
  private readonly serialLabel = byId<HTMLElement>('serial-label');
  private readonly portState = byId<HTMLElement>('port-state');
  private readonly baseState = byId<HTMLElement>('base-state');
  private readonly overlayState = byId<HTMLElement>('overlay-state');
  private readonly modeState = byId<HTMLElement>('mode-state');
  private readonly gestureGlyph = byId<HTMLElement>('gesture-glyph');
  private readonly gestureName = byId<HTMLElement>('gesture-name');
  private readonly holdPanel = byId<HTMLElement>('hold-panel');
  private readonly holdState = byId<HTMLElement>('hold-state');
  private readonly holdFill = byId<HTMLElement>('hold-fill');
  private readonly holdHint = byId<HTMLElement>('hold-hint');
  private readonly holdMarkShort = byId<HTMLElement>('hold-mark-short');
  private readonly fps = byId<HTMLElement>('fps');
  private readonly particles = byId<HTMLElement>('particles');
  private readonly confirmPanel = byId<HTMLElement>('confirm-panel');
  private readonly flashLayer = byId<HTMLElement>('flash');
  private readonly toastElement = byId<HTMLElement>('toast');
  private readonly startNote = byId<HTMLElement>('start-note');
  private readonly modeItems = Array.from(document.querySelectorAll<HTMLElement>('#mode-list li'));

  private toastTimer = 0;
  private flashTimer = 0;

  constructor(callbacks: HudCallbacks) {
    this.startButton.addEventListener('click', () => callbacks.onStart(true, false));
    this.plainButton.addEventListener('click', () => callbacks.onStart(false, false));
    this.lowButton.addEventListener('click', () => callbacks.onStart(true, true));
    this.connectButton.addEventListener('click', () => callbacks.onConnect());
    this.fullscreenButton.addEventListener('click', () => callbacks.onFullscreen());
    this.muteButton.addEventListener('click', () => callbacks.onMute());
    this.debugButton.addEventListener('click', () => callbacks.onToggleDebug());

    if (!getSerialApi()) {
      this.connectButton.disabled = true;
      this.connectButton.title = '仅 Chrome / Edge 支持 Web Serial';
      this.startButton.querySelector('.start-btn-sub')!.textContent = 'FULLSCREEN · AUDIO · KEYBOARD';
      this.startNote.textContent =
        '当前浏览器不支持 Web Serial。请使用 Chrome / Edge，并通过 localhost 或 https 打开；仍可用键盘 1–6 进行调试。';
      this.setSerialState('unsupported', '当前浏览器不支持 Web Serial');
    }
  }

  hideStart(): void {
    this.startScreen.classList.add('hidden');
    document.body.classList.add('started');
  }

  /** 首屏显示性能警告（例如浏览器关闭了硬件加速）。 */
  setStartWarning(message: string): void {
    this.startNote.textContent = message;
    this.startNote.classList.add('warn');
  }

  get startVisible(): boolean {
    return !this.startScreen.classList.contains('hidden');
  }

  setSerialState(state: SerialState, detail: string): void {
    this.serialPill.dataset.state = state;
    this.serialPill.title = detail || SERIAL_LABELS[state];
    this.serialLabel.textContent = SERIAL_LABELS[state];

    if (state === 'connected') {
      this.connectButton.textContent = '已连接';
    } else if (state === 'connecting') {
      this.connectButton.textContent = '连接中…';
    } else {
      this.connectButton.textContent = '连接串口';
    }
  }

  setPort(label: string): void {
    this.portState.textContent = label;
    this.portState.title = label;
  }
  /**
   * 手势保持：状态名 + 进度条。短按阈值一道刻度，长按阈值满格。
   * 数据来自桥接器的 HOLD 帧（10 Hz），松手后传 null 收起。
   */
  setHold(state: HoldState | null): void {
    if (!state) {
      this.holdPanel.classList.remove('active', 'hot');
      this.holdPanel.setAttribute('aria-hidden', 'true');
      this.holdFill.style.width = '0%';
      return;
    }

    const total = Math.max(state.longMs, state.shortMs, 1);
    const ratio = Math.min(1, state.elapsed / total);
    const seconds = (state.elapsed / 1000).toFixed(1);
    const longSeconds = (state.longMs / 1000).toFixed(1);

    this.holdPanel.classList.add('active');
    this.holdPanel.classList.toggle('hot', state.elapsed >= state.longMs);
    this.holdPanel.setAttribute('aria-hidden', 'false');
    this.holdState.textContent = state.state;
    this.holdFill.style.width = (ratio * 100).toFixed(1) + '%';
    this.holdMarkShort.style.left = ((state.shortMs / total) * 100).toFixed(1) + '%';
    this.holdHint.textContent = seconds + 's / ' + longSeconds + 's';

    const shortLabel = state.short ? COMMAND_META[state.short].label : '—';
    const longLabel = state.long ? COMMAND_META[state.long].label : null;
    this.holdHint.title = longLabel
      ? state.state + '：' + shortLabel + ' → 长按 ' + longLabel
      : state.state + '：' + shortLabel;
  }

  setGesture(command: Command | null): void {
    if (!command) {
      this.gestureGlyph.textContent = '◇';
      this.gestureName.textContent = '等待指令';
      return;
    }
    const meta = COMMAND_META[command];
    this.gestureGlyph.textContent = meta.glyph;
    this.gestureName.textContent = `${meta.label} · ${command}`;
    this.gestureGlyph.classList.remove('pop');
    // 强制重排以重启动画
    void this.gestureGlyph.offsetWidth;
    this.gestureGlyph.classList.add('pop');
  }

  sync(snapshot: StateSnapshot): void {
    this.baseState.textContent = BASE_LABELS[snapshot.base] ?? snapshot.base;
    this.overlayState.textContent = OVERLAY_LABELS[snapshot.overlay] ?? snapshot.overlay;
    this.modeState.textContent = snapshot.mode ? MODE_LABELS[snapshot.mode] : '—';

    for (const item of this.modeItems) {
      item.classList.toggle('active', item.dataset.mode === snapshot.mode);
    }

    const confirming = snapshot.overlay === 'CONFIRM';
    this.confirmPanel.classList.toggle('active', confirming);
    this.confirmPanel.setAttribute('aria-hidden', confirming ? 'false' : 'true');
  }

  setFps(value: number): void {
    this.fps.textContent = `${Math.round(value)} FPS`;
  }

  setParticles(count: number): void {
    this.particles.textContent = `${count.toLocaleString('en-US')} P`;
  }

  flash(): void {
    this.flashLayer.classList.remove('on', 'soft');
    void this.flashLayer.offsetWidth;
    this.flashLayer.classList.add('on');
    window.clearTimeout(this.flashTimer);
    this.flashTimer = window.setTimeout(() => this.flashLayer.classList.remove('on'), 650);
  }

  /** CONFIRM 的轻闪光，避免全屏过曝。 */
  flashSoft(): void {
    this.flashLayer.classList.remove('on', 'soft');
    void this.flashLayer.offsetWidth;
    this.flashLayer.classList.add('soft', 'on');
    window.clearTimeout(this.flashTimer);
    this.flashTimer = window.setTimeout(() => {
      this.flashLayer.classList.remove('on', 'soft');
    }, 500);
  }

  toast(message: string, kind: 'info' | 'error' = 'info'): void {
    this.toastElement.textContent = message;
    this.toastElement.classList.toggle('error', kind === 'error');
    this.toastElement.classList.add('show');
    window.clearTimeout(this.toastTimer);
    this.toastTimer = window.setTimeout(() => this.toastElement.classList.remove('show'), 3600);
  }

  setMuted(muted: boolean): void {
    this.muteButton.textContent = muted ? '取消静音' : '静音';
    this.muteButton.classList.toggle('active', muted);
  }

  setDebugActive(active: boolean): void {
    this.debugButton.classList.toggle('active', active);
  }
}
