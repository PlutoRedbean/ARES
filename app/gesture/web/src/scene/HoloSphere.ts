import * as THREE from 'three';
import { CONFIG } from '../config';

function makeGlowTexture(): THREE.Texture {
  const size = 256;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (ctx) {
    const gradient = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    gradient.addColorStop(0, 'rgba(255, 255, 255, 1)');
    gradient.addColorStop(0.18, 'rgba(255, 210, 150, 0.8)');
    gradient.addColorStop(0.45, 'rgba(255, 179, 71, 0.22)');
    gradient.addColorStop(1, 'rgba(255, 179, 71, 0)');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, size, size);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

const SHELL_VERTEX = /* glsl */ `
  varying vec3 vNormal;
  varying vec3 vView;
  void main() {
    vNormal = normalize(normalMatrix * normal);
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    vView = normalize(-mv.xyz);
    gl_Position = projectionMatrix * mv;
  }
`;

const SHELL_FRAGMENT = /* glsl */ `
  uniform float uOpacity;
  uniform float uCharge;
  uniform vec3 uColorA;
  uniform vec3 uColorB;
  varying vec3 vNormal;
  varying vec3 vView;

  void main() {
    float fresnel = pow(1.0 - abs(dot(normalize(vNormal), normalize(vView))), 2.3);
    vec3 col = mix(uColorA, uColorB, 0.25 + uCharge * 0.6);
    float alpha = (0.04 + fresnel * 0.55) * uOpacity;
    gl_FragColor = vec4(col * (0.7 + fresnel), alpha);
  }
`;

interface RingParts {
  mesh: THREE.Mesh;
  material: THREE.MeshBasicMaterial;
  speed: number;
  axis: 'x' | 'y' | 'z';
}

export class HoloSphere {
  readonly group = new THREE.Group();
  private readonly shellMaterial: THREE.ShaderMaterial;
  private readonly wireMaterial: THREE.LineBasicMaterial;
  private readonly rings: RingParts[] = [];
  private readonly core: THREE.Sprite;
  private readonly coreMaterial: THREE.SpriteMaterial;
  private readonly glowTexture: THREE.Texture;
  private readonly baseOpacities: number[] = [];

  private active = false;
  private fade = 0;
  private age = 0;
  private time = 0;
  private charge = 0;
  private flash = 0;
  private kick = 0;

  constructor() {
    this.group.visible = false;

    const shellGeometry = new THREE.SphereGeometry(1.46, 48, 32);
    this.shellMaterial = new THREE.ShaderMaterial({
      vertexShader: SHELL_VERTEX,
      fragmentShader: SHELL_FRAGMENT,
      uniforms: {
        uOpacity: { value: 0 },
        uCharge: { value: 0 },
        uColorA: { value: new THREE.Color(CONFIG.colors.cyan) },
        uColorB: { value: new THREE.Color(CONFIG.colors.charge) },
      },
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      side: THREE.FrontSide,
    });
    const shell = new THREE.Mesh(shellGeometry, this.shellMaterial);
    this.group.add(shell);

    const ico = new THREE.IcosahedronGeometry(1.52, 1);
    const wire = new THREE.WireframeGeometry(ico);
    ico.dispose();
    this.wireMaterial = new THREE.LineBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    const wireMesh = new THREE.LineSegments(wire, this.wireMaterial);
    this.group.add(wireMesh);

    const ringColors = [CONFIG.colors.cyan, CONFIG.colors.violet, CONFIG.colors.charge];
    const ringConfig: Array<{ rot: [number, number, number]; speed: number; axis: 'x' | 'y' | 'z' }> = [
      { rot: [Math.PI / 2, 0, 0], speed: 0.35, axis: 'z' },
      { rot: [1.05, 0.35, 0.2], speed: -0.55, axis: 'y' },
      { rot: [-0.85, -0.3, -0.5], speed: 0.42, axis: 'x' },
    ];

    ringConfig.forEach((cfg, index) => {
      const geometry = new THREE.RingGeometry(1.72, 1.75, 160);
      const material = new THREE.MeshBasicMaterial({
        color: ringColors[index],
        transparent: true,
        opacity: 0,
        side: THREE.DoubleSide,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
      });
      const mesh = new THREE.Mesh(geometry, material);
      mesh.rotation.set(...cfg.rot);
      this.group.add(mesh);
      this.rings.push({ mesh, material, speed: cfg.speed, axis: cfg.axis });
      this.baseOpacities.push(0.32);
    });

    this.glowTexture = makeGlowTexture();
    this.coreMaterial = new THREE.SpriteMaterial({
      map: this.glowTexture,
      color: CONFIG.colors.charge,
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    this.core = new THREE.Sprite(this.coreMaterial);
    this.core.scale.set(2.6, 2.6, 1);
    this.group.add(this.core);
  }

  enter(): void {
    this.active = true;
    this.age = 0;
    this.charge = 0;
    this.group.visible = true;
  }

  exit(): void {
    this.active = false;
  }

  pulse(): void {
    this.flash = 1;
    this.kick = 0.1;
    this.charge = Math.min(1, this.charge + 0.35);
  }

  update(dt: number): void {
    this.time += dt;
    if (this.active) this.age += dt;

    this.fade += ((this.active ? 1 : 0) - this.fade) * (1 - Math.exp(-dt * 6));
    if (this.fade < 0.01 && !this.active) {
      this.group.visible = false;
      return;
    }
    this.group.visible = true;

    const shrink = 1 - 0.3 * THREE.MathUtils.smoothstep(this.age, 0.2, 2.6);
    this.flash = Math.max(0, this.flash - dt * 2.6);
    this.kick = Math.max(0, this.kick - dt * 0.5);

    const scale = (shrink + this.flash * 0.04 + this.kick) * (0.92 + this.fade * 0.08);
    this.group.scale.setScalar(scale);

    // 蓄力程度：进入 1.6s 内拉满，退出后回落
    const chargeTarget = this.active ? THREE.MathUtils.smoothstep(this.age, 0.1, 1.8) : 0;
    this.charge += (chargeTarget - this.charge) * (1 - Math.exp(-dt * 3));
    this.charge = Math.max(this.charge, this.flash * 0.5);

    this.shellMaterial.uniforms.uOpacity.value = this.fade * 0.7;
    this.shellMaterial.uniforms.uCharge.value = this.charge;
    this.wireMaterial.opacity = this.fade * (0.1 + this.charge * 0.14);

    this.rings.forEach((ring, i) => {
      const base = this.baseOpacities[i];
      const pulse = 0.7 + 0.3 * Math.sin(this.time * (1.5 + i * 0.4) + i);
      ring.material.opacity = this.fade * base * (0.55 + this.charge * 0.4) * pulse;
      ring.mesh.rotation[ring.axis] += dt * ring.speed;
      ring.mesh.scale.setScalar(1 + this.charge * 0.06 + this.flash * 0.05);
    });

    this.coreMaterial.opacity = this.fade * (0.1 + this.charge * 0.32 + this.flash * 0.3);
    const coreScale = 1.7 + this.charge * 0.6 + Math.sin(this.time * 2.2) * 0.1 + this.flash * 0.6;
    this.core.scale.set(coreScale, coreScale, 1);
    this.core.rotation.z += dt * 0.1;

    this.group.rotation.y += dt * 0.12;
  }

  dispose(): void {
    this.group.traverse((child) => {
      if (child instanceof THREE.Mesh || child instanceof THREE.LineSegments) {
        child.geometry.dispose();
        const material = child.material as THREE.Material;
        material.dispose();
      }
    });
    this.shellMaterial.dispose();
    this.wireMaterial.dispose();
    this.rings.forEach((ring) => ring.material.dispose());
    this.glowTexture.dispose();
    this.coreMaterial.dispose();
  }
}
