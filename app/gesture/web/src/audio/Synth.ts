import type { Command } from '../app/commands';

export type SoundName = Command | 'CHARGE' | 'SCAN' | 'UI' | 'ERROR';

/**
 * 纯 WebAudio 程序化音效，无外部音频文件。
 * 必须在用户手势里调用 unlock()。
 */
export class Synth {
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private noiseBuffer: AudioBuffer | null = null;
  private muted = false;

  get isMuted(): boolean {
    return this.muted;
  }

  get isReady(): boolean {
    return this.ctx !== null && this.ctx.state === 'running';
  }

  unlock(): void {
    if (typeof window === 'undefined') return;
    if (!this.ctx) {
      const Ctor =
        window.AudioContext ??
        (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (!Ctor) return;
      try {
        this.ctx = new Ctor();
        this.master = this.ctx.createGain();
        this.master.gain.value = this.muted ? 0 : 0.32;
        this.master.connect(this.ctx.destination);
        this.noiseBuffer = this.createNoiseBuffer(this.ctx);
      } catch {
        this.ctx = null;
      }
    }
    if (this.ctx && this.ctx.state === 'suspended') {
      void this.ctx.resume();
    }
  }

  toggleMute(): boolean {
    this.muted = !this.muted;
    if (this.master && this.ctx) {
      this.master.gain.setTargetAtTime(this.muted ? 0 : 0.32, this.ctx.currentTime, 0.02);
    }
    return this.muted;
  }

  play(name: SoundName): void {
    if (!this.ctx || !this.master || this.muted) return;
    switch (name) {
      case 'START':
        this.sweep(90, 720, 1.8, 'sine', 0.36, 0);
        this.sweep(180, 1440, 1.8, 'triangle', 0.08, 0.05);
        this.noise(2.0, 'highpass', 1200, 0.06, 0.2);
        break;
      case 'FIST':
        this.sweep(96, 38, 0.55, 'sine', 0.5, 0);
        this.noise(0.32, 'lowpass', 520, 0.28, 0);
        break;
      case 'POINT':
        this.blip(1480, 0.06, 0.16);
        this.blip(2200, 0.035, 0.09, 0.035);
        break;
      case 'MODE':
        this.sweep(420, 880, 0.14, 'triangle', 0.18, 0);
        this.sweep(660, 1320, 0.16, 'sine', 0.14, 0.09);
        break;
      case 'CONFIRM':
        this.chord([523.25, 659.25, 783.99, 1046.5], 0.85, 0.11);
        this.noise(0.5, 'highpass', 2400, 0.05, 0);
        break;
      case 'ULTIMATE':
        this.noise(1.4, 'lowpass', 1400, 0.5, 0);
        this.sweep(120, 28, 1.5, 'sawtooth', 0.32, 0);
        this.sweep(900, 120, 0.9, 'square', 0.08, 0.05);
        break;
      case 'RESET':
        this.sweep(720, 160, 0.4, 'sine', 0.18, 0);
        break;
      case 'CHARGE':
        this.sweep(120, 60, 0.3, 'sine', 0.28, 0);
        this.noise(0.18, 'lowpass', 700, 0.12, 0);
        break;
      case 'SCAN':
        this.blip(1780, 0.05, 0.1);
        break;
      case 'UI':
        this.blip(980, 0.04, 0.07);
        break;
      case 'ERROR':
        this.sweep(300, 150, 0.25, 'square', 0.12, 0);
        break;
      default:
        break;
    }
  }

  private createNoiseBuffer(ctx: AudioContext): AudioBuffer {
    const length = Math.floor(ctx.sampleRate * 2);
    const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    for (let i = 0; i < length; i += 1) {
      data[i] = Math.random() * 2 - 1;
    }
    return buffer;
  }

  private sweep(
    from: number,
    to: number,
    duration: number,
    type: OscillatorType,
    gainValue: number,
    delay: number,
  ): void {
    if (!this.ctx || !this.master) return;
    const t0 = this.ctx.currentTime + delay;
    const osc = this.ctx.createOscillator();
    const gain = this.ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(Math.max(1, from), t0);
    osc.frequency.exponentialRampToValueAtTime(Math.max(1, to), t0 + duration);
    gain.gain.setValueAtTime(0.0001, t0);
    gain.gain.exponentialRampToValueAtTime(gainValue, t0 + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, t0 + duration);
    osc.connect(gain);
    gain.connect(this.master);
    osc.start(t0);
    osc.stop(t0 + duration + 0.05);
  }

  private blip(frequency: number, duration: number, gainValue: number, delay = 0): void {
    if (!this.ctx || !this.master) return;
    const t0 = this.ctx.currentTime + delay;
    const osc = this.ctx.createOscillator();
    const gain = this.ctx.createGain();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(frequency, t0);
    gain.gain.setValueAtTime(0.0001, t0);
    gain.gain.exponentialRampToValueAtTime(gainValue, t0 + 0.008);
    gain.gain.exponentialRampToValueAtTime(0.0001, t0 + duration);
    osc.connect(gain);
    gain.connect(this.master);
    osc.start(t0);
    osc.stop(t0 + duration + 0.02);
  }

  private chord(frequencies: number[], duration: number, gainValue: number): void {
    frequencies.forEach((frequency, index) => {
      this.sweep(frequency, frequency * 1.002, duration, 'sine', gainValue, index * 0.03);
    });
  }

  private noise(
    duration: number,
    filterType: BiquadFilterType,
    cutoff: number,
    gainValue: number,
    delay: number,
  ): void {
    if (!this.ctx || !this.master || !this.noiseBuffer) return;
    const t0 = this.ctx.currentTime + delay;
    const source = this.ctx.createBufferSource();
    source.buffer = this.noiseBuffer;
    source.loop = true;
    const filter = this.ctx.createBiquadFilter();
    filter.type = filterType;
    filter.frequency.setValueAtTime(cutoff, t0);
    if (filterType === 'lowpass') {
      filter.frequency.exponentialRampToValueAtTime(Math.max(80, cutoff * 0.25), t0 + duration);
    }
    const gain = this.ctx.createGain();
    gain.gain.setValueAtTime(0.0001, t0);
    gain.gain.exponentialRampToValueAtTime(gainValue, t0 + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, t0 + duration);
    source.connect(filter);
    filter.connect(gain);
    gain.connect(this.master);
    source.start(t0);
    source.stop(t0 + duration + 0.05);
  }
}
