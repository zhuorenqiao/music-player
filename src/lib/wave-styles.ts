/**
 * wave-styles.ts —— 彩色波形的样式注册表
 *
 * 形态逐格对照参考图（2 列 × 8 行 = 16 种），另外保留项目里原本那条
 * 「底部彩虹柱 + 峰值点阵」作为默认样式，切换时不至于把已定稿的观感弄丢。
 *
 * 所有样式只读 WaveFrame（bands / wave / level / phase），不碰音频链路；
 * 数据从哪来（真实频谱还是装饰信号）由 wave-signal 决定，样式层不关心。
 *
 * 配色沿用参考图的高饱和霓虹，但色相收敛到项目已有的紫红→橙→金这一段，
 *  cool 端接回 --accent 的青绿，避免整块界面变成另一种设计语言。
 */

import type { WaveFrame } from './wave-signal';

const TAU = Math.PI * 2;

// ---------------------------------------------------------------------------
// 渐变
// ---------------------------------------------------------------------------

export type RampId = 'sunset' | 'ember' | 'neon';

/** 色标里的 hue 允许超过 360，这样 344°→16° 这种「跨过红端」的过渡不会倒着走。 */
const HUE_RAMPS: Record<RampId, Array<[number, number]>> = {
  // 紫 → 品红 → 玫红 → 橙 → 金（参考图主色）
  sunset: [[0, 272], [0.26, 312], [0.5, 344], [0.74, 376], [1, 404]],
  // 玫红 → 橙 → 金（暖色那几张）
  ember: [[0, 340], [0.34, 368], [0.66, 386], [1, 406]],
  // 青绿 → 蓝 → 紫 → 品红 → 红（现有频谱条那条，接得住 --accent）
  neon: [[0, 148], [0.16, 178], [0.34, 212], [0.52, 262], [0.68, 300], [0.82, 340], [0.93, 372], [1, 456]],
};

function hueAt(ramp: RampId, t: number): number {
  const stops = HUE_RAMPS[ramp];
  const x = t < 0 ? 0 : t > 1 ? 1 : t;
  for (let i = 1; i < stops.length; i += 1) {
    if (x <= stops[i][0] || i === stops.length - 1) {
      const [o0, h0] = stops[i - 1];
      const [o1, h1] = stops[i];
      const span = o1 - o0;
      const k = span > 0 ? (x - o0) / span : 0;
      return h0 + (h1 - h0) * (k < 0 ? 0 : k > 1 ? 1 : k);
    }
  }
  return stops[0][1];
}

/** 取渐变上某一点的实色，供逐柱 / 逐线着色。 */
export function rampColor(ramp: RampId, t: number, sat = 92, light = 58): string {
  const hue = ((hueAt(ramp, t) % 360) + 360) % 360;
  return `hsl(${hue.toFixed(1)} ${sat}% ${light}%)`;
}

export function buildGradient(
  ctx: CanvasRenderingContext2D,
  ramp: RampId,
  width: number,
  sat = 92,
  light = 58,
): CanvasGradient {
  const grad = ctx.createLinearGradient(0, 0, width, 0);
  for (let i = 0; i <= 24; i += 1) {
    const t = i / 24;
    grad.addColorStop(t, rampColor(ramp, t, sat, light));
  }
  return grad;
}

// ---------------------------------------------------------------------------
// 画布小工具
// ---------------------------------------------------------------------------

function sampleAt(arr: Float32Array, t: number): number {
  const n = arr.length;
  if (n === 0) {
    return 0;
  }
  if (n === 1) {
    return arr[0];
  }
  const x = (t < 0 ? 0 : t > 1 ? 1 : t) * (n - 1);
  const i = Math.floor(x);
  const a = arr[i];
  const b = arr[Math.min(n - 1, i + 1)];
  return a + (b - a) * (x - i);
}

/** 三点加权滑动平均，passes 越大越圆润（彩带、山形要多遍，尖刺类一遍都不做）。 */
function smoothSeries(arr: Float32Array, passes: number): Float32Array {
  let out = arr;
  for (let p = 0; p < passes; p += 1) {
    const next = new Float32Array(out.length);
    for (let i = 0; i < out.length; i += 1) {
      const a = out[Math.max(0, i - 1)];
      const b = out[i];
      const c = out[Math.min(out.length - 1, i + 1)];
      next[i] = (a + b * 2 + c) / 4;
    }
    out = next;
  }
  return out;
}

function roundRectPath(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  const radius = Math.max(0, Math.min(r, w / 2, h / 2));
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.lineTo(x + w - radius, y);
  ctx.arcTo(x + w, y, x + w, y + radius, radius);
  ctx.lineTo(x + w, y + h - radius);
  ctx.arcTo(x + w, y + h, x + w - radius, y + h, radius);
  ctx.lineTo(x + radius, y + h);
  ctx.arcTo(x, y + h, x, y + h - radius, radius);
  ctx.lineTo(x, y + radius);
  ctx.arcTo(x, y, x + radius, y, radius);
  ctx.closePath();
}

/** 沿 x 前进的一列中心点 + 一半厚度 → 一条带子的闭合多边形。 */
function ribbonPolygon(
  ctx: CanvasRenderingContext2D,
  center: Float32Array,
  thick: Float32Array,
  step: number,
): void {
  ctx.beginPath();
  for (let i = 0; i < center.length; i += 1) {
    const x = i * step;
    const y = center[i] - thick[i];
    if (i === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  }
  for (let i = center.length - 1; i >= 0; i -= 1) {
    ctx.lineTo(i * step, center[i] + thick[i]);
  }
  ctx.closePath();
}

/** 两端收拢、中间张开，参考图里的波形几乎都有这个「纺锤」轮廓。 */
function spindle(t: number, power = 1): number {
  const s = Math.sin(Math.PI * t);
  return power === 1 ? s : s ** power;
}

/** 稳定伪随机：同一个 (列, 序号) 永远抖到同一个位置，散点才不会每帧「炒豆」。 */
function stableNoise(col: number, index: number): number {
  let h = (col * 0x9e3779b1) ^ (index * 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return (h >>> 0) / 0xffffffff;
}

// ---------------------------------------------------------------------------
// 样式接口
// ---------------------------------------------------------------------------

export interface StyleEnv {
  ctx: CanvasRenderingContext2D;
  frame: WaveFrame;
  /** 横向渐变，宿主按当前宽度和样式色带建好 */
  grad: CanvasGradient;
  /** 同 rampColor，但绑定当前样式的色带 */
  colorAt(t: number, sat?: number, light?: number): string;
  /** 峰值保持数组，长度与 frame.bands 一致；宿主每帧先衰减再交给样式 */
  peaks: Float32Array;
}

export interface WaveStyle {
  id: string;
  name: string;
  ramp: RampId;
  /** 需要峰值保持的样式，宿主才去维护 peaks */
  usesPeaks?: boolean;
  draw(env: StyleEnv): void;
}

/** 把 bands 抽稀成指定列数的采样点，同时保证 peaks 下标仍落在原数组上。 */
function strideIndexes(count: number, cols: number): number[] {
  const stride = Math.max(1, Math.round(count / cols));
  const out: number[] = [];
  for (let i = 0; i < count; i += stride) {
    out.push(i);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 样式
// ---------------------------------------------------------------------------

/** 0 · 项目原有的彩虹频谱柱 + 悬空峰值点 */
const spectrumStyle: WaveStyle = {
  id: 'spectrum',
  name: '彩虹频谱',
  ramp: 'neon',
  usesPeaks: true,
  draw({ ctx, frame, grad, peaks }) {
    const { width: w, height: h, bands } = frame;
    const count = bands.length;
    if (!count) {
      return;
    }
    const baseline = h - 8;
    const maxAmp = baseline - 8;
    const step = w / count;
    const barWidth = Math.max(1, step - 1);

    ctx.save();
    ctx.fillStyle = grad;
    ctx.shadowColor = 'rgba(255, 255, 255, 0.3)';
    ctx.shadowBlur = 6;
    for (let i = 0; i < count; i += 1) {
      const amp = bands[i] * maxAmp;
      ctx.fillRect(i * step, baseline - amp, barWidth, amp);
      peaks[i] = Math.max(amp, peaks[i]);
    }
    ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
    for (let i = 0; i < count; i += 3) {
      if (peaks[i] <= 0) {
        continue;
      }
      ctx.beginPath();
      ctx.arc(i * step + barWidth / 2, baseline - peaks[i] - 6, 1, 0, TAU);
      ctx.fill();
    }
    ctx.restore();
  },
};

/** 1 · 彩带：几条互相交叠的平滑缎带 */
const ribbonStyle: WaveStyle = {
  id: 'ribbon',
  name: '渐变彩带',
  ramp: 'sunset',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, wave, bands, level, phase } = frame;
    const mid = h / 2;
    const amp = mid;
    const line = smoothSeries(wave, 10);
    const points = Math.max(24, Math.min(72, Math.round(w / 4)));
    const step = w / points;
    const strands = [
      { amp: 0.24, freq: 1.5, off: -0.14, thick: 0.16, alpha: 0.92 },
      { amp: 0.21, freq: 2.1, off: 0, thick: 0.12, alpha: 0.78 },
      { amp: 0.18, freq: 1.05, off: 0.14, thick: 0.09, alpha: 0.62 },
    ];
    // 三条缎带对称排在中线两侧，整体才不会整块偏到上半栏
    const limit = amp - 2;

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.22)';
    ctx.shadowBlur = 5;
    strands.forEach((s, k) => {
      const center = new Float32Array(points + 1);
      const thick = new Float32Array(points + 1);
      for (let i = 0; i <= points; i += 1) {
        const t = i / points;
        const env = 0.28 + 0.72 * spindle(t);
        const shape = Math.sin(t * TAU * s.freq + phase * 1.5 + k * 1.15) * 0.62
          + Math.sin(t * TAU * s.freq * 2.1 - phase * 1.1 + k * 0.7) * 0.38;
        const v = shape * (0.4 + 0.6 * level) + sampleAt(line, t) * 0.5;
        const th = (1.4 + s.thick * h * 0.5) * (0.3 + 0.7 * sampleAt(bands, t));
        const y = mid + v * s.amp * h * env + s.off * h;
        center[i] = Math.max(mid - limit, Math.min(mid + limit, y));
        thick[i] = Math.min(th, limit - Math.abs(center[i] - mid));
      }
      ctx.globalAlpha = s.alpha;
      ctx.fillStyle = grad;
      ribbonPolygon(ctx, center, thick, step);
      ctx.fill();
    });
    ctx.restore();
  },
};

/** 2 · 密集细线：一根根发丝竖线，跟着响度包络鼓包 */
const hairlineStyle: WaveStyle = {
  id: 'hairline',
  name: '细线爆发',
  ramp: 'ember',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, bands } = frame;
    const mid = h / 2;
    const amp = mid - 3;
    const env = smoothSeries(bands, 2);

    ctx.save();
    ctx.strokeStyle = grad;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.92;
    ctx.beginPath();
    for (let x = 0; x < w; x += 2) {
      const t = x / w;
      const a = Math.max(0.6, sampleAt(env, t) * amp);
      ctx.moveTo(x + 0.5, mid - a);
      ctx.lineTo(x + 0.5, mid + a);
    }
    ctx.stroke();
    ctx.restore();
  },
};

/** 3 · 双正弦：一条基准线 + 两三条不同频率的平滑正弦 */
const sineStyle: WaveStyle = {
  id: 'sine',
  name: '双正弦线',
  ramp: 'sunset',
  draw({ ctx, frame, grad, colorAt }) {
    const { width: w, height: h, wave, level, phase, seed } = frame;
    const mid = h / 2;
    const amp = mid - 3;
    const line = smoothSeries(wave, 12);
    const root = seed ? seed.charCodeAt(0) + seed.length : 7;
    const f1 = 1.4 + (root % 5) * 0.3;
    const f2 = 2.6 + ((root >> 2) % 4) * 0.35;

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.2)';
    ctx.shadowBlur = 4;

    ctx.globalAlpha = 0.55;
    ctx.strokeStyle = grad;
    ctx.lineWidth = 1.2;
    ctx.beginPath();
    ctx.moveTo(0, mid + 0.5);
    ctx.lineTo(w, mid + 0.5);
    ctx.stroke();

    const curves = [
      { f: f1, speed: 1.6, weight: 0.78, width: 2.4, alpha: 0.95, color: grad },
      { f: f2, speed: -1.1, weight: 0.5, width: 1.6, alpha: 0.8, color: colorAt(0.18) },
      { f: f1 * 0.55, speed: 0.7, weight: 0.34, width: 1.2, alpha: 0.45, color: colorAt(0.72) },
    ];
    const points = Math.max(28, Math.round(w / 4));
    curves.forEach((c) => {
      ctx.globalAlpha = c.alpha;
      ctx.strokeStyle = c.color;
      ctx.lineWidth = c.width;
      ctx.beginPath();
      for (let i = 0; i <= points; i += 1) {
        const t = i / points;
        const x = t * w;
        const shape = Math.sin(t * TAU * c.f + phase * c.speed) * 0.8
          + sampleAt(line, t) * 0.6;
        const y = mid + shape * amp * (0.5 + 0.5 * level) * spindle(t, 0.6);
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.stroke();
    });
    ctx.restore();
  },
};

/** 4 · 圆头对称柱：上下对称的胶囊柱，峰值处再甩一颗孤点 */
const roundBarsStyle: WaveStyle = {
  id: 'roundBars',
  name: '对称胶囊柱',
  ramp: 'sunset',
  usesPeaks: true,
  draw({ ctx, frame, grad, colorAt, peaks }) {
    const { width: w, height: h, bands } = frame;
    const mid = h / 2;
    const amp = mid - 4;
    const cols = Math.max(9, Math.round(w / 14));
    const idx = strideIndexes(bands.length, cols);
    const step = w / idx.length;
    const barWidth = Math.max(3, Math.min(5.5, step * 0.42));

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.25)';
    ctx.shadowBlur = 5;
    idx.forEach((bandIndex, k) => {
      const t = bandIndex / Math.max(1, bands.length - 1);
      const v = bands[bandIndex];
      const a = Math.max(barWidth / 2, v * amp);
      const x = k * step + (step - barWidth) / 2;
      ctx.fillStyle = k % 2 === 0 ? grad : colorAt(t, 90, 64);
      roundRectPath(ctx, x, mid - a, barWidth, a * 2, barWidth / 2);
      ctx.fill();
      peaks[bandIndex] = Math.max(a, peaks[bandIndex]);
      if (peaks[bandIndex] > amp * 0.62) {
        ctx.fillStyle = colorAt(t, 92, 70);
        ctx.beginPath();
        ctx.arc(x + barWidth / 2, mid - peaks[bandIndex] - 4, 1.4, 0, TAU);
        ctx.fill();
      }
    });
    ctx.restore();
  },
};

/** 5 · 胖包络：整条糊成一坨平滑的、上下镜像的能量块 */
const blobStyle: WaveStyle = {
  id: 'blob',
  name: '平滑胖包络',
  ramp: 'sunset',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, bands } = frame;
    const mid = h / 2;
    const amp = mid - 3;
    const env = smoothSeries(bands, 5);
    const points = Math.max(24, Math.round(w / 4));
    const step = w / points;

    const edge = (scale: number, offset: number): [Float32Array, Float32Array] => {
      const top = new Float32Array(points + 1);
      const bottom = new Float32Array(points + 1);
      for (let i = 0; i <= points; i += 1) {
        const a = sampleAt(env, i / points) * amp * scale + offset;
        top[i] = mid - a;
        bottom[i] = mid + a;
      }
      return [top, bottom];
    };

    const paint = (top: Float32Array, bottom: Float32Array) => {
      ctx.beginPath();
      ctx.moveTo(0, top[0]);
      for (let i = 1; i <= points; i += 1) {
        ctx.lineTo(i * step, top[i]);
      }
      for (let i = points; i >= 0; i -= 1) {
        ctx.lineTo(i * step, bottom[i]);
      }
      ctx.closePath();
      ctx.fill();
    };

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.2)';
    ctx.shadowBlur = 6;
    ctx.globalAlpha = 0.8;
    ctx.fillStyle = grad;
    const [t1, b1] = edge(1, 1);
    paint(t1, b1);
    ctx.globalAlpha = 0.9;
    ctx.fillStyle = grad;
    const [t2, b2] = edge(0.42, 0.5);
    paint(t2, b2);
    ctx.restore();
  },
};

/** 6 · 多股细线：一束平行曲线，两端收拢、中间张开 */
const strandsStyle: WaveStyle = {
  id: 'strands',
  name: '多股细线',
  ramp: 'sunset',
  draw({ ctx, frame, colorAt }) {
    const { width: w, height: h, wave, level, phase } = frame;
    const mid = h / 2;
    const line = smoothSeries(wave, 9);
    const count = 9;
    const points = Math.max(28, Math.round(w / 4));
    const spread = h * 0.34;

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.18)';
    ctx.shadowBlur = 4;
    ctx.lineWidth = 1.2;
    for (let k = 0; k < count; k += 1) {
      const rel = (k - (count - 1) / 2) / ((count - 1) / 2);
      ctx.strokeStyle = colorAt(k / (count - 1), 92, 56 + (k % 3) * 5);
      ctx.globalAlpha = 0.62 + 0.3 * (1 - Math.abs(rel));
      ctx.beginPath();
      for (let i = 0; i <= points; i += 1) {
        const t = i / points;
        const x = t * w;
        const shape = sampleAt(line, t) * 0.75
          + Math.sin(t * TAU * 2.2 + phase * 1.8 + k * 0.4) * 0.25;
        const y = mid
          + shape * h * 0.3 * (0.4 + 0.6 * level)
          + rel * spread * spindle(t, 0.8);
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.stroke();
    }
    ctx.restore();
  },
};

/** 7 · 尖刺噪声：一像素一根的密集毛刺，中间压一条白芯 */
const noiseStyle: WaveStyle = {
  id: 'noise',
  name: '尖刺噪声',
  ramp: 'sunset',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, wave, bands } = frame;
    const mid = h / 2;
    const amp = mid - 2;
    const env = smoothSeries(bands, 3);

    ctx.save();
    ctx.strokeStyle = grad;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.9;
    ctx.shadowColor = 'rgba(255, 255, 255, 0.28)';
    ctx.shadowBlur = 5;
    ctx.beginPath();
    for (let x = 0; x < w; x += 1) {
      const t = x / w;
      const spike = Math.abs(sampleAt(wave, t));
      const a = Math.max(0.5, spike * amp * (0.45 + 0.9 * sampleAt(env, t)));
      ctx.moveTo(x + 0.5, mid - a);
      ctx.lineTo(x + 0.5, mid + a);
    }
    ctx.stroke();

    ctx.globalAlpha = 0.9;
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.9)';
    ctx.lineWidth = 1.4;
    ctx.beginPath();
    ctx.moveTo(0, mid);
    ctx.lineTo(w, mid);
    ctx.stroke();
    ctx.restore();
  },
};

/** 8 · 底部柱状：从底边起立的圆头柱，柱顶悬一颗峰值点 */
const histogramStyle: WaveStyle = {
  id: 'histogram',
  name: '底部柱状',
  ramp: 'sunset',
  usesPeaks: true,
  draw({ ctx, frame, grad, peaks }) {
    const { width: w, height: h, bands } = frame;
    const baseline = h - 2;
    const maxAmp = h - 8;
    const cols = Math.max(14, Math.round(w / 6));
    const idx = strideIndexes(bands.length, cols);
    const step = w / idx.length;
    const barWidth = Math.max(2, step - 2.4);

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.22)';
    ctx.shadowBlur = 5;
    ctx.fillStyle = grad;
    idx.forEach((bandIndex, k) => {
      const amp = Math.max(1.5, bands[bandIndex] * maxAmp);
      const x = k * step + (step - barWidth) / 2;
      roundRectPath(ctx, x, baseline - amp, barWidth, amp, barWidth / 2);
      ctx.fill();
      peaks[bandIndex] = Math.max(amp, peaks[bandIndex]);
    });
    ctx.fillStyle = 'rgba(255, 255, 255, 0.5)';
    idx.forEach((bandIndex, k) => {
      if (peaks[bandIndex] <= 0) {
        return;
      }
      ctx.beginPath();
      ctx.arc(k * step + step / 2, baseline - peaks[bandIndex] - 4, 1, 0, TAU);
      ctx.fill();
    });
    ctx.restore();
  },
};

/** 9 · 镜像平滑山：以中线为轴，平滑曲线一会儿鼓上一会儿鼓下 */
const mirrorAreaStyle: WaveStyle = {
  id: 'mirrorArea',
  name: '镜像平滑山',
  ramp: 'sunset',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, wave, level } = frame;
    const mid = h / 2;
    const amp = mid - 3;
    const line = smoothSeries(wave, 26);
    const points = Math.max(24, Math.round(w / 4));
    const step = w / points;

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.22)';
    ctx.shadowBlur = 6;
    ctx.fillStyle = grad;
    ctx.globalAlpha = 0.92;
    ctx.beginPath();
    ctx.moveTo(0, mid);
    for (let i = 0; i <= points; i += 1) {
      const t = i / points;
      const v = sampleAt(line, t) * (0.45 + 0.55 * level) * 2.2;
      ctx.lineTo(i * step, mid - v * amp);
    }
    ctx.lineTo(w, mid);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  },
};

/** 10 · 锯齿折线：时域信号直接连线，背后留一道重影 */
const jaggedStyle: WaveStyle = {
  id: 'jagged',
  name: '锯齿折线',
  ramp: 'sunset',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, wave, bands, level } = frame;
    const mid = h / 2;
    const amp = mid - 3;
    const env = smoothSeries(bands, 3);

    const trace = (scale: number, offset: number) => {
      ctx.beginPath();
      for (let x = 0; x <= w; x += 2) {
        const t = x / w;
        const v = sampleAt(wave, t) * scale * (0.4 + 0.6 * level) * 2
          * (0.35 + 0.8 * sampleAt(env, t));
        const y = mid + offset - v * amp;
        if (x === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.stroke();
    };

    ctx.save();
    ctx.lineJoin = 'round';
    ctx.strokeStyle = grad;
    ctx.globalAlpha = 0.28;
    ctx.lineWidth = 1;
    trace(0.7, 3);
    ctx.globalAlpha = 0.95;
    ctx.lineWidth = 1.6;
    ctx.shadowColor = 'rgba(255, 255, 255, 0.25)';
    ctx.shadowBlur = 4;
    trace(1, 0);
    ctx.restore();
  },
};

/** 11 · 白描边竖纹：外面一圈白描边，里面clip 出竖向条纹 */
const hatchStyle: WaveStyle = {
  id: 'hatch',
  name: '白描边竖纹',
  ramp: 'sunset',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, wave, bands } = frame;
    const mid = h / 2;
    const amp = mid - 3;
    const line = smoothSeries(wave, 14);
    const env = smoothSeries(bands, 3);
    const points = Math.max(24, Math.round(w / 4));
    const step = w / points;

    const build = () => {
      ctx.beginPath();
      for (let i = 0; i <= points; i += 1) {
        const t = i / points;
        const v = Math.abs(sampleAt(line, t)) * 1.8 * (0.3 + 0.7 * sampleAt(env, t)) + 0.06;
        const a = Math.min(amp, v * amp);
        if (i === 0) {
          ctx.moveTo(0, mid - a);
        } else {
          ctx.lineTo(i * step, mid - a);
        }
      }
      for (let i = points; i >= 0; i -= 1) {
        const t = i / points;
        const v = Math.abs(sampleAt(line, t)) * 1.8 * (0.3 + 0.7 * sampleAt(env, t)) + 0.06;
        ctx.lineTo(i * step, mid + Math.min(amp, v * amp));
      }
      ctx.closePath();
    };

    ctx.save();
    build();
    ctx.clip();
    ctx.fillStyle = grad;
    ctx.globalAlpha = 0.95;
    for (let x = 0; x < w; x += 4) {
      ctx.fillRect(x, 0, 2, h);
    }
    ctx.restore();

    ctx.save();
    build();
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.92)';
    ctx.lineWidth = 1.5;
    ctx.shadowColor = 'rgba(255, 255, 255, 0.4)';
    ctx.shadowBlur = 5;
    ctx.stroke();
    ctx.restore();
  },
};

/** 12 · 尖峰镜像：不做任何平滑，锐角三角峰上下镜像，中间一条亮线 */
const spikesStyle: WaveStyle = {
  id: 'spikes',
  name: '尖峰镜像',
  ramp: 'ember',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, bands } = frame;
    const mid = h / 2;
    const amp = mid - 2;
    if (!bands.length) {
      return;
    }
    // 参考图是二三十根粗尖峰，直接按频段画会糊成一片毛刺
    const cols = Math.max(10, Math.round(w / 13));
    const idx = strideIndexes(bands.length, cols);
    const step = w / idx.length;

    ctx.save();
    ctx.fillStyle = grad;
    ctx.globalAlpha = 0.9;
    ctx.shadowColor = 'rgba(255, 255, 255, 0.2)';
    ctx.shadowBlur = 5;
    ctx.beginPath();
    idx.forEach((bandIndex, k) => {
      const v = bands[bandIndex];
      const x = k * step;
      ctx.moveTo(x, mid);
      ctx.lineTo(x + step / 2, mid - v * amp);
      ctx.lineTo(x + step, mid);
      ctx.moveTo(x, mid);
      ctx.lineTo(x + step / 2, mid + v * amp * 0.8);
      ctx.lineTo(x + step, mid);
    });
    ctx.fill();

    ctx.globalAlpha = 0.85;
    ctx.strokeStyle = 'rgba(255, 246, 232, 0.95)';
    ctx.lineWidth = 1.6;
    ctx.beginPath();
    ctx.moveTo(0, mid);
    ctx.lineTo(w, mid);
    ctx.stroke();
    ctx.restore();
  },
};

/** 13 · 点阵 LED：方格堆出来的柱状图，最高一格单独留一颗余辉 */
const ledStyle: WaveStyle = {
  id: 'led',
  name: '点阵 LED',
  ramp: 'sunset',
  usesPeaks: true,
  draw({ ctx, frame, colorAt, peaks }) {
    const { width: w, height: h, bands } = frame;
    const pitch = 4;
    const cell = 3;
    const cols = Math.max(12, Math.floor(w / pitch));
    const idx = strideIndexes(bands.length, cols);
    const baseline = h - 2;
    const rows = Math.floor((baseline - 2) / pitch);

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.22)';
    ctx.shadowBlur = 4;
    idx.forEach((bandIndex, k) => {
      const t = bandIndex / Math.max(1, bands.length - 1);
      const lit = Math.round(bands[bandIndex] * rows);
      const x = k * pitch;
      ctx.fillStyle = colorAt(t, 92, 58);
      for (let r = 0; r < lit; r += 1) {
        ctx.fillRect(x, baseline - (r + 1) * pitch + cell, cell, cell);
      }
      peaks[bandIndex] = Math.max(lit, peaks[bandIndex]);
      const peak = Math.round(peaks[bandIndex]);
      if (peak > 0 && peak < rows) {
        ctx.fillStyle = colorAt(t, 96, 76);
        ctx.fillRect(x, baseline - (peak + 1) * pitch + cell, cell, cell);
      }
    });
    ctx.restore();
  },
};

/** 14 · 平行波纹线：一摞水平波浪线，跟着同一个形状一起摆 */
const flowStyle: WaveStyle = {
  id: 'flow',
  name: '平行波纹线',
  ramp: 'sunset',
  draw({ ctx, frame, colorAt }) {
    const { width: w, height: h, wave, level, phase } = frame;
    const mid = h / 2;
    const line = smoothSeries(wave, 12);
    const count = 7;
    const gap = (h * 0.66) / count;
    const points = Math.max(28, Math.round(w / 4));

    ctx.save();
    ctx.lineWidth = 1.3;
    ctx.shadowColor = 'rgba(255, 255, 255, 0.16)';
    ctx.shadowBlur = 4;
    for (let k = 0; k < count; k += 1) {
      const rel = (k - (count - 1) / 2) / ((count - 1) / 2);
      ctx.strokeStyle = colorAt(k / (count - 1), 92, 58);
      ctx.globalAlpha = 0.7 + 0.3 * (1 - Math.abs(rel));
      ctx.beginPath();
      for (let i = 0; i <= points; i += 1) {
        const t = i / points;
        const x = t * w;
        const shape = sampleAt(line, t) * 1.6 + Math.sin(t * TAU * 2.6 + phase * 1.4) * 0.2;
        const y = mid
          + rel * gap * (count / 2) * spindle(t, 0.7)
          + shape * h * 0.16 * (0.4 + 0.6 * level);
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.stroke();
    }
    ctx.restore();
  },
};

/** 15 · 点阵包络：用散点堆出上下镜像的包络，中间密两头疏 */
const dotsStyle: WaveStyle = {
  id: 'dots',
  name: '点阵包络',
  ramp: 'sunset',
  draw({ ctx, frame, colorAt }) {
    const { width: w, height: h, bands } = frame;
    const mid = h / 2;
    const amp = mid - 2;
    const env = smoothSeries(bands, 2);
    const pitch = 5;

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.2)';
    ctx.shadowBlur = 3;
    for (let x = pitch / 2, col = 0; x < w; x += pitch, col += 1) {
      const t = x / Math.max(1, w - 1);
      const v = sampleAt(env, t);
      const hh = Math.max(2, v * amp);
      // 宁疏勿密：一列最多三四颗，散在包络内部而不是糊成一片
      const dots = 1 + Math.round(v * 3);
      ctx.fillStyle = colorAt(t, 92, 56 + (col % 3) * 7);
      for (let d = 0; d < dots; d += 1) {
        const fy = 0.2 + 0.8 * stableNoise(col, d);
        const fx = (stableNoise(col + 512, d) - 0.5) * pitch * 0.9;
        const y = hh * fy;
        ctx.beginPath();
        ctx.arc(x + fx, mid - y, 1.2, 0, TAU);
        ctx.fill();
        ctx.beginPath();
        ctx.arc(x + fx, mid + y, 1.2, 0, TAU);
        ctx.fill();
      }
    }
    ctx.restore();
  },
};

/** 16 · 层叠山峰：从底边叠上来的几层半透明平滑山 */
const hillsStyle: WaveStyle = {
  id: 'hills',
  name: '层叠山峰',
  ramp: 'ember',
  draw({ ctx, frame, grad }) {
    const { width: w, height: h, bands } = frame;
    const baseline = h;
    // 平滑遍数一多，四层会塌成同一座山；靠「各自错开一点」拉开前后层次
    const layers = [
      { passes: 3, scale: 1, shift: 0, alpha: 0.45 },
      { passes: 3, scale: 0.78, shift: 0.12, alpha: 0.58 },
      { passes: 2, scale: 0.58, shift: -0.1, alpha: 0.72 },
      { passes: 2, scale: 0.4, shift: 0.22, alpha: 0.88 },
    ];
    const points = Math.max(24, Math.round(w / 4));
    const step = w / points;

    ctx.save();
    ctx.shadowColor = 'rgba(255, 255, 255, 0.18)';
    ctx.shadowBlur = 6;
    layers.forEach((layer, k) => {
      const env = smoothSeries(bands, layer.passes);
      ctx.globalAlpha = layer.alpha;
      ctx.fillStyle = grad;
      ctx.beginPath();
      ctx.moveTo(0, baseline);
      for (let i = 0; i <= points; i += 1) {
        const t = i / points;
        const shifted = (t + layer.shift + 1) % 1;
        const v = sampleAt(env, shifted) * layer.scale * (h - 6 - k * 2);
        ctx.lineTo(i * step, baseline - Math.max(2, v));
      }
      ctx.lineTo(w, baseline);
      ctx.closePath();
      ctx.fill();
    });
    ctx.restore();
  },
};

export const WAVE_STYLES: WaveStyle[] = [
  spectrumStyle,
  ribbonStyle,
  hairlineStyle,
  sineStyle,
  roundBarsStyle,
  blobStyle,
  strandsStyle,
  noiseStyle,
  histogramStyle,
  mirrorAreaStyle,
  jaggedStyle,
  hatchStyle,
  spikesStyle,
  ledStyle,
  flowStyle,
  dotsStyle,
  hillsStyle,
];

export const DEFAULT_WAVE_STYLE_ID = spectrumStyle.id;

export function findWaveStyle(id: string | undefined): WaveStyle {
  return WAVE_STYLES.find((s) => s.id === id) ?? WAVE_STYLES[0];
}
