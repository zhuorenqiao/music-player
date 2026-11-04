/**
 * spectrum.ts —— 真实频谱分析（Web Audio AnalyserNode）
 *
 * 关键约束：`<audio>` 一旦被 `createMediaElementSource` 接管，声音就只能经由
 * AudioContext 送到 destination —— 上下文没跑起来、或媒体跨源，都会变成
 * 「有画面没声音」。所以这里只在 AudioContext 确认 running 之后才接管音频，
 * 失败时宁可没有频谱，也不改变原来的音频链路。
 */

interface SpectrumChain {
  audio: HTMLAudioElement;
  ctx: AudioContext;
  analyser: AnalyserNode;
}

let chain: SpectrumChain | null = null;
let pending: Promise<AnalyserNode | null> | null = null;
let unsupported = false;

type AudioContextCtor = typeof AudioContext;

function getAudioContextCtor(): AudioContextCtor | null {
  if (typeof window === 'undefined') {
    return null;
  }
  return window.AudioContext
    ?? (window as unknown as { webkitAudioContext?: AudioContextCtor }).webkitAudioContext
    ?? null;
}

/**
 * 只有同源音频能保证 MediaElementSource 不会把媒体变静音。
 * 跨源且没有 CORS 头的媒体被接进音频图后，输出是静音。
 */
export function isAnalysableSource(src: string): boolean {
  if (!src) {
    return false;
  }
  try {
    return new URL(src, window.location.href).origin === window.location.origin;
  } catch {
    return false;
  }
}

/**
 * 取已经建好的分析器（同一个 audio 元素复用）。
 * @param audio 播放器的 audio 元素
 */
export function getSharedAnalyser(audio: HTMLAudioElement): AnalyserNode | null {
  return chain && chain.audio === audio ? chain.analyser : null;
}

/**
 * 懒建音频图：ctx + source + analyser，并把 source 同时接到 destination。
 * 多次调用只会接管一次；任何一步失败都退回 null，由调用方继续用装饰动画。
 * @param audio 播放器的 audio 元素
 */
export function ensureAnalyser(audio: HTMLAudioElement): Promise<AnalyserNode | null> {
  if (chain) {
    return Promise.resolve(chain.audio === audio ? chain.analyser : null);
  }
  if (pending) {
    return pending;
  }
  if (unsupported) {
    return Promise.resolve(null);
  }

  pending = (async () => {
    const Ctor = getAudioContextCtor();
    if (!Ctor) {
      unsupported = true;
      return null;
    }

    let ctx: AudioContext | null = null;
    let source: MediaElementAudioSourceNode | null = null;
    try {
      ctx = new Ctor();
      if (ctx.state === 'suspended') {
        await ctx.resume();
      }
      // 没跑起来就绝不接管媒体，否则整首歌会静音
      if (ctx.state !== 'running') {
        await ctx.close().catch(() => {});
        unsupported = true;
        return null;
      }

      source = ctx.createMediaElementSource(audio);
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 2048;
      analyser.smoothingTimeConstant = 0.78;
      analyser.minDecibels = -90;
      analyser.maxDecibels = -15;
      source.connect(analyser);
      analyser.connect(ctx.destination);

      const context = ctx;
      context.addEventListener('statechange', () => {
        // 被系统挂起时尽快拉起，否则音频图会跟着没声
        if (context.state === 'suspended') {
          void context.resume().catch(() => {});
        }
      });

      chain = { audio, ctx: context, analyser };
      return analyser;
    } catch (error) {
      console.warn('[spectrum] 频谱分析不可用，退回装饰动画：', error);
      unsupported = true;
      if (source && ctx) {
        // 媒体已经被接管：至少接回扬声器，宁可没有频谱也不能没声音
        try {
          source.connect(ctx.destination);
        } catch {
          /* 忽略：已经无法再降级 */
        }
      } else if (ctx) {
        try {
          await ctx.close();
        } catch {
          /* 忽略 */
        }
      }
      return null;
    } finally {
      pending = null;
    }
  })();

  return pending;
}
