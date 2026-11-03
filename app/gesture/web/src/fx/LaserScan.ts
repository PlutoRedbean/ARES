import * as THREE from 'three';
import { CONFIG } from '../config';
import { ModelFader } from '../scene/MaterialFader';

function makeGlowTexture(): THREE.CanvasTexture {
  const size = 128;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (ctx) {
    const gradient = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    gradient.addColorStop(0, 'rgba(255,255,255,1)');
    gradient.addColorStop(0.25, 'rgba(120,240,255,0.55)');
    gradient.addColorStop(1, 'rgba(57,230,255,0)');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, size, size);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

const GRID_VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const GRID_FRAGMENT = /* glsl */ `
  uniform float uTime;
  uniform float uOpacity;
  varying vec2 vUv;

  void main() {
    vec2 cell = abs(fract(vUv * vec2(42.0, 23.0)) - 0.5);
    float line = 1.0 - smoothstep(0.0, 0.055, min(cell.x, cell.y));
    float scanY = 0.5 + 0.32 * sin(uTime * 0.45);
    float scan = exp(-pow((vUv.y - scanY) * 60.0, 2.0));
    float edge = smoothstep(0.0, 0.12, vUv.x) * smoothstep(1.0, 0.88, vUv.x)
      * smoothstep(0.0, 0.16, vUv.y) * smoothstep(1.0, 0.84, vUv.y);
    vec3 col = mix(vec3(0.08, 0.45, 0.6), vec3(0.36, 0.2, 0.85), vUv.y);
    float alpha = (line * 0.05 + scan * 0.07 + 0.012) * edge * uOpacity;
    gl_FragColor = vec4(col, alpha);
  }
`;

const UP = new THREE.Vector3(0, 1, 0);

export class LaserScan {
  readonly group = new THREE.Group();
  private readonly fader: ModelFader;
  private readonly gridMaterial: THREE.ShaderMaterial;
  private readonly beamCore: THREE.Mesh;
  private readonly beamGlow: THREE.Mesh;
  private readonly reticle = new THREE.Group();
  private readonly flash: THREE.Sprite;
  private readonly flashMaterial: THREE.SpriteMaterial;
  private readonly glowTexture: THREE.CanvasTexture;
  private readonly scanBar: THREE.Mesh;
  private readonly scanBarMaterial: THREE.MeshBasicMaterial;
  private readonly origin = new THREE.Vector3(0, -3.1, 1.2);
  private readonly target = new THREE.Vector3();
  private readonly direction = new THREE.Vector3();
  private pointer: { x: number; y: number } | null = null;

  private active = false;
  private fade = 0;
  private time = 0;
  private flashAmount = 0;

  constructor() {
    this.group.visible = false;

    const gridGeometry = new THREE.PlaneGeometry(13, 8);
    this.gridMaterial = new THREE.ShaderMaterial({
      vertexShader: GRID_VERTEX,
      fragmentShader: GRID_FRAGMENT,
      uniforms: {
        uTime: { value: 0 },
        uOpacity: { value: 1 },
      },
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    const grid = new THREE.Mesh(gridGeometry, this.gridMaterial);
    grid.position.set(0, 0, -3.0);
    this.group.add(grid);

    const coreGeometry = new THREE.CylinderGeometry(0.005, 0.01, 1, 8, 1, true);
    const coreMaterial = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.9,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.beamCore = new THREE.Mesh(coreGeometry, coreMaterial);
    this.group.add(this.beamCore);

    const glowGeometry = new THREE.CylinderGeometry(0.03, 0.045, 1, 12, 1, true);
    const glowMaterial = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.16,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.beamGlow = new THREE.Mesh(glowGeometry, glowMaterial);
    this.group.add(this.beamGlow);

    const emitterMaterial = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    const emitter = new THREE.Mesh(new THREE.SphereGeometry(0.06, 16, 12), emitterMaterial);
    emitter.position.copy(this.origin);
    this.group.add(emitter);

    this.glowTexture = makeGlowTexture();
    const emitterGlow = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: this.glowTexture,
        transparent: true,
        opacity: 0.8,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
      }),
    );
    emitterGlow.position.copy(this.origin);
    emitterGlow.scale.set(0.3, 0.3, 1);
    this.group.add(emitterGlow);

    const ringGeometry = new THREE.RingGeometry(0.26, 0.273, 64);
    const ringMaterial = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      side: THREE.DoubleSide,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    const outerRing = new THREE.Mesh(ringGeometry, ringMaterial);
    this.reticle.add(outerRing);

    const innerRing = new THREE.Mesh(
      new THREE.RingGeometry(0.1, 0.108, 48),
      new THREE.MeshBasicMaterial({
        color: CONFIG.colors.white,
        transparent: true,
        side: THREE.DoubleSide,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
      }),
    );
    this.reticle.add(innerRing);

    const crossMaterial = new THREE.LineBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.9,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    const crossPoints: number[] = [];
    const crossRadius = 0.42;
    for (const angle of [0, Math.PI / 2, Math.PI, Math.PI * 1.5]) {
      const inner = 0.3;
      crossPoints.push(
        Math.cos(angle) * inner,
        Math.sin(angle) * inner,
        0,
        Math.cos(angle) * crossRadius,
        Math.sin(angle) * crossRadius,
        0,
      );
    }
    const crossGeometry = new THREE.BufferGeometry();
    crossGeometry.setAttribute('position', new THREE.Float32BufferAttribute(crossPoints, 3));
    this.reticle.add(new THREE.LineSegments(crossGeometry, crossMaterial));

    const bracketPoints: number[] = [];
    const bracketRadius = 0.52;
    for (const angle of [0, Math.PI / 2, Math.PI, Math.PI * 1.5]) {
      const start = angle - 0.18;
      const end = angle + 0.18;
      bracketPoints.push(
        Math.cos(start) * bracketRadius,
        Math.sin(start) * bracketRadius,
        0,
        Math.cos(end) * bracketRadius,
        Math.sin(end) * bracketRadius,
        0,
      );
    }
    const bracketGeometry = new THREE.BufferGeometry();
    bracketGeometry.setAttribute('position', new THREE.Float32BufferAttribute(bracketPoints, 3));
    this.reticle.add(new THREE.LineSegments(bracketGeometry, crossMaterial));

    this.group.add(this.reticle);

    this.flashMaterial = new THREE.SpriteMaterial({
      map: this.glowTexture,
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    this.flash = new THREE.Sprite(this.flashMaterial);
    this.flash.scale.set(1.6, 1.6, 1);
    this.group.add(this.flash);

    this.scanBarMaterial = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.3,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    this.scanBar = new THREE.Mesh(new THREE.PlaneGeometry(11, 0.03), this.scanBarMaterial);
    this.scanBar.position.set(0, 1.6, 1.4);
    this.group.add(this.scanBar);

    this.fader = new ModelFader(this.group);
    this.setFade(0);
  }

  enter(): void {
    this.active = true;
    this.group.visible = true;
  }

  exit(): void {
    this.active = false;
    this.pointer = null;
  }

  pulse(): void {
    this.flashAmount = 1;
  }

  setPointer(x: number, y: number): void {
    this.pointer = { x, y };
  }

  private setFade(value: number): void {
    this.fade = value;
    this.fader.set(value);
    if (value <= 0.002) this.group.visible = false;
  }

  private updateTarget(): void {
    if (this.pointer) {
      const px = (this.pointer.x / 1000 - 0.5) * 6.4;
      const py = (0.5 - this.pointer.y / 1000) * 3.2;
      this.target.set(px, py, 0.9);
      return;
    }
    const t = this.time;
    this.target.set(
      Math.sin(t * 0.85) * 2.45 + Math.sin(t * 0.33) * 0.65,
      Math.sin(t * 1.25 + 1.2) * 1.0 + Math.cos(t * 0.47) * 0.3,
      0.9 + Math.sin(t * 0.55) * 0.5,
    );
  }

  update(dt: number, camera: THREE.Camera): void {
    this.time += dt;
    this.flashAmount = Math.max(0, this.flashAmount - dt * 2.4);

    this.fade += ((this.active ? 1 : 0) - this.fade) * (1 - Math.exp(-dt * 7));
    if (this.fade < 0.01 && !this.active) {
      this.group.visible = false;
      return;
    }
    this.group.visible = true;
    this.fader.set(this.fade);

    this.updateTarget();
    this.direction.copy(this.target).sub(this.origin);
    const length = this.direction.length();
    this.direction.normalize();

    for (const beam of [this.beamCore, this.beamGlow]) {
      beam.position.copy(this.origin).addScaledVector(this.direction, length * 0.5);
      beam.scale.set(1, length, 1);
      beam.quaternion.setFromUnitVectors(UP, this.direction);
    }

    this.reticle.position.copy(this.target);
    this.reticle.quaternion.copy(camera.quaternion);
    this.reticle.rotation.z += dt * 0.6;
    const reticlePulse = 1 + Math.sin(this.time * 3.2) * 0.04 + this.flashAmount * 0.35;
    this.reticle.scale.setScalar(reticlePulse);

    this.glowTexture.needsUpdate = false;
    this.flash.position.copy(this.target);
    const hit = Math.pow(Math.max(0, Math.sin(this.time * 2.1)), 10);
    this.flashMaterial.opacity = (hit * 0.55 + this.flashAmount * 0.9) * this.fade;
    const flashScale = 1.1 + hit * 0.8 + this.flashAmount * 1.2;
    this.flash.scale.set(flashScale, flashScale, 1);

    this.gridMaterial.uniforms.uTime.value = this.time;
    this.gridMaterial.uniforms.uOpacity.value = this.fade;

    this.scanBar.position.y = Math.sin(this.time * 0.55) * 1.9;
    this.scanBarMaterial.opacity = this.fade * (0.1 + 0.08 * (0.5 + 0.5 * Math.sin(this.time * 2.0)));
    this.scanBar.quaternion.copy(camera.quaternion);
  }

  dispose(): void {
    this.group.traverse((child) => {
      const mesh = child as THREE.Mesh;
      if (mesh.geometry) mesh.geometry.dispose();
      const material = mesh.material as THREE.Material | undefined;
      if (material && !(material instanceof THREE.SpriteMaterial && material.map === this.glowTexture)) {
        material.dispose();
      }
    });
    this.glowTexture.dispose();
  }
}
