import * as THREE from 'three';
import { CONFIG } from '../config';
import { mulberry32 } from './random';

const LOGO_WORLD_WIDTH = 5.9;
const LOGO_CANVAS_WIDTH = 1600;
const LOGO_CANVAS_HEIGHT = 450;

function drawSpacedText(
  ctx: CanvasRenderingContext2D,
  text: string,
  centerX: number,
  centerY: number,
  spacing: number,
): void {
  const chars = [...text];
  const widths = chars.map((ch) => ctx.measureText(ch).width);
  const total = widths.reduce((sum, w) => sum + w, 0) + spacing * (chars.length - 1);
  let x = centerX - total / 2;
  for (let i = 0; i < chars.length; i += 1) {
    ctx.fillText(chars[i], x + widths[i] / 2, centerY);
    x += widths[i] + spacing;
  }
}

/** 图片加载失败时的兜底：纯文字 ARES + 框线。 */
function drawFallbackLogo(ctx: CanvasRenderingContext2D): void {
  ctx.fillStyle = '#fff';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.font = '900 300px "Arial Black", "Segoe UI Black", Arial, sans-serif';
  drawSpacedText(ctx, 'ARES', LOGO_CANVAS_WIDTH / 2, 220, 36);

  ctx.strokeStyle = '#fff';
  ctx.lineWidth = 4;
  ctx.beginPath();
  ctx.moveTo(250, 70);
  ctx.lineTo(1350, 70);
  ctx.moveTo(250, 400);
  ctx.lineTo(1350, 400);
  ctx.stroke();
}

/**
 * 把 ARES Logo 画到离屏画布，再按 alpha 采样成世界坐标点集。
 * Logo 实际图像来自 public/ares-logo.svg（圣盔 + 芯片 + 几何字标）。
 */
function sampleLogo(count: number, image: HTMLImageElement | null): Float32Array {
  const canvas = document.createElement('canvas');
  canvas.width = LOGO_CANVAS_WIDTH;
  canvas.height = LOGO_CANVAS_HEIGHT;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!ctx) return new Float32Array(count * 3);

  if (image) {
    ctx.drawImage(image, 0, 0, LOGO_CANVAS_WIDTH, LOGO_CANVAS_HEIGHT);
  } else {
    drawFallbackLogo(ctx);
  }

  const data = ctx.getImageData(0, 0, LOGO_CANVAS_WIDTH, LOGO_CANVAS_HEIGHT).data;
  const samples: number[] = [];
  const step = 2;
  const worldHeight = LOGO_WORLD_WIDTH * (LOGO_CANVAS_HEIGHT / LOGO_CANVAS_WIDTH);

  for (let y = 0; y < LOGO_CANVAS_HEIGHT; y += step) {
    for (let x = 0; x < LOGO_CANVAS_WIDTH; x += step) {
      const alpha = data[(y * LOGO_CANVAS_WIDTH + x) * 4 + 3];
      if (alpha > 100) {
        const wx = (x / LOGO_CANVAS_WIDTH - 0.5) * LOGO_WORLD_WIDTH;
        const wy = (0.5 - y / LOGO_CANVAS_HEIGHT) * worldHeight + 0.03;
        samples.push(wx, wy);
        // 左侧圣盔图标的线条比字标细，采样时加权，避免 3D 里糊成一团
        if (x >= 84 && x <= 380 && y >= 70 && y <= 365) {
          samples.push(wx, wy, wx, wy);
        }
      }
    }
  }

  const rng = mulberry32(0x5eed);
  const out = new Float32Array(count * 3);
  const sampleCount = samples.length / 2;

  if (sampleCount === 0) {
    return out;
  }

  for (let i = 0; i < count; i += 1) {
    const idx = Math.floor(rng() * sampleCount);
    out[i * 3] = samples[idx * 2] + (rng() - 0.5) * 0.004;
    out[i * 3 + 1] = samples[idx * 2 + 1] + (rng() - 0.5) * 0.004;
    out[i * 3 + 2] = (rng() - 0.5) * 0.07;
  }

  return out;
}

const VERTEX = /* glsl */ `
  uniform float uTime;
  uniform float uBoot;
  uniform float uMix;
  uniform float uExplode;
  uniform float uOpacity;
  uniform float uScale;
  uniform float uPixelRatio;
  uniform float uPointScale;
  uniform float uCharge;
  uniform float uFlash;
  uniform vec3 uColorA;
  uniform vec3 uColorB;

  attribute vec3 aFrom;
  attribute vec3 aLogo;
  attribute vec3 aSphere;
  attribute float aSeed;
  attribute float aSize;

  varying float vSeed;
  varying float vAlpha;
  varying float vRadius;
  varying vec3 vColor;

  mat2 rotate2d(float a) {
    float s = sin(a);
    float c = cos(a);
    return mat2(c, -s, s, c);
  }

  void main() {
    vec3 target = mix(aLogo, aSphere, uMix);
    vec3 pos = mix(aFrom, target, uBoot);

    // READY 态的呼吸浮动
    pos.y += sin(uTime * 0.9 + aSeed * 6.283) * 0.018 * uBoot * (1.0 - uMix);

    float radius = length(pos.xy);
    float chargeGlow = uCharge * smoothstep(2.4, 0.0, radius);
    pos.xz = rotate2d(uTime * 0.05 + uCharge * 0.25) * pos.xz;
    pos *= uScale * (1.0 + chargeGlow * 0.05);

    // 爆炸：径向速度 + 缓慢湍流
    vec3 dir = normalize(pos + vec3(0.0001, 0.0001, 0.0001));
    pos += dir * uExplode * (1.4 + aSeed * 5.2);
    pos += vec3(
      sin(uTime * 2.1 + aSeed * 17.0),
      cos(uTime * 1.7 + aSeed * 11.0),
      sin(uTime * 1.3 + aSeed * 7.0)
    ) * uExplode * 0.9;

    vec4 mv = modelViewMatrix * vec4(pos, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = aSize * uPixelRatio * (uPointScale / max(0.35, -mv.z)) * (1.0 + uExplode * 1.3);

    vSeed = aSeed;
    vRadius = radius;
    vAlpha = uOpacity * (0.72 + 0.28 * sin(uTime * 1.8 + aSeed * 30.0));
    vColor = mix(uColorA, uColorB, smoothstep(0.35, 0.98, aSeed));
  }
`;

const FRAGMENT = /* glsl */ `
  uniform vec3 uColorC;
  uniform float uCharge;
  uniform float uFlash;

  varying float vSeed;
  varying float vAlpha;
  varying float vRadius;
  varying vec3 vColor;

  void main() {
    vec2 p = gl_PointCoord - 0.5;
    float d = length(p);
    if (d > 0.5) discard;
    float core = 1.0 - smoothstep(0.02, 0.5, d);
    vec3 col = vColor;
    col = mix(col, uColorC, uCharge * smoothstep(1.9, 0.1, vRadius) * 0.85);
    col += uFlash * 0.6;
    gl_FragColor = vec4(col, core * vAlpha * 0.78);
  }
`;

export type LogoShape = 'logo' | 'sphere';

export class LogoParticles {
  readonly points: THREE.Points;
  private readonly material: THREE.ShaderMaterial;
  private readonly geometry: THREE.BufferGeometry;
  private readonly totalCount: number;

  private bootTime = 0;
  private booting = false;
  private time = 0;
  private mix = 0;
  private mixTarget = 0;
  private scale = 1;
  private scaleTarget = 1;
  private opacity = 0;
  private opacityTarget = 0;
  private charge = 0;
  private flash = 0;
  private explodeTime = -1;
  private explode = 0;
  private kick = 0;

  constructor(pixelRatio: number, logoImage: HTMLImageElement | null = null) {
    const count = CONFIG.visual.particleCount;
    this.totalCount = count;
    const rng = mulberry32(0x1a2b3c);
    const logo = sampleLogo(count, logoImage);
    const from = new Float32Array(count * 3);
    const sphere = new Float32Array(count * 3);
    const seeds = new Float32Array(count);
    const sizes = new Float32Array(count);
    const positions = new Float32Array(count * 3);
    const golden = Math.PI * (3 - Math.sqrt(5));

    for (let i = 0; i < count; i += 1) {
      // 开场前：屏幕外的大范围尘埃
      from[i * 3] = (rng() - 0.5) * 15;
      from[i * 3 + 1] = (rng() - 0.5) * 9;
      from[i * 3 + 2] = (rng() - 0.5) * 7 - 1.5;

      // 球面均匀采样
      const y = 1 - (i / Math.max(1, count - 1)) * 2;
      const r = Math.sqrt(Math.max(0, 1 - y * y));
      const theta = golden * i;
      const radius = 1.46 + rng() * 0.14;
      sphere[i * 3] = Math.cos(theta) * r * radius;
      sphere[i * 3 + 1] = y * radius;
      sphere[i * 3 + 2] = Math.sin(theta) * r * radius;

      positions[i * 3] = logo[i * 3];
      positions[i * 3 + 1] = logo[i * 3 + 1];
      positions[i * 3 + 2] = logo[i * 3 + 2];

      seeds[i] = rng();
      sizes[i] = 0.55 + rng() * 1.35;
    }

    this.geometry = new THREE.BufferGeometry();
    this.geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    this.geometry.setAttribute('aFrom', new THREE.BufferAttribute(from, 3));
    this.geometry.setAttribute('aLogo', new THREE.BufferAttribute(logo, 3));
    this.geometry.setAttribute('aSphere', new THREE.BufferAttribute(sphere, 3));
    this.geometry.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 1));
    this.geometry.setAttribute('aSize', new THREE.BufferAttribute(sizes, 1));
    this.geometry.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 40);

    this.material = new THREE.ShaderMaterial({
      vertexShader: VERTEX,
      fragmentShader: FRAGMENT,
      uniforms: {
        uTime: { value: 0 },
        uBoot: { value: 0 },
        uMix: { value: 0 },
        uExplode: { value: 0 },
        uOpacity: { value: 0 },
        uScale: { value: 1 },
        uPixelRatio: { value: pixelRatio },
        uPointScale: { value: 15.0 },
        uCharge: { value: 0 },
        uFlash: { value: 0 },
        uColorA: { value: new THREE.Color(CONFIG.colors.cyan) },
        uColorB: { value: new THREE.Color(CONFIG.colors.white) },
        uColorC: { value: new THREE.Color(CONFIG.colors.charge) },
      },
      transparent: true,
      depthWrite: false,
      depthTest: true,
      blending: THREE.AdditiveBlending,
    });

    this.points = new THREE.Points(this.geometry, this.material);
    this.points.frustumCulled = false;
    this.points.renderOrder = 10;
  }

  playBoot(): void {
    this.bootTime = 0;
    this.booting = true;
    this.mix = 0;
    this.mixTarget = 0;
    this.scale = 1;
    this.scaleTarget = 1;
    this.opacity = 1;
    this.opacityTarget = 1;
    this.charge = 0;
    this.explode = 0;
    this.explodeTime = -1;
  }

  enterIdle(): void {
    this.booting = false;
    this.bootTime = 0;
    this.material.uniforms.uBoot.value = 0;
    this.mix = 0;
    this.mixTarget = 0;
    this.scale = 0.7;
    this.scaleTarget = 0.7;
    this.opacity = 0.14;
    this.opacityTarget = 0.14;
    this.explode = 0;
    this.explodeTime = -1;
  }

  setShape(shape: LogoShape): void {
    if (shape === 'sphere') {
      this.mixTarget = 1;
      this.scaleTarget = 0.7;
    } else {
      this.mixTarget = 0;
      this.scaleTarget = 1;
    }
  }

  setOpacity(value: number): void {
    this.opacityTarget = value;
  }

  pulseCharge(): void {
    this.charge = 1;
    this.flash = 0.55;
    this.kick = 0.05;
  }

  pulseScan(): void {
    this.flash = 0.25;
  }

  explodeNow(): void {
    this.explodeTime = 0;
    this.explode = 0;
    this.mix = 0;
    this.mixTarget = 0;
    this.opacity = 1;
    this.opacityTarget = 1;
    this.scaleTarget = 1;
  }

  update(dt: number): void {
    this.time += dt;
    const u = this.material.uniforms;

    if (this.booting) {
      this.bootTime += dt;
      const p = Math.min(1, this.bootTime / CONFIG.timings.boot);
      const eased = 1 - Math.pow(1 - p, 3);
      u.uBoot.value = eased;
      this.flash = Math.max(this.flash, p > 0.94 ? 0.8 : 0);
      if (p >= 1) {
        this.booting = false;
        this.flash = 0.9;
      }
    }

    const mixK = 1 - Math.exp(-dt * 5.5);
    this.mix += (this.mixTarget - this.mix) * mixK;
    const scaleK = 1 - Math.exp(-dt * 4.5);
    this.scale += (this.scaleTarget - this.scale) * scaleK;
    const opacityK = 1 - Math.exp(-dt * 5);
    this.opacity += (this.opacityTarget - this.opacity) * opacityK;

    this.charge = Math.max(0, this.charge - dt * 1.6);
    this.flash = Math.max(0, this.flash - dt * 3.2);
    this.kick = Math.max(0, this.kick - dt * 0.6);

    if (this.explodeTime >= 0) {
      this.explodeTime += dt;
      const t = this.explodeTime;
      if (t < 0.3) {
        this.explode = Math.pow(t / 0.3, 1.6);
      } else if (t < 2.15) {
        this.explode = 1;
      } else if (t < 3.0) {
        this.explode = 1 - Math.pow((t - 2.15) / 0.85, 2.2);
      } else {
        this.explode = 0;
        this.explodeTime = -1;
      }
    }

    u.uTime.value = this.time;
    u.uMix.value = this.mix;
    u.uScale.value = this.scale + this.kick;
    u.uOpacity.value = this.opacity;
    u.uCharge.value = this.charge;
    u.uFlash.value = this.flash;
    u.uExplode.value = this.explode;

    this.points.position.y = Math.sin(this.time * 0.55) * 0.035 * (1 - this.mix);
    this.points.rotation.y = this.booting ? Math.sin(this.bootTime * 0.6) * 0.06 : 0;
  }

  setPixelRatio(pixelRatio: number): void {
    this.material.uniforms.uPixelRatio.value = pixelRatio;
  }

  /** 降画质时只绘制前一部分粒子，避免重建几何体。 */
  setParticleFraction(fraction: number): void {
    const f = Math.min(1, Math.max(0.1, fraction));
    this.geometry.setDrawRange(0, Math.max(400, Math.floor(this.totalCount * f)));
  }

  dispose(): void {
    this.geometry.dispose();
    this.material.dispose();
  }
}
