import * as THREE from 'three';
import { CONFIG } from '../config';
import { mulberry32 } from './random';

function makeNebulaTexture(rgb: string): THREE.Texture {
  const size = 256;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (ctx) {
    const gradient = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    gradient.addColorStop(0, `rgba(${rgb}, 0.85)`);
    gradient.addColorStop(0.35, `rgba(${rgb}, 0.35)`);
    gradient.addColorStop(1, `rgba(${rgb}, 0)`);
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, size, size);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

const STAR_VERTEX = /* glsl */ `
  attribute float aSize;
  attribute float aSeed;
  attribute vec3 aColor;
  uniform float uTime;
  uniform float uOpacity;
  uniform float uPixelRatio;
  varying vec3 vColor;
  varying float vAlpha;

  void main() {
    vec3 pos = position;
    pos.y += sin(uTime * 0.07 + aSeed * 6.283) * 0.12;
    pos.x += cos(uTime * 0.05 + aSeed * 3.1) * 0.08;
    vec4 mv = modelViewMatrix * vec4(pos, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = aSize * uPixelRatio * (72.0 / max(6.0, -mv.z));
    vColor = aColor;
    vAlpha = uOpacity * (0.45 + 0.55 * (0.5 + 0.5 * sin(uTime * 0.9 + aSeed * 40.0)));
  }
`;

const STAR_FRAGMENT = /* glsl */ `
  varying vec3 vColor;
  varying float vAlpha;

  void main() {
    vec2 uv = gl_PointCoord - 0.5;
    float d = length(uv);
    if (d > 0.5) discard;
    float core = smoothstep(0.5, 0.0, d);
    float glow = pow(core, 3.0);
    gl_FragColor = vec4(vColor * (0.6 + glow), core * vAlpha);
  }
`;

export class Starfield {
  readonly group = new THREE.Group();
  private readonly stars: THREE.Points;
  private readonly starMaterial: THREE.ShaderMaterial;
  private readonly grid: THREE.PolarGridHelper;
  private readonly nebulaGroup = new THREE.Group();
  private readonly totalCount: number;

  constructor(pixelRatio: number) {
    const count = CONFIG.visual.starCount;
    this.totalCount = count;
    const rng = mulberry32(0xa2e5);
    const positions = new Float32Array(count * 3);
    const colors = new Float32Array(count * 3);
    const sizes = new Float32Array(count);
    const seeds = new Float32Array(count);

    const cyan = new THREE.Color(CONFIG.colors.cyan);
    const violet = new THREE.Color(CONFIG.colors.violet);
    const white = new THREE.Color(CONFIG.colors.white);

    for (let i = 0; i < count; i += 1) {
      const radius = 14 + rng() * 42;
      const u = rng() * 2 - 1;
      const theta = rng() * Math.PI * 2;
      const r = Math.sqrt(1 - u * u);
      positions[i * 3] = Math.cos(theta) * r * radius;
      positions[i * 3 + 1] = u * radius * 0.62;
      positions[i * 3 + 2] = Math.sin(theta) * r * radius - 8;

      const tint = rng();
      const color = tint < 0.62 ? white : tint < 0.84 ? cyan : violet;
      const dim = 0.2 + rng() * 0.5;
      colors[i * 3] = color.r * dim;
      colors[i * 3 + 1] = color.g * dim;
      colors[i * 3 + 2] = color.b * dim;

      sizes[i] = 0.4 + rng() * 1.1;
      seeds[i] = rng();
    }

    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geometry.setAttribute('aColor', new THREE.BufferAttribute(colors, 3));
    geometry.setAttribute('aSize', new THREE.BufferAttribute(sizes, 1));
    geometry.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 1));

    this.starMaterial = new THREE.ShaderMaterial({
      vertexShader: STAR_VERTEX,
      fragmentShader: STAR_FRAGMENT,
      uniforms: {
        uTime: { value: 0 },
        uOpacity: { value: 1 },
        uPixelRatio: { value: pixelRatio },
      },
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });

    this.stars = new THREE.Points(geometry, this.starMaterial);
    this.stars.frustumCulled = false;
    this.group.add(this.stars);

    const violetNebula = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: makeNebulaTexture('138, 92, 255'),
        color: CONFIG.colors.violet,
        transparent: true,
        opacity: 0.26,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
      }),
    );
    violetNebula.position.set(-11, 4, -24);
    violetNebula.scale.set(34, 22, 1);
    this.nebulaGroup.add(violetNebula);

    const cyanNebula = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: makeNebulaTexture('57, 230, 255'),
        color: CONFIG.colors.cyan,
        transparent: true,
        opacity: 0.18,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
      }),
    );
    cyanNebula.position.set(12, -5, -26);
    cyanNebula.scale.set(30, 20, 1);
    this.nebulaGroup.add(cyanNebula);

    this.group.add(this.nebulaGroup);

    this.grid = new THREE.PolarGridHelper(9, 12, 3, 64, 0x1c4a66, 0x0d2634);
    this.grid.position.set(0, -2.9, 0);
    const gridMaterial = this.grid.material as THREE.LineBasicMaterial;
    gridMaterial.transparent = true;
    gridMaterial.opacity = 0.26;
    gridMaterial.depthWrite = false;
    this.group.add(this.grid);
  }

  update(dt: number, elapsed: number): void {
    this.starMaterial.uniforms.uTime.value = elapsed;
    this.stars.rotation.y += dt * 0.008;
    this.nebulaGroup.rotation.y = Math.sin(elapsed * 0.02) * 0.04;
    this.nebulaGroup.position.y = Math.sin(elapsed * 0.11) * 0.15;
    const gridMaterial = this.grid.material as THREE.LineBasicMaterial;
    gridMaterial.opacity = 0.2 + Math.sin(elapsed * 0.6) * 0.05;
  }

  setPixelRatio(pixelRatio: number): void {
    this.starMaterial.uniforms.uPixelRatio.value = pixelRatio;
  }

  setParticleFraction(fraction: number): void {
    const f = Math.min(1, Math.max(0.1, fraction));
    this.stars.geometry.setDrawRange(0, Math.max(200, Math.floor(this.totalCount * f)));
  }

  dispose(): void {
    this.stars.geometry.dispose();
    this.starMaterial.dispose();
    for (const child of this.nebulaGroup.children) {
      const sprite = child as THREE.Sprite;
      sprite.material.map?.dispose();
      sprite.material.dispose();
    }
    this.grid.geometry.dispose();
    (this.grid.material as THREE.Material).dispose();
  }
}
