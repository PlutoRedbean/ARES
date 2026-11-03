import * as THREE from 'three';
import type { Stage } from '../scene/Stage';
import { Starfield } from '../scene/Starfield';
import { LogoParticles } from '../scene/LogoParticles';
import { HoloSphere } from '../scene/HoloSphere';
import { Planet } from '../scene/modes/Planet';
import { Dna } from '../scene/modes/Dna';
import { Soc } from '../scene/modes/Soc';
import type { HoloModel } from '../scene/modes/HoloModel';
import { LaserScan } from '../fx/LaserScan';
import { EnergyWave } from '../fx/EnergyWave';
import { Explosion } from '../fx/Explosion';
import { Transition } from '../fx/Transition';
import { CONFIG } from '../config';
import type { BaseState, ModeId, StateEvent, StateSnapshot } from './stateMachine';

function isModeState(state: BaseState): state is ModeId {
  return state === 'MODE_PLANET' || state === 'MODE_DNA' || state === 'MODE_SOC';
}

/** 逻辑状态 -> 场景表现。所有视觉对象都只由这里驱动。 */
export class EffectDirector {
  readonly starfield: Starfield;
  readonly logo: LogoParticles;
  readonly holo: HoloSphere;
  readonly laser: LaserScan;
  readonly waves: EnergyWave;
  readonly explosion: Explosion;
  readonly transition: Transition;
  private readonly models: Record<ModeId, HoloModel>;
  private readonly modelOpacity: Record<ModeId, number> = {
    MODE_PLANET: 0,
    MODE_DNA: 0,
    MODE_SOC: 0,
  };
  private readonly stage: Stage;
  private elapsed = 0;
  private activeMode: ModeId | null = null;
  /** 模式切换时先让旧模型退场，再让新模型入场，避免两个模型叠加。 */
  private modeHold: { incoming: ModeId; elapsed: number } | null = null;
  private disposed = false;

  constructor(stage: Stage, logoImage: HTMLImageElement | null = null) {
    this.stage = stage;

    this.starfield = new Starfield(Math.min(window.devicePixelRatio, CONFIG.visual.pixelRatioMax));
    this.logo = new LogoParticles(
      Math.min(window.devicePixelRatio, CONFIG.visual.pixelRatioMax),
      logoImage,
    );
    this.holo = new HoloSphere();
    this.laser = new LaserScan();
    this.waves = new EnergyWave(20);
    this.explosion = new Explosion(Math.min(window.devicePixelRatio, CONFIG.visual.pixelRatioMax));
    this.transition = new Transition(stage.camera);

    this.models = {
      MODE_PLANET: new Planet(),
      MODE_DNA: new Dna(),
      MODE_SOC: new Soc(),
    };

    stage.scene.add(this.starfield.group);
    stage.scene.add(this.logo.points);
    stage.scene.add(this.holo.group);
    for (const model of Object.values(this.models)) stage.scene.add(model.group);
    stage.scene.add(this.laser.group);
    stage.scene.add(this.waves.group);
    stage.scene.add(this.explosion.group);

    this.logo.enterIdle();
    this.stage.setCameraFocus('default');
    this.transition.setAspect(stage.aspect);
  }

  handleEvents(events: StateEvent[], _state: StateSnapshot): void {
    for (const event of events) {
      switch (event.type) {
        case 'base':
          this.onBaseChange(event.from, event.to);
          break;
        case 'overlayStart':
          this.onOverlayStart(event.overlay);
          break;
        case 'overlayEnd':
          this.onOverlayEnd(event.overlay);
          break;
        case 'pulse':
          if (event.kind === 'charge') {
            this.holo.pulse();
            this.logo.pulseCharge();
            this.waves.spawn({
              count: 1,
              startRadius: 0.5,
              endRadius: 2.8,
              duration: 0.9,
              opacity: 0.4,
              color: CONFIG.colors.charge,
            });
          } else {
            this.laser.pulse();
            this.logo.pulseScan();
          }
          break;
        case 'mode':
          this.showMode(event.mode);
          break;
        case 'reset':
          this.resetVisuals();
          break;
        case 'ignored':
        case 'pending':
          break;
        default:
          break;
      }
    }
  }

  update(dt: number, state: StateSnapshot): void {
    if (this.disposed) return;
    this.elapsed += dt;

    const overlayActive = state.overlay !== 'NONE';
    let logoOpacity: number;
    if (overlayActive) {
      logoOpacity = 1;
    } else {
      switch (state.base) {
        case 'IDLE':
          logoOpacity = 0.14;
          break;
        case 'TRACK':
          logoOpacity = 0.38;
          break;
        case 'MODE_PLANET':
        case 'MODE_DNA':
        case 'MODE_SOC':
          logoOpacity = 0;
          break;
        default:
          logoOpacity = 1;
          break;
      }
    }
    this.logo.setOpacity(logoOpacity);
    this.logo.update(dt);

    this.holo.update(dt);
    this.laser.update(dt, this.stage.camera);
    this.waves.update(dt, this.stage.camera);
    this.explosion.update(dt);
    this.transition.update(dt);
    this.starfield.update(dt, this.elapsed);

    if (!state.mode) {
      this.activeMode = null;
      this.modeHold = null;
    } else if (this.modeHold) {
      if (state.mode !== this.modeHold.incoming) {
        this.modeHold = null;
      } else {
        this.modeHold.elapsed += dt;
      }
    }
    const holdIncoming =
      this.modeHold && this.modeHold.elapsed < 0.12 ? this.modeHold.incoming : null;

    for (const model of Object.values(this.models)) {
      const id = model.id;
      if (holdIncoming === id) {
        // 旧模型还没退干净时，新模型保持不可见
        this.modelOpacity[id] = 0;
        model.setOpacity(0);
        model.update(dt, this.elapsed);
        continue;
      }
      const target = state.base === id ? 1 : 0;
      const current = this.modelOpacity[id];
      // 出场比入场快得多：旧模型在约 0.1 s 内消失
      const rate = target > current ? 8 : 36;
      let next = current + (target - current) * (1 - Math.exp(-dt * rate));
      if (target === 0 && next < 0.01) next = 0;
      this.modelOpacity[id] = next;
      model.setOpacity(next);
      model.update(dt, this.elapsed);
    }

    if (this.modeHold && this.modeHold.elapsed > 0.6) this.modeHold = null;
  }

  setPointer(x: number, y: number): void {
    this.laser.setPointer(x, y);
  }

  /** 降画质时压缩粒子数（不重建几何体），并同步所有场景对象的像素比。 */
  setQuality(preset: {
    particleFraction: number;
    starFraction: number;
    explosionFraction: number;
  }): void {
    this.logo.setParticleFraction(preset.particleFraction);
    this.starfield.setParticleFraction(preset.starFraction);
    this.explosion.setParticleFraction(preset.explosionFraction);
  }

  /** 临时显示所有对象渲染一帧，预编译 shader / 上传纹理，然后恢复可见性。 */
  warmup(): void {
    const hiddenObjects: THREE.Object3D[] = [];
    const hiddenMaterials: THREE.Material[] = [];

    this.stage.scene.traverse((object) => {
      if (!object.visible) {
        hiddenObjects.push(object);
        object.visible = true;
      }
      const material = (object as THREE.Mesh).material;
      if (!material) return;
      const list = Array.isArray(material) ? material : [material];
      for (const item of list) {
        if (!item.visible) {
          hiddenMaterials.push(item);
          item.visible = true;
        }
      }
    });

    this.stage.warmup();

    for (const material of hiddenMaterials) material.visible = false;
    for (const object of hiddenObjects) object.visible = false;
  }

  resize(width: number, height: number, pixelRatio: number): void {
    const pr = Math.min(pixelRatio, CONFIG.visual.pixelRatioMax);
    this.starfield.setPixelRatio(pr);
    this.logo.setPixelRatio(pr);
    this.explosion.setPixelRatio(pr);
    this.transition.setAspect(width / Math.max(1, height));
  }

  private onBaseChange(from: BaseState, to: BaseState): void {
    const leavingCompress = from === 'COMPRESS' && to !== 'COMPRESS';
    const leavingTrack = from === 'TRACK' && to !== 'TRACK';
    const leavingMode = isModeState(from) && !isModeState(to);

    if (leavingCompress) {
      this.holo.exit();
      this.logo.setShape('logo');
    }
    if (leavingTrack) this.laser.exit();
    if (leavingMode) {
      this.activeMode = null;
      this.modeHold = null;
      if (to === 'READY') {
        this.transition.trigger(CONFIG.colors.cyan, CONFIG.timings.release);
      }
    }

    switch (to) {
      case 'IDLE':
        this.resetVisuals();
        break;
      case 'READY':
        this.stage.setCameraFocus('default');
        this.logo.setShape('logo');
        if (from !== 'READY' && from !== 'IDLE') {
          this.transition.trigger(CONFIG.colors.cyan, CONFIG.timings.release);
        }
        break;
      case 'COMPRESS':
        this.logo.setShape('sphere');
        this.holo.enter();
        this.stage.setCameraFocus('compress');
        this.transition.trigger(CONFIG.colors.cyan, 0.5);
        break;
      case 'TRACK':
        this.logo.setShape('logo');
        this.laser.enter();
        this.stage.setCameraFocus('default');
        this.transition.trigger(CONFIG.colors.cyan, 0.45);
        break;
      case 'MODE_PLANET':
      case 'MODE_DNA':
      case 'MODE_SOC':
        this.stage.setCameraFocus('mode');
        this.logo.setShape('logo');
        this.transition.trigger(CONFIG.colors.violet, CONFIG.timings.modeSwitch);
        break;
      default:
        break;
    }
  }

  private onOverlayStart(overlay: StateSnapshot['overlay']): void {
    switch (overlay) {
      case 'BOOT':
        this.logo.playBoot();
        this.waves.spawn({
          count: 1,
          startRadius: 0.3,
          endRadius: 6,
          duration: 1.9,
          opacity: 0.35,
          color: CONFIG.colors.cyan,
        });
        this.stage.bloomBurst(0.5);
        this.transition.trigger(CONFIG.colors.cyan, 0.55);
        break;
      case 'CONFIRM':
        this.logo.pulseCharge();
        this.waves.spawn({
          count: 3,
          startRadius: 0.4,
          endRadius: 4.4,
          duration: 1.35,
          delay: 0.14,
          opacity: 0.45,
          color: CONFIG.colors.cyan,
        });
        this.stage.shake(0.26);
        this.stage.bloomBurst(0.9);
        this.transition.trigger(CONFIG.colors.cyan, 0.55);
        break;
      case 'ULTIMATE':
        this.logo.explodeNow();
        this.explosion.burst();
        this.waves.spawn({
          count: 2,
          startRadius: 0.8,
          endRadius: 8.5,
          duration: 1.7,
          opacity: 0.55,
          color: CONFIG.colors.white,
        });
        this.stage.shake(1.15);
        this.stage.glitch(1);
        this.stage.bloomBurst(2.2);
        this.transition.trigger(CONFIG.colors.white, 0.9);
        break;
      default:
        break;
    }
  }

  private onOverlayEnd(overlay: StateSnapshot['overlay']): void {
    switch (overlay) {
      case 'BOOT':
        this.waves.spawn({
          count: 1,
          startRadius: 0.5,
          endRadius: 5,
          duration: 1.6,
          opacity: 0.3,
          color: CONFIG.colors.cyan,
        });
        this.stage.bloomBurst(0.4);
        break;
      case 'CONFIRM':
        this.transition.trigger(CONFIG.colors.cyan, 0.4);
        break;
      case 'ULTIMATE':
        this.stage.glitch(0.35);
        break;
      default:
        break;
    }
  }

  private showMode(mode: ModeId): void {
    const previous = this.activeMode;
    this.activeMode = mode;
    if (previous && previous !== mode) {
      // 旧模型先退场约 0.12 s，新模型再开始淡入
      this.modeHold = { incoming: mode, elapsed: 0 };
    } else {
      this.modeHold = null;
    }
    this.stage.setCameraFocus('mode');
    this.transition.trigger(CONFIG.colors.violet, CONFIG.timings.modeSwitch);
  }

  private resetVisuals(): void {
    this.activeMode = null;
    this.modeHold = null;
    this.logo.enterIdle();
    this.holo.exit();
    this.laser.exit();
    this.explosion.cancel();
    this.stage.setCameraFocus('default');
    this.stage.glitch(0);
    for (const id of Object.keys(this.models) as ModeId[]) {
      this.modelOpacity[id] = 0;
      this.models[id].setOpacity(0);
    }
  }

  dispose(): void {
    this.disposed = true;
    this.starfield.dispose();
    this.logo.dispose();
    this.holo.dispose();
    this.laser.dispose();
    this.waves.dispose();
    this.explosion.dispose();
    this.transition.dispose();
    for (const model of Object.values(this.models)) model.dispose();
  }
}
