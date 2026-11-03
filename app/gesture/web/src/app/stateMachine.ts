import { CONFIG } from '../config';
import type { Command } from './commands';
import { nextMode } from './commands';

export type BaseState =
  | 'IDLE'
  | 'READY'
  | 'COMPRESS'
  | 'TRACK'
  | 'MODE_PLANET'
  | 'MODE_DNA'
  | 'MODE_SOC';

export type Overlay = 'NONE' | 'BOOT' | 'CONFIRM' | 'ULTIMATE';

export type ModeId = 'MODE_PLANET' | 'MODE_DNA' | 'MODE_SOC';

export type PulseKind = 'charge' | 'scan';

export type StateEvent =
  | { type: 'base'; from: BaseState; to: BaseState }
  | { type: 'overlayStart'; overlay: Overlay; duration: number }
  | { type: 'overlayEnd'; overlay: Overlay }
  | { type: 'pulse'; kind: PulseKind }
  | { type: 'mode'; mode: ModeId; cyclic: boolean }
  | { type: 'reset' }
  | { type: 'ignored'; command: Command; reason: string }
  | { type: 'pending'; command: Command };

export interface StateSnapshot {
  base: BaseState;
  overlay: Overlay;
  mode: ModeId | null;
  overlayProgress: number;
  pendingCommand: Command | null;
}

const MODE_STATES: ReadonlySet<BaseState> = new Set<BaseState>([
  'MODE_PLANET',
  'MODE_DNA',
  'MODE_SOC',
]);

/**
 * 纯逻辑状态机：基础状态 + 瞬时叠加层。
 * 不引用 DOM / Three.js，全部输出为 StateEvent，便于单测。
 */
export class StateMachine {
  base: BaseState = 'IDLE';
  overlay: Overlay = 'NONE';
  pendingCommand: Command | null = null;

  private overlayElapsed = 0;
  private overlayDuration = 0;

  get mode(): ModeId | null {
    return MODE_STATES.has(this.base) ? (this.base as ModeId) : null;
  }

  get overlayProgress(): number {
    if (this.overlay === 'NONE' || this.overlayDuration <= 0) return 0;
    return Math.min(1, this.overlayElapsed / this.overlayDuration);
  }

  get isBusy(): boolean {
    return this.overlay !== 'NONE';
  }

  snapshot(): StateSnapshot {
    return {
      base: this.base,
      overlay: this.overlay,
      mode: this.mode,
      overlayProgress: this.overlayProgress,
      pendingCommand: this.pendingCommand,
    };
  }

  /** 输入一条指令，返回本次产生的状态事件（按发生顺序）。 */
  command(cmd: Command): StateEvent[] {
    const events: StateEvent[] = [];
    this.handle(cmd, events);
    return events;
  }

  /** 推动叠加层计时；返回事件（可能包含暂存指令的执行结果）。 */
  update(dt: number): StateEvent[] {
    const events: StateEvent[] = [];
    if (this.overlay === 'NONE') return events;

    this.overlayElapsed += Math.max(0, dt);
    if (this.overlayElapsed + 1e-6 >= this.overlayDuration) {
      this.finishOverlay(events);
    }
    return events;
  }

  /** 开发/调试用：无动画直接复位。 */
  forceIdle(): void {
    this.overlay = 'NONE';
    this.overlayElapsed = 0;
    this.overlayDuration = 0;
    this.pendingCommand = null;
    this.base = 'IDLE';
  }

  private handle(cmd: Command, events: StateEvent[]): void {
    // 1) ULTIMATE 期间只接受 RESET
    if (this.overlay === 'ULTIMATE') {
      if (cmd === 'RESET') this.resetToIdle(events);
      else events.push({ type: 'ignored', command: cmd, reason: 'ultimate-lock' });
      return;
    }

    // 2) 全局复位
    if (cmd === 'RESET') {
      this.resetToIdle(events);
      return;
    }

    // 3) START 可随时重启开场
    if (cmd === 'START') {
      this.resetToIdle(events);
      this.startOverlay('BOOT', CONFIG.timings.boot, events);
      return;
    }

    // 3.5) 空画面：手离开取景框 -> 退出粘性状态，回到待机
    //      BOOT / CONFIRM 期间不打断（动画结束本来就会回 READY）
    if (cmd === 'IDLE') {
      if (this.overlay === 'BOOT' || this.overlay === 'CONFIRM') {
        events.push({ type: 'ignored', command: cmd, reason: 'overlay-busy' });
        return;
      }
      if (this.base === 'READY' || this.base === 'IDLE') {
        events.push({ type: 'ignored', command: cmd, reason: 'already-idle' });
        return;
      }
      this.exitToReady(events);
      return;
    }

    // 4) 未启动时忽略其他指令
    if (this.base === 'IDLE' && this.overlay === 'NONE') {
      events.push({ type: 'ignored', command: cmd, reason: 'idle' });
      return;
    }

    // 5) ULTIMATE 可打断 BOOT / CONFIRM
    if (cmd === 'ULTIMATE') {
      if (this.base !== 'READY') this.exitToReady(events);
      this.startOverlay('ULTIMATE', CONFIG.timings.ultimate, events);
      return;
    }

    // 6) 开场 / 确认动画期间只保留最后一条
    if (this.overlay === 'BOOT' || this.overlay === 'CONFIRM') {
      this.pendingCommand = cmd;
      events.push({ type: 'pending', command: cmd });
      return;
    }

    // 7) 粘性状态下的重复触发
    if (this.base === 'COMPRESS' && cmd === 'FIST') {
      events.push({ type: 'pulse', kind: 'charge' });
      return;
    }
    if (this.base === 'TRACK' && cmd === 'POINT') {
      events.push({ type: 'pulse', kind: 'scan' });
      return;
    }
    if (this.mode && cmd === 'MODE') {
      const next = nextMode(this.mode);
      this.setBase(next, events);
      events.push({ type: 'mode', mode: next, cyclic: true });
      return;
    }

    // 8) 其他指令：先退出当前粘性状态，再执行
    if (this.base !== 'READY') this.exitToReady(events);

    switch (cmd) {
      case 'FIST':
        this.setBase('COMPRESS', events);
        break;
      case 'POINT':
        this.setBase('TRACK', events);
        break;
      case 'MODE':
        this.setBase('MODE_PLANET', events);
        events.push({ type: 'mode', mode: 'MODE_PLANET', cyclic: false });
        break;
      case 'CONFIRM':
        this.startOverlay('CONFIRM', CONFIG.timings.confirm, events);
        break;
      default:
        break;
    }
  }

  private finishOverlay(events: StateEvent[]): void {
    const finished = this.overlay;
    this.overlay = 'NONE';
    this.overlayElapsed = 0;
    this.overlayDuration = 0;

    events.push({ type: 'overlayEnd', overlay: finished });
    this.setBase('READY', events);

    const pending = this.pendingCommand;
    this.pendingCommand = null;
    if (pending) {
      this.handle(pending, events);
    }
  }

  private startOverlay(overlay: Overlay, duration: number, events: StateEvent[]): void {
    if (this.overlay !== 'NONE') {
      events.push({ type: 'overlayEnd', overlay: this.overlay });
    }
    this.pendingCommand = null;
    this.overlay = overlay;
    this.overlayDuration = duration;
    this.overlayElapsed = 0;
    events.push({ type: 'overlayStart', overlay, duration });
  }

  private resetToIdle(events: StateEvent[]): void {
    if (this.overlay !== 'NONE') {
      events.push({ type: 'overlayEnd', overlay: this.overlay });
      this.overlay = 'NONE';
      this.overlayElapsed = 0;
      this.overlayDuration = 0;
    }
    this.pendingCommand = null;
    this.setBase('IDLE', events);
    events.push({ type: 'reset' });
  }

  private exitToReady(events: StateEvent[]): void {
    this.setBase('READY', events);
  }

  private setBase(to: BaseState, events: StateEvent[]): void {
    if (this.base === to) return;
    const from = this.base;
    this.base = to;
    events.push({ type: 'base', from, to });
  }
}
