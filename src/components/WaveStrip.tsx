/**
 * WaveStrip —— 详情页右栏下方的频谱条
 *
 * 一条画布，样式由歌词页右上角的按钮在 WAVE_STYLES 里切换（彩带 / 尖刺噪声 / 点阵 LED…），
 * 桌面右栏和窄屏进度条上方共用同一个选择。
 * 播放时优先用 Web Audio 的 AnalyserNode 取真实频段 + 时域数据（跟着鼓点 / 能量起伏）；
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
import { useWaveStyle } from '../state/wave-style';
import { useTheme } from '../state/theme';
import { ensureAnalyser, isAnalysableSource } from '../lib/spectrum';
import { createWaveSampler } from '../lib/wave-signal';
import { wavePalette } from '../lib/wave-styles';

/** 画布高度（CSS 像素）。 */
const HEIGHT = 48;

/** 每根频段柱占的横向像素（含间隙）。 */
const PX_PER_BAND = 4;

/** 相位推进速度（弧度/秒），装饰回退信号靠它起伏。 */
const PHASE_SPEED = 3;

/** 峰值每秒的保持比例（越小落得越快）。 */
const PEAK_DECAY_PER_SEC = 0.03;

export function WaveStrip() {
  const { current, playing, player } = usePlayer();
  const { style, colored, lyricColor } = useWaveStyle();
  /** 换肤会换强调色：非彩色波形和渐变都要跟着重画 */
  const { themeKey } = useTheme();
  const canvasRef = useRef<HTMLCanvasElement>(null);
  /** 峰值点阵的「保持态」：缓慢下落，所以点会短暂悬在柱顶上 */
  const peaksRef = useRef<Float32Array>(new Float32Array(0));
  const phaseRef = useRef(0);
  const drawRef = useRef<((phase: number, dt: number) => void) | null>(null);
  /** 取样器持有分析器与复用缓冲，切样式时不用重建音频图 */
  const samplerRef = useRef(createWaveSampler());

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

    /** 横向渐变 + 逐点取色：彩色 / 白色由下拉里的开关决定，一次建好整条样式共用 */
    let palette: ReturnType<typeof wavePalette> | null = null;

    const resize = () => {
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      cssWidth = canvas.clientWidth || 240;
      height = canvas.clientHeight || HEIGHT;
      canvas.width = Math.round(cssWidth * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      const bandCount = Math.max(24, Math.round(cssWidth / PX_PER_BAND));
      if (peaksRef.current.length !== bandCount) {
        peaksRef.current = new Float32Array(bandCount);
      }
      palette = wavePalette(ctx, style, cssWidth, colored);
    };

    /** 峰值回落用墙钟时间算，rAF 和兜底定时器重复调用也不会多掉 */
    let lastDrawAt = 0;

    /** 画一帧；整条一起按 phase 起伏，与播放进度无关。 */
    const draw = (phase: number, dtHint: number) => {
      if (!palette || cssWidth === 0) {
        return;
      }
      const now = performance.now();
      const dt = lastDrawAt ? Math.min(0.5, (now - lastDrawAt) / 1000) : dtHint;
      lastDrawAt = now;

      const bandCount = peaksRef.current.length;
      const waveCount = Math.min(512, Math.max(120, Math.round(cssWidth)));
      const frame = samplerRef.current.read({
        playing,
        phase,
        dt,
        seed,
        bandCount,
        waveCount,
        width: cssWidth,
        height,
      });

      const peaks = peaksRef.current;
      if (style.usesPeaks) {
        const decay = Math.pow(PEAK_DECAY_PER_SEC, dt);
        for (let i = 0; i < peaks.length; i += 1) {
          peaks[i] *= decay;
        }
      }

      ctx.clearRect(0, 0, cssWidth, height);
      style.draw({
        ctx,
        frame,
        grad: palette.grad,
        peaks,
        colorAt: palette.colorAt,
      });
    };

    drawRef.current = draw;
    resize();
    const observer = typeof ResizeObserver === 'function'
      ? new ResizeObserver(() => {
        resize();
        draw(phaseRef.current, 1 / 60);
      })
      : null;
    observer?.observe(canvas);

    let lastFrameAt = 0;
    const loop = (now: number) => {
      const dt = lastFrameAt ? Math.min(0.1, (now - lastFrameAt) / 1000) : 1 / 60;
      lastFrameAt = now;
      phaseRef.current += dt * PHASE_SPEED;
      draw(phaseRef.current, dt);
      raf = window.requestAnimationFrame(loop);
    };

    /** 后台标签页 rAF 会被完全节流，用低频定时器兜底，回来时不至于「静止」 */
    const fallbackTick = () => {
      if (document.visibilityState === 'visible') {
        return;
      }
      phaseRef.current += 0.25 * PHASE_SPEED;
      draw(phaseRef.current, 0.25);
    };

    if (playing && !reduced) {
      raf = window.requestAnimationFrame(loop);
      fallback = window.setInterval(fallbackTick, 250);
    } else {
      draw(phaseRef.current, 1 / 60);
    }

    return () => {
      window.cancelAnimationFrame(raf);
      window.clearInterval(fallback);
      observer?.disconnect();
      drawRef.current = null;
    };
  }, [playing, seed, style, colored, lyricColor, themeKey]);

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
      samplerRef.current.attach(analyser);
      drawRef.current?.(phaseRef.current, 1 / 60);
    });
    return () => {
      cancelled = true;
    };
  }, [playing, current?.src, player]);

  /** 播放状态切换时立刻重画一帧（暂停时冻结在当前形态）。 */
  useEffect(() => {
    drawRef.current?.(phaseRef.current, 1 / 60);
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
