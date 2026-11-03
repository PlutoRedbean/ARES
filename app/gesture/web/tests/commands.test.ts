import { describe, expect, it } from 'vitest';
import { CommandBus, parseCommandLine } from '../src/app/commands';

describe('parseCommandLine', () => {
  it('大小写与空白不敏感', () => {
    expect(parseCommandLine('  fist ')).toEqual({ command: 'FIST' });
    expect(parseCommandLine('ULTIMATE')).toEqual({ command: 'ULTIMATE' });
  });

  it('未知指令返回 null', () => {
    expect(parseCommandLine('HELLO')).toBeNull();
    expect(parseCommandLine('')).toBeNull();
  });

  it('预留 POINT x y 坐标，范围 0-1000', () => {
    expect(parseCommandLine('POINT 500 250')).toEqual({ command: 'POINT', x: 500, y: 250 });
    expect(parseCommandLine('POINT 1001 0')).toEqual({ command: 'POINT' });
    expect(parseCommandLine('POINT abc 0')).toEqual({ command: 'POINT' });
  });
});

describe('CommandBus 去重 / 冷却', () => {
  it('S10 300ms 内重复 MODE 只切换一次', () => {
    let now = 0;
    const bus = new CommandBus({ now: () => now, cooldowns: { MODE: 300 } });
    expect(bus.push({ command: 'MODE' }).accepted).toBe(true);
    now = 200;
    const second = bus.push({ command: 'MODE' });
    expect(second.accepted).toBe(false);
    expect(second.reason).toBe('cooldown');
    now = 500;
    expect(bus.push({ command: 'MODE' }).accepted).toBe(true);
  });

  it('S11 ULTIMATE 5s 内重复，第二次忽略', () => {
    let now = 0;
    const bus = new CommandBus({ now: () => now });
    expect(bus.push({ command: 'ULTIMATE' }).accepted).toBe(true);
    now = 4000;
    expect(bus.push({ command: 'ULTIMATE' }).accepted).toBe(false);
    now = 5001;
    expect(bus.push({ command: 'ULTIMATE' }).accepted).toBe(true);
  });

  it('不同指令互不影响', () => {
    let now = 0;
    const bus = new CommandBus({ now: () => now });
    expect(bus.push({ command: 'FIST' }).accepted).toBe(true);
    expect(bus.push({ command: 'POINT' }).accepted).toBe(true);
    expect(bus.push({ command: 'MODE' }).accepted).toBe(true);
  });

  it('默认 300ms 去重 + reset 清空历史', () => {
    let now = 0;
    const bus = new CommandBus({ now: () => now, cooldowns: { RESET: 300 } });
    expect(bus.push({ command: 'RESET' }).accepted).toBe(true);
    now = 100;
    expect(bus.push({ command: 'RESET' }).accepted).toBe(false);
    bus.reset();
    expect(bus.push({ command: 'RESET' }).accepted).toBe(true);
  });

  it('START 1s 冷却', () => {
    let now = 0;
    const bus = new CommandBus({ now: () => now, cooldowns: { START: 1000 } });
    expect(bus.push({ command: 'START' }).accepted).toBe(true);
    now = 900;
    expect(bus.push({ command: 'START' }).accepted).toBe(false);
    expect(bus.remaining('START')).toBe(100);
    now = 1000;
    expect(bus.push({ command: 'START' }).accepted).toBe(true);
  });
});
