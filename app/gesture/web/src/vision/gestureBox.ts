/**
 * 绿框跟踪算法 —— 从 FPGA 固件的 mt_track.c 1:1 移植。
 *
 * 输入是一张 32×32 的灰度网格（板上由相机中心 640×480 按 2:1 降采样得到，
 * 网页里由 grabGrid() 从任意"给坐标取亮度"的函数采样得到）。
 *
 * 流程与固件完全一致：
 *   帧差 -> 8 连通域（面积≥3）-> 近邻合并（<5 格）->
 *   与上一帧关联（<12 格最近邻，3 帧确认）-> 中心/尺寸平滑 ->
 *   静止保持 -> 用"全网格均值 − 18"贴合整只手
 *
 * 参数一个都没改，改参数会让它和板上行为不一致。
 */

export const GRID = 32;
const MOTION_THRESHOLD = 12;
const MIN_BLOB_AREA = 3;
const MERGE_DIST = 5;
const ASSOC_RADIUS = 12;
const CONFIRM_HITS = 3;
const HOLD_FRAMES = 300;
const REFIT_DARK = 18;
const REFIT_MIN_AREA = 3;

export interface Track {
  used: boolean;
  confirmed: boolean;
  /** 中心，单位是网格格 */
  cx: number;
  cy: number;
  w: number;
  h: number;
  hits: number;
  misses: number;
  /** 静止保持了多少帧 */
  held: number;
}

interface Blob {
  cx: number;
  cy: number;
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

const emptyTrack = (): Track => ({
  used: false, confirmed: false, cx: 0, cy: 0, w: 0, h: 0,
  hits: 0, misses: 0, held: 0,
});

/** 每格取 4 个采样点求平均，与固件的 trk_grab 相同（4096 次读，而不是 76800）。 */
export function grabGrid(
  sample: (x: number, y: number) => number,
  srcW = 320,
  srcH = 240,
): Uint8Array {
  const out = new Uint8Array(GRID * GRID);

  for (let cy = 0; cy < GRID; cy += 1) {
    const y0 = Math.floor((cy * 15) / 2);           // 240 / 32 = 7.5 行
    for (let cx = 0; cx < GRID; cx += 1) {
      const x0 = cx * 10;                            // 320 / 32 = 10 列
      let sum = 0;
      for (let k = 0; k < 4; k += 1) {
        let x = x0 + ((k & 1) ? 7 : 2);
        let y = y0 + ((k & 2) ? 5 : 2);
        if (x > srcW - 1) x = srcW - 1;
        if (y > srcH - 1) y = srcH - 1;
        sum += sample(x, y);
      }
      out[cy * GRID + cx] = sum >> 2;
    }
  }
  return out;
}

export class GestureBoxTracker {
  private tracks: Track[] = Array.from({ length: 8 }, emptyTrack);
  private threshold = MOTION_THRESHOLD;
  private prev: Uint8Array | null = null;

  reset(): void {
    this.tracks = Array.from({ length: 8 }, emptyTrack);
    this.prev = null;
  }

  setThreshold(t: number): void {
    this.threshold = Math.min(200, Math.max(1, Math.trunc(t)));
  }

  /** 喂一帧 32×32 灰度，返回已确认的跟踪框（最多 4 个）。 */
  step(cur: Uint8Array): Track[] {
    const prev = this.prev ?? cur;
    const blobs = this.findBlobs(prev, cur);
    this.prev = cur.slice();

    for (const t of this.tracks) if (t.used) t.misses += 1;

    for (const b of blobs) {
      let best = -1;
      let bestD = ASSOC_RADIUS * ASSOC_RADIUS;
      this.tracks.forEach((t, i) => {
        if (!t.used) return;
        const dx = t.cx - b.cx;
        const dy = t.cy - b.cy;
        const d = dx * dx + dy * dy;
        if (d < bestD) { bestD = d; best = i; }
      });

      if (best < 0) {
        best = this.tracks.findIndex((t) => !t.used);
        if (best < 0) continue;
        const t = this.tracks[best];
        t.used = true;
        t.confirmed = false;
        t.cx = b.cx;
        t.cy = b.cy;
        t.w = b.x1 - b.x0 + 1;
        t.h = b.y1 - b.y0 + 1;
        t.hits = 1;
        t.misses = 0;
        t.held = 0;
      } else {
        const t = this.tracks[best];
        t.cx = (3 * t.cx + b.cx) >> 2;
        t.cy = (3 * t.cy + b.cy) >> 2;
        t.w = (3 * t.w + (b.x1 - b.x0 + 1)) >> 2;
        t.h = (3 * t.h + (b.y1 - b.y0 + 1)) >> 2;
        t.hits += 1;
        t.misses = 0;
      }
      if (this.tracks[best].hits >= CONFIRM_HITS) this.tracks[best].confirmed = true;
    }

    const out: Track[] = [];
    for (const t of this.tracks) {
      if (!t.used) continue;
      if (t.misses === 0) {
        t.held = 0;
      } else if (t.confirmed) {
        t.held += 1;
        if (t.held > HOLD_FRAMES) { t.used = false; continue; }
      } else if (t.misses > 5) {
        t.used = false;
        continue;
      }
      if (t.confirmed && out.length < 4) out.push({ ...t });
    }
    return out;
  }

  /** 用静止画面把框贴合到整只手（阈值取全网格均值，不能取窗口内均值）。 */
  refit(track: Track, grid: Uint8Array): void {
    let sum = 0;
    for (let i = 0; i < grid.length; i += 1) sum += grid[i];
    const mean = Math.trunc(sum / grid.length);
    const thr = Math.max(30, mean - REFIT_DARK);

    const wx0 = Math.max(0, track.cx - 9);
    const wy0 = Math.max(0, track.cy - 9);
    const wx1 = Math.min(GRID - 1, track.cx + 9);
    const wy1 = Math.min(GRID - 1, track.cy + 9);

    const seen = new Uint8Array(GRID * GRID);
    let bestArea = 0;
    let box = { x0: 0, y0: 0, x1: 0, y1: 0 };

    for (let y = wy0; y <= wy1; y += 1) {
      for (let x = wx0; x <= wx1; x += 1) {
        const start = y * GRID + x;
        if (seen[start] || grid[start] > thr) continue;

        const stack = [start];
        seen[start] = 1;
        let area = 0;
        let x0 = GRID;
        let y0 = GRID;
        let x1 = 0;
        let y1 = 0;

        while (stack.length) {
          const c = stack.pop() as number;
          const cx = c % GRID;
          const cy = (c / GRID) | 0;
          area += 1;
          if (cx < x0) x0 = cx;
          if (cx > x1) x1 = cx;
          if (cy < y0) y0 = cy;
          if (cy > y1) y1 = cy;

          for (let dy = -1; dy <= 1; dy += 1) {
            for (let dx = -1; dx <= 1; dx += 1) {
              const nx = cx + dx;
              const ny = cy + dy;
              if (nx < wx0 || ny < wy0 || nx > wx1 || ny > wy1) continue;
              const ni = ny * GRID + nx;
              if (!seen[ni] && grid[ni] <= thr) { seen[ni] = 1; stack.push(ni); }
            }
          }
        }

        if (area > bestArea) { bestArea = area; box = { x0, y0, x1, y1 }; }
      }
    }

    if (bestArea < REFIT_MIN_AREA) return;

    const ncx = (box.x0 + box.x1) >> 1;
    const ncy = (box.y0 + box.y1) >> 1;
    const nw = box.x1 - box.x0 + 1;
    const nh = box.y1 - box.y0 + 1;

    // 突然只剩一半大小是"只看到一部分"，不是手变小了：保留旧框
    if (nw * 2 < track.w || nh * 2 < track.h) return;

    track.cx = Math.trunc((track.cx * 2 + ncx) / 3);
    track.cy = Math.trunc((track.cy * 2 + ncy) / 3);
    track.w = Math.trunc((track.w * 2 + nw) / 3);
    track.h = Math.trunc((track.h * 2 + nh) / 3);
  }

  /** 框（含 10% 边距）按长边 letterbox 成 32×32，供分类器使用。 */
  patch(
    track: Track,
    sample: (x: number, y: number) => number,
    background = 0,
  ): { data: Uint8Array; edge: boolean } {
    const data = new Uint8Array(32 * 32);
    if (track.w <= 0 || track.h <= 0) return { data, edge: true };

    let x0 = (track.cx - (track.w >> 1)) * 10;
    let y0 = Math.trunc(((track.cy - (track.h >> 1)) * 15) / 2);
    const bw = track.w * 10;
    const bh = Math.trunc((track.h * 15) / 2);

    x0 -= Math.trunc(bw / 10);
    y0 -= Math.trunc(bh / 10);

    const side = Math.max(16, bw > bh ? bw : bh);
    const ox = x0 + (bw >> 1) - (side >> 1);
    const oy = y0 + (bh >> 1) - (side >> 1);
    const edge = ox < 0 || oy < 0 || ox + side > 320 || oy + side > 240;

    for (let j = 0; j < 32; j += 1) {
      const sy = oy + Math.trunc((j * side) / 32);
      for (let i = 0; i < 32; i += 1) {
        const sx = ox + Math.trunc((i * side) / 32);
        data[j * 32 + i] =
          sx < 0 || sy < 0 || sx > 319 || sy > 239 ? background : sample(sx, sy);
      }
    }
    return { data, edge };
  }

  private findBlobs(prev: Uint8Array, cur: Uint8Array): Blob[] {
    const mask = new Uint8Array(GRID * GRID);
    for (let i = 0; i < mask.length; i += 1) {
      const d = cur[i] - prev[i];
      mask[i] = (d < 0 ? -d : d) > this.threshold ? 1 : 0;
    }

    const seen = new Uint8Array(GRID * GRID);
    let blobs: Blob[] = [];

    for (let i = 0; i < mask.length; i += 1) {
      if (seen[i] || !mask[i]) continue;

      const stack = [i];
      seen[i] = 1;
      let area = 0;
      let sx = 0;
      let sy = 0;
      let x0 = GRID;
      let y0 = GRID;
      let x1 = 0;
      let y1 = 0;

      while (stack.length) {
        const c = stack.pop() as number;
        const cx = c % GRID;
        const cy = (c / GRID) | 0;
        area += 1;
        sx += cx;
        sy += cy;
        if (cx < x0) x0 = cx;
        if (cx > x1) x1 = cx;
        if (cy < y0) y0 = cy;
        if (cy > y1) y1 = cy;

        for (let dy = -1; dy <= 1; dy += 1) {
          for (let dx = -1; dx <= 1; dx += 1) {
            const nx = cx + dx;
            const ny = cy + dy;
            if (nx < 0 || ny < 0 || nx >= GRID || ny >= GRID) continue;
            const ni = ny * GRID + nx;
            if (!seen[ni] && mask[ni]) { seen[ni] = 1; stack.push(ni); }
          }
        }
      }

      if (area < MIN_BLOB_AREA) continue;
      blobs.push({ cx: Math.trunc(sx / area), cy: Math.trunc(sy / area), x0, y0, x1, y1 });
    }

    // 手指和手掌分开成两块时会互相抢同一个 track，先合并
    let merged = true;
    while (merged) {
      merged = false;
      outer: for (let i = 0; i < blobs.length; i += 1) {
        for (let j = i + 1; j < blobs.length; j += 1) {
          const dx = blobs[i].cx - blobs[j].cx;
          const dy = blobs[i].cy - blobs[j].cy;
          if (dx * dx + dy * dy > MERGE_DIST * MERGE_DIST) continue;
          blobs[i] = {
            cx: Math.trunc((blobs[i].cx + blobs[j].cx) / 2),
            cy: Math.trunc((blobs[i].cy + blobs[j].cy) / 2),
            x0: Math.min(blobs[i].x0, blobs[j].x0),
            y0: Math.min(blobs[i].y0, blobs[j].y0),
            x1: Math.max(blobs[i].x1, blobs[j].x1),
            y1: Math.max(blobs[i].y1, blobs[j].y1),
          };
          blobs.splice(j, 1);
          merged = true;
          break outer;
        }
      }
    }
    return blobs;
  }
}

/** 选最大的那个框（固件里就是这么定的"这是手"）。pct 是绿框相对跟踪框的放大百分比。 */
export function pickHand(tracks: Track[], pct = 130): Track | null {
  let best: Track | null = null;
  for (const t of tracks) {
    if (!best || t.w * t.h > best.w * best.h) best = t;
  }
  if (!best) return null;
  return {
    ...best,
    w: Math.trunc((best.w * pct) / 100),
    h: Math.trunc((best.h * pct) / 100),
  };
}
