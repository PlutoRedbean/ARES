import { CONFIG } from '../config';
import type { ModeId } from './stateMachine';

export const COMMANDS = [
  'START',
  'FIST',
  'POINT',
  'MODE',
  'CONFIRM',
  'ULTIMATE',
  'RESET',
  /** 空画面：手离开取景框，回到待机 */
  'IDLE',
] as const;

export type Command = (typeof COMMANDS)[number];

export type CommandKind = 'event' | 'sticky' | 'instant' | 'reset';

export interface CommandMeta {
  label: string;
  glyph: string;
  kind: CommandKind;
  hint: string;
}

export const COMMAND_META: Record<Command, CommandMeta> = {
  START: { label: '开场', glyph: '✳', kind: 'event', hint: '启动系统 / 粒子汇聚' },
  FIST: { label: '压缩', glyph: '◉', kind: 'sticky', hint: '能量压缩' },
  POINT: { label: '激光', glyph: '⌖', kind: 'sticky', hint: '激光跟踪 / 扫描' },
  MODE: { label: '换模型', glyph: '⬡', kind: 'sticky', hint: '切换全息模型' },
  CONFIRM: { label: '确认', glyph: '✓', kind: 'instant', hint: '确认 / 能量波' },
  ULTIMATE: { label: '爆发', glyph: '✹', kind: 'instant', hint: '终极爆发' },
  RESET: { label: '复位', glyph: '⟲', kind: 'reset', hint: '清空场景' },
  IDLE: { label: '空画面', glyph: '○', kind: 'event', hint: '手离开 → 回到待机' },
};

export interface ParsedCommand {
  command: Command;
  /** 预留 POINT x y，范围 0–1000 */
  x?: number;
  y?: number;
}

export type CommandSource = 'serial' | 'keyboard' | 'debug' | 'demo' | 'ui' | 'bridge';

const COMMAND_SET = new Set<string>(COMMANDS);

/**
 * 文本 -> 指令。大小写不敏感，容忍多余空白；未知指令返回 null。
 * 支持预留的 `POINT x y`（0–1000），坐标非法时退化为普通 POINT。
 */
export function parseCommandLine(text: string): ParsedCommand | null {
  const parts = text.trim().toUpperCase().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return null;

  const head = parts[0];
  if (!COMMAND_SET.has(head)) return null;
  const command = head as Command;

  if (command === 'POINT' && parts.length >= 3) {
    const x = Number(parts[1]);
    const y = Number(parts[2]);
    if (Number.isFinite(x) && Number.isFinite(y) && x >= 0 && x <= 1000 && y >= 0 && y <= 1000) {
      return { command, x, y };
    }
  }

  return { command };
}

export type DecisionReason = 'accepted' | 'cooldown';

export interface CommandDecision {
  accepted: boolean;
  reason: DecisionReason;
  command: Command;
  at: number;
  cooldownRemainingMs: number;
}

export interface CommandBusOptions {
  now?: () => number;
  /** 覆盖默认去重窗口，单位 ms */
  cooldowns?: Partial<Record<Command, number>>;
}

/**
 * 指令去重 / 冷却。同一条指令在冷却窗口内重复到达时只放行一次。
 * 冷却时间表见 CONFIG.serial.cooldowns。
 */
export class CommandBus {
  private readonly now: () => number;
  private readonly cooldowns: Record<Command, number>;
  private readonly lastAt = new Map<Command, number>();

  constructor(options: CommandBusOptions = {}) {
    this.now = options.now ?? (() => performance.now());
    this.cooldowns = { ...(CONFIG.serial.cooldowns as Record<Command, number>) };
    if (options.cooldowns) {
      for (const [cmd, ms] of Object.entries(options.cooldowns)) {
        if (typeof ms === 'number') this.cooldowns[cmd as Command] = ms;
      }
    }
  }

  push(message: ParsedCommand): CommandDecision {
    const at = this.now();
    const window = this.cooldowns[message.command] ?? CONFIG.serial.debounceMs;
    const last = this.lastAt.get(message.command);

    if (last !== undefined && at - last < window) {
      return {
        accepted: false,
        reason: 'cooldown',
        command: message.command,
        at,
        cooldownRemainingMs: Math.max(0, Math.round(window - (at - last))),
      };
    }

    this.lastAt.set(message.command, at);
    return {
      accepted: true,
      reason: 'accepted',
      command: message.command,
      at,
      cooldownRemainingMs: 0,
    };
  }

  reset(): void {
    this.lastAt.clear();
  }

  /** 调试面板用：某条指令剩余冷却时间 */
  remaining(command: Command): number {
    const last = this.lastAt.get(command);
    if (last === undefined) return 0;
    const window = this.cooldowns[command] ?? CONFIG.serial.debounceMs;
    return Math.max(0, Math.round(window - (this.now() - last)));
  }
}

const MODE_CYCLE: ModeId[] = ['MODE_PLANET', 'MODE_DNA', 'MODE_SOC'];

export function nextMode(current: ModeId): ModeId {
  const idx = MODE_CYCLE.indexOf(current);
  return MODE_CYCLE[(idx + 1) % MODE_CYCLE.length];
}

export const MODE_LABELS: Record<ModeId, string> = {
  MODE_PLANET: '星球',
  MODE_DNA: 'DNA 双螺旋',
  MODE_SOC: 'SoC 芯片',
};
