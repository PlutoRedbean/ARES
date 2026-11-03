import * as THREE from 'three';

/**
 * 收集一个组内所有材质，并按统一的不透明度淡入/淡出。
 * ShaderMaterial 通过 uOpacity uniform 控制，其余材质走 material.opacity。
 */
export class ModelFader {
  private readonly items: Array<{ material: THREE.Material; base: number }> = [];
  private value = 0;

  constructor(root: THREE.Object3D) {
    const seen = new Set<THREE.Material>();
    root.traverse((child) => {
      const withMaterial = child as THREE.Mesh;
      const material = withMaterial.material as THREE.Material | THREE.Material[] | undefined;
      if (!material) return;
      const list = Array.isArray(material) ? material : [material];
      for (const item of list) {
        if (seen.has(item)) continue;
        seen.add(item);
        let base = 1;
        if (item.userData.baseOpacity !== undefined) {
          base = item.userData.baseOpacity as number;
        } else if (item instanceof THREE.ShaderMaterial && item.uniforms.uOpacity) {
          base = 1;
        } else if (item.transparent) {
          base = item.opacity;
        }
        this.items.push({ material: item, base });
      }
    });
  }

  set(value: number): void {
    this.value = value;
    const clamped = Math.max(0, Math.min(1, value));
    for (const item of this.items) {
      const material = item.material;
      const alpha = item.base * clamped;
      if (material instanceof THREE.ShaderMaterial && material.uniforms.uOpacity) {
        material.uniforms.uOpacity.value = alpha;
      } else {
        material.transparent = true;
        material.opacity = alpha;
        if (material.userData.baseDepthWrite !== undefined) {
          material.depthWrite = Boolean(material.userData.baseDepthWrite) && clamped > 0.98;
        }
      }
      material.visible = clamped > 0.002;
    }
  }

  get current(): number {
    return this.value;
  }
}
