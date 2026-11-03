import { describe, expect, it } from 'vitest';
import { StateMachine } from '../src/app/stateMachine';
import type { BaseState, StateEvent } from '../src/app/stateMachine';

function booted(): StateMachine {
  const sm = new StateMachine();
  sm.command('START');
  sm.update(2.6);
  return sm;
}

function bases(events: StateEvent[]): Array<[string, string]> {
  return events
    .filter((e): e is Extract<StateEvent, { type: 'base' }> => e.type === 'base')
    .map((e) => [e.from, e.to]);
}

describe('stateMachine', () => {
  it('S01 IDLE + FIST 忽略', () => {
    const sm = new StateMachine();
    const events = sm.command('FIST');
    expect(sm.base).toBe('IDLE');
    expect(events.some((e) => e.type === 'ignored')).toBe(true);
  });

  it('S02 READY + FIST -> COMPRESS', () => {
    const sm = booted();
    expect(sm.base).toBe('READY');
    const events = sm.command('FIST');
    expect(sm.base).toBe('COMPRESS');
    expect(bases(events)).toContainEqual(['READY', 'COMPRESS']);
  });

  it('S03 COMPRESS + MODE 先回 READY 再进入 MODE_PLANET', () => {
    const sm = booted();
    sm.command('FIST');
    const events = sm.command('MODE');
    expect(sm.base).toBe('MODE_PLANET');
    expect(bases(events)).toEqual([
      ['COMPRESS', 'READY'],
      ['READY', 'MODE_PLANET'],
    ]);
  });

  it('S04 COMPRESS + CONFIRM 退出压缩、播放确认、结束回 READY', () => {
    const sm = booted();
    sm.command('FIST');
    const events = sm.command('CONFIRM');
    expect(sm.base).toBe('READY');
    expect(sm.overlay).toBe('CONFIRM');
    expect(events.some((e) => e.type === 'overlayStart' && e.overlay === 'CONFIRM')).toBe(true);

    const done = sm.update(1.6);
    expect(sm.overlay).toBe('NONE');
    expect(sm.base).toBe('READY');
    expect(done.some((e) => e.type === 'overlayEnd' && e.overlay === 'CONFIRM')).toBe(true);
  });

  it('S05 MODE_PLANET + MODE -> MODE_DNA', () => {
    const sm = booted();
    sm.command('MODE');
    sm.command('MODE');
    expect(sm.base).toBe('MODE_DNA');
  });

  it('S06 MODE_SOC + MODE -> MODE_PLANET', () => {
    const sm = booted();
    sm.command('MODE');
    sm.command('MODE');
    sm.command('MODE');
    expect(sm.base).toBe('MODE_SOC');
    sm.command('MODE');
    expect(sm.base).toBe('MODE_PLANET');
  });

  it('S07 READY + MODE -> MODE_PLANET', () => {
    const sm = booted();
    const events = sm.command('MODE');
    expect(sm.base).toBe('MODE_PLANET');
    expect(events.some((e) => e.type === 'mode' && e.mode === 'MODE_PLANET')).toBe(true);
  });

  it('S08 BOOT 中收到 FIST 暂存，BOOT 结束后执行', () => {
    const sm = new StateMachine();
    sm.command('START');
    expect(sm.overlay).toBe('BOOT');
    sm.command('FIST');
    expect(sm.pendingCommand).toBe('FIST');
    expect(sm.base).toBe('IDLE');

    sm.update(2.6);
    expect(sm.overlay).toBe('NONE');
    expect(sm.base).toBe('COMPRESS');
    expect(sm.pendingCommand).toBeNull();
  });

  it('S09 ULTIMATE 中断 CONFIRM', () => {
    const sm = booted();
    sm.command('CONFIRM');
    expect(sm.overlay).toBe('CONFIRM');
    sm.command('ULTIMATE');
    expect(sm.overlay).toBe('ULTIMATE');
    expect(sm.base).toBe('READY');
  });

  it('S12 TRACK + POINT 只触发扫描脉冲，不重新进入', () => {
    const sm = booted();
    sm.command('POINT');
    expect(sm.base).toBe('TRACK');
    const events = sm.command('POINT');
    expect(bases(events)).toEqual([]);
    expect(events.some((e) => e.type === 'pulse' && e.kind === 'scan')).toBe(true);
    expect(sm.base).toBe('TRACK');
  });

  it('S13 READY + RESET -> IDLE', () => {
    const sm = booted();
    sm.command('RESET');
    expect(sm.base).toBe('IDLE');
    expect(sm.overlay).toBe('NONE');
  });

  it('START 可在任意状态重启开场', () => {
    const sm = booted();
    sm.command('FIST');
    sm.command('START');
    expect(sm.base).toBe('IDLE');
    expect(sm.overlay).toBe('BOOT');
    sm.update(2.6);
    expect(sm.base).toBe('READY');
  });

  it('ULTIMATE 期间只接受 RESET', () => {
    const sm = booted();
    sm.command('ULTIMATE');
    sm.command('FIST');
    expect(sm.overlay).toBe('ULTIMATE');
    expect(sm.base).toBe('READY');
    sm.command('RESET');
    expect(sm.base).toBe('IDLE');
    expect(sm.overlay).toBe('NONE');
  });

  it('ULTIMATE 结束回 READY', () => {
    const sm = booted();
    sm.command('ULTIMATE');
    sm.update(3.1);
    expect(sm.overlay).toBe('NONE');
    expect(sm.base).toBe('READY');
  });

  it('POINT 粘性保持；FIST 退出跟踪进入压缩', () => {
    const sm = booted();
    sm.command('POINT');
    expect(sm.base).toBe('TRACK');
    sm.command('FIST');
    expect(sm.base).toBe('COMPRESS');
  });

  it('状态转移表逐项验证', () => {
    const expectations: Array<[BaseState, string, BaseState]> = [
      ['READY', 'FIST', 'COMPRESS'],
      ['READY', 'POINT', 'TRACK'],
      ['READY', 'MODE', 'MODE_PLANET'],
      ['COMPRESS', 'POINT', 'TRACK'],
      ['COMPRESS', 'MODE', 'MODE_PLANET'],
      ['TRACK', 'FIST', 'COMPRESS'],
      ['TRACK', 'MODE', 'MODE_PLANET'],
      ['MODE_PLANET', 'FIST', 'COMPRESS'],
      ['MODE_DNA', 'POINT', 'TRACK'],
      ['MODE_SOC', 'FIST', 'COMPRESS'],
    ];

    for (const [start, command, expected] of expectations) {
      const sm = booted();
      // 先直达目标基础状态
      if (start.startsWith('MODE_')) {
        sm.command('MODE');
        if (start === 'MODE_DNA') sm.command('MODE');
        if (start === 'MODE_SOC') {
          sm.command('MODE');
          sm.command('MODE');
        }
      } else if (start === 'COMPRESS') {
        sm.command('FIST');
      } else if (start === 'TRACK') {
        sm.command('POINT');
      }
      expect(sm.base).toBe(start);
      sm.command(command as never);
      if (command === 'CONFIRM') continue;
      expect(sm.base).toBe(expected);
    }
  });

  it('IDLE 指令：手离开 -> 退出粘性状态回待机', () => {
    const sm = booted();
    sm.command('FIST');
    expect(sm.base).toBe('COMPRESS');
    const events = sm.command('IDLE');
    expect(sm.base).toBe('READY');
    expect(bases(events)).toContainEqual(['COMPRESS', 'READY']);
  });

  it('IDLE 指令：模式状态退出回待机', () => {
    const sm = booted();
    sm.command('MODE');
    expect(sm.base).toBe('MODE_PLANET');
    sm.command('IDLE');
    expect(sm.base).toBe('READY');
  });

  it('IDLE 在 ULTIMATE 期间不打断', () => {
    const sm = booted();
    sm.command('ULTIMATE');
    sm.command('IDLE');
    expect(sm.overlay).toBe('ULTIMATE');
    expect(sm.base).toBe('READY');
  });

  it('IDLE 在开场动画期间忽略，动画结束自然回 READY', () => {
    const sm = new StateMachine();
    sm.command('START');
    const events = sm.command('IDLE');
    expect(events.some((e) => e.type === 'ignored')).toBe(true);
    sm.update(2.6);
    expect(sm.base).toBe('READY');
  });

  it('IDLE 未启动时什么也不做', () => {
    const sm = new StateMachine();
    sm.command('IDLE');
    expect(sm.base).toBe('IDLE');
    expect(sm.overlay).toBe('NONE');
  });
});
