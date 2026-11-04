/**
 * wave-thumb.ts —— 样式下拉列表里的静态缩略图
 *
 * 缩略图不接音频：用固定 seed 的装饰信号跑同一套渲染器，
 * 所以列表里看到的形状和选中后真正画出来的是同一段代码，不会「图不对版」。
 */

import { createWaveSampler } from './wave-signal';
import { buildGradient, rampColor, type WaveStyle } from './wave-styles';

/** 固定种子 + 固定相位：每次打开下拉，缩略图都长同一个样子。 */
const THUMB_SEED = 'wave-thumb';
const THUMB_PHASE = 1.15;

/** 缩略图默认尺寸（CSS 像素），画布没布局出来时按这个兜底。 */
export const THUMB_WIDTH = 76;
export const THUMB_HEIGHT = 28;

export function renderWaveThumb(canvas: HTMLCanvasElement, style: WaveStyle): void {
  const ctx = canvas.getContext('2d');
  if (!ctx) {
    return;
  }
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  const width = canvas.clientWidth || THUMB_WIDTH;
  const height = canvas.clientHeight || THUMB_HEIGHT;
  canvas.width = Math.round(width * dpr);
  canvas.height = Math.round(height * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const bandCount = Math.max(14, Math.round(width / 3));
  const frame = createWaveSampler().read({
    playing: false,
    phase: THUMB_PHASE,
    dt: 0,
    seed: THUMB_SEED,
    bandCount,
    waveCount: Math.max(64, Math.round(width)),
    width,
    height,
  });

  style.draw({
    ctx,
    frame,
    grad: buildGradient(ctx, style.ramp, width),
    peaks: new Float32Array(bandCount),
    colorAt: (t, sat = 92, light = 58) => rampColor(style.ramp, t, sat, light),
  });
}
