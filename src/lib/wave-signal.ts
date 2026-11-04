/**
 * wave-signal.ts —— 波形样式的统一数据源
 *
 * 一次采样给出两路信号：
 * - bands：对数分频后的频段能量（0..1），柱状 / 点阵 / 山形这类样式吃它；
 * - wave：时域采样（-1..1），彩带 / 折线 / 多股细线这类样式吃它。
 *
 * 三种状态：播放且音频图就绪 → 读 AnalyserNode 的真实数据；暂停 → 冻结在最后一帧
 * 真实数据；音频图不可用（跨源媒体、环境不支持）→ 退回按曲目 id 生成的装饰信号，
 * 并带上正弦起伏，保证「播放中」仍然有律动。
 *
 * 返回的两个数组是复用缓冲，只在这一帧内有效，调用方不能存下来。
 */

/** FNV-1a：同一个曲目 id 永远得到同一条装饰波形。 */
export function hashString(text: string): number {
  let value = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    value ^= text.charCodeAt(i);
    value = Math.imul(value, 0x01000193);
  }
  return value >>> 0;
}

export interface WaveFrame {
  /** 频段能量，0..1 */
  bands: Float32Array;
  /** 时域波形，-1..1 */
  wave: Float32Array;
  /** 整帧平均能量，0..1 */
  level: number;
  /** 累计动画时间（秒） */
  phase: number;
  /** 距上一帧的秒数，峰值回落要用墙钟而不是帧数 */
  dt: number;
  width: number;
  height: number;
  /** 是否来自真实音频（含暂停后冻结的那一帧） */
  live: boolean;
  /** 当前曲目 id，装饰回退与样式的随机频率都拿它当种子 */
  seed: string;
}

export interface ReadInput {
  playing: boolean;
  phase: number;
  dt: number;
  seed: string;
  bandCount: number;
  waveCount: number;
  width: number;
  height: number;
}

export interface WaveSampler {
  attach(analyser: AnalyserNode | null): void;
  read(input: ReadInput): WaveFrame;
}

/** 装饰频谱的包络：一条偏向中左的钟形 + 每根柱子的哈希抖动。 */
function fallbackBands(seed: string, count: number, phase: number, out: Float32Array): void {
  const root = hashString(seed || 'unknown');
  const center = 0.38 + ((root % 25) / 100);
  const spread = 0.16 + ((root >>> 5) % 10) / 100;
  for (let i = 0; i < count; i += 1) {
    const t = i / Math.max(1, count - 1);
    const bell = Math.exp(-((t - center) ** 2) / (2 * spread * spread));
    const jitter = 0.72 + ((hashString(`${seed}#${i}`) % 1000) / 1000) * 0.45;
    // 两端强制压低，形成「中间高、两头贴地」
    const edge = Math.min(1, Math.sin(Math.PI * Math.min(1, t * 1.04 + 0.02)) * 1.8);
    const wobble = 1 + (Math.sin(phase * 2.2 + i * 0.35) + Math.sin(phase * 1.4 + i * 0.11)) * 0.12;
    out[i] = Math.min(1, Math.max(0.03, bell * jitter * edge * wobble));
  }
}

/** 装饰波形：五条不同频率的正弦叠加，频率由曲目 id 决定，整体包络随位置起伏。 */
function fallbackWave(seed: string, count: number, phase: number, out: Float32Array): void {
  const root = hashString(`${seed}|wave`);
  const f1 = 1.6 + (root % 7) * 0.35;
  const f2 = 3.1 + ((root >>> 3) % 5) * 0.4;
  const f3 = 6.4 + ((root >>> 6) % 4) * 0.5;
  // 再叠两个高次谐波：只有低频正弦的曲线一眼就是「假律动」，细碎结构才像真实音频
  const f4 = 12.5 + ((root >>> 9) % 6) * 0.7;
  const f5 = 21 + ((root >>> 13) % 9) * 1.1;
  const level = 0.35 + ((root >>> 17) % 40) / 100;
  for (let i = 0; i < count; i += 1) {
    const t = count > 1 ? i / (count - 1) : 0;
    const env = 0.3 + 0.7 * Math.abs(Math.sin(Math.PI * (t * 1.3 + 0.12)));
    const v = Math.sin(t * Math.PI * 2 * f1 + phase * 1.7) * 0.5
      + Math.sin(t * Math.PI * 2 * f2 - phase * 2.3) * 0.27
      + Math.sin(t * Math.PI * 2 * f3 + phase * 3.1) * 0.14
      + Math.sin(t * Math.PI * 2 * f4 - phase * 4.4) * 0.06
      + Math.sin(t * Math.PI * 2 * f5 + phase * 5.6) * 0.03;
    out[i] = Math.max(-1, Math.min(1, v * env * level * 2.6));
  }
}

export function createWaveSampler(): WaveSampler {
  let analyser: AnalyserNode | null = null;
  let freqBuf: Uint8Array<ArrayBuffer> | null = null;
  let timeBuf: Uint8Array<ArrayBuffer> | null = null;
  let bands = new Float32Array(0);
  let wave = new Float32Array(0);
  let frozenBands: Float32Array | null = null;
  let frozenWave: Float32Array | null = null;

  const ensureSize = (count: number): Float32Array => {
    if (bands.length !== count) {
      bands = new Float32Array(count);
    }
    return bands;
  };
  const ensureWaveSize = (count: number): Float32Array => {
    if (wave.length !== count) {
      wave = new Float32Array(count);
    }
    return wave;
  };

  /**
   * 对数分频取样：低频不挤在最左边，高频也不至于大半空着。
   * 音乐的高频能量天然低得多，给右侧一点显示补偿。
   */
  const readBands = (out: Float32Array): void => {
    if (!analyser || !freqBuf) {
      return;
    }
    analyser.getByteFrequencyData(freqBuf);
    const count = out.length;
    const binWidth = analyser.context.sampleRate / analyser.fftSize;
    const maxBin = Math.max(8, Math.min(freqBuf.length - 1, Math.round(10000 / binWidth)));
    for (let i = 0; i < count; i += 1) {
      const t = count > 1 ? i / (count - 1) : 0;
      const bin = Math.max(1, Math.min(maxBin, Math.round(Math.pow(maxBin, t))));
      const value = Math.max(freqBuf[bin], freqBuf[Math.min(maxBin, bin + 1)]);
      const tilt = 0.78 + 0.72 * t;
      out[i] = Math.min(1, Math.max(0.02, Math.pow(value / 255, 1.35) * tilt * 1.05));
    }
  };

  /** 时域窗口按显示宽度重采样，保证一条曲线正好铺满整条波形。 */
  const readWave = (out: Float32Array): void => {
    if (!analyser || !timeBuf) {
      return;
    }
    analyser.getByteTimeDomainData(timeBuf);
    const count = out.length;
    const span = timeBuf.length / count;
    for (let i = 0; i < count; i += 1) {
      const idx = Math.min(timeBuf.length - 1, Math.floor(i * span));
      out[i] = (timeBuf[idx] - 128) / 128;
    }
  };

  return {
    attach(next) {
      if (next === analyser) {
        return;
      }
      analyser = next;
      freqBuf = next ? new Uint8Array(new ArrayBuffer(next.frequencyBinCount)) : null;
      timeBuf = next ? new Uint8Array(new ArrayBuffer(next.fftSize)) : null;
      // 换了一首歌 / 重建了音频图，旧的冻结帧就不要再用了
      frozenBands = null;
      frozenWave = null;
    },

    read(input) {
      const {
        playing, phase, dt, seed, bandCount, waveCount, width, height,
      } = input;
      const outBands = ensureSize(bandCount);
      const outWave = ensureWaveSize(waveCount);

      if (playing && analyser) {
        readBands(outBands);
        readWave(outWave);
        frozenBands = outBands.slice();
        frozenWave = outWave.slice();
      } else if (frozenBands && frozenWave
        && frozenBands.length === bandCount && frozenWave.length === waveCount) {
        // 暂停：沿用最后一帧真实数据，不要回落到装饰形状
        outBands.set(frozenBands);
        outWave.set(frozenWave);
      } else {
        fallbackBands(seed, bandCount, phase, outBands);
        fallbackWave(seed, waveCount, phase, outWave);
      }

      let sum = 0;
      for (let i = 0; i < outBands.length; i += 1) {
        sum += outBands[i];
      }
      return {
        bands: outBands,
        wave: outWave,
        level: outBands.length ? sum / outBands.length : 0,
        phase,
        dt,
        width,
        height,
        live: Boolean(analyser) && (playing || Boolean(frozenBands)),
        seed,
      };
    },
  };
}
