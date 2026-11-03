import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { CONFIG } from '../../config';
import type { ModeId } from '../../app/stateMachine';
import { ModelFader, type HoloModel } from './HoloModel';

function makeLabelTexture(): THREE.CanvasTexture {
  const canvas = document.createElement('canvas');
  canvas.width = 512;
  canvas.height = 160;
  const ctx = canvas.getContext('2d');
  if (ctx) {
    ctx.clearRect(0, 0, 512, 160);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = '900 96px "Arial Black", "Segoe UI Black", Arial, sans-serif';
    ctx.shadowColor = 'rgba(57, 230, 255, 0.95)';
    ctx.shadowBlur = 26;
    ctx.fillStyle = '#eaf6ff';
    ctx.fillText('ARES', 256, 84);
    ctx.shadowBlur = 0;
    ctx.strokeStyle = 'rgba(57, 230, 255, 0.65)';
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.moveTo(88, 140);
    ctx.lineTo(424, 140);
    ctx.stroke();
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

function makeGlowTexture(): THREE.CanvasTexture {
  const size = 256;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (ctx) {
    const gradient = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    gradient.addColorStop(0, 'rgba(57, 230, 255, 0.55)');
    gradient.addColorStop(0.4, 'rgba(57, 230, 255, 0.15)');
    gradient.addColorStop(1, 'rgba(57, 230, 255, 0)');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, size, size);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

export class Soc implements HoloModel {
  readonly id: ModeId = 'MODE_SOC';
  readonly group = new THREE.Group();
  private readonly fader: ModelFader;
  private readonly labelTexture: THREE.CanvasTexture;
  private readonly glowTexture: THREE.CanvasTexture;
  private readonly labelMaterial: THREE.MeshBasicMaterial;
  private readonly glow: THREE.Sprite;
  private time = 0;
  private opacity = 0;

  constructor() {
    const baseMaterial = new THREE.MeshStandardMaterial({
      color: 0x08131f,
      metalness: 0.86,
      roughness: 0.32,
      emissive: 0x061a26,
      emissiveIntensity: 1,
    });
    const base = new THREE.Mesh(new RoundedBoxGeometry(2.9, 2.9, 0.32, 6, 0.09), baseMaterial);
    this.group.add(base);

    const edgeGeometry = new THREE.EdgesGeometry(base.geometry, 18);
    const edgeMaterial = new THREE.LineBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.35,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    const edges = new THREE.LineSegments(edgeGeometry, edgeMaterial);
    edges.position.z = 0.002;
    this.group.add(edges);

    const dieMaterial = new THREE.MeshStandardMaterial({
      color: 0x0a1e2a,
      metalness: 0.7,
      roughness: 0.25,
      emissive: CONFIG.colors.cyan,
      emissiveIntensity: 0.08,
    });
    const die = new THREE.Mesh(new RoundedBoxGeometry(1.46, 1.46, 0.12, 4, 0.04), dieMaterial);
    die.position.z = 0.21;
    this.group.add(die);

    // 芯片表面网格
    const gridPositions: number[] = [];
    const half = 0.65;
    const divisions = 10;
    for (let i = 0; i <= divisions; i += 1) {
      const p = (i / divisions) * 2 - 1;
      gridPositions.push(-half, p * half, 0.285, half, p * half, 0.285);
      gridPositions.push(p * half, -half, 0.285, p * half, half, 0.285);
    }
    const gridGeometry = new THREE.BufferGeometry();
    gridGeometry.setAttribute('position', new THREE.Float32BufferAttribute(gridPositions, 3));
    const gridMaterial = new THREE.LineBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.3,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    this.group.add(new THREE.LineSegments(gridGeometry, gridMaterial));

    // 引脚阵列
    const pinGeometry = new THREE.BoxGeometry(1, 1, 1);
    const pinMaterial = new THREE.MeshStandardMaterial({
      color: 0x9fd8e8,
      metalness: 0.95,
      roughness: 0.25,
      emissive: 0x0b3a4a,
      emissiveIntensity: 0.8,
    });
    const pins = new THREE.InstancedMesh(pinGeometry, pinMaterial, 52);
    const dummy = new THREE.Object3D();
    let index = 0;
    for (let i = 0; i < 13; i += 1) {
      const offset = -1.2 + i * 0.2;
      dummy.position.set(-1.52, offset, 0);
      dummy.scale.set(0.26, 0.05, 0.05);
      dummy.rotation.set(0, 0, 0);
      dummy.updateMatrix();
      pins.setMatrixAt(index++, dummy.matrix);

      dummy.position.set(1.52, offset, 0);
      dummy.updateMatrix();
      pins.setMatrixAt(index++, dummy.matrix);

      dummy.position.set(offset, -1.52, 0);
      dummy.scale.set(0.05, 0.26, 0.05);
      dummy.updateMatrix();
      pins.setMatrixAt(index++, dummy.matrix);

      dummy.position.set(offset, 1.52, 0);
      dummy.updateMatrix();
      pins.setMatrixAt(index++, dummy.matrix);
    }
    pins.instanceMatrix.needsUpdate = true;
    this.group.add(pins);

    // 走线
    const tracePositions: number[] = [];
    for (let i = 0; i < 9; i += 1) {
      const y = -0.56 + i * 0.14;
      tracePositions.push(0.74, y, 0.17, 1.22, y, 0.17, 1.22, y, 0.17, 1.38, y, 0.17);
      tracePositions.push(-0.74, y, 0.17, -1.22, y, 0.17, -1.22, y, 0.17, -1.38, y, 0.17);
      const x = -0.56 + i * 0.14;
      tracePositions.push(x, 0.74, 0.17, x, 1.22, 0.17, x, 1.22, 0.17, x, 1.38, 0.17);
      tracePositions.push(x, -0.74, 0.17, x, -1.22, 0.17, x, -1.22, 0.17, x, -1.38, 0.17);
    }
    const traceGeometry = new THREE.BufferGeometry();
    traceGeometry.setAttribute('position', new THREE.Float32BufferAttribute(tracePositions, 3));
    const traceMaterial = new THREE.LineBasicMaterial({
      color: CONFIG.colors.violet,
      transparent: true,
      opacity: 0.55,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    this.group.add(new THREE.LineSegments(traceGeometry, traceMaterial));

    // ARES 标签
    this.labelTexture = makeLabelTexture();
    this.labelMaterial = new THREE.MeshBasicMaterial({
      map: this.labelTexture,
      transparent: true,
      depthWrite: false,
      depthTest: false,
      side: THREE.DoubleSide,
      blending: THREE.AdditiveBlending,
    });
    const label = new THREE.Mesh(new THREE.PlaneGeometry(1.4, 0.42), this.labelMaterial);
    label.position.set(0, -1.02, 0.24);
    label.renderOrder = 6;
    this.group.add(label);

    this.glowTexture = makeGlowTexture();
    this.glow = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: this.glowTexture,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        opacity: 0.35,
      }),
    );
    this.glow.position.set(0, 0, -0.6);
    this.glow.scale.set(5.4, 5.4, 1);
    this.group.add(this.glow);

    this.group.rotation.x = 0.16;
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
    if (this.opacity <= 0.002) return;
    const sway = Math.sin(elapsed * 0.32);
    this.group.rotation.y = sway * 0.4;
    this.group.rotation.x = 0.16 + Math.sin(elapsed * 0.22) * 0.04;
    this.group.position.y = Math.sin(elapsed * 0.9) * 0.05;
    const pulse = 0.9 + Math.sin(this.time * 2.0) * 0.1;
    this.labelMaterial.opacity = 0.95 * this.opacity * pulse;
    this.glow.material.opacity = 0.3 * this.opacity;
  }

  dispose(): void {
    this.group.traverse((child) => {
      const mesh = child as THREE.Mesh;
      if (mesh.geometry) mesh.geometry.dispose();
      const material = mesh.material as THREE.Material | undefined;
      if (material) material.dispose();
    });
    this.labelTexture.dispose();
    this.glowTexture.dispose();
  }
}
