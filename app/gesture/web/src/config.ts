/**
 * 全场可调参数。现场调参只改这一处。
 * 时间单位为秒，颜色为 THREE 数值色（0xRRGGBB）。
 */
export type QualityLevel = 'high' | 'medium' | 'low';

export interface QualityPreset {
  label: string;
  /** 渲染分辨率上限（相对 CSS 像素的 devicePixelRatio 上限） */
  pixelRatioMax: number;
  bloom: boolean;
  /** Bloom 强度倍率（叠加在 CONFIG.visual.bloomStrength 上） */
  bloomScale: number;
  particleFraction: number;
  starFraction: number;
  explosionFraction: number;
}

/** 画质档位：帧率不足时由 AppController 自动逐级降档，也可用 ?quality= 指定。 */
export const QUALITY_PRESETS: Record<QualityLevel, QualityPreset> = {
  high: {
    label: 'HIGH',
    pixelRatioMax: 2,
    bloom: true,
    bloomScale: 1,
    particleFraction: 1,
    starFraction: 1,
    explosionFraction: 1,
  },
  medium: {
    label: 'MEDIUM',
    pixelRatioMax: 1.25,
    bloom: true,
    bloomScale: 0.7,
    particleFraction: 0.7,
    starFraction: 0.7,
    explosionFraction: 0.8,
  },
  low: {
    label: 'LOW',
    pixelRatioMax: 1,
    bloom: false,
    bloomScale: 0,
    particleFraction: 0.45,
    starFraction: 0.5,
    explosionFraction: 0.55,
  },
};

export const CONFIG = {
  serial: {
    baudRate: 115200,
    maxLineBytes: 64,
    /** 单条指令默认去重窗口 */
    debounceMs: 300,
    /** 每条指令的独立冷却窗口，覆盖 debounceMs */
    cooldowns: {
      START: 1000,
      FIST: 1000,
      POINT: 500,
      MODE: 400,
      CONFIRM: 1000,
      ULTIMATE: 5000,
      RESET: 300,
      IDLE: 400,
    } as Record<string, number>,
  },
  /**
   * 外部手势桥接：tools/gesture-bridge 在本机跑一个 SSE 服务，
   * 把串口里的手势翻译成 START / FIST / MODE 等指令推给页面。
   * 页面用 ?bridge=<端口> 覆盖，?bridge=off 关闭。
   */
  bridge: {
    enabled: true,
    port: 8765,
    maxLineBytes: 64,
  },
  timings: {
    boot: 2.5,
    release: 0.3,
    compressEnter: 0.6,
    compressExit: 0.4,
    confirm: 1.5,
    ultimate: 3.0,
    modeSwitch: 0.6,
  },
  visual: {
    particleCount: 12000,
    starCount: 4200,
    explosionCount: 3200,
    bloomStrength: 0.85,
    bloomRadius: 0.5,
    bloomThreshold: 0.62,
    pixelRatioMax: 2,
    cameraZ: 6.4,
    cameraZCompress: 5.5,
    cameraZMode: 6.7,
  },
  colors: {
    background: 0x05070d,
    cyan: 0x39e6ff,
    violet: 0x8a5cff,
    white: 0xeaf6ff,
    charge: 0xffb347,
    deep: 0x0a1220,
  },
} as const;

export type Config = typeof CONFIG;

export const CSS_COLORS = {
  background: '#05070d',
  cyan: '#39e6ff',
  violet: '#8a5cff',
  white: '#eaf6ff',
  charge: '#ffb347',
  dim: '#6f8ca0',
} as const;
