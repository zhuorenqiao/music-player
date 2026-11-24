/**
 * lib/sleep-audio.ts —— 助眠声景的程序化生成（React 端）
 *
 * 每条曲目都是 32 秒、22050Hz、单声道 16bit 的 WAV，用一条短循环换来：
 *   · 不依赖网络 / 版权音频，离线也能播；
 *   · 包体不增加一个字节；
 *   · 与 Flutter 端同一套配方（`lib/sleep/sleep_audio.dart`），听感对齐。
 *
 * 生成流程：先按配方算出 32s + 0.6s 的浮点样本，再把尾巴线性折叠回开头
 * （循环接缝处听不出断点），归一化后编码成 WAV Blob。整个过程是纯计算，
 * 不碰 Web Audio 的调度，暂停 / 续播都交给一枚常驻 `<audio loop>`。
 */

import { SLEEP_LOOP_SECONDS, SLEEP_SAMPLE_RATE, type SleepRecipe } from './sleep';

const SR = SLEEP_SAMPLE_RATE;
const LOOP = SLEEP_LOOP_SECONDS;
const LEN = SR * LOOP;
/** 折叠进开头的尾巴长度（0.6s）：循环接缝靠它抹平。 */
const TAIL = Math.floor(SR * 0.6);

/** 确定性伪随机：同一首每次生成的噪声完全一样，刷新不会换一段雨。 */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a += 0x6D2B79F5;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** 一阶低通系数：fc 为 -3dB 截止频率（Hz）。 */
function lowA(fc: number): number {
  return 1 - Math.exp(-2 * Math.PI * fc / SR);
}

/** 把 [trigger, trigger + life) 区间里的一枚正弦“雨滴 / 铃声”叠进样本。 */
function addPluck(
  out: Float64Array,
  trigger: number,
  freq: number,
  amp: number,
  rate: number,
  life: number,
  harmonic = 0,
): void {
  const start = Math.floor(trigger * SR);
  const count = Math.floor(life * SR);
  for (let i = 0; i < count; i += 1) {
    const index = start + i;
    if (index < 0 || index >= out.length) break;
    const t = i / SR;
    // 前 12ms 淡入：直接起正弦会有一声“哒”
    const attack = Math.min(1, t / 0.012);
    const envelope = attack * Math.exp(-t * rate);
    const phase = 2 * Math.PI * freq * t;
    out[index] += amp * envelope * (Math.sin(phase) + harmonic * Math.sin(phase * 2));
  }
}

/**
 * 把一枚「滑音」叠进样本：气泡、鸟鸣这类短促的音，起点与终点频率不同。
 * 相位按 f0·t + (f1-f0)·t²/(2·dur) 积分，频率是均匀滑过去的；
 * 包络两端都收到 0，收尾不会留一声「咔」。
 */
function addSweep(
  out: Float64Array,
  trigger: number,
  from: number,
  to: number,
  amp: number,
  dur: number,
  power: number,
): void {
  const start = Math.floor(trigger * SR);
  const count = Math.floor(dur * SR);
  for (let i = 0; i < count; i += 1) {
    const index = start + i;
    if (index < 0 || index >= out.length) break;
    const t = i / SR;
    const u = i / count;
    const attack = Math.min(1, t / 0.01);
    const envelope = attack * Math.pow(1 - u, power);
    const phase = 2 * Math.PI * (from * t + ((to - from) * t * t) / (2 * dur));
    out[index] += amp * envelope * Math.sin(phase);
  }
}

/** 柴火的噼啪：几毫秒的白噪脉冲，起音 1ms、指数衰减，比正弦更像木头开裂。 */
function addCrackle(
  out: Float64Array,
  rng: () => number,
  trigger: number,
  amp: number,
  dur: number,
  rate: number,
): void {
  const start = Math.floor(trigger * SR);
  const count = Math.floor(dur * SR);
  for (let i = 0; i < count; i += 1) {
    const index = start + i;
    if (index < 0 || index >= out.length) break;
    const t = i / SR;
    const attack = Math.min(1, t / 0.001);
    out[index] += amp * attack * Math.exp(-t * rate) * (rng() * 2 - 1);
  }
}

function buildRain(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 雨声不再铺一层 2.4kHz 的宽带「沙」。主体是两段很软的低中频：
  //   · body：460Hz 以下的屋顶湿气，慢慢起伏；
  //   · texture：900Hz 以下的一点潮意，只留一点点；
  //   · room：180Hz 的房间底噪，几乎听不见。
  const aBody = lowA(460);
  const aTexture = lowA(900);
  const aRoom = lowA(180);
  let body = 0;
  let texture = 0;
  let room = 0;
  let brown = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    body += aBody * (white - body);
    texture += aTexture * (white - texture);
    room += aRoom * (white - room);
    brown = (brown + 0.012 * white) * 0.995;
    // 8 秒一轮的强弱，雨势有呼吸，而不是一条恒定噪声
    const drift = 0.78 + 0.22 * Math.sin((2 * Math.PI * t) / 8);
    out[i] = body * 0.34 * drift + texture * 0.040 + room * 0.09 + brown * 0.035;
  }

  // 细碎的雨点：约每秒 1.7 颗，频率压到 340~860Hz，短、轻、密。
  // 这是「雨」的主要识别点，不是噪声主体。
  const grains = 54;
  for (let g = 0; g < grains; g += 1) {
    const at = (LOOP / grains) * g + rng() * 0.4;
    addPluck(out, at, 340 + rng() * 520, 0.012 + rng() * 0.018, 28 + rng() * 22, 0.2, 0.08);
  }

  // 偶尔一颗更清楚的檐滴：32 秒里 7 颗。
  const drops = 7;
  for (let d = 0; d < drops; d += 1) {
    const at = (LOOP / drops) * d + 0.2 + rng() * 0.6;
    addPluck(out, at, 620 + rng() * 350, 0.02 + rng() * 0.012, 12 + rng() * 6, 0.42, 0.12);
  }
}

function buildOcean(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 潮汐的主角是「慢」：16 秒一涨落，波峰才带一点泡沫；
  // 波谷只剩很深的低频涌动，给耳朵留空白。
  const aSmooth = lowA(140);
  const aDeep = lowA(70);
  const aFoam = lowA(2200);
  let smooth = 0;
  let deep = 0;
  let foam = 0;
  let brown = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    smooth += aSmooth * (white - smooth);
    deep += aDeep * (white - deep);
    foam += aFoam * (white - foam);
    brown = (brown + 0.01 * white) * 0.996;

    // 0 在波谷、1 在波峰；crest 只在峰顶附近抬起来
    const swell = 0.5 - 0.5 * Math.cos((2 * Math.PI * t) / 16);
    const crest = Math.pow(swell, 2.6);
    const back = 0.5 + 0.5 * Math.sin((2 * Math.PI * t) / 16 + 1.1);
    const wash = foam * 0.018 * crest * (0.55 + 0.45 * back);

    out[i] = deep * 0.42 * (0.18 + 0.82 * swell)
      + smooth * 0.16 * swell
      + brown * 0.10 * swell
      + wash
      + Math.sin(2 * Math.PI * 46 * t) * 0.018 * swell;
  }
}

function buildWind(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 林风只留一条 140~800Hz 的空气带，加两层很轻的叶子摩擦；
  // 阵风 16 秒一轮，再叠一个 5.3 秒的细碎涡流，避免机械的呼吸。
  const aWide = lowA(800);
  const aNarrow = lowA(140);
  const aRustle = lowA(3200);
  const aLeafBase = lowA(1400);
  const aLow = lowA(45);
  let wide = 0;
  let narrow = 0;
  let rustle = 0;
  let leafBase = 0;
  let low = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    wide += aWide * (white - wide);
    narrow += aNarrow * (white - narrow);
    rustle += aRustle * (white - rustle);
    leafBase += aLeafBase * (white - leafBase);
    low += aLow * (white - low);

    const slow = 0.5 - 0.5 * Math.cos((2 * Math.PI * t) / 16);
    const eddy = 0.5 + 0.5 * Math.sin((2 * Math.PI * t) / (LOOP / 6) + 0.6);
    const gust = Math.pow(slow, 1.55) * (0.76 + 0.24 * eddy);
    const leaves = rustle - leafBase;

    out[i] = (wide * 0.52 - narrow * 0.34) * 0.34 * (0.10 + 0.90 * gust)
      + leaves * 0.032 * Math.pow(gust, 1.8)
      + Math.sin(2 * Math.PI * (235 + 9 * Math.sin((2 * Math.PI * t) / 16)) * t) * 0.010 * gust
      + low * 0.06;
    // 极轻的低频垫：让风有「远处山谷」的厚度，但不超过主带的 1/5。
  }
}

/** 大调 / 小调轮换的四段和弦，每段 8 秒，段首段尾各淡入淡出 0.6s。 */
const LULLABY_CHORDS: number[][] = [
  [220, 261.63, 329.63],
  [174.61, 220, 261.63],
  [196, 246.94, 293.66],
  [130.81, 196, 246.94],
];

function buildLullaby(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  const segment = 8;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const which = Math.floor(t / segment) % LULLABY_CHORDS.length;
    const inSegment = t % segment;
    const fade = Math.min(1, inSegment / 0.6) * Math.min(1, (segment - inSegment) / 0.6);
    const chord = LULLABY_CHORDS[which];
    let pad = 0;
    for (let n = 0; n < chord.length; n += 1) {
      const freq = chord[n];
      // 三枚正弦轻微错相：听上去是柔软的钢琴 / 弦乐垫，而不是电子蜂鸣
      pad += Math.sin(2 * Math.PI * freq * t + n * 0.55) * (0.09 - n * 0.012);
    }
    const breath = 0.86 + 0.14 * Math.sin((2 * Math.PI * t) / 8);
    out[i] = pad * fade * breath + Math.sin(2 * Math.PI * 110 * t) * 0.012;
  }

  // 4 秒一枚的琶音，像有人很慢地在琴上点了一下
  const notes = [440, 523.25, 659.25, 392];
  for (let k = 0; k < 8; k += 1) {
    addPluck(out, k * 4 + 0.4 + rng() * 0.2, notes[k % notes.length], 0.05, 2.2, 2.6, 0.18);
  }
}

function buildMusicbox(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 低音垫：146.83Hz 两枚正弦，整段不切段，循环处自然连续
  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    out[i] = Math.sin(2 * Math.PI * 146.83 * t) * 0.028
      + Math.sin(2 * Math.PI * 196 * t + 0.8) * 0.018;
  }

  // 音乐盒的钉子：每 2 秒一枚，音高在两组之间游走，长衰减带一点二次泛音
  const notes = [784, 988, 1174.66, 1318.51, 1046.5, 880];
  for (let k = 0; k < 16; k += 1) {
    const at = k * 2 + 0.2 + rng() * 0.15;
    addPluck(out, at, notes[(k * 3) % notes.length], 0.062, 3.4, 2.4, 0.42);
  }
}

function buildNoise(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  const aLow = lowA(900);
  let brown = 0;
  let lp = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    brown = (brown + 0.018 * white) * 0.997;
    lp += aLow * (brown - lp);
    // 低频底噪 + 60Hz 的极轻“房间嗡声”：白噪不刺耳的那一档
    out[i] = lp * 0.95 + Math.sin(2 * Math.PI * 60 * t) * 0.012
      + Math.sin(2 * Math.PI * 220 * t + 1.4) * 0.008;
  }
}

function buildStream(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 溪流的主色是 420~2600Hz 的「水面」带：一次高通减一次低通就出台。
  // 再加 120Hz 的石底低频（水落在石头上那点厚度）与一层棕色底噪。
  const aHigh = lowA(2600);
  const aLow = lowA(420);
  const aDeep = lowA(120);
  let high = 0;
  let low = 0;
  let deep = 0;
  let brown = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    high += aHigh * (white - high);
    low += aLow * (white - low);
    deep += aDeep * (white - deep);
    brown = (brown + 0.012 * white) * 0.996;
    // 2.8 秒推一股水、9.5 秒换一次水位：水在流，不是在喷
    const flow = 0.72 + 0.28 * Math.sin((2 * Math.PI * t) / 2.8 + 0.5);
    const breath = 0.85 + 0.15 * Math.sin((2 * Math.PI * t) / 9.5 + 1.3);
    out[i] = (high - low) * 0.30 * flow * breath
      + deep * 0.10 * breath
      + brown * 0.05;
  }

  // 气泡：32 秒 30 颗，每颗是一段短促上滑，这是「流水」最好认的地方
  const bubbles = 30;
  for (let b = 0; b < bubbles; b += 1) {
    const at = (LOOP / bubbles) * b + rng() * 0.5;
    const f0 = 420 + rng() * 420;
    const rise = 1.5 + rng() * 0.5;
    addSweep(out, at, f0, f0 * rise, 0.035 + rng() * 0.03, 0.07 + rng() * 0.07, 1.8);
  }

  // 偶尔一颗水珠落在石面上：频率更高、衰减更快
  for (let d = 0; d < 6; d += 1) {
    const at = (LOOP / 6) * d + 0.3 + rng() * 0.9;
    addPluck(out, at, 900 + rng() * 500, 0.018 + rng() * 0.012, 16 + rng() * 8, 0.3, 0.1);
  }
}

function buildBirds(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 林子的底：700Hz 以下的树叶湿气 + 一点点 3kHz 的枝梢摩擦（后者只跟明暗走）
  const aBed = lowA(700);
  const aRustle = lowA(3000);
  const aLeafBase = lowA(1200);
  let bed = 0;
  let rustle = 0;
  let leafBase = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    bed += aBed * (white - bed);
    rustle += aRustle * (white - rustle);
    leafBase += aLeafBase * (white - leafBase);
    // 9 秒一次明暗：晨光在林梢挪一格
    const slow = 0.5 - 0.5 * Math.cos((2 * Math.PI * t) / 9);
    out[i] = bed * 0.16 * (0.62 + 0.38 * slow) + (rustle - leafBase) * 0.020 * slow;
  }

  // 7 声鸟叫，每声 2~4 个音：1.9~3.3kHz 的基音，每个音向上滑一点
  const calls = 7;
  for (let c = 0; c < calls; c += 1) {
    const at = (LOOP / calls) * c + 0.6 + rng() * 1.3;
    const notes = 2 + Math.floor(rng() * 3);
    const base = 1900 + rng() * 1400;
    for (let k = 0; k < notes; k += 1) {
      const start = at + k * (0.11 + rng() * 0.05);
      const rise = 1.3 + rng() * 0.2;
      addSweep(out, start, base * (1 + rng() * 0.06), base * rise, 0.06 + rng() * 0.04, 0.05 + rng() * 0.05, 1.25);
    }
  }

  // 远处另一种鸟：两声低沉的「咕——咕」，下行的长音，给叫声留个远近层次
  for (let c = 0; c < 3; c += 1) {
    const at = c * 10 + 2.4 + rng() * 1.5;
    const f0 = 1150 + rng() * 260;
    addSweep(out, at, f0, f0 * 0.93, 0.05, 0.22, 1.1);
    addSweep(out, at + 0.42, f0 * 1.04, f0 * 0.97, 0.04, 0.18, 1.1);
  }
}

function buildCampfire(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 火塘：300Hz 以下的热气 + 1.8kHz 的轻嘶 + 60Hz 的木头底
  const aBody = lowA(300);
  const aHiss = lowA(1800);
  const aLow = lowA(60);
  let body = 0;
  let hiss = 0;
  let low = 0;
  let brown = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    body += aBody * (white - body);
    hiss += aHiss * (white - hiss);
    low += aLow * (white - low);
    brown = (brown + 0.015 * white) * 0.995;
    // 两个不同周期的抖动叠在一起，才不像一条被调制的噪声
    const flicker = 0.78 + 0.14 * Math.sin((2 * Math.PI * t) / 2.3 + 0.7)
      + 0.08 * Math.sin((2 * Math.PI * t) / 5.7 + 2.1);
    out[i] = body * 0.30 * flicker + hiss * 0.05 * flicker + low * 0.15 + brown * 0.10;
  }

  // 噼啪：32 秒 110 颗几毫秒的白噪。密，但别密成雨
  const pops = 110;
  for (let p = 0; p < pops; p += 1) {
    const at = rng() * LOOP;
    addCrackle(out, rng, at, 0.02 + rng() * 0.05, 0.004 + rng() * 0.012, 220 + rng() * 260);
  }

  // 偶尔一根柴塌下去：很低的闷响
  for (let t = 0; t < 4; t += 1) {
    addPluck(out, t * 8 + 1.2 + rng() * 2.0, 96 + rng() * 28, 0.03, 9, 0.7, 0.15);
  }
}

/**
 * 一声蟋蟀：在 [cycle] 的循环里响 [windowLen] 一段，载波 [carrier]，
 * 段内按 [pulseHz] 打成脉冲串；窗两端各 0.12s 淡入淡出，免得切口「咔」。
 */
function cricket(
  t: number,
  offset: number,
  carrier: number,
  cycle: number,
  windowLen: number,
  pulseHz: number,
  amp: number,
): number {
  const ct = (t + offset) % cycle;
  if (ct >= windowLen) return 0;
  const edge = Math.min(1, ct / 0.12) * Math.min(1, (windowLen - ct) / 0.12);
  const pulse = Math.pow(0.5 + 0.5 * Math.sin(2 * Math.PI * pulseHz * ct), 3);
  return amp * edge * pulse * Math.sin(2 * Math.PI * carrier * t + offset);
}

function buildCrickets(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  const aAir = lowA(260);
  let air = 0;
  // 两只虫的周期取 32 的整分数（32/12、32/10）：循环接缝处刚好接得上
  const cycleA = LOOP / 12;
  const cycleB = LOOP / 10;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    air += aAir * (white - air);
    out[i] = air * 0.05
      + cricket(t, 0.4, 4180, cycleA, 0.92, 26, 0.16)
      + cricket(t, 1.3, 4560, cycleB, 0.78, 31, 0.12);
  }
}

/** 夜曲的四段和弦：Dm → Bb → F → C，比摇篮更低、更沉。 */
const NOCTURNE_CHORDS: number[][] = [
  [146.83, 174.61, 220],
  [116.54, 146.83, 174.61],
  [174.61, 220, 261.63],
  [130.81, 164.81, 196],
];

function buildNocturne(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  const segment = 8;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const which = Math.floor(t / segment) % NOCTURNE_CHORDS.length;
    const inSegment = t % segment;
    // 段首段尾各 0.8s 淡入淡出：和弦换得慢，但不能「跳」过去
    const fade = Math.min(1, inSegment / 0.8) * Math.min(1, (segment - inSegment) / 0.8);
    const chord = NOCTURNE_CHORDS[which];
    let pad = 0;
    for (let n = 0; n < chord.length; n += 1) {
      pad += Math.sin(2 * Math.PI * chord[n] * t + n * 0.7) * (0.070 - n * 0.010);
    }
    // 低一个八度的根音：夜曲的厚度全在这里
    const sub = Math.sin(2 * Math.PI * (chord[0] / 2) * t) * 0.022;
    out[i] = (pad + sub) * fade;
  }

  // 3.2 秒一枚的慢句，衰减比摇篮长：像有人隔着墙在弹琴
  const notes = [196, 233.08, 261.63, 220, 174.61, 146.83, 261.63, 233.08];
  for (let k = 0; k < 10; k += 1) {
    addPluck(out, k * 3.2 + 0.5 + rng() * 0.3, notes[k % notes.length], 0.045, 1.4, 3.4, 0.16);
  }
}

function buildWaterfall(seed: number, out: Float64Array): void {
  const rng = mulberry32(seed);
  // 瀑布是「宽带但不刺」：3.6kHz 的亮面 + 1.1kHz 的水体 + 180Hz 的落差
  const aBright = lowA(3600);
  const aBody = lowA(1100);
  const aDeep = lowA(180);
  let bright = 0;
  let body = 0;
  let deep = 0;
  let brown = 0;

  for (let i = 0; i < out.length; i += 1) {
    const t = i / SR;
    const white = rng() * 2 - 1;
    bright += aBright * (white - bright);
    body += aBody * (white - body);
    deep += aDeep * (white - deep);
    brown = (brown + 0.02 * white) * 0.995;
    // 7.5 秒一次的大水量：落差在推水，不是一条恒定的沙
    const swell = 0.88 + 0.12 * Math.sin((2 * Math.PI * t) / 7.5 + 0.3);
    out[i] = bright * 0.30 * swell + body * 0.26 + deep * 0.10 + brown * 0.06
      + Math.sin(2 * Math.PI * 58 * t) * 0.015;
  }
}

/**
 * 归一化：声景按 RMS 定响度，而不是只追峰值。
 *
 * 只按峰值归一化时，稀疏雨滴会把整段噪声一起拉响 —— 听感就是「沙沙声
 * 很大」。这里给声景同时设 RMS 与峰值上限；摇篮 / 音乐盒 / 夜曲这类
 * 稀疏的乐句仍按峰值归一化，保持原来的轻响。
 */
function normalize(out: Float64Array, recipe: SleepRecipe): void {
  let peak = 0;
  let sumSq = 0;
  for (let i = 0; i < LEN; i += 1) {
    const value = out[i];
    const abs = Math.abs(value);
    if (abs > peak) peak = abs;
    sumSq += value * value;
  }
  const rms = Math.sqrt(sumSq / LEN);

  let rmsTarget: number | null = null;
  let peakLimit: number;
  let maxGain: number;
  switch (recipe) {
    case 'rain':
      rmsTarget = 0.10;
      peakLimit = 0.58;
      maxGain = 2.2;
      break;
    case 'ocean':
      rmsTarget = 0.078;
      peakLimit = 0.55;
      maxGain = 2.9;
      break;
    case 'wind':
      rmsTarget = 0.065;
      peakLimit = 0.52;
      maxGain = 4.1;
      break;
    case 'noise':
      rmsTarget = 0.12;
      peakLimit = 0.62;
      maxGain = 1.5;
      break;
    case 'stream':
      rmsTarget = 0.085;
      peakLimit = 0.52;
      maxGain = 3.0;
      break;
    case 'birds':
      rmsTarget = 0.068;
      peakLimit = 0.60;
      maxGain = 3.0;
      break;
    case 'campfire':
      rmsTarget = 0.072;
      peakLimit = 0.55;
      maxGain = 2.6;
      break;
    case 'crickets':
      rmsTarget = 0.052;
      peakLimit = 0.50;
      maxGain = 4.0;
      break;
    case 'waterfall':
      rmsTarget = 0.12;
      peakLimit = 0.62;
      maxGain = 1.6;
      break;
    case 'lullaby':
      peakLimit = 0.78;
      maxGain = 1.7;
      break;
    case 'musicbox':
      peakLimit = 0.78;
      maxGain = 2.6;
      break;
    case 'nocturne':
      peakLimit = 0.74;
      maxGain = 2.0;
      break;
    default:
      peakLimit = 0.82;
      maxGain = 1.8;
      break;
  }

  let gain = peak > 0 ? peakLimit / peak : 1;
  if (rmsTarget !== null && rms > 0) {
    gain = Math.min(gain, rmsTarget / rms);
  }
  gain = Math.min(gain, maxGain);
  for (let i = 0; i < LEN; i += 1) {
    out[i] = Math.max(-1, Math.min(1, out[i] * gain));
  }
}

function buildSamples(recipe: SleepRecipe, seed: number): Float64Array {
  const out = new Float64Array(LEN + TAIL);
  const rngSeed = Math.floor(seed * 1_000_000) + 17;
  switch (recipe) {
    case 'rain':
      buildRain(rngSeed, out);
      break;
    case 'ocean':
      buildOcean(rngSeed, out);
      break;
    case 'wind':
      buildWind(rngSeed, out);
      break;
    case 'lullaby':
      buildLullaby(rngSeed, out);
      break;
    case 'musicbox':
      buildMusicbox(rngSeed, out);
      break;
    case 'stream':
      buildStream(rngSeed, out);
      break;
    case 'birds':
      buildBirds(rngSeed, out);
      break;
    case 'campfire':
      buildCampfire(rngSeed, out);
      break;
    case 'crickets':
      buildCrickets(rngSeed, out);
      break;
    case 'nocturne':
      buildNocturne(rngSeed, out);
      break;
    case 'waterfall':
      buildWaterfall(rngSeed, out);
      break;
    case 'noise':
    default:
      buildNoise(rngSeed, out);
      break;
  }

  // 尾巴线性折回开头：out[i] 与 out[LEN + i] 是同一时刻的连续样本，
  // 折叠后最后一个样本（LEN-1）与第一个样本接得上，循环无“咔哒”。
  for (let i = 0; i < TAIL; i += 1) {
    const w = i / TAIL;
    out[i] = out[i] * w + out[LEN + i] * (1 - w);
  }

  normalize(out, recipe);
  return out.subarray(0, LEN);
}

/** 浮点样本 → 16bit 单声道 WAV。 */
function encodeWav(samples: Float64Array): Blob {
  const bytes = 44 + samples.length * 2;
  const buffer = new ArrayBuffer(bytes);
  const view = new DataView(buffer);
  const writeString = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i += 1) {
      view.setUint8(offset + i, text.charCodeAt(i));
    }
  };

  writeString(0, 'RIFF');
  view.setUint32(4, bytes - 8, true);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, SR, true);
  view.setUint32(28, SR * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeString(36, 'data');
  view.setUint32(40, samples.length * 2, true);

  let offset = 44;
  for (let i = 0; i < samples.length; i += 1) {
    const value = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, value < 0 ? value * 0x8000 : value * 0x7fff, true);
    offset += 2;
  }
  return new Blob([buffer], { type: 'audio/wav' });
}

/** 已生成曲目的 Blob URL 缓存：同一首第二次点开是瞬时的。 */
const urlCache = new Map<string, string>();

/** 取一条曲目的可播放 URL（首次调用会做一次生成）。 */
export function sleepAudioUrl(id: string, recipe: SleepRecipe, seed: number): string {
  const cached = urlCache.get(id);
  if (cached) return cached;
  const url = URL.createObjectURL(encodeWav(buildSamples(recipe, seed)));
  urlCache.set(id, url);
  return url;
}
