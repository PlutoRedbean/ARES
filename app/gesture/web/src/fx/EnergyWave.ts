import * as THREE from 'three';
import { CONFIG } from '../config';

export interface WaveOptions {
  count?: number;
  color?: number;
  duration?: number;
  startRadius?: number;
  endRadius?: number;
  delay?: number;
  opacity?: number;
  facing?: 'camera' | 'flat';
}

interface WaveSlot {
  mesh: THREE.Mesh;
  material: THREE.MeshBasicMaterial;
  active: boolean;
  time: number;
  duration: number;
  startRadius: number;
  endRadius: number;
  baseOpacity: number;
  facing: 'camera' | 'flat';
  spin: number;
}

export class EnergyWave {
  readonly group = new THREE.Group();
  private readonly pool: WaveSlot[] = [];
  private readonly geometry: THREE.RingGeometry;

  constructor(capacity = 16) {
    this.geometry = new THREE.RingGeometry(0.985, 1.0, 160);
    for (let i = 0; i < capacity; i += 1) {
      const material = new THREE.MeshBasicMaterial({
        color: CONFIG.colors.cyan,
        transparent: true,
        opacity: 0,
        side: THREE.DoubleSide,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
      });
      const mesh = new THREE.Mesh(this.geometry, material);
      mesh.visible = false;
      this.group.add(mesh);
      this.pool.push({
        mesh,
        material,
        active: false,
        time: 0,
        duration: 1,
        startRadius: 0.5,
        endRadius: 4,
        baseOpacity: 0.6,
        facing: 'camera',
        spin: 0,
      });
    }
  }

  spawn(options: WaveOptions = {}): void {
    const count = options.count ?? 1;
    for (let i = 0; i < count; i += 1) {
      const slot = this.pool.find((item) => !item.active);
      if (!slot) return;
      slot.active = true;
      slot.time = -i * (options.delay ?? 0.12);
      slot.duration = options.duration ?? 1.15;
      slot.startRadius = options.startRadius ?? 0.55;
      slot.endRadius = options.endRadius ?? 4.4;
      slot.baseOpacity = options.opacity ?? 0.55;
      slot.facing = options.facing ?? 'camera';
      slot.spin = (Math.random() - 0.5) * 0.4;
      slot.material.color.set(options.color ?? CONFIG.colors.cyan);
      slot.material.opacity = 0;
      slot.mesh.visible = true;
      slot.mesh.scale.setScalar(slot.startRadius);
      slot.mesh.rotation.set(
        slot.facing === 'flat' ? Math.PI / 2 : 0,
        (Math.random() - 0.5) * 0.5,
        0,
      );
    }
  }

  update(dt: number, camera: THREE.Camera): void {
    for (const slot of this.pool) {
      if (!slot.active) continue;
      slot.time += dt;
      if (slot.time < 0) {
        slot.material.opacity = 0;
        continue;
      }
      const p = slot.time / slot.duration;
      if (p >= 1) {
        slot.active = false;
        slot.mesh.visible = false;
        slot.material.opacity = 0;
        continue;
      }
      const eased = 1 - Math.pow(1 - p, 3);
      const radius = slot.startRadius + (slot.endRadius - slot.startRadius) * eased;
      slot.mesh.scale.setScalar(radius);
      slot.material.opacity = slot.baseOpacity * Math.pow(1 - p, 1.8);
      if (slot.facing === 'camera') {
        slot.mesh.quaternion.copy(camera.quaternion);
        slot.mesh.rotateZ(slot.spin);
      } else {
        slot.mesh.rotation.z += dt * slot.spin;
      }
    }
  }

  dispose(): void {
    for (const slot of this.pool) slot.material.dispose();
    this.geometry.dispose();
  }
}
