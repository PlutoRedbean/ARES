import * as THREE from 'three';
import type { ModeId } from '../../app/stateMachine';

export { ModelFader } from '../MaterialFader';

export interface HoloModel {
  readonly id: ModeId;
  readonly group: THREE.Group;
  update(dt: number, elapsed: number): void;
  setOpacity(value: number): void;
  dispose(): void;
}
