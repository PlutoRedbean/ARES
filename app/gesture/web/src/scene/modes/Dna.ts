import * as THREE from 'three';
import { CONFIG } from '../../config';
import type { ModeId } from '../../app/stateMachine';
import { ModelFader, type HoloModel } from './HoloModel';

const STEPS = 56;
const RADIUS = 0.95;
const HEIGHT = 3.25;
const TURNS = 2.35;

export class Dna implements HoloModel {
  readonly id: ModeId = 'MODE_DNA';
  readonly group = new THREE.Group();
  private readonly fader: ModelFader;
  private readonly strandA: THREE.InstancedMesh;
  private readonly strandB: THREE.InstancedMesh;
  private readonly rungMaterial: THREE.LineBasicMaterial;
  private readonly axisMaterial: THREE.MeshBasicMaterial;
  private time = 0;
  private opacity = 0;

  constructor() {
    const nodeGeometry = new THREE.SphereGeometry(0.03, 12, 10);

    const materialA = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    const materialB = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.violet,
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });

    this.strandA = new THREE.InstancedMesh(nodeGeometry, materialA, STEPS);
    this.strandB = new THREE.InstancedMesh(nodeGeometry, materialB, STEPS);
    this.strandA.frustumCulled = false;
    this.strandB.frustumCulled = false;

    const dummy = new THREE.Object3D();
    const backboneA: number[] = [];
    const backboneB: number[] = [];

    for (let i = 0; i < STEPS; i += 1) {
      const t = i / (STEPS - 1);
      const angle = t * Math.PI * 2 * TURNS;
      const y = (t - 0.5) * HEIGHT;
      const x = Math.cos(angle) * RADIUS;
      const z = Math.sin(angle) * RADIUS;

      dummy.position.set(x, y, z);
      dummy.scale.setScalar(0.9 + 0.22 * Math.sin(i * 1.7));
      dummy.updateMatrix();
      this.strandA.setMatrixAt(i, dummy.matrix);

      dummy.position.set(-x, y, -z);
      dummy.scale.setScalar(0.9 + 0.22 * Math.cos(i * 1.3));
      dummy.updateMatrix();
      this.strandB.setMatrixAt(i, dummy.matrix);

      backboneA.push(x, y, z);
      backboneB.push(-x, y, -z);
    }

    const lineGeometryA = new THREE.BufferGeometry();
    lineGeometryA.setAttribute('position', new THREE.Float32BufferAttribute(backboneA, 3));
    const lineGeometryB = new THREE.BufferGeometry();
    lineGeometryB.setAttribute('position', new THREE.Float32BufferAttribute(backboneB, 3));

    const lineMaterialA = new THREE.LineBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.32,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    const lineMaterialB = new THREE.LineBasicMaterial({
      color: CONFIG.colors.violet,
      transparent: true,
      opacity: 0.32,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });

    this.group.add(new THREE.Line(lineGeometryA, lineMaterialA));
    this.group.add(new THREE.Line(lineGeometryB, lineMaterialB));

    // 横杆：每 3 个节点连接一次，带渐变色
    const rungPositions: number[] = [];
    const rungColors: number[] = [];
    const cyan = new THREE.Color(CONFIG.colors.cyan);
    const violet = new THREE.Color(CONFIG.colors.violet);

    for (let i = 0; i < STEPS; i += 3) {
      const t = i / (STEPS - 1);
      const angle = t * Math.PI * 2 * TURNS;
      const y = (t - 0.5) * HEIGHT;
      const x = Math.cos(angle) * RADIUS;
      const z = Math.sin(angle) * RADIUS;
      rungPositions.push(x, y, z, -x, y, -z);
      rungColors.push(cyan.r, cyan.g, cyan.b, violet.r, violet.g, violet.b);
    }

    const rungGeometry = new THREE.BufferGeometry();
    rungGeometry.setAttribute('position', new THREE.Float32BufferAttribute(rungPositions, 3));
    rungGeometry.setAttribute('color', new THREE.Float32BufferAttribute(rungColors, 3));
    this.rungMaterial = new THREE.LineBasicMaterial({
      vertexColors: true,
      transparent: true,
      opacity: 0.38,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    this.group.add(new THREE.LineSegments(rungGeometry, this.rungMaterial));

    this.axisMaterial = new THREE.MeshBasicMaterial({
      color: CONFIG.colors.cyan,
      transparent: true,
      opacity: 0.16,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
    const axis = new THREE.Mesh(new THREE.CylinderGeometry(0.01, 0.01, HEIGHT + 0.5, 6, 1, true), this.axisMaterial);
    this.group.add(axis);

    this.group.add(this.strandA);
    this.group.add(this.strandB);
    this.group.rotation.x = 0.14;

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
    this.group.rotation.y += dt * 0.32;
    this.group.position.y = Math.sin(elapsed * 0.7) * 0.07;
    this.strandA.rotation.y = 0;
    this.strandB.rotation.y = 0;
    const pulse = 1 + Math.sin(this.time * 1.6) * 0.008;
    this.group.scale.setScalar(pulse);
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
