/** 固定种子的伪随机，保证每次启动的粒子分布一致。 */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** 均匀采样球面方向。 */
export function randomDirection(rng: () => number, out: { x: number; y: number; z: number }): void {
  const u = rng() * 2 - 1;
  const theta = rng() * Math.PI * 2;
  const r = Math.sqrt(1 - u * u);
  out.x = Math.cos(theta) * r;
  out.y = u;
  out.z = Math.sin(theta) * r;
}
