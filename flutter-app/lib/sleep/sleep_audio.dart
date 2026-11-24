// lib/sleep/sleep_audio.dart
//
// 助眠声景的程序化生成 + 本地缓存 + media_kit 播放内核（Flutter 端）。
//
// 每条曲目都是 32 秒、22050Hz、单声道 16bit 的 WAV，用一条短循环换来：
//   · 不依赖网络 / 版权音频，离线也能播；
//   · 包体不增加一个字节；
//   · 与 React 端同一套配方（`src/lib/sleep-audio.ts`），听感对齐。
//
// 生成流程：先按配方算出 32s + 0.6s 的浮点样本，再把尾巴线性折叠回开头
// （循环接缝处听不出断点），归一化后编码成 WAV 字节。首播前跑一次
// `compute`（独立 isolate），30 秒内不会卡住界面；生成结果写进临时目录，
// 同一首第二次点开直接拿文件。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'sleep_track.dart';

const int _kSampleRate = kSleepSampleRate;
const int _kLoopSeconds = kSleepLoopSeconds;
const int _kLen = _kSampleRate * _kLoopSeconds;

/// 一阶低通系数：fc 为 -3dB 截止频率（Hz）。
double _lowA(double fc) => 1 - math.exp(-2 * math.pi * fc / _kSampleRate);

/// 确定性伪随机：同一首每次生成的噪声完全一样，重启不会换一段雨。
/// 与 React `mulberry32` 同一条公式（32 位环绕）。
class _Rng {
  _Rng(int seed) : _a = (seed + 17) & 0xFFFFFFFF;

  int _a;

  double next() {
    _a = (_a + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _a;
    t = ((t ^ (t >>> 15)) * (t | 1)) & 0xFFFFFFFF;
    t ^= (t + ((t ^ (t >>> 7)) * (t | 61))) & 0xFFFFFFFF;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296.0;
  }
}

/// 把 [trigger, trigger + life) 区间里的一枚正弦「雨滴 / 铃声」叠进样本。
void _addPluck(
  Float64List out,
  double trigger,
  double freq,
  double amp,
  double rate,
  double life, {
  double harmonic = 0,
}) {
  final start = (trigger * _kSampleRate).floor();
  final count = (life * _kSampleRate).floor();
  for (var i = 0; i < count; i++) {
    final index = start + i;
    if (index < 0 || index >= out.length) break;
    final t = i / _kSampleRate;
    // 前 12ms 淡入：直接起正弦会有一声「哒」
    final attack = math.min(1, t / 0.012);
    final envelope = attack * math.exp(-t * rate);
    final phase = 2 * math.pi * freq * t;
    out[index] +=
        amp * envelope * (math.sin(phase) + harmonic * math.sin(phase * 2));
  }
}

/// 把一枚「滑音」叠进样本：气泡、鸟鸣这类短促的音，起点与终点频率不同。
/// 相位按 f0·t + (f1-f0)·t²/(2·dur) 积分，频率是均匀滑过去的；
/// 包络两端都收到 0，收尾不会留一声「咔」。
void _addSweep(
  Float64List out,
  double trigger,
  double from,
  double to,
  double amp,
  double dur,
  double power,
) {
  final start = (trigger * _kSampleRate).floor();
  final count = (dur * _kSampleRate).floor();
  for (var i = 0; i < count; i++) {
    final index = start + i;
    if (index < 0 || index >= out.length) break;
    final t = i / _kSampleRate;
    final u = i / count;
    final attack = math.min(1, t / 0.01);
    final envelope = attack * math.pow(1 - u, power).toDouble();
    final phase =
        2 * math.pi * (from * t + ((to - from) * t * t) / (2 * dur));
    out[index] += amp * envelope * math.sin(phase);
  }
}

/// 柴火的噼啪：几毫秒的白噪脉冲，起音 1ms、指数衰减，比正弦更像木头开裂。
void _addCrackle(
  Float64List out,
  _Rng rng,
  double trigger,
  double amp,
  double dur,
  double rate,
) {
  final start = (trigger * _kSampleRate).floor();
  final count = (dur * _kSampleRate).floor();
  for (var i = 0; i < count; i++) {
    final index = start + i;
    if (index < 0 || index >= out.length) break;
    final t = i / _kSampleRate;
    final attack = math.min(1, t / 0.001);
    out[index] += amp * attack * math.exp(-t * rate) * (rng.next() * 2 - 1);
  }
}

void _buildRain(_Rng rng, Float64List out) {
  // 雨声不再铺一层 2.4kHz 的宽带「沙」。主体是两段很软的低中频：
  //   · body：460Hz 以下的屋顶湿气，慢慢起伏；
  //   · texture：900Hz 以下的一点潮意，只留一点点；
  //   · room：180Hz 的房间底噪，几乎听不见。
  final aBody = _lowA(460);
  final aTexture = _lowA(900);
  final aRoom = _lowA(180);
  var body = 0.0;
  var texture = 0.0;
  var room = 0.0;
  var brown = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    body += aBody * (white - body);
    texture += aTexture * (white - texture);
    room += aRoom * (white - room);
    brown = (brown + 0.012 * white) * 0.995;
    // 8 秒一轮的强弱，雨势有呼吸，而不是一条恒定噪声
    final drift = 0.78 + 0.22 * math.sin((2 * math.pi * t) / 8);
    out[i] =
        body * 0.34 * drift + texture * 0.040 + room * 0.09 + brown * 0.035;
  }

  // 细碎的雨点：约每秒 1.7 颗，频率压到 340~860Hz，短、轻、密。
  // 这是「雨」的主要识别点，不是噪声主体。
  const grains = 54;
  for (var g = 0; g < grains; g++) {
    final at = (_kLoopSeconds / grains) * g + rng.next() * 0.4;
    _addPluck(
      out,
      at,
      340 + rng.next() * 520,
      0.012 + rng.next() * 0.018,
      28 + rng.next() * 22,
      0.2,
      harmonic: 0.08,
    );
  }

  // 偶尔一颗更清楚的檐滴：32 秒里 7 颗。
  const drops = 7;
  for (var d = 0; d < drops; d++) {
    final at = (_kLoopSeconds / drops) * d + 0.2 + rng.next() * 0.6;
    _addPluck(
      out,
      at,
      620 + rng.next() * 350,
      0.02 + rng.next() * 0.012,
      12 + rng.next() * 6,
      0.42,
      harmonic: 0.12,
    );
  }
}

void _buildOcean(_Rng rng, Float64List out) {
  // 潮汐的主角是「慢」：16 秒一涨落，波峰才带一点泡沫；
  // 波谷只剩很深的低频涌动，给耳朵留空白。
  final aSmooth = _lowA(140);
  final aDeep = _lowA(70);
  final aFoam = _lowA(2200);
  var smooth = 0.0;
  var deep = 0.0;
  var foam = 0.0;
  var brown = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    smooth += aSmooth * (white - smooth);
    deep += aDeep * (white - deep);
    foam += aFoam * (white - foam);
    brown = (brown + 0.01 * white) * 0.996;

    // 0 在波谷、1 在波峰；crest 只在峰顶附近抬起来
    final swell = 0.5 - 0.5 * math.cos((2 * math.pi * t) / 16);
    final crest = math.pow(swell, 2.6).toDouble();
    final back = 0.5 + 0.5 * math.sin((2 * math.pi * t) / 16 + 1.1);
    final wash = foam * 0.018 * crest * (0.55 + 0.45 * back);

    out[i] =
        deep * 0.42 * (0.18 + 0.82 * swell) +
        smooth * 0.16 * swell +
        brown * 0.10 * swell +
        wash +
        math.sin(2 * math.pi * 46 * t) * 0.018 * swell;
  }
}

void _buildWind(_Rng rng, Float64List out) {
  // 林风只留一条 140~800Hz 的空气带，加两层很轻的叶子摩擦；
  // 阵风 16 秒一轮，再叠一个 5.3 秒的细碎涡流，避免机械的呼吸。
  final aWide = _lowA(800);
  final aNarrow = _lowA(140);
  final aRustle = _lowA(3200);
  final aLeafBase = _lowA(1400);
  final aLow = _lowA(45);
  var wide = 0.0;
  var narrow = 0.0;
  var rustle = 0.0;
  var leafBase = 0.0;
  var low = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    wide += aWide * (white - wide);
    narrow += aNarrow * (white - narrow);
    rustle += aRustle * (white - rustle);
    leafBase += aLeafBase * (white - leafBase);
    low += aLow * (white - low);

    final slow = 0.5 - 0.5 * math.cos((2 * math.pi * t) / 16);
    final eddy =
        0.5 + 0.5 * math.sin((2 * math.pi * t) / (_kLoopSeconds / 6) + 0.6);
    final gust = math.pow(slow, 1.55).toDouble() * (0.76 + 0.24 * eddy);
    final leaves = rustle - leafBase;

    out[i] =
        (wide * 0.52 - narrow * 0.34) * 0.34 * (0.10 + 0.90 * gust) +
        leaves * 0.032 * math.pow(gust, 1.8).toDouble() +
        math.sin(
              2 * math.pi * (235 + 9 * math.sin((2 * math.pi * t) / 16)) * t,
            ) *
            0.010 *
            gust +
        low * 0.06;
    // 极轻的低频垫：让风有「远处山谷」的厚度，但不超过主带的 1/5。
  }
}

/// 大调 / 小调轮换的四段和弦，每段 8 秒，段首段尾各淡入淡出 0.6s。
const List<List<double>> _kLullabyChords = [
  [220, 261.63, 329.63],
  [174.61, 220, 261.63],
  [196, 246.94, 293.66],
  [130.81, 196, 246.94],
];

void _buildLullaby(_Rng rng, Float64List out) {
  const segment = 8.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final which = (t / segment).floor() % _kLullabyChords.length;
    final inSegment = t % segment;
    final fade =
        math.min(1, inSegment / 0.6) * math.min(1, (segment - inSegment) / 0.6);
    final chord = _kLullabyChords[which];
    var pad = 0.0;
    for (var n = 0; n < chord.length; n++) {
      // 三枚正弦轻微错相：听上去是柔软的钢琴 / 弦乐垫，而不是电子蜂鸣
      pad +=
          math.sin(2 * math.pi * chord[n] * t + n * 0.55) * (0.09 - n * 0.012);
    }
    final breath = 0.86 + 0.14 * math.sin((2 * math.pi * t) / 8);
    out[i] = pad * fade * breath + math.sin(2 * math.pi * 110 * t) * 0.012;
  }

  // 4 秒一枚的琶音，像有人很慢地在琴上点了一下
  const notes = <double>[440, 523.25, 659.25, 392];
  for (var k = 0; k < 8; k++) {
    _addPluck(
      out,
      k * 4 + 0.4 + rng.next() * 0.2,
      notes[k % notes.length],
      0.05,
      2.2,
      2.6,
      harmonic: 0.18,
    );
  }
}

void _buildMusicbox(_Rng rng, Float64List out) {
  // 低音垫：146.83Hz 两枚正弦，整段不切段，循环处自然连续
  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    out[i] =
        math.sin(2 * math.pi * 146.83 * t) * 0.028 +
        math.sin(2 * math.pi * 196 * t + 0.8) * 0.018;
  }

  // 音乐盒的钉子：每 2 秒一枚，音高在两组之间游走，长衰减带一点二次泛音
  const notes = <double>[784, 988, 1174.66, 1318.51, 1046.5, 880];
  for (var k = 0; k < 16; k++) {
    final at = k * 2 + 0.2 + rng.next() * 0.15;
    _addPluck(
      out,
      at,
      notes[(k * 3) % notes.length],
      0.062,
      3.4,
      2.4,
      harmonic: 0.42,
    );
  }
}

void _buildNoise(_Rng rng, Float64List out) {
  final aLow = _lowA(900);
  var brown = 0.0;
  var lp = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    brown = (brown + 0.018 * white) * 0.997;
    lp += aLow * (brown - lp);
    // 低频底噪 + 60Hz 的极轻「房间嗡声」：白噪不刺耳的那一档
    out[i] =
        lp * 0.95 +
        math.sin(2 * math.pi * 60 * t) * 0.012 +
        math.sin(2 * math.pi * 220 * t + 1.4) * 0.008;
  }
}

void _buildStream(_Rng rng, Float64List out) {
  // 溪流的主色是 420~2600Hz 的「水面」带：一次高通减一次低通就出台。
  // 再加 120Hz 的石底低频（水落在石头上那点厚度）与一层棕色底噪。
  final aHigh = _lowA(2600);
  final aLow = _lowA(420);
  final aDeep = _lowA(120);
  var high = 0.0;
  var low = 0.0;
  var deep = 0.0;
  var brown = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    high += aHigh * (white - high);
    low += aLow * (white - low);
    deep += aDeep * (white - deep);
    brown = (brown + 0.012 * white) * 0.996;
    // 2.8 秒推一股水、9.5 秒换一次水位：水在流，不是在喷
    final flow = 0.72 + 0.28 * math.sin((2 * math.pi * t) / 2.8 + 0.5);
    final breath = 0.85 + 0.15 * math.sin((2 * math.pi * t) / 9.5 + 1.3);
    out[i] =
        (high - low) * 0.30 * flow * breath + deep * 0.10 * breath + brown * 0.05;
  }

  // 气泡：32 秒 30 颗，每颗是一段短促上滑，这是「流水」最好认的地方
  const bubbles = 30;
  for (var b = 0; b < bubbles; b++) {
    final at = (_kLoopSeconds / bubbles) * b + rng.next() * 0.5;
    final f0 = 420 + rng.next() * 420;
    final rise = 1.5 + rng.next() * 0.5;
    _addSweep(
      out,
      at,
      f0,
      f0 * rise,
      0.035 + rng.next() * 0.03,
      0.07 + rng.next() * 0.07,
      1.8,
    );
  }

  // 偶尔一颗水珠落在石面上：频率更高、衰减更快
  for (var d = 0; d < 6; d++) {
    final at = (_kLoopSeconds / 6) * d + 0.3 + rng.next() * 0.9;
    _addPluck(
      out,
      at,
      900 + rng.next() * 500,
      0.018 + rng.next() * 0.012,
      16 + rng.next() * 8,
      0.3,
      harmonic: 0.1,
    );
  }
}

void _buildBirds(_Rng rng, Float64List out) {
  // 林子的底：700Hz 以下的树叶湿气 + 一点点 3kHz 的枝梢摩擦（后者只跟明暗走）
  final aBed = _lowA(700);
  final aRustle = _lowA(3000);
  final aLeafBase = _lowA(1200);
  var bed = 0.0;
  var rustle = 0.0;
  var leafBase = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    bed += aBed * (white - bed);
    rustle += aRustle * (white - rustle);
    leafBase += aLeafBase * (white - leafBase);
    // 9 秒一次明暗：晨光在林梢挪一格
    final slow = 0.5 - 0.5 * math.cos((2 * math.pi * t) / 9);
    out[i] =
        bed * 0.16 * (0.62 + 0.38 * slow) + (rustle - leafBase) * 0.020 * slow;
  }

  // 7 声鸟叫，每声 2~4 个音：1.9~3.3kHz 的基音，每个音向上滑一点
  const calls = 7;
  for (var c = 0; c < calls; c++) {
    final at = (_kLoopSeconds / calls) * c + 0.6 + rng.next() * 1.3;
    final notes = 2 + (rng.next() * 3).floor();
    final base = 1900 + rng.next() * 1400;
    for (var k = 0; k < notes; k++) {
      final start = at + k * (0.11 + rng.next() * 0.05);
      final rise = 1.3 + rng.next() * 0.2;
      _addSweep(
        out,
        start,
        base * (1 + rng.next() * 0.06),
        base * rise,
        0.06 + rng.next() * 0.04,
        0.05 + rng.next() * 0.05,
        1.25,
      );
    }
  }

  // 远处另一种鸟：两声低沉的「咕——咕」，下行的长音，给叫声留个远近层次
  for (var c = 0; c < 3; c++) {
    final at = c * 10 + 2.4 + rng.next() * 1.5;
    final f0 = 1150 + rng.next() * 260;
    _addSweep(out, at, f0, f0 * 0.93, 0.05, 0.22, 1.1);
    _addSweep(out, at + 0.42, f0 * 1.04, f0 * 0.97, 0.04, 0.18, 1.1);
  }
}

void _buildCampfire(_Rng rng, Float64List out) {
  // 火塘：300Hz 以下的热气 + 1.8kHz 的轻嘶 + 60Hz 的木头底
  final aBody = _lowA(300);
  final aHiss = _lowA(1800);
  final aLow = _lowA(60);
  var body = 0.0;
  var hiss = 0.0;
  var low = 0.0;
  var brown = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    body += aBody * (white - body);
    hiss += aHiss * (white - hiss);
    low += aLow * (white - low);
    brown = (brown + 0.015 * white) * 0.995;
    // 两个不同周期的抖动叠在一起，才不像一条被调制的噪声
    final flicker =
        0.78 +
        0.14 * math.sin((2 * math.pi * t) / 2.3 + 0.7) +
        0.08 * math.sin((2 * math.pi * t) / 5.7 + 2.1);
    out[i] =
        body * 0.30 * flicker +
        hiss * 0.05 * flicker +
        low * 0.15 +
        brown * 0.10;
  }

  // 噼啪：32 秒 110 颗几毫秒的白噪。密，但别密成雨
  const pops = 110;
  for (var p = 0; p < pops; p++) {
    final at = rng.next() * _kLoopSeconds;
    _addCrackle(
      out,
      rng,
      at,
      0.02 + rng.next() * 0.05,
      0.004 + rng.next() * 0.012,
      220 + rng.next() * 260,
    );
  }

  // 偶尔一根柴塌下去：很低的闷响
  for (var t = 0; t < 4; t++) {
    _addPluck(
      out,
      t * 8 + 1.2 + rng.next() * 2.0,
      96 + rng.next() * 28,
      0.03,
      9,
      0.7,
      harmonic: 0.15,
    );
  }
}

/// 一声蟋蟀：在 [cycle] 的循环里响 [windowLen] 一段，载波 [carrier]，
/// 段内按 [pulseHz] 打成脉冲串；窗两端各 0.12s 淡入淡出，免得切口「咔」。
double _cricket(
  double t,
  double offset,
  double carrier,
  double cycle,
  double windowLen,
  double pulseHz,
  double amp,
) {
  final ct = (t + offset) % cycle;
  if (ct >= windowLen) return 0;
  final edge =
      math.min(1, ct / 0.12) * math.min(1, (windowLen - ct) / 0.12);
  final pulse = math.pow(
    0.5 + 0.5 * math.sin(2 * math.pi * pulseHz * ct),
    3,
  ).toDouble();
  return amp * edge * pulse * math.sin(2 * math.pi * carrier * t + offset);
}

void _buildCrickets(_Rng rng, Float64List out) {
  final aAir = _lowA(260);
  var air = 0.0;
  // 两只虫的周期取 32 的整分数（32/12、32/10）：循环接缝处刚好接得上
  final cycleA = _kLoopSeconds / 12;
  final cycleB = _kLoopSeconds / 10;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    air += aAir * (white - air);
    out[i] =
        air * 0.05 +
        _cricket(t, 0.4, 4180, cycleA, 0.92, 26, 0.16) +
        _cricket(t, 1.3, 4560, cycleB, 0.78, 31, 0.12);
  }
}

/// 夜曲的四段和弦：Dm → Bb → F → C，比摇篮更低、更沉。
const List<List<double>> _kNocturneChords = [
  [146.83, 174.61, 220],
  [116.54, 146.83, 174.61],
  [174.61, 220, 261.63],
  [130.81, 164.81, 196],
];

void _buildNocturne(_Rng rng, Float64List out) {
  const segment = 8.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final which = (t / segment).floor() % _kNocturneChords.length;
    final inSegment = t % segment;
    // 段首段尾各 0.8s 淡入淡出：和弦换得慢，但不能「跳」过去
    final fade =
        math.min(1, inSegment / 0.8) * math.min(1, (segment - inSegment) / 0.8);
    final chord = _kNocturneChords[which];
    var pad = 0.0;
    for (var n = 0; n < chord.length; n++) {
      pad +=
          math.sin(2 * math.pi * chord[n] * t + n * 0.7) * (0.070 - n * 0.010);
    }
    // 低一个八度的根音：夜曲的厚度全在这里
    final sub = math.sin(2 * math.pi * (chord[0] / 2) * t) * 0.022;
    out[i] = (pad + sub) * fade;
  }

  // 3.2 秒一枚的慢句，衰减比摇篮长：像有人隔着墙在弹琴
  const notes = <double>[
    196,
    233.08,
    261.63,
    220,
    174.61,
    146.83,
    261.63,
    233.08,
  ];
  for (var k = 0; k < 10; k++) {
    _addPluck(
      out,
      k * 3.2 + 0.5 + rng.next() * 0.3,
      notes[k % notes.length],
      0.045,
      1.4,
      3.4,
      harmonic: 0.16,
    );
  }
}

void _buildWaterfall(_Rng rng, Float64List out) {
  // 瀑布是「宽带但不刺」：3.6kHz 的亮面 + 1.1kHz 的水体 + 180Hz 的落差
  final aBright = _lowA(3600);
  final aBody = _lowA(1100);
  final aDeep = _lowA(180);
  var bright = 0.0;
  var body = 0.0;
  var deep = 0.0;
  var brown = 0.0;

  for (var i = 0; i < out.length; i++) {
    final t = i / _kSampleRate;
    final white = rng.next() * 2 - 1;
    bright += aBright * (white - bright);
    body += aBody * (white - body);
    deep += aDeep * (white - deep);
    brown = (brown + 0.02 * white) * 0.995;
    // 7.5 秒一次的大水量：落差在推水，不是一条恒定的沙
    final swell = 0.88 + 0.12 * math.sin((2 * math.pi * t) / 7.5 + 0.3);
    out[i] =
        bright * 0.30 * swell +
        body * 0.26 +
        deep * 0.10 +
        brown * 0.06 +
        math.sin(2 * math.pi * 58 * t) * 0.015;
  }
}

/// 归一化：声景按 RMS 定响度，而不是只追峰值。
///
/// 只按峰值归一化时，稀疏雨滴会把整段噪声一起拉响 —— 听感就是「沙沙声
/// 很大」。这里给声景同时设 RMS 与峰值上限；摇篮 / 音乐盒 / 夜曲这类
/// 稀疏的乐句仍按峰值归一化，保持原来的轻响。
void _normalize(Float64List out, SleepRecipe recipe) {
  var peak = 0.0;
  var sumSq = 0.0;
  for (var i = 0; i < _kLen; i++) {
    final value = out[i];
    final abs = value.abs();
    if (abs > peak) peak = abs;
    sumSq += value * value;
  }
  final rms = math.sqrt(sumSq / _kLen);

  double? rmsTarget;
  final double peakLimit;
  final double maxGain;
  switch (recipe) {
    case SleepRecipe.rain:
      rmsTarget = 0.10;
      peakLimit = 0.58;
      maxGain = 2.2;
    case SleepRecipe.ocean:
      rmsTarget = 0.078;
      peakLimit = 0.55;
      maxGain = 2.9;
    case SleepRecipe.wind:
      rmsTarget = 0.065;
      peakLimit = 0.52;
      maxGain = 4.1;
    case SleepRecipe.noise:
      rmsTarget = 0.12;
      peakLimit = 0.62;
      maxGain = 1.5;
    case SleepRecipe.stream:
      rmsTarget = 0.085;
      peakLimit = 0.52;
      maxGain = 3.0;
    case SleepRecipe.birds:
      rmsTarget = 0.068;
      peakLimit = 0.60;
      maxGain = 3.0;
    case SleepRecipe.campfire:
      rmsTarget = 0.072;
      peakLimit = 0.55;
      maxGain = 2.6;
    case SleepRecipe.crickets:
      rmsTarget = 0.052;
      peakLimit = 0.50;
      maxGain = 4.0;
    case SleepRecipe.waterfall:
      rmsTarget = 0.12;
      peakLimit = 0.62;
      maxGain = 1.6;
    case SleepRecipe.lullaby:
      peakLimit = 0.78;
      maxGain = 1.7;
    case SleepRecipe.musicbox:
      peakLimit = 0.78;
      maxGain = 2.6;
    case SleepRecipe.nocturne:
      peakLimit = 0.74;
      maxGain = 2.0;
  }

  var gain = peak > 0 ? peakLimit / peak : 1.0;
  if (rmsTarget != null && rms > 0) {
    gain = math.min(gain, rmsTarget / rms);
  }
  gain = math.min(gain, maxGain);
  for (var i = 0; i < _kLen; i++) {
    out[i] = (out[i] * gain).clamp(-1.0, 1.0);
  }
}

Float64List _buildSamples(SleepRecipe recipe, double seed) {
  final tail = (_kSampleRate * 0.6).floor();
  final out = Float64List(_kLen + tail);
  final rng = _Rng((seed * 1000000).floor());
  switch (recipe) {
    case SleepRecipe.rain:
      _buildRain(rng, out);
    case SleepRecipe.ocean:
      _buildOcean(rng, out);
    case SleepRecipe.wind:
      _buildWind(rng, out);
    case SleepRecipe.lullaby:
      _buildLullaby(rng, out);
    case SleepRecipe.musicbox:
      _buildMusicbox(rng, out);
    case SleepRecipe.noise:
      _buildNoise(rng, out);
    case SleepRecipe.stream:
      _buildStream(rng, out);
    case SleepRecipe.birds:
      _buildBirds(rng, out);
    case SleepRecipe.campfire:
      _buildCampfire(rng, out);
    case SleepRecipe.crickets:
      _buildCrickets(rng, out);
    case SleepRecipe.nocturne:
      _buildNocturne(rng, out);
    case SleepRecipe.waterfall:
      _buildWaterfall(rng, out);
  }

  // 尾巴线性折回开头：out[i] 与 out[_kLen + i] 是同一时刻的连续样本，
  // 折叠后最后一个样本（_kLen-1）与第一个样本接得上，循环无「咔哒」。
  for (var i = 0; i < tail; i++) {
    final w = i / tail;
    out[i] = out[i] * w + out[_kLen + i] * (1 - w);
  }

  _normalize(out, recipe);
  return Float64List.sublistView(out, 0, _kLen);
}

/// 浮点样本 → 16bit 单声道 WAV。
Uint8List _encodeWav(Float64List samples) {
  final bytes = Uint8List(44 + samples.length * 2);
  final view = ByteData.view(bytes.buffer);

  void writeString(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      view.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  view.setUint32(4, bytes.length - 8, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, _kSampleRate, Endian.little);
  view.setUint32(28, _kSampleRate * 2, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  writeString(36, 'data');
  view.setUint32(40, samples.length * 2, Endian.little);

  var offset = 44;
  for (var i = 0; i < samples.length; i++) {
    final value = samples[i].clamp(-1.0, 1.0);
    view.setInt16(
      offset,
      value < 0 ? (value * 0x8000).round() : (value * 0x7fff).round(),
      Endian.little,
    );
    offset += 2;
  }
  return bytes;
}

/// isolate 入口：只收一个 id，目录表在两边都有一份，传字符串最稳。
Uint8List generateSleepWavForId(String id) {
  final track = sleepTrackById(id);
  if (track == null) {
    throw StateError('未知的休眠曲目：$id');
  }
  return _encodeWav(_buildSamples(track.recipe, track.seed));
}

/// 助手声景缓存：临时目录下 `light_music_sleep/<id>-v2.wav`。
///
/// 文件名带版本号：声景配方改过之后，旧缓存（`<id>.wav`）必须作废，否则
/// 用户重装/重启后听到的还是上一版的「沙沙」噪声。
class SleepAudioCache {
  SleepAudioCache({this.folderOverride});

  /// 当前声景配方版本；改动 [_buildRain] / [_buildOcean] / [_buildWind]
  /// 等生成逻辑时同步 +1。
  static const String version = 'v2';

  /// 测试用：指定一个现成目录，避免碰 path_provider 的平台通道。
  final Directory? folderOverride;

  final Map<String, String> _paths = <String, String>{};

  Future<Directory> _folder() async {
    final base =
        folderOverride ??
        Directory('${(await getTemporaryDirectory()).path}/light_music_sleep');
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base;
  }

  Future<String> fileFor(SleepTrack track) async {
    final cached = _paths[track.id];
    if (cached != null && await File(cached).exists()) return cached;
    final folder = await _folder();

    // 旧版缓存直接删掉：一条 32 秒 WAV 有 1.4MB，留着只会占空间，
    // 更麻烦的是旧声音会被继续播出来。
    final legacy = File('${folder.path}/${track.id}.wav');
    if (await legacy.exists()) {
      await legacy.delete();
    }

    final file = File('${folder.path}/${track.id}-$version.wav');
    if (!await file.exists() || await file.length() < 1024) {
      final bytes = await compute(generateSleepWavForId, track.id);
      await file.writeAsBytes(bytes, flush: true);
    }
    _paths[track.id] = file.path;
    return file.path;
  }
}

/// 休眠声景播放内核：与电台 / 曲库各用一台 Player，三条链路互不打扰。
abstract class SleepAudioEngine {
  Future<bool> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> setVolume(double value);
  Future<void> dispose();

  Stream<bool> get playingStream;
  Stream<bool> get loadingStream;
  Stream<String> get errorStream;

  bool get isPlaying;
}

class MediaKitSleepEngine implements SleepAudioEngine {
  Player? _player;
  bool _disposed = false;

  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _loadingSub;
  StreamSubscription<String>? _errorSub;

  Player _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final player = Player();
    _player = player;
    _playingSub = player.stream.playing.listen(
      (value) => _push(_playing, value),
    );
    _loadingSub = player.stream.buffering.listen(
      (value) => _push(_loading, value),
    );
    _errorSub = player.stream.error.listen((message) {
      if (MediaKitSleepEngine.isNonFatalNoise(message)) return;
      _push(_errors, message);
    });
    return player;
  }

  /// 本地 WAV 不该出这些，但 mpv 仍会为临时缓存报同样的日志。
  static bool isNonFatalNoise(String message) =>
      message.contains('Failed to create file cache') ||
      message.contains('Cache ended before') ||
      message.contains('Failed to recognize file format');

  @override
  Future<bool> open(String path) async {
    if (_disposed) return false;
    try {
      final player = _ensure();
      await player.open(Media(path), play: false);
      // 32 秒的循环要无缝接上，交给 mpv 的 playlist loop
      await player.setPlaylistMode(PlaylistMode.loop);
      return true;
    } catch (error) {
      _push(_errors, error.toString());
      return false;
    }
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    try {
      await _ensure().play();
    } catch (error) {
      _push(_errors, error.toString());
    }
  }

  @override
  Future<void> pause() async {
    // 还没开过任何一条声景时不创建内核：tune() 起手会先 pause 一次让位，
    // 这一步不该顺手把 mpv 拉起来。
    final player = _player;
    if (_disposed || player == null) return;
    try {
      await player.pause();
    } catch (_) {
      // 暂停失败没有可操作的东西，静默
    }
  }

  @override
  Future<void> stop() async {
    final player = _player;
    if (_disposed || player == null) return;
    try {
      await player.stop();
    } catch (_) {
      // 同上
    }
  }

  @override
  Future<void> setVolume(double value) async {
    final player = _player;
    if (_disposed || player == null) return;
    try {
      await player.setVolume(value * 100);
    } catch (_) {
      // 同上
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _playingSub?.cancel();
    await _loadingSub?.cancel();
    await _errorSub?.cancel();
    try {
      await _player?.dispose();
    } catch (_) {
      // 原生实例释放失败不反过来打断收尾
    }
    _player = null;
    await _playing.close();
    await _loading.close();
    await _errors.close();
  }

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get loadingStream => _loading.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  bool get isPlaying => _player?.state.playing ?? false;

  void _push<T>(StreamController<T> controller, T value) {
    if (_disposed || controller.isClosed) return;
    controller.add(value);
  }
}

/// 可脚本化的替身：组件测试注入它，既不开原生库、也不写临时文件。
class FakeSleepEngine implements SleepAudioEngine {
  final List<String> calls = <String>[];

  bool failNextOpen = false;

  final _playing = StreamController<bool>.broadcast();
  final _loading = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();

  bool _playingValue = false;
  bool _disposed = false;

  void emitPlaying(bool value) {
    _playingValue = value;
    _push(_playing, value);
  }

  void emitLoading(bool value) => _push(_loading, value);

  void emitError(String message) => _push(_errors, message);

  @override
  Future<bool> open(String path) async {
    calls.add('open:$path');
    if (failNextOpen) {
      failNextOpen = false;
      _push(_errors, 'wav unavailable');
      return false;
    }
    return true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    emitPlaying(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emitPlaying(false);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    emitPlaying(false);
  }

  @override
  Future<void> setVolume(double value) async {
    calls.add('volume:${value.toStringAsFixed(2)}');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    if (_disposed) return;
    _disposed = true;
    await _playing.close();
    await _loading.close();
    await _errors.close();
  }

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get loadingStream => _loading.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  bool get isPlaying => _playingValue;

  void _push<T>(StreamController<T> controller, T value) {
    if (_disposed || controller.isClosed) return;
    controller.add(value);
  }
}
