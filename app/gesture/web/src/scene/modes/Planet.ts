import * as THREE from 'three';
import { CONFIG } from '../../config';
import type { ModeId } from '../../app/stateMachine';
import { ModelFader, type HoloModel } from './HoloModel';

const NOISE_GLSL = /* glsl */ `
  float hash(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
  }

  float noise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash(i + vec3(0.0, 0.0, 0.0));
    float n100 = hash(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash(i + vec3(1.0, 1.0, 1.0));
    return mix(
      mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
      mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
      f.z
    );
  }

  float fbm(vec3 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
      v += a * noise3(p);
      p *= 2.03;
      a *= 0.5;
    }
    return v;
  }
`;

const PLANET_VERTEX = /* glsl */ `
  varying vec3 vPos;
  varying vec3 vNormalV;
  varying vec3 vViewDir;

  void main() {
    vPos = position;
    vNormalV = normalize(normalMatrix * normal);
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    vViewDir = normalize(-mv.xyz);
    gl_Position = projectionMatrix * mv;
  }
`;

const PLANET_FRAGMENT = /* glsl */ `
  uniform float uTime;
  uniform float uOpacity;
  uniform vec3 uDeep;
  uniform vec3 uCyan;
  uniform vec3 uViolet;
  varying vec3 vPos;
  varying vec3 vNormalV;
  varying vec3 vViewDir;

  ${NOISE_GLSL}

  void main() {
    vec3 dir = normalize(vPos);
    float n = fbm(dir * 2.2 + vec3(0.0, uTime * 0.025, 0.0));
    float detail = fbm(dir * 5.5 + vec3(4.2, 1.7, 2.3));
    float bands = 0.5 + 0.5 * sin(dir.y * 15.0 + n * 8.0);

    vec3 col = mix(uDeep, uCyan, smoothstep(0.38, 0.78, n));
    col = mix(col, uViolet, smoothstep(0.45, 0.95, detail) * 0.55);
    col *= 0.55 + bands * 0.55;

    // 城市/能量脉络
    float veins = smoothstep(0.655, 0.71, detail) * smoothstep(0.5, 0.9, n);
    col += uCyan * veins * 0.65;

    float fresnel = pow(1.0 - max(dot(normalize(vNormalV), normalize(vViewDir)), 0.0), 3.0);
    col += uCyan * fresnel * 0.55;

    gl_FragColor = vec4(col, (0.86 + fresnel * 0.14) * uOpacity);
  }
`;

const ATMO_VERTEX = /* glsl */ `
  varying vec3 vNormalV;
  varying vec3 vViewDir;
  void main() {
    vNormalV = normalize(normalMatrix * normal);
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    vViewDir = normalize(-mv.xyz);
    gl_Position = projectionMatrix * mv;
  }
`;

const ATMO_FRAGMENT = /* glsl */ `
  uniform float uOpacity;
  uniform vec3 uColor;
  varying vec3 vNormalV;
  varying vec3 vViewDir;
  void main() {
    float f = pow(1.0 - abs(dot(normalize(vNormalV), normalize(vViewDir))), 3.4);
    gl_FragColor = vec4(uColor * (0.6 + f), f * 0.45 * uOpacity);
  }
`;

const RING_VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const RING_FRAGMENT = /* glsl */ `
  uniform float uOpacity;
  uniform vec3 uColorA;
  uniform vec3 uColorB;
  varying vec2 vUv;

  void main() {
    float r = length(vUv - 0.5) * 2.0;
    float edge = smoothstep(0.0, 0.2, r) * (1.0 - smoothstep(0.92, 1.0, r));
    float bands = 0.55 + 0.45 * sin(r * 90.0);
    float fine = 0.5 + 0.5 * sin(r * 240.0);
    float alpha = edge * (bands * 0.28 + fine * 0.08) * uOpacity;
    vec3 col = mix(uColorA, uColorB, r);
    gl_FragColor = vec4(col, alpha);
  }
`;

export class Planet implements HoloModel {
  readonly id: ModeId = 'MODE_PLANET';
  readonly group = new THREE.Group();
  private readonly fader: ModelFader;
  private readonly planetMaterial: THREE.ShaderMaterial;
  private readonly atmoMaterial: THREE.ShaderMaterial;
  private readonly ringMaterial: THREE.ShaderMaterial;
  private readonly moon: THREE.Mesh;
  private readonly moonMaterial: THREE.MeshBasicMaterial;
  private readonly orbit: THREE.LineLoop;
  private readonly orbitMaterial: THREE.LineBasicMaterial;
  private readonly ring: THREE.Mesh;
  private time = 0;
  private opacity = 0;

  constructor() {
    const planetGeometry = new THREE.SphereGeometry(1.38, 96, 64);
    this.planetMaterial = new THREE.ShaderMaterial({
      vertexShader: PLANET_VERTEX,
      fragmentShader: PLANET_FRAGMENT,
      uniforms: {
        uTime: { value: 0 },
        uOpacity: { value: 0 },
        uDeep: { value: new THREE.Color(0x071a2c) },
        uCyan: { value: new THREE.Color(CONFIG.colors.cyan) },
        uViolet: { value: new THREE.Color(CONFIG.colors.violet) },
      },
      transparent: true,
      depthWrite: true,
    });
    const planet = new THREE.Mesh(planetGeometry, this.planetMaterial);
    planet.rotation.z = 0.22;
    this.group.add(planet);

    const atmoGeometry = new THREE.SphereGeometry(1.62, 64, 48);
    this.atmoMaterial = new THREE.ShaderMaterial({
      vertexShader: ATMO_VERTEX,
      fragmentShader: ATMO_FRAGMENT,
      uniforms: {
        uOpacity: { value: 0 },
        uColor: { value: new THREE.Color(CONFIG.colors.cyan) },
      },
      transparent: true,
      depthWrite: false,
      side: THREE.BackSide,
      blending: THREE.AdditiveBlending,
    });
    const atmo = new THREE.Mesh(atmoGeometry, this.atmoMaterial);
    this.group.add(atmo);

    const ringGeometry = new THREE.RingGeometry(1.95, 2.75, 180, 1);
    this.ringMaterial = new THREE.ShaderMaterial({
      vertexShader: RING_VERTEX,
      fragmentShader: RING_FRAGMENT,
      uniforms: {
        uOpacity: { value: 0 },
        uColorA: { value: new THREE.Color(CONFIG.colors.violet) },
        uColorB: { value: new THREE.Color(CONFIG.colors.cyan) },
      },
      transparent: true,
      depthWrite: false,
      side: THREE.DoubleSide,
      blending: THREE.AdditiveBlending,
    });
    this.ring = new THREE.Mesh(ringGeometry, this.ringMaterial);
    this.ring.rotation.set(-1.12, 0.12, 0.28);
    this.group.add(this.ring);

    const orbitPoints: THREE.Vector3[] = [];
    for (let i = 0; i < 180; i += 1) {
      const a = (i / 180) * Math.PI * 2;
      orbitPoints.push(new THREE.Vector3(Math.cos(a) * 2.95, Math.sin(a) * 2.95, 0));
    }
    this.orbitMaterial = new THREE.LineBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.18,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    this.orbit = new THREE.LineLoop(new THREE.BufferGeometry().setFromPoints(orbitPoints), this.orbitMaterial);
    this.orbit.rotation.set(1.1, 0.3, 0.2);
    this.group.add(this.orbit);

    this.moonMaterial = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.85,
      blending: THREE.AdditiveBlending,
    });
    this.moon = new THREE.Mesh(new THREE.SphereGeometry(0.045, 16, 12), this.moonMaterial);
    this.group.add(this.moon);

    this.fader = new ModelFader(this.group);
    this.group.visible = false;
  }

  setOpacity(value: number): void {
    this.opacity = value;
    this.fader.set(value);
    this.group.visible = value > 0.002;
  }

  update(dt: number, elapsed: number): void {
    this.time += dt;
    this.planetMaterial.uniforms.uTime.value = this.time;

    if (this.opacity > 0.002) {
      this.group.rotation.y += dt * 0.09;
      this.ring.rotation.z += dt * 0.04;
      const angle = elapsed * 0.35;
      this.moon.position.set(Math.cos(angle) * 2.95, Math.sin(angle) * 2.95, 0);
      this.moon.position.applyEuler(new THREE.Euler(1.1, 0.3, 0.2));
      this.moonMaterial.opacity = 0.9 * this.opacity;
    }
  }

  dispose(): void {
    this.group.traverse((child) => {
      const mesh = child as THREE.Mesh;
      if (mesh.geometry) mesh.geometry.dispose();
      const material = mesh.material as THREE.Material | undefined;
      if (material) material.dispose();
    });
  }
}
