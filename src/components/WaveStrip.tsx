/**
 * WaveStrip —— 详情页右栏下方的频谱条
 *
 * 视觉：一排竖直频谱柱 + 横向彩虹渐变 + 柱顶一串峰值点阵（参考图那种「彩色频谱」）。
 * 播放时优先用 Web Audio 的 AnalyserNode 取真实频段数据（跟着鼓点 / 能量起伏）；
 * 音频图不可用（环境不支持、跨源媒体等）时退回按曲目 id 生成的装饰形状 + 正弦起伏。
 * 两种模式都在暂停时冻结。
 *
 * 为什么不用 Web Audio 的 AnalyserNode 拿真实频谱：必须把 `<audio>` 接进 AudioContext
 * （createMediaElementSource）才能分析，而一旦音频图没接好或媒体跨源，结果是**播放静音** ——
 * 对播放器来说这是最不能接受的失败模式。所以这里只做视觉，绝不碰音频链路。
 *
 * 纯装饰，对读屏隐藏；`prefers-reduced-motion` 下不跑动画。
 */

import { useEffect, useRef } from 'react';
import { usePlayer } from '../state/player';
import { ensureAnalyser, isAnalysableSource } from '../lib/spectrum';

/** 画布高度（CSS 像素）。 */
const HEIGHT = 48;

/** 每根柱子占的横向像素（含间隙）。 */
const PX_PER_BAR = 6;

/** 播放时的振幅浮动范围。 */
const WOBBLE_MIN = 0.88;
const WOBBLE_MAX = 1.12;

/** 峰值点相对柱顶的悬空距离（像素）。 */
const PEAK_GAP = 6;

/** 峰值点每秒的保持比例（越小落得越快）。 */
const PEAK_DECAY_PER_SEC = 0.03;

/** 相位推进速度（弧度/秒）。 */
const PHASE_SPEED = 3;

/** 彩虹渐变的关键色标（HSL 色相，从左到右扫过一圈再回到绿）。 */
const HUE_STOPS: Array<[number, number]> = [
  [0, 148],
  [0.16, 178],
  [0.34, 212],
  [0.52, 262],
  [0.68, 300],
  [0.82, 340],
  [0.93, 12],
  [1, 96],
];

/** FNV-1a：同一个曲目 id 永远得到同一条频谱。 */
function hashString(text: string): number {
  let value = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    value ^= text.charCodeAt(i);
    value = Math.imul(value, 0x01000193);
  }
  return value >>> 0;
}

/**
 * 生成 0..1 的柱高：一条偏向中左的钟形包络 + 每根柱子的哈希抖动。
 * 两端收得很低、中间堆起来，才像参考图那种频谱轮廓。
 * @param seed 曲目 id
 * @param count 柱子数量
 */
function buildBars(seed: string, count: number): Float32Array {
  const root = hashString(seed || 'unknown');
  // 峰值位置随机偏左 / 偏右一点，避免每首歌都是同一个「山」
  const center = 0.38 + ((root % 25) / 100);
  const spread = 0.16 + ((root >>> 5) % 10) / 100;
  const bars = new Float32Array(count);
  for (let i = 0; i < count; i += 1) {
    const t = i / Math.max(1, count - 1);
    const bell = Math.exp(-((t - center) ** 2) / (2 * spread * spread));
    const jitter = 0.72 + ((hashString(`${seed}#${i}`) % 1000) / 1000) * 0.45;
    // 两端强制压低，形成参考图那种「中间高、两头贴地」
    const edge = Math.min(1, Math.sin(Math.PI * Math.min(1, t * 1.04 + 0.02)) * 1.8);
    bars[i] = Math.min(1, Math.max(0.03, bell * jitter * edge));
  }
  return bars;
}

export function WaveStrip() {
  const { current, playing, player } = usePlayer();
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const barsRef = useRef<Float32Array>(new Float32Array(0));
  /** 峰值点阵的「保持态」：缓慢下落，所以点会短暂悬在柱顶上 */
  const peaksRef = useRef<Float32Array>(new Float32Array(0));
  const phaseRef = useRef(0);
  const drawRef = useRef<((phase: number) => void) | null>(null);
  /** 真实频谱分析器与复用的取样缓冲 */
  const analyserRef = useRef<AnalyserNode | null>(null);
  const freqRef = useRef<Uint8Array<ArrayBuffer> | null>(null);
  /** 真实频谱的最后一帧：暂停时沿用它，避免回落到装饰形状 */
  const liveRef = useRef<Float32Array | null>(null);

  const seed = current?.id ?? '';

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) {
      return;
    }
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      return;
    }

    let cssWidth = 0;
    let height = HEIGHT;
    let raf = 0;
    let fallback = 0;
    const reduced = typeof window.matchMedia === 'function'
      && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    /** 横向彩虹渐变：一次建好，所有柱子共用 */
    let spectrum: CanvasGradient | null = null;

    const resize = () => {
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      cssWidth = canvas.clientWidth || 240;
      height = canvas.clientHeight || HEIGHT;
      canvas.width = Math.round(cssWidth * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      const count = Math.max(24, Math.round(cssWidth / PX_PER_BAR));
      barsRef.current = buildBars(seed, count);
      peaksRef.current = new Float32Array(count);

      spectrum = ctx.createLinearGradient(0, 0, cssWidth, 0);
      HUE_STOPS.forEach(([offset, hue]) => {
        spectrum?.addColorStop(offset, `hsl(${hue} 92% 58%)`);
      });
    };

    /** 峰值回落用墙钟时间算，rAF 和兜底定时器重复调用也不会多掉 */
    let lastDrawAt = 0;

    /** 画一帧；整条频谱一起按 phase 起伏，与播放进度无关。 */
    const draw = (phase: number) => {
      const bars = barsRef.current;
      const peaks = peaksRef.current;
      const count = bars.length;
      if (count === 0 || cssWidth === 0 || !spectrum) {
        return;
      }

      const now = performance.now();
      const dt = lastDrawAt ? Math.min(0.5, (now - lastDrawAt) / 1000) : 0;
      lastDrawAt = now;
      const decay = Math.pow(PEAK_DECAY_PER_SEC, dt);

      const baseline = height - 8;
      const maxAmp = baseline - PEAK_GAP - 2;
      const step = cssWidth / count;
      const barWidth = Math.max(1, step - 1);

      /** 真实频谱优先：播放中每帧采样；暂停时沿用最后一帧 */
      const analyser = analyserRef.current;
      const freq = freqRef.current;
      let live = liveRef.current && liveRef.current.length === count ? liveRef.current : null;
      if (playing && analyser && freq) {
        analyser.getByteFrequencyData(freq);
        const target = live ?? new Float32Array(count);
        // 对数分频：低频不挤在最左边，高频也不至于大半空着
        const binWidth = analyser.context.sampleRate / analyser.fftSize;
        const maxBin = Math.max(8, Math.min(freq.length - 1, Math.round(10000 / binWidth)));
        for (let i = 0; i < count; i += 1) {
          const t = count > 1 ? i / (count - 1) : 0;
          const bin = Math.max(1, Math.min(maxBin, Math.round(Math.pow(maxBin, t))));
          const value = Math.max(freq[bin], freq[Math.min(maxBin, bin + 1)]);
          // 音乐的高频能量天然低得多，给右侧一点显示补偿，整条才不会变成左高右空
          const tilt = 0.78 + 0.72 * t;
          const level = Math.pow(value / 255, 1.35) * tilt * 1.05;
          target[i] = Math.min(1, Math.max(0.02, level));
        }
        live = target;
        liveRef.current = target;
      }

      ctx.clearRect(0, 0, cssWidth, height);

      // 所有柱子同亮度、同节奏：亮色 + 发光
      ctx.save();
      ctx.fillStyle = spectrum;
      ctx.shadowColor = 'rgba(255, 255, 255, 0.3)';
      ctx.shadowBlur = 6;
      const wobbleSpan = (WOBBLE_MAX - WOBBLE_MIN) / 2;
      for (let i = 0; i < count; i += 1) {
        const wobble = 1
          + (Math.sin(phase * 2.2 + i * 0.35) + Math.sin(phase * 1.4 + i * 0.11)) * wobbleSpan;
        // 有真实数据就跟真实数据，没有才用装饰形状的正弦起伏
        const level = live ? live[i] : Math.min(1, bars[i] * wobble);
        const amp = level * maxAmp;
        ctx.fillRect(i * step, baseline - amp, barWidth, amp);
        // 峰值点：跟随柱顶但悬空一点，缓慢回落
        peaks[i] = Math.max(amp, (peaks[i] || 0) * decay);
      }

      // 峰值点阵：贯穿整条频谱（参考图就是这样），隔三根点一颗，避免太碎
      ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
      for (let i = 0; i < count; i += 3) {
        const peak = peaks[i];
        if (peak <= 0) {
          continue;
        }
        const x = i * step + barWidth / 2;
        const y = baseline - peak - PEAK_GAP;
        ctx.beginPath();
        ctx.arc(x, y, 1, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    };

    drawRef.current = draw;
    resize();
    const observer = typeof ResizeObserver === 'function'
      ? new ResizeObserver(() => {
        resize();
        draw(phaseRef.current);
      })
      : null;
    observer?.observe(canvas);

    let lastFrameAt = 0;
    const loop = (now: number) => {
      const dt = lastFrameAt ? Math.min(0.1, (now - lastFrameAt) / 1000) : 1 / 60;
      lastFrameAt = now;
      phaseRef.current += dt * PHASE_SPEED;
      draw(phaseRef.current);
      raf = window.requestAnimationFrame(loop);
    };

    /** 后台标签页 rAF 会被完全节流，用低频定时器兜底，回来时不至于「静止」 */
    const fallbackTick = () => {
      if (document.visibilityState === 'visible') {
        return;
      }
      phaseRef.current += 0.25 * PHASE_SPEED;
      draw(phaseRef.current);
    };

    if (playing && !reduced) {
      raf = window.requestAnimationFrame(loop);
      fallback = window.setInterval(fallbackTick, 250);
    } else {
      draw(phaseRef.current);
    }

    return () => {
      window.cancelAnimationFrame(raf);
      window.clearInterval(fallback);
      observer?.disconnect();
      drawRef.current = null;
    };
  }, [playing, seed]);

  /**
   * 首次真正播放时才接管音频图：AudioContext 需要用户交互后的活跃状态，
   * 而且 createMediaElementSource 一旦接上就不能撤销。失败则继续用装饰动画。
   */
  useEffect(() => {
    if (!playing || !current?.src || !isAnalysableSource(current.src)) {
      return;
    }
    let cancelled = false;
    void ensureAnalyser(player.audio).then((analyser) => {
      if (cancelled || !analyser) {
        return;
      }
      analyserRef.current = analyser;
      freqRef.current = new Uint8Array(new ArrayBuffer(analyser.frequencyBinCount));
      drawRef.current?.(phaseRef.current);
    });
    return () => {
      cancelled = true;
    };
  }, [playing, current?.src, player]);

  /** 播放状态切换时立刻重画一帧（暂停时冻结在当前形态）。 */
  useEffect(() => {
    drawRef.current?.(phaseRef.current);
  }, [playing]);

  return (
    <canvas
      ref={canvasRef}
      className="lyrics-page__wave"
      height={HEIGHT}
      aria-hidden="true"
    />
  );
}
