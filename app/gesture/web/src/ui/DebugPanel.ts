export type DebugLogKind = 'ok' | 'ignore' | 'error' | 'event';

export interface DebugStats {
  base: string;
  overlay: string;
  mode: string;
  fps: number;
  particles: number;
  bloom: boolean;
  serial: string;
  port: string;
  quality: string;
}

export interface DebugCallbacks {
  onCommand(text: string): void;
  onReset(): void;
  onReconnect(): void;
  onFullscreen(): void;
  onToggleMute(): void;
  onToggleBloom(): void;
  onCycleQuality(): void;
  onClose(): void;
}

/** 调试面板：最近 50 条原始行 / 解析结果 / 状态 / FPS，以及手工指令输入。 */
export class DebugPanel {
  private readonly panel: HTMLElement;
  private readonly logElement: HTMLElement;
  private readonly input: HTMLInputElement;
  private readonly stats: Record<string, HTMLElement>;
  private openState = false;
  private readonly maxEntries = 50;

  constructor(root: HTMLElement, private readonly callbacks: DebugCallbacks) {
    this.panel = document.createElement('section');
    this.panel.className = 'debug-panel hidden';
    this.panel.innerHTML = `
      <div class="debug-head">
        <span>DEBUG // 指令监视</span>
        <button type="button" class="js-close">关闭 ✕</button>
      </div>
      <div class="debug-stats">
        <div>STATE<b class="js-base">IDLE</b></div>
        <div>OVERLAY<b class="js-overlay">—</b></div>
        <div>MODE<b class="js-mode">—</b></div>
        <div>SERIAL<b class="js-serial">—</b></div>
        <div>PORT<b class="js-port">—</b></div>
        <div>FPS<b class="js-fps">--</b></div>
        <div>PARTICLES<b class="js-particles">--</b></div>
        <div>BLOOM<b class="js-bloom">ON</b></div>
        <div>QUALITY<b class="js-quality">HIGH</b></div>
      </div>
      <div class="debug-log js-log"></div>
      <div class="debug-input">
        <input class="js-input" type="text" spellcheck="false" autocomplete="off" placeholder="输入指令，如 FIST / POINT 500 250" />
        <button type="button" class="js-send">发送</button>
      </div>
      <div class="debug-actions">
        <button type="button" data-act="reset">复位</button>
        <button type="button" data-act="reconnect">重连</button>
        <button type="button" data-act="fullscreen">全屏</button>
        <button type="button" data-act="mute">静音</button>
        <button type="button" data-act="bloom">Bloom</button>
        <button type="button" data-act="quality">画质</button>
        <button type="button" data-act="clear">清空日志</button>
      </div>
    `;
    root.appendChild(this.panel);

    this.logElement = this.panel.querySelector<HTMLElement>('.js-log')!;
    this.input = this.panel.querySelector<HTMLInputElement>('.js-input')!;
    this.stats = {
      base: this.panel.querySelector<HTMLElement>('.js-base')!,
      overlay: this.panel.querySelector<HTMLElement>('.js-overlay')!,
      mode: this.panel.querySelector<HTMLElement>('.js-mode')!,
      serial: this.panel.querySelector<HTMLElement>('.js-serial')!,
      port: this.panel.querySelector<HTMLElement>('.js-port')!,
      fps: this.panel.querySelector<HTMLElement>('.js-fps')!,
      particles: this.panel.querySelector<HTMLElement>('.js-particles')!,
      bloom: this.panel.querySelector<HTMLElement>('.js-bloom')!,
      quality: this.panel.querySelector<HTMLElement>('.js-quality')!,
    };

    this.panel.querySelector('.js-close')!.addEventListener('click', () => this.close());
    this.panel.querySelector('.js-send')!.addEventListener('click', () => this.submit());
    this.input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        this.submit();
      }
    });

    for (const button of Array.from(this.panel.querySelectorAll<HTMLButtonElement>('[data-act]'))) {
      button.addEventListener('click', () => {
        switch (button.dataset.act) {
          case 'reset':
            this.callbacks.onReset();
            break;
          case 'reconnect':
            this.callbacks.onReconnect();
            break;
          case 'fullscreen':
            this.callbacks.onFullscreen();
            break;
          case 'mute':
            this.callbacks.onToggleMute();
            break;
          case 'bloom':
            this.callbacks.onToggleBloom();
            break;
          case 'quality':
            this.callbacks.onCycleQuality();
            break;
          case 'clear':
            this.clearLog();
            break;
          default:
            break;
        }
        button.blur();
      });
    }
  }

  get isOpen(): boolean {
    return this.openState;
  }

  open(): void {
    this.openState = true;
    this.panel.classList.remove('hidden');
    this.input.focus();
  }

  close(): void {
    this.openState = false;
    this.panel.classList.add('hidden');
    this.callbacks.onClose();
  }

  toggle(force?: boolean): boolean {
    const next = force ?? !this.openState;
    if (next) this.open();
    else this.close();
    return this.openState;
  }

  log(message: string, kind: DebugLogKind = 'event'): void {
    const entry = document.createElement('div');
    entry.className = `debug-entry ${kind}`;
    const time = document.createElement('span');
    time.className = 't';
    time.textContent = this.stamp();
    const text = document.createElement('span');
    text.className = 'msg';
    text.textContent = message;
    entry.append(time, text);
    this.logElement.appendChild(entry);
    while (this.logElement.childElementCount > this.maxEntries) {
      this.logElement.firstElementChild?.remove();
    }
    this.logElement.scrollTop = this.logElement.scrollHeight;
  }

  clearLog(): void {
    this.logElement.replaceChildren();
  }

  update(stats: DebugStats): void {
    this.stats.base.textContent = stats.base;
    this.stats.overlay.textContent = stats.overlay;
    this.stats.mode.textContent = stats.mode;
    this.stats.serial.textContent = stats.serial;
    this.stats.port.textContent = stats.port;
    this.stats.fps.textContent = `${Math.round(stats.fps)}`;
    this.stats.particles.textContent = String(stats.particles);
    this.stats.bloom.textContent = stats.bloom ? 'ON' : 'OFF';
    this.stats.quality.textContent = stats.quality;
  }

  private submit(): void {
    const value = this.input.value.trim();
    if (!value) return;
    this.callbacks.onCommand(value);
    this.input.value = '';
  }

  private stamp(): string {
    const now = new Date();
    const pad = (value: number, length = 2): string => String(value).padStart(length, '0');
    return `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}.${pad(now.getMilliseconds(), 3)}`;
  }
}
