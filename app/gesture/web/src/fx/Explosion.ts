import * as THREE from 'three';
import { CONFIG } from '../config';
import { mulberry32, randomDirection } from '../scene/random';

const VERTEX = /* glsl */ `
  uniform float uTime;
  uniform float uPixelRatio;
  uniform float uOpacity;
  attribute vec3 aDir;
  attribute float aSpeed;
  attribute float aSeed;
  varying float vSeed;
  varying float vLife;

  void main() {
    float t = uTime;
    // 阻尼运动：快速冲出后减速
    float damp = (1.0 - exp(-t * 1.5)) / 1.5;
    vec3 pos = aDir * aSpeed * damp;
    pos.x += sin(t * 2.1 + aSeed * 12.0) * 0.35;
    pos.y += cos(t * 1.6 + aSeed * 9.0) * 0.35 - 0.22 * t * t;
    pos.z += sin(t * 1.9 + aSeed * 7.0) * 0.35;

    vec4 mv = modelViewMatrix * vec4(pos, 1.0);
    gl_Position = projectionMatrix * mv;
    float fade = 1.0 - smoothstep(1.8, 3.0, t);
    gl_PointSize = (0.9 + aSeed * 2.2) * uPixelRatio * (18.0 / max(0.5, -mv.z)) * fade;
    vSeed = aSeed;
    vLife = fade * uOpacity;
  }
`;

const FRAGMENT = /* glsl */ `
  uniform vec3 uColorA;
  uniform vec3 uColorB;
  uniform vec3 uColorC;
  varying float vSeed;
  varying float vLife;

  void main() {
    vec2 p = gl_PointCoord - 0.5;
    float d = length(p);
    if (d > 0.5) discard;
    float core = 1.0 - smoothstep(0.0, 0.5, d);
    vec3 col = mix(uColorA, uColorB, smoothstep(0.2, 0.85, vSeed));
    col = mix(col, uColorC, smoothstep(0.75, 0.95, vSeed));
    gl_FragColor = vec4(col, core * vLife);
  }
`;

export class Explosion {
  readonly group = new THREE.Group();
  private readonly points: THREE.Points;
  private readonly material: THREE.ShaderMaterial;
  private readonly geometry: THREE.BufferGeometry;
  private readonly shock: THREE.LineSegments;
  private readonly shockMaterial: THREE.LineBasicMaterial;
  private readonly shockGeometry: THREE.BufferGeometry;
  private readonly totalCount: number;
  private active = false;
  private time = 0;

  constructor(pixelRatio: number) {
    const count = CONFIG.visual.explosionCount;
    this.totalCount = count;
    const rng = mulberry32(0xb00b5);
    const positions = new Float32Array(count * 3);
    const dirs = new Float32Array(count * 3);
    const speeds = new Float32Array(count);
    const seeds = new Float32Array(count);
    const dir = { x: 0, y: 0, z: 0 };

    for (let i = 0; i < count; i += 1) {
      randomDirection(rng, dir);
      dirs[i * 3] = dir.x;
      dirs[i * 3 + 1] = dir.y;
      dirs[i * 3 + 2] = dir.z;
      speeds[i] = 2.0 + Math.pow(rng(), 0.6) * 11.0;
      seeds[i] = rng();
    }

    this.geometry = new THREE.BufferGeometry();
    this.geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    this.geometry.setAttribute('aDir', new THREE.BufferAttribute(dirs, 3));
    this.geometry.setAttribute('aSpeed', new THREE.BufferAttribute(speeds, 1));
    this.geometry.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 1));
    this.geometry.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 60);

    this.material = new THREE.ShaderMaterial({
      vertexShader: VERTEX,
      fragmentShader: FRAGMENT,
      uniforms: {
        uTime: { value: 0 },
        uPixelRatio: { value: pixelRatio },
        uOpacity: { value: 1 },
        uColorA: { value: new THREE.Color(CONFIG.colors.white) },
        uColorB: { value: new THREE.Color(CONFIG.colors.cyan) },
        uColorC: { value: new THREE.Color(CONFIG.colors.charge) },
      },
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });

    this.points = new THREE.Points(this.geometry, this.material);
    this.points.frustumCulled = false;
    this.points.visible = false;
    this.group.add(this.points);

    const shockSource = new THREE.SphereGeometry(1.2, 36, 20);
    const wire = new THREE.WireframeGeometry(shockSource);
    shockSource.dispose();
    this.shockGeometry = wire;
    this.shockMaterial = new THREE.LineBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    this.shock = new THREE.LineSegments(wire, this.shockMaterial);
    this.shock.visible = false;
    this.group.add(this.shock);
  }

  burst(): void {
    this.active = true;
    this.time = 0;
    this.material.uniforms.uTime.value = 0;
    this.material.uniforms.uOpacity.value = 1;
    this.points.visible = true;
    this.shock.visible = true;
    this.shock.scale.setScalar(0.6);
    this.shockMaterial.opacity = 0.65;
  }

  cancel(): void {
    this.active = false;
    this.time = 0;
    this.points.visible = false;
    this.shock.visible = false;
    this.material.uniforms.uTime.value = 0;
    this.shockMaterial.opacity = 0;
  }

  update(dt: number): void {
    if (!this.active) return;
    this.time += dt;
    this.material.uniforms.uTime.value = this.time;

    const p = this.time / 0.85;
    if (p < 1) {
      const eased = 1 - Math.pow(1 - p, 3);
      this.shock.scale.setScalar(0.6 + eased * 5.2);
      this.shockMaterial.opacity = 0.55 * (1 - p);
    } else {
      this.shock.visible = false;
    }

    if (this.time > 3.0) {
      this.cancel();
    }
  }

  setPixelRatio(pixelRatio: number): void {
    this.material.uniforms.uPixelRatio.value = pixelRatio;
  }

  setParticleFraction(fraction: number): void {
    const f = Math.min(1, Math.max(0.1, fraction));
    this.geometry.setDrawRange(0, Math.max(200, Math.floor(this.totalCount * f)));
  }

  dispose(): void {
    this.geometry.dispose();
    this.material.dispose();
    this.shockGeometry.dispose();
    this.shockMaterial.dispose();
  }
}
