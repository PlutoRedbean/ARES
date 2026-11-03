import * as THREE from 'three';
import { CONFIG } from '../config';

const VERTEX = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const FRAGMENT = /* glsl */ `
  uniform float uProgress;
  uniform float uOpacity;
  uniform float uTime;
  uniform float uAspect;
  uniform vec3 uColor;
  varying vec2 vUv;

  void main() {
    float bandY = 1.18 - uProgress * 1.36;
    float band = smoothstep(0.075, 0.0, abs(vUv.y - bandY));
    float core = smoothstep(0.018, 0.0, abs(vUv.y - bandY));

    // 横向细密刻度，增强全息扫描感
    float ticks = step(0.5, fract(vUv.x * 64.0 + floor(uTime * 20.0) * 0.13));
    float edgeFade = smoothstep(0.0, 0.18, vUv.x) * smoothstep(1.0, 0.82, vUv.x);
    float alpha = (band * 0.3 + core * 0.55 * ticks) * edgeFade * uOpacity;
    vec3 col = mix(uColor, vec3(1.0), core * 0.55);
    gl_FragColor = vec4(col, alpha);
  }
`;

/**
 * 屏幕空间扫描带：模式切换、粘性状态退出、CONFIRM 时掠过画面。
 * 挂在相机下，不参与世界坐标。
 */
export class Transition {
  readonly mesh: THREE.Mesh;
  private readonly material: THREE.ShaderMaterial;
  private active = false;
  private progress = 0;
  private duration = 0.6;
  private time = 0;

  constructor(camera: THREE.Camera) {
    this.material = new THREE.ShaderMaterial({
      vertexShader: VERTEX,
      fragmentShader: FRAGMENT,
      uniforms: {
        uProgress: { value: 0 },
        uOpacity: { value: 0 },
        uTime: { value: 0 },
        uAspect: { value: 1 },
        uColor: { value: new THREE.Color(CONFIG.colors.cyan) },
      },
      transparent: true,
      depthTest: false,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });

    this.mesh = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.material);
    this.mesh.position.set(0, 0, -1);
    this.mesh.renderOrder = 1000;
    this.mesh.frustumCulled = false;
    this.mesh.visible = false;
    camera.add(this.mesh);
  }

  setAspect(aspect: number): void {
    this.material.uniforms.uAspect.value = aspect;
    const height = 1.1;
    this.mesh.scale.set((height * aspect) / 1.0, height, 1);
  }

  trigger(color: number = CONFIG.colors.cyan, duration = 0.6): void {
    this.active = true;
    this.progress = 0;
    this.duration = Math.max(0.1, duration);
    this.material.uniforms.uColor.value.set(color);
    this.mesh.visible = true;
  }

  update(dt: number): void {
    if (!this.active) return;
    this.time += dt;
    this.progress += dt / this.duration;
    const p = Math.min(1, this.progress);
    this.material.uniforms.uProgress.value = p;
    this.material.uniforms.uTime.value = this.time;
    this.material.uniforms.uOpacity.value = Math.sin(Math.PI * p) * 0.95;

    if (this.progress >= 1) {
      this.active = false;
      this.mesh.visible = false;
    }
  }

  dispose(): void {
    this.mesh.geometry.dispose();
    this.material.dispose();
  }
}
