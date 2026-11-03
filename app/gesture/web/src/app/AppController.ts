import {
  CONFIG,
  QUALITY_PRESETS,
  type QualityLevel,
  type QualityPreset,
} from '../config';
import { CommandBus, parseCommandLine, type Command, type CommandSource, type ParsedCommand } from './commands';
import { StateMachine, type StateEvent } from './stateMachine';
import { EffectDirector } from './EffectDirector';
import { Stage } from '../scene/Stage';
import { WebSerialLink, type SerialState } from '../serial/WebSerialLink';
import { BridgeLink, type BridgeState } from '../serial/BridgeLink';
import { describePort } from '../serial/serialTypes';
import type { ParsedLine } from '../serial/lineParser';
import { Synth } from '../audio/Synth';
import { Hud } from '../ui/Hud';
import { DebugPanel } from '../ui/DebugPanel';

const KEY_COMMANDS: Record<string, Command> = {
  '1': 'START',
  '2': 'FIST',
  '3': 'POINT',
  '4': 'MODE',
  '5': 'CONFIRM',
  '6': 'ULTIMATE',
  '0': 'RESET',
};

/** ?bridge=<端口>：指定手势桥接端口；?bridge=off 关闭；缺省用 CONFIG.bridge。 */
function resolveBridgePort(): number | null {
  if (typeof window === 'undefined') return null;
  const raw = new URLSearchParams(window.location.search).get('bridge');
  if (raw === null) return CONFIG.bridge.enabled ? CONFIG.bridge.port : null;
  const value = raw.trim().toLowerCase();
  if (value === '' || value === '0' || value === 'off' || value === 'false') return null;
  const port = Number(value);
  return Number.isFinite(port) && port > 0 && port < 65536 ? port : CONFIG.bridge.port;
}

const SERIAL_SHORT: Record<SerialState, string> = {
  unsupported: 'N/A',
  disconnected: 'OFF',
  connecting: 'WAIT',
  connected: 'OK',
  error: 'ERR',
};

export class AppController {
  private readonly stage: Stage;
  private readonly director: EffectDirector;
  private readonly stateMachine = new StateMachine();
  private readonly bus = new CommandBus();
  private readonly synth = new Synth();
  private readonly serial: WebSerialLink;
  private readonly bridge: BridgeLink | null;
  private bridgeStateValue: BridgeState = 'off';
  private bridgeWelcomed = false;
  private readonly hud: Hud;
  private readonly debug: DebugPanel;

  private raf = 0;
  private lastFrame = 0;
  private fps = 60;
  private fpsAccum = 0;
  private fpsFrames = 0;
  private lastHudSync = 0;
  private started = false;
  private qualityLevel: QualityLevel = 'high';
  private quality: QualityPreset = QUALITY_PRESETS.high;
  private perfTimer = 0;
  private demoTimers: number[] = [];
  private restartTimer = 0;

  constructor(canvas: HTMLCanvasElement, logoImage: HTMLImageElement | null = null) {
    this.stage = new Stage(canvas);
    this.stage.setPixelRatioCap(this.quality.pixelRatioMax);
    this.stage.setBloomScale(this.quality.bloomScale);
    this.director = new EffectDirector(this.stage, logoImage);
    this.director.setQuality(this.quality);

    this.hud = new Hud({
      onStart: (connectSerial, lowQuality) => this.startShow(connectSerial, true, lowQuality),
      onConnect: () => void this.reconnect(),
      onFullscreen: () => this.toggleFullscreen(),
      onMute: () => this.toggleMute(),
      onToggleDebug: () => this.toggleDebug(),
    });

    this.debug = new DebugPanel(document.getElementById('debug-root') ?? document.body, {
      onCommand: (text) => this.dispatchText(text),
      onReset: () => this.dispatch({ command: 'RESET' }, 'debug'),
      onReconnect: () => void this.reconnect(),
      onFullscreen: () => this.toggleFullscreen(),
      onToggleMute: () => this.toggleMute(),
      onToggleBloom: () => this.toggleBloom(),
      onCycleQuality: () => this.cycleQuality(),
      onClose: () => this.hud.setDebugActive(false),
    });

    this.serial = new WebSerialLink({
      onLine: (line) => this.handleSerialLine(line),
      onState: (state, detail) => this.handleSerialState(state, detail),
      onPort: (info) => this.hud.setPort(info ? describePort(info) : '—'),
      onLog: (message) => this.debug.log(message, 'event'),
    });

    const bridgePort = resolveBridgePort();
    this.bridge =
      bridgePort === null
        ? null
        : new BridgeLink({
            url: `http://127.0.0.1:${bridgePort}/events`,
            onLine: (text) => this.handleBridgeLine(text),
            onState: (state, detail) => this.handleBridgeState(state, detail),
          });
    if (this.bridge) {
      this.bridge.connect();
      this.debug.log(`手势桥接：${this.bridgeLabel}`, 'event');
    }

    this.hud.setParticles(CONFIG.visual.particleCount);
    this.hud.setFps(this.fps);
    this.hud.setPort('—');
    this.hud.setMuted(this.synth.isMuted);
    this.hud.sync(this.stateMachine.snapshot());
    this.debug.log('ARES 全息交互页就绪。键盘 1–6 / 0 可直接驱动。', 'event');
    this.debug.log('串口协议：ASCII 行、115200 8N1、\\n 结尾。', 'event');

    if (this.stage.isSoftwareRenderer) {
      this.setQuality('low', false);
      this.hud.setStartWarning(
        '检测到浏览器正在使用软件渲染（硬件加速可能已关闭），动画会明显卡顿。请开启 Chrome/Edge 的“使用图形加速”，或使用独立的浏览器配置启动。',
      );
      this.debug.log(`[gpu] 软件渲染：${this.stage.rendererName}`, 'error');
    } else {
      this.debug.log(`[gpu] ${this.stage.rendererName}`, 'event');
    }

    this.bindEvents();
    this.resize();
    if (!this.stage.isSoftwareRenderer) this.director.warmup();
    this.lastFrame = performance.now();
    this.raf = requestAnimationFrame(this.loop);
  }

  get serialState(): SerialState {
    return this.serial.currentState;
  }

  get bridgeState(): BridgeState {
    return this.bridgeStateValue;
  }

  get bridgeLabel(): string {
    return this.bridge ? `127.0.0.1:${this.bridgePort}` : 'off';
  }

  private get bridgePort(): number {
    return resolveBridgePort() ?? CONFIG.bridge.port;
  }

  get snapshot() {
    return this.stateMachine.snapshot();
  }

  get currentFps(): number {
    return this.fps;
  }

  get qualityLabel(): string {
    return this.quality.label;
  }

  startShow(connectSerial: boolean, requestFs = true, lowQuality = false): void {
    if (this.started) return;
    this.started = true;
    if (lowQuality) this.setQuality('low', false);
    this.hud.hideStart();
    this.synth.unlock();

    const connection = connectSerial ? this.serial.connect() : null;
    if (requestFs) this.requestFullscreen();
    if (this.stage.isSoftwareRenderer) {
      this.hud.toast('当前为软件渲染，动画可能卡顿；请开启浏览器硬件加速', 'error');
    }

    this.dispatch({ command: 'START' }, 'ui');
    if (connection) {
      connection.catch((error: unknown) => this.reportSerialFailure(error));
    }
  }

  async reconnect(): Promise<void> {
    this.synth.unlock();
    try {
      await this.serial.connect();
    } catch (error) {
      this.reportSerialFailure(error);
    }
  }

  toggleDebug(): void {
    this.debug.toggle();
    this.hud.setDebugActive(this.debug.isOpen);
  }

  openDebug(): void {
    if (!this.debug.isOpen) {
      this.debug.open();
      this.hud.setDebugActive(true);
    }
  }

  toggleMute(): void {
    this.synth.unlock();
    const muted = this.synth.toggleMute();
    this.hud.setMuted(muted);
    this.debug.log(muted ? '音频已静音' : '音频已开启', 'event');
  }

  toggleBloom(): void {
    const enabled = !this.stage.bloomIsEnabled;
    this.stage.setBloomEnabled(enabled);
    this.debug.log(`Bloom ${enabled ? 'ON' : 'OFF'}`, 'event');
    this.hud.toast(`Bloom ${enabled ? '已开启' : '已关闭'}`);
  }

  /** 手动 / 自动切换画质。改像素比、Bloom、粒子绘制数量，不重建场景。 */
  setQuality(level: QualityLevel, notify = true): void {
    this.qualityLevel = level;
    this.quality = QUALITY_PRESETS[level];
    this.stage.setPixelRatioCap(this.quality.pixelRatioMax);
    this.stage.setBloomScale(this.quality.bloomScale);
    this.stage.setBloomEnabled(this.quality.bloom);
    this.director.setQuality(this.quality);
    this.perfTimer = 0;
    this.resize();
    this.debug.log(`画质 → ${this.quality.label}`, 'event');
    if (notify) this.hud.toast(`画质：${this.quality.label}`);
    this.syncUi();
  }

  cycleQuality(): void {
    const order: QualityLevel[] = ['high', 'medium', 'low'];
    const index = order.indexOf(this.qualityLevel);
    this.setQuality(order[(index + 1) % order.length]);
  }

  toggleFullscreen(): void {
    if (document.fullscreenElement) {
      void document.exitFullscreen().catch(() => undefined);
    } else {
      this.requestFullscreen();
    }
  }

  /** 开发/演示用：固定节奏轮播全部效果。 */
  enableDemo(): void {
    if (this.demoTimers.length > 0) return;
    this.started = true;
    this.hud.hideStart();
    this.synth.unlock();
    this.debug.log('DEMO 模式：自动轮播', 'event');

    const script: Array<[number, Command]> = [
      [0, 'START'],
      [3100, 'FIST'],
      [5200, 'MODE'],
      [6500, 'MODE'],
      [7800, 'MODE'],
      [9200, 'POINT'],
      [11200, 'FIST'],
      [12700, 'CONFIRM'],
      [15200, 'ULTIMATE'],
      [19800, 'RESET'],
    ];

    for (const [delay, command] of script) {
      this.demoTimers.push(
        window.setTimeout(() => {
          this.dispatch({ command }, 'demo');
        }, delay),
      );
    }

    this.restartTimer = window.setTimeout(() => {
      this.demoTimers = [];
      this.enableDemo();
    }, 21400);
  }

  /** 截图/联调用的固定场景预设，例如 ?scene=planet。 */
  applyScenePreset(scene: string): void {
    this.started = true;
    this.hud.hideStart();
    this.synth.unlock();

    const send = (delay: number, command: Command): void => {
      this.demoTimers.push(window.setTimeout(() => this.dispatch({ command }, 'demo'), delay));
    };

    send(300, 'START');
    switch (scene) {
      case 'boot':
        break;
      case 'ready':
        break;
      case 'compress':
        send(3400, 'FIST');
        break;
      case 'track':
        send(3400, 'POINT');
        break;
      case 'planet':
        send(3400, 'MODE');
        break;
      case 'dna':
        send(3400, 'MODE');
        send(4700, 'MODE');
        break;
      case 'soc':
        send(3400, 'MODE');
        send(4700, 'MODE');
        send(6000, 'MODE');
        break;
      case 'confirm':
        send(3400, 'FIST');
        send(4600, 'CONFIRM');
        break;
      case 'ultimate':
        send(3400, 'ULTIMATE');
        break;
      case 'reset':
        send(3400, 'RESET');
        break;
      default:
        break;
    }
  }

  private bindEvents(): void {
    window.addEventListener('resize', this.resize);
    window.addEventListener('keydown', this.handleKeyDown);
    window.addEventListener('pointermove', this.handlePointerMove);
    window.addEventListener('beforeunload', this.handleUnload);
    document.addEventListener('fullscreenchange', this.handleFullscreenChange);
  }

  private requestFullscreen(): void {
    const target = document.documentElement;
    if (!document.fullscreenElement && target.requestFullscreen) {
      void target.requestFullscreen().catch(() => {
        this.hud.toast('浏览器阻止了全屏，可按 F11 手动进入全屏');
      });
    }
  }

  private reportSerialFailure(error: unknown): void {
    const message =
      error instanceof Error
        ? error.name === 'NotFoundError'
          ? '未选择串口；键盘与演示模式仍可用'
          : error.message
        : '串口连接失败';
    this.hud.toast(`串口连接失败：${message}`, 'error');
    this.debug.log(`[serial] 连接失败：${message}`, 'error');
  }

  private handleSerialState(state: SerialState, detail: string): void {
    this.hud.setSerialState(state, detail);
    if (state === 'connected') {
      this.hud.toast(`串口已连接 · ${detail.replace('已连接 ', '')}`);
    } else if (state === 'error') {
      this.hud.toast(detail, 'error');
    }
    this.debug.log(`[serial] ${detail}`, state === 'error' ? 'error' : 'event');
  }

  private handleSerialLine(line: ParsedLine): void {
    if (line.status === 'empty') {
      this.debug.log('空行 → 忽略', 'ignore');
      return;
    }
    if (line.status === 'too-long') {
      this.debug.log(`超长行 "${line.raw.slice(0, 40)}…" → 丢弃`, 'ignore');
      return;
    }
    if (line.status === 'non-ascii') {
      this.debug.log(`非 ASCII 行 "${line.raw.slice(0, 40)}" → 忽略`, 'ignore');
      return;
    }

    const message = parseCommandLine(line.text);
    if (!message) {
      this.debug.log(`${line.text} → 未知指令，已忽略`, 'ignore');
      return;
    }
    this.dispatch(message, 'serial', line.raw);
  }

  private handleBridgeLine(text: string): void {
    // HOLD 帧不是指令，是"手势保持进度 + 状态名"，只喂给 HUD 的进度条
    if (text.startsWith('HOLD')) {
      this.handleHoldLine(text);
      return;
    }
    const message = parseCommandLine(text);
    if (!message) {
      this.debug.log(`bridge「${text}」→ 未知指令，已忽略`, 'ignore');
      return;
    }
    this.dispatch(message, 'bridge', text);
  }


  /**
   * HOLD <状态名> <短按指令> <已保持ms> <短按阈值ms> <长按阈值ms> <长按指令>
   * HOLD off 表示松手。
   */
  private handleHoldLine(text: string): void {
    const parts = text.trim().split(/\s+/);
    if (parts.length < 7 || parts[1] === 'off') {
      this.hud.setHold(null);
      return;
    }
    this.hud.setHold({
      state: parts[1],
      short: parts[2] === '-' ? null : (parts[2] as Command),
      elapsed: Number(parts[3]) || 0,
      shortMs: Number(parts[4]) || 0,
      longMs: Number(parts[5]) || 1,
      long: parts[6] === '-' ? null : (parts[6] as Command),
    });
  }

  private handleBridgeState(state: BridgeState, detail: string): void {
    this.bridgeStateValue = state;
    if (state === 'online') {
      if (!this.bridgeWelcomed) {
        this.bridgeWelcomed = true;
        this.hud.toast(`手势桥接已连接 ${this.bridgeLabel}`, 'info');
      }
      this.debug.log(`手势桥接已连接 ${detail}`, 'ok');
    } else if (state === 'error') {
      this.debug.log(`手势桥接未连接 ${detail}（页面会自动重试）`, 'ignore');
    }
  }

  private dispatchText(text: string): void {
    const message = parseCommandLine(text);
    if (!message) {
      this.debug.log(`"${text}" → 未知指令`, 'ignore');
      this.hud.toast(`未知指令：${text}`, 'error');
      return;
    }
    this.dispatch(message, 'debug', text);
  }

  private dispatch(message: ParsedCommand, source: CommandSource, rawLine?: string): void {
    const { command } = message;
    const commandLabel =
      message.x !== undefined && message.y !== undefined
        ? `${command} ${message.x} ${message.y}`
        : command;
    if (command === 'POINT' && message.x !== undefined && message.y !== undefined) {
      this.director.setPointer(message.x, message.y);
    }
    // 空画面是"回待机"，不能在首屏还没点"启动演示"时把它顶掉
    if (command === 'IDLE' && !this.started) return;

    const decision = this.bus.push(message);
    if (!decision.accepted) {
      this.debug.log(
        `${commandLabel} → ${decision.cooldownRemainingMs} ms 冷却中，已忽略`,
        'ignore',
      );
      return;
    }

    if (!this.started) {
      this.started = true;
      this.hud.hideStart();
      this.synth.unlock();
    }

    this.hud.setGesture(command);
    const events = this.stateMachine.command(command);
    const snapshot = this.stateMachine.snapshot();
    const effective = events.some((event) => event.type !== 'ignored');

    this.director.handleEvents(events, snapshot);
    this.handleOverlayFeedback(events);
    this.playCommandSound(command, events);

    if (effective) {
      const raw = rawLine ? `「${rawLine.trim()}」 ` : '';
      this.debug.log(`${source} ${raw}${commandLabel} → ${this.describeEvents(events)}`, 'ok');
    } else {
      const reason = events.find((event) => event.type === 'ignored');
      const why =
        reason && reason.type === 'ignored'
          ? reason.reason === 'idle'
            ? '未启动（先 START）'
            : reason.reason === 'ultimate-lock'
              ? 'ULTIMATE 播放中'
              : reason.reason
          : '忽略';
      this.debug.log(`${source} ${commandLabel} → 忽略：${why}`, 'ignore');
    }

    this.syncUi();
  }

  private playCommandSound(command: Command, events: StateEvent[]): void {
    const ignoredOnly = events.length > 0 && events.every((event) => event.type === 'ignored');
    if (!ignoredOnly) this.synth.play(command);
    for (const event of events) {
      if (event.type === 'pulse') {
        this.synth.play(event.kind === 'charge' ? 'CHARGE' : 'SCAN');
      }
    }
  }

  private handleOverlayFeedback(events: StateEvent[]): void {
    for (const event of events) {
      if (event.type === 'overlayStart' && event.overlay === 'ULTIMATE') {
        this.hud.flash();
      }
      if (event.type === 'overlayStart' && event.overlay === 'CONFIRM') {
        this.hud.flashSoft();
      }
    }
  }

  private describeEvents(events: StateEvent[]): string {
    const parts: string[] = [];
    for (const event of events) {
      switch (event.type) {
        case 'base':
          parts.push(`${event.from}→${event.to}`);
          break;
        case 'overlayStart':
          parts.push(`▶${event.overlay}`);
          break;
        case 'overlayEnd':
          parts.push(`■${event.overlay}`);
          break;
        case 'pulse':
          parts.push(event.kind === 'charge' ? '蓄力脉冲' : '扫描脉冲');
          break;
        case 'mode':
          parts.push(`${event.mode}${event.cyclic ? '(循环)' : ''}`);
          break;
        case 'reset':
          parts.push('RESET');
          break;
        case 'pending':
          parts.push(`暂存 ${event.command}`);
          break;
        case 'ignored':
          parts.push(`忽略(${event.reason})`);
          break;
        default:
          break;
      }
    }
    return parts.join(' · ') || '—';
  }

  private handleKeyDown = (event: KeyboardEvent): void => {
    if (event.repeat || event.ctrlKey || event.metaKey || event.altKey) return;
    const target = event.target as HTMLElement | null;
    if (target) {
      const tag = target.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable) {
        return;
      }
    }

    const key = event.key.toLowerCase();
    const command = KEY_COMMANDS[key];
    if (command) {
      event.preventDefault();
      if (!this.started) {
        this.started = true;
        this.hud.hideStart();
        this.synth.unlock();
      }
      this.dispatch({ command }, 'keyboard');
      return;
    }

    if (key === 'd') {
      event.preventDefault();
      this.toggleDebug();
    } else if (key === 'f') {
      event.preventDefault();
      this.toggleFullscreen();
    } else if (key === 'm') {
      event.preventDefault();
      this.toggleMute();
    }
  };

  private handlePointerMove = (event: PointerEvent): void => {
    const nx = (event.clientX / window.innerWidth) * 2 - 1;
    const ny = -((event.clientY / window.innerHeight) * 2 - 1);
    this.stage.setPointerNormalized(nx, ny);

    if (event.altKey && this.stateMachine.base === 'TRACK') {
      const x = Math.round((event.clientX / window.innerWidth) * 1000);
      const y = Math.round((event.clientY / window.innerHeight) * 1000);
      this.director.setPointer(x, y);
    }
  };

  private handleUnload = (): void => {
    cancelAnimationFrame(this.raf);
    for (const timer of this.demoTimers) window.clearTimeout(timer);
    window.clearTimeout(this.restartTimer);
    this.serial.dispose();
    this.director.dispose();
    this.stage.dispose();
    window.removeEventListener('resize', this.resize);
    window.removeEventListener('keydown', this.handleKeyDown);
    window.removeEventListener('pointermove', this.handlePointerMove);
    window.removeEventListener('beforeunload', this.handleUnload);
    document.removeEventListener('fullscreenchange', this.handleFullscreenChange);
  };

  private handleFullscreenChange = (): void => {
    if (document.fullscreenElement) {
      this.debug.log('进入全屏', 'event');
    } else {
      this.debug.log('退出全屏', 'event');
    }
  };

  private resize = (): void => {
    const width = window.innerWidth;
    const height = window.innerHeight;
    const pixelRatio = window.devicePixelRatio || 1;
    const effectivePixelRatio = this.stage.resize(width, height, pixelRatio);
    this.director.resize(width, height, effectivePixelRatio);
  };

  private syncUi(): void {
    const snapshot = this.stateMachine.snapshot();
    this.hud.sync(snapshot);
    this.debug.update({
      base: snapshot.base,
      overlay: snapshot.overlay,
      mode: snapshot.mode ?? '—',
      fps: this.fps,
      particles: Math.round(CONFIG.visual.particleCount * this.quality.particleFraction),
      bloom: this.stage.bloomIsEnabled,
      serial: SERIAL_SHORT[this.serial.currentState],
      port: this.serial.portLabel,
      quality: this.quality.label,
    });
  }

  private loop = (now: number): void => {
    this.raf = requestAnimationFrame(this.loop);
    const rawDt = (now - this.lastFrame) / 1000;
    this.lastFrame = now;

    if (document.hidden) return;

    const dt = Math.min(Math.max(rawDt, 0), 0.05);

    const events = this.stateMachine.update(dt);
    if (events.length > 0) {
      const snapshot = this.stateMachine.snapshot();
      this.director.handleEvents(events, snapshot);
      this.handleOverlayFeedback(events);
      this.syncUi();
    }

    const snapshot = this.stateMachine.snapshot();
    this.director.update(dt, snapshot);
    this.stage.update(dt);
    this.stage.render();

    this.fpsAccum += rawDt;
    this.fpsFrames += 1;
    if (this.fpsAccum >= 0.5) {
      this.fps = this.fpsFrames / this.fpsAccum;
      this.hud.setFps(this.fps);
      this.fpsAccum = 0;
      this.fpsFrames = 0;

      // 自动降档：只在已经开始演示后观察，High → Medium → Low 各降一次
      if (this.started) {
        this.perfTimer += 0.5;
        if (this.perfTimer >= 2.5) {
          this.perfTimer = 0;
          if (this.fps < 50 && this.qualityLevel === 'high') {
            this.setQuality('medium');
          } else if (this.fps < 45 && this.qualityLevel === 'medium') {
            this.setQuality('low');
          }
        }
      }
    }

    if (now - this.lastHudSync > 250) {
      this.lastHudSync = now;
      this.syncUi();
    }
  };
}
