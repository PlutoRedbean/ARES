import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { CONFIG } from '../config';

/** 轻微 RGB 偏移 + 扫描线 + 暗角，用于 ULTIMATE 与模式切换。 */
const GlitchShader = {
  uniforms: {
    tDiffuse: { value: null as THREE.Texture | null },
    uAmount: { value: 0 },
    uTime: { value: 0 },
    uResolution: { value: new THREE.Vector2(1, 1) },
  },
  vertexShader: /* glsl */ `
    varying vec2 vUv;
    void main() {
      vUv = uv;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse;
    uniform float uAmount;
    uniform float uTime;
    uniform vec2 uResolution;
    varying vec2 vUv;

    float hash(float n) { return fract(sin(n) * 43758.5453123); }

    void main() {
      vec2 uv = vUv;
      float block = floor(uv.y * 32.0);
      float jitter = hash(block + floor(uTime * 18.0) * 13.0) - 0.5;
      float shift = uAmount * 0.018 * jitter;

      float r = texture2D(tDiffuse, uv + vec2(shift, 0.0)).r;
      float g = texture2D(tDiffuse, uv + vec2(shift * 0.25, 0.0)).g;
      float b = texture2D(tDiffuse, uv - vec2(shift, 0.0)).b;
      vec3 col = vec3(r, g, b);

      float scan = 0.965 + 0.035 * sin(uv.y * uResolution.y * 1.8 + uTime * 36.0);
      col *= scan;
      float band = smoothstep(0.0, 0.06, abs(fract(uv.y + uTime * 0.18) - 0.5));
      col *= mix(1.0, band, uAmount * 0.35);

      float vign = smoothstep(1.05, 0.38, length(uv - 0.5));
      col *= mix(1.0, vign, 0.32);

      gl_FragColor = vec4(col, 1.0);
    }
  `,
};

export class Stage {
  readonly scene = new THREE.Scene();
  readonly camera: THREE.PerspectiveCamera;
  readonly renderer: THREE.WebGLRenderer;
  readonly composer: EffectComposer;
  readonly bloomPass: UnrealBloomPass;
  readonly glitchPass: ShaderPass;
  readonly rendererName: string;
  readonly isSoftwareRenderer: boolean;

  private readonly size = new THREE.Vector2(1, 1);
  private readonly pointer = new THREE.Vector2();
  private readonly pointerTarget = new THREE.Vector2();
  private cameraZ: number = CONFIG.visual.cameraZ;
  private targetZ: number = CONFIG.visual.cameraZ;
  private pixelRatioCap: number = CONFIG.visual.pixelRatioMax;
  private effectivePixelRatio = 1;
  private bloomScale = 1;
  private time = 0;
  private shakeAmp = 0;
  private glitchAmount = 0;
  private bloomBoost = 0;
  private bloomEnabled = true;
  private disposed = false;

  constructor(canvas: HTMLCanvasElement) {
    this.scene.background = new THREE.Color(CONFIG.colors.background);

    this.camera = new THREE.PerspectiveCamera(45, 16 / 9, 0.1, 160);
    this.camera.position.set(0, 0, CONFIG.visual.cameraZ);
    this.camera.lookAt(0, 0, 0);
    this.scene.add(this.camera);

    this.renderer = new THREE.WebGLRenderer({
      canvas,
      antialias: true,
      powerPreference: 'high-performance',
      stencil: false,
    });
    this.renderer.setClearColor(CONFIG.colors.background, 1);
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.0;
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;

    const gl = this.renderer.getContext();
    const debugInfo = gl.getExtension('WEBGL_debug_renderer_info');
    this.rendererName = debugInfo
      ? String(gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL))
      : 'unknown';
    this.isSoftwareRenderer = /swiftshader|llvmpipe|software|basic render/i.test(
      this.rendererName,
    );

    // SoC 模型使用标准材质，需要基础照明
    this.scene.add(new THREE.AmbientLight(0x2f4f68, 1.4));
    const cyanLight = new THREE.PointLight(CONFIG.colors.cyan, 32, 24, 2);
    cyanLight.position.set(4.5, 3.5, 5.5);
    this.scene.add(cyanLight);
    const violetLight = new THREE.PointLight(CONFIG.colors.violet, 28, 24, 2);
    violetLight.position.set(-4.5, -2.5, 4.5);
    this.scene.add(violetLight);

    const renderPass = new RenderPass(this.scene, this.camera);
    this.bloomPass = new UnrealBloomPass(
      new THREE.Vector2(960, 540),
      CONFIG.visual.bloomStrength,
      CONFIG.visual.bloomRadius,
      CONFIG.visual.bloomThreshold,
    );
    this.glitchPass = new ShaderPass(GlitchShader);

    this.composer = new EffectComposer(this.renderer);
    this.composer.addPass(renderPass);
    this.composer.addPass(this.bloomPass);
    this.composer.addPass(this.glitchPass);
    this.composer.addPass(new OutputPass());

    // 平时关闭 glitch pass，省掉一次全屏采样；ULTIMATE 时再打开
    this.glitchPass.enabled = false;
  }

  get elapsed(): number {
    return this.time;
  }

  get pixelRatio(): number {
    return this.effectivePixelRatio;
  }

  setPixelRatioCap(cap: number): void {
    this.pixelRatioCap = Math.max(0.5, cap);
  }

  setBloomScale(scale: number): void {
    this.bloomScale = Math.max(0, scale);
  }

  get aspect(): number {
    return this.size.x / Math.max(1, this.size.y);
  }

  setPointerNormalized(x: number, y: number): void {
    this.pointerTarget.set(
      THREE.MathUtils.clamp(x, -1, 1),
      THREE.MathUtils.clamp(y, -1, 1),
    );
  }

  resize(width: number, height: number, pixelRatio: number): number {
    this.size.set(width, height);
    const pr = Math.min(pixelRatio, this.pixelRatioCap);
    this.effectivePixelRatio = pr;
    this.camera.aspect = width / Math.max(1, height);
    this.camera.updateProjectionMatrix();
    this.renderer.setPixelRatio(pr);
    this.renderer.setSize(width, height, false);
    this.composer.setPixelRatio(pr);
    this.composer.setSize(width, height);
    this.bloomPass.setSize(
      Math.max(1, Math.floor((width * pr) / 2)),
      Math.max(1, Math.floor((height * pr) / 2)),
    );
    const glitchResolution = this.glitchPass.uniforms.uResolution.value as THREE.Vector2;
    glitchResolution.set(width * pr, height * pr);
    return pr;
  }

  setCameraFocus(kind: 'default' | 'compress' | 'mode'): void {
    this.targetZ =
      kind === 'compress'
        ? CONFIG.visual.cameraZCompress
        : kind === 'mode'
          ? CONFIG.visual.cameraZMode
          : CONFIG.visual.cameraZ;
  }

  shake(amplitude = 0.3): void {
    this.shakeAmp = Math.max(this.shakeAmp, amplitude);
  }

  glitch(amount = 0.8): void {
    this.glitchAmount = Math.max(this.glitchAmount, amount);
    if (this.glitchAmount > 0.002) this.glitchPass.enabled = true;
  }

  bloomBurst(amount = 1): void {
    this.bloomBoost = Math.max(this.bloomBoost, amount);
  }

  setBloomEnabled(enabled: boolean): void {
    this.bloomEnabled = enabled;
    this.bloomPass.enabled = enabled;
  }

  get bloomIsEnabled(): boolean {
    return this.bloomEnabled;
  }

  update(dt: number): void {
    this.time += dt;
    this.pointer.lerp(this.pointerTarget, 1 - Math.exp(-dt * 2.2));

    this.cameraZ += (this.targetZ - this.cameraZ) * (1 - Math.exp(-dt * 3.0));
    this.shakeAmp *= Math.exp(-dt * 3.0);
    this.glitchAmount *= Math.exp(-dt * 2.4);
    this.bloomBoost *= Math.exp(-dt * 1.6);

    const amp = this.shakeAmp;
    const jitterX = (Math.random() - 0.5) * amp;
    const jitterY = (Math.random() - 0.5) * amp * 0.7;
    const jitterZ = (Math.random() - 0.5) * amp * 0.5;

    this.camera.position.set(
      this.pointer.x * 0.14 + jitterX,
      this.pointer.y * 0.1 + jitterY,
      this.cameraZ + jitterZ,
    );
    this.camera.lookAt(0, 0, 0);
    this.camera.rotation.z += (Math.random() - 0.5) * amp * 0.02;

    this.glitchPass.uniforms.uTime.value = this.time;
    this.glitchPass.uniforms.uAmount.value = this.glitchAmount;
    this.glitchPass.enabled = this.glitchAmount > 0.002;
    this.bloomPass.strength =
      CONFIG.visual.bloomStrength * this.bloomScale + this.bloomBoost;
  }

  render(): void {
    if (this.disposed) return;
    this.composer.render();
  }

  /** 启动时预编译所有 pass 的 shader，避免第一次 ULTIMATE / 模式切换时卡一下。 */
  warmup(): void {
    if (this.disposed) return;
    const glitchEnabled = this.glitchPass.enabled;
    this.glitchPass.enabled = true;
    this.glitchPass.uniforms.uAmount.value = 0;
    try {
      this.composer.render();
    } finally {
      this.glitchPass.enabled = glitchEnabled;
    }
  }

  dispose(): void {
    this.disposed = true;
    this.composer.dispose();
    this.renderer.dispose();
  }
}
