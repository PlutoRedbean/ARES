import './style.css';
import { AppController } from './app/AppController';

declare global {
  interface Window {
    __ARES__?: AppController;
  }
}

const canvas = document.getElementById('stage');
if (!(canvas instanceof HTMLCanvasElement)) {
  throw new Error('缺少 #stage canvas');
}

function loadLogoImage(): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => resolve(null);
    image.src = `${import.meta.env.BASE_URL}ares-logo.svg`;
  });
}

async function boot(): Promise<void> {
  const logoImage = await loadLogoImage();

  let app: AppController;
  try {
    app = new AppController(canvas as HTMLCanvasElement, logoImage);
  } catch (error) {
    console.error('[ares] 初始化失败', error);
    const note = document.getElementById('start-note');
    if (note) {
      note.textContent =
        '初始化失败：当前浏览器可能不支持 WebGL。请使用最新版 Chrome / Edge，并确认已启用硬件加速。';
    }
    throw error;
  }

  window.__ARES__ = app;

  const params = new URLSearchParams(window.location.search);
  if (params.get('debug') === '1') {
    app.openDebug();
  }

  const quality = params.get('quality');
  if (quality === 'high' || quality === 'medium' || quality === 'low') {
    app.setQuality(quality, false);
  }

  const scene = params.get('scene');
  if (scene) {
    window.setTimeout(() => app.applyScenePreset(scene), 350);
  } else if (params.get('demo') === '1') {
    window.setTimeout(() => app.enableDemo(), 400);
  } else if (params.get('autostart') === '1') {
    window.setTimeout(() => app.startShow(false, false), 350);
  }
}

void boot().catch((error: unknown) => {
  console.error('[ares] boot failed', error);
});
