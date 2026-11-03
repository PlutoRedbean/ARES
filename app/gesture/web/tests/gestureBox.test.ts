import { describe, expect, it } from 'vitest';
import { GRID, GestureBoxTracker, grabGrid, pickHand, type Track } from '../src/vision/gestureBox';

/** 与固件单测同样的五个场景：身份稳定、跟随、两个目标、碎片合并、离开后删除。 */

const blank = () => new Uint8Array(GRID * GRID).fill(100);

function square(cx: number, cy: number, r: number): Uint8Array {
  const g = blank();
  for (let y = cy - r; y <= cy + r; y += 1) {
    for (let x = cx - r; x <= cx + r; x += 1) {
      if (x >= 0 && y >= 0 && x < GRID && y < GRID) g[y * GRID + x] = 160;
    }
  }
  return g;
}

describe('gesture box tracker', () => {
  it('keeps one identity while a square moves', () => {
    const tr = new GestureBoxTracker();
    let last: Track[] = [];
    for (let f = 0; f < 12; f += 1) last = tr.step(square(6 + 2 * f, 10, 2));
    expect(last).toHaveLength(1);
    expect(last[0].cx).toBeGreaterThanOrEqual(20);
  });

  it('reports two tracks for two separated objects', () => {
    const tr = new GestureBoxTracker();
    let last: Track[] = [];
    for (let f = 0; f < 6; f += 1) {
      const g = blank();
      for (let y = 4; y <= 8; y += 1) {
        for (let x = 4 + f; x <= 8 + f; x += 1) g[y * GRID + x] = 160;
      }
      for (let y = 20; y <= 24; y += 1) {
        for (let x = 22 + f; x <= 26 + f; x += 1) g[y * GRID + x] = 160;
      }
      last = tr.step(g);
    }
    expect(last).toHaveLength(2);
  });

  it('merges fragments of one object', () => {
    const tr = new GestureBoxTracker();
    // 两片只隔 2 格（手指 + 手掌），并且真的在动，否则帧差为空、根本没有 blob
    const fragments = (shift: number) => {
      const g = blank();
      for (let y = 10; y <= 14; y += 1) {
        for (let x = 10 + shift; x <= 13 + shift; x += 1) g[y * GRID + x] = 160;
        for (let x = 16 + shift; x <= 18 + shift; x += 1) g[y * GRID + x] = 160;
      }
      return g;
    };
    let last: Track[] = [];
    for (let f = 0; f < 8; f += 1) last = tr.step(fragments(f % 2));
    expect(last).toHaveLength(1);
  });

  it('drops a track after the object leaves', () => {
    const tr = new GestureBoxTracker();
    for (let f = 0; f < 4; f += 1) tr.step(square(10 + f, 12, 3));
    let last: Track[] = [];
    for (let f = 0; f < 320; f += 1) last = tr.step(blank());
    expect(last).toHaveLength(0);
  });

  it('refits onto a bright-background hand instead of collapsing', () => {
    const tr = new GestureBoxTracker();
    for (let f = 0; f < 4; f += 1) tr.step(square(10 + f, 12, 3));

    const grid = blank().fill(150);
    for (let y = 10; y <= 16; y += 1) {
      for (let x = 12; x <= 19; x += 1) grid[y * GRID + x] = 60;
    }
    const track = { ...tr.step(blank())[0] };
    const before = track.w * track.h;
    tr.refit(track, grid);
    expect(track.w * track.h).toBeGreaterThanOrEqual(before / 2);
  });

  it('samples a 32x32 letterboxed patch', () => {
    const tr = new GestureBoxTracker();
    const track: Track = {
      used: true, confirmed: true, cx: 16, cy: 12, w: 8, h: 6,
      hits: 3, misses: 0, held: 0,
    };
    const { data, edge } = tr.patch(track, () => 77);
    expect(data).toHaveLength(32 * 32);
    expect(edge).toBe(false);
    expect(data.every((v) => v === 77)).toBe(true);
  });

  it('grabGrid averages four samples per cell', () => {
    const grid = grabGrid((x, y) => x + y);
    expect(grid).toHaveLength(GRID * GRID);
    expect(grid[0]).toBeGreaterThan(0);
  });

  it('pickHand expands the largest track', () => {
    const a: Track = { used: true, confirmed: true, cx: 5, cy: 5, w: 4, h: 4, hits: 3, misses: 0, held: 0 };
    const b: Track = { ...a, cx: 20, w: 10, h: 8 };
    const picked = pickHand([a, b], 130);
    expect(picked?.w).toBe(13);
    expect(picked?.h).toBe(10);
  });
});
