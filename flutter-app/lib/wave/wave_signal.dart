// lib/wave/wave_signal.dart
//
// 波形数据的统一数据源（M3 T9）：对译 React `src/lib/wave-signal.ts`。
//
// 一次读取给出两路信号：
//   * bands：对数折叠后的频段能量（0..1），柱状 / 点阵 / 山形样式吃它；
//   * wave：时域采样（-1..1），彩带 / 折线 / 多股细线样式吃它。
//
// 三态（wave-signal.ts:8-10 的语义）：
//   * 播放且有帧表 → 按当前进度插值取帧（live = true）；
//   * 暂停 → 冻结在最后一帧真实数据（**不**回落装饰）；
//   * 无帧表（解码失败 / 未算完）→ 装饰回退（fallbackBands/fallbackWave），
//     并带正弦起伏保证「播放中」仍有律动。
//
// 返回的两个数组是复用缓冲，只在这一帧内有效，调用方不能存下来。
import 'dart:math' as math;
import 'dart:typed_data';

import '../playback/track.dart';
import 'spectrum_pipeline.dart';

/// FNV-1a：同一个曲目 id 永远得到同一条装饰波形（wave-signal.ts:16-23）。
int waveHash(String text) {
  var value = 0x811c9dc5;
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    value ^= units[i];
    value = (value * 0x01000193) & 0xFFFFFFFF;
  }
  return value;
}

/// 一帧波形数据（wave-signal.ts:25-42 同构）。
class WaveFrame {
  const WaveFrame({
    required this.bands,
    required this.wave,
    required this.level,
    required this.phase,
    required this.dt,
    required this.width,
    required this.height,
    required this.live,
    required this.seed,
  });

  /// 频段能量 0..1。
  final Float32List bands;

  /// 时域 -1..1。
  final Float32List wave;

  /// 整帧平均能量。
  final double level;

  /// 累计动画时间（秒）。
  final double phase;

  /// 距上一帧的秒数（峰值回落用墙钟而不是帧数）。
  final double dt;
  final double width;
  final double height;

  /// 是否来自真实音频（含暂停后冻结的那一帧）。
  final bool live;

  /// 当前曲目 id，装饰回退与样式的随机频率都拿它当种子。
  final String seed;
}

/// 装饰频谱的包络：一条偏向中左的钟形 + 每根柱子的哈希抖动
///（wave-signal.ts:61-74 逐字）。
void fallbackBands(String seed, int count, double phase, Float32List out) {
  final root = waveHash(seed.isEmpty ? 'unknown' : seed);
  final center = 0.38 + (root % 25) / 100;
  final spread = 0.16 + ((root >> 5) % 10) / 100;
  for (var i = 0; i < count; i++) {
    final t = i / math.max(1, count - 1);
    final bell = math.exp(-_sqr(t - center) / (2 * spread * spread));
    final jitter = 0.72 + ((waveHash('$seed#$i') % 1000) / 1000) * 0.45;
    // 两端强制压低，形成「中间高、两头贴地」。
    final edge = math.min(1, math.sin(math.pi * math.min(1, t * 1.04 + 0.02)) * 1.8);
    final wobble =
        1 + (math.sin(phase * 2.2 + i * 0.35) + math.sin(phase * 1.4 + i * 0.11)) * 0.12;
    out[i] = math.min(1, math.max(0.03, bell * jitter * edge * wobble));
  }
}

double _sqr(double v) => v * v;

/// 装饰波形：五条不同频率的正弦叠加，频率由曲目 id 决定
///（wave-signal.ts:77-96 逐字）。
void fallbackWave(String seed, int count, double phase, Float32List out) {
  final root = waveHash('${seed.isEmpty ? 'unknown' : seed}|wave');
  final f1 = 1.6 + (root % 7) * 0.35;
  final f2 = 3.1 + ((root >> 3) % 5) * 0.4;
  final f3 = 6.4 + ((root >> 6) % 4) * 0.5;
  // 再叠两个高次谐波：只有低频正弦的曲线一眼就是「假律动」。
  final f4 = 12.5 + ((root >> 9) % 6) * 0.7;
  final f5 = 21 + ((root >> 13) % 9) * 1.1;
  final level = 0.35 + ((root >> 17) % 40) / 100;
  for (var i = 0; i < count; i++) {
    final t = count > 1 ? i / (count - 1) : 0.0;
    final env = 0.3 + 0.7 * math.sin(math.pi * (t * 1.3 + 0.12)).abs();
    final v = math.sin(t * math.pi * 2 * f1 + phase * 1.7) * 0.5 +
        math.sin(t * math.pi * 2 * f2 - phase * 2.3) * 0.27 +
        math.sin(t * math.pi * 2 * f3 + phase * 3.1) * 0.14 +
        math.sin(t * math.pi * 2 * f4 - phase * 4.4) * 0.06 +
        math.sin(t * math.pi * 2 * f5 + phase * 5.6) * 0.03;
    out[i] = math.max(-1.0, math.min(1.0, v * env * level * 2.6));
  }
}

/// 帧表读取器：挂一张 [SpectrumFrameTable]（可空），按 positionSeconds 插值
/// 取帧；暂停冻结；无帧表走装饰。
class WaveSource {
  SpectrumFrameTable? _table;
  String? _tableKey;

  /// 冻结帧（最后一帧真实数据）。
  Uint8List? _frozenBands;
  Int8List? _frozenWave;

  /// 当前挂的曲目 id（换歌时冻结帧作废）。
  String? _trackId;

  /// 帧表是否就位（live 判据）。
  bool get hasTable => _table != null;

  /// 挂帧表（解析完成 / 从缓存读回）。换曲目时旧的冻结帧作废。
  void attach(SpectrumFrameTable table, String trackId) {
    if (_tableKey == '$trackId|${table.frameCount}|${table.frameMs}') return;
    _table = table;
    _tableKey = '$trackId|${table.frameCount}|${table.frameMs}';
    _frozenBands = null;
    _frozenWave = null;
    _trackId = trackId;
  }

  void detach() {
    _table = null;
    _tableKey = null;
    _frozenBands = null;
    _frozenWave = null;
    _trackId = null;
  }

  /// 读取一帧（wave-signal.ts:168-205 的 read 对译）。
  WaveFrame read({
    required bool playing,
    required double positionSeconds,
    required double phase,
    required double dt,
    required Track? track,
    required int bandCount,
    required int waveCount,
    required double width,
    required double height,
  }) {
    final seed = track?.id ?? '';
    final outBands = Float32List(bandCount);
    final outWave = Float32List(waveCount);

    final table = _table;
    if (table != null && _trackId == seed && seed.isNotEmpty) {
      if (playing) {
        _readReal(table, positionSeconds, bandCount, waveCount, outBands, outWave);
        _frozenBands = Uint8List.fromList(_tableBytes(outBands));
        _frozenWave = Int8List.fromList(_tableWaveBytes(outWave));
      } else if (_frozenBands != null && _frozenWave != null) {
        // 暂停：沿用最后一帧真实数据，不要回落到装饰形状。
        for (var i = 0; i < bandCount; i++) {
          outBands[i] = i < _frozenBands!.length ? _frozenBands![i] / 255 : 0;
        }
        for (var i = 0; i < waveCount; i++) {
          outWave[i] = i < _frozenWave!.length ? _frozenWave![i] / 127 : 0;
        }
      } else {
        _readReal(table, positionSeconds, bandCount, waveCount, outBands, outWave);
      }
    } else {
      fallbackBands(seed, bandCount, phase, outBands);
      fallbackWave(seed, waveCount, phase, outWave);
    }

    var sum = 0.0;
    for (final v in outBands) {
      sum += v;
    }
    return WaveFrame(
      bands: outBands,
      wave: outWave,
      level: outBands.isEmpty ? 0 : sum / outBands.length,
      phase: phase,
      dt: dt,
      width: width,
      height: height,
      live: table != null && _trackId == seed && seed.isNotEmpty,
      seed: seed,
    );
  }

  Uint8List _tableBytes(Float32List bands) {
    final out = Uint8List(bands.length);
    for (var i = 0; i < bands.length; i++) {
      out[i] = (bands[i] * 255).round().clamp(0, 255);
    }
    return out;
  }

  Int8List _tableWaveBytes(Float32List wave) {
    final out = Int8List(wave.length);
    for (var i = 0; i < wave.length; i++) {
      out[i] = (wave[i] * 127).round().clamp(-128, 127);
    }
    return out;
  }

  /// 按 positionSeconds 从帧表插值取帧（帧 i 覆盖 [i*frameMs,(i+1)*frameMs)）。
  void _readReal(
    SpectrumFrameTable table,
    double positionSeconds,
    int bandCount,
    int waveCount,
    Float32List outBands,
    Float32List outWave,
  ) {
    final pos = positionSeconds.clamp(0.0, 1e9);
    final exact = pos * 1000 / table.frameMs;
    final i0 = exact.floor().clamp(0, table.frameCount - 1);
    final i1 = math.min(table.frameCount - 1, i0 + 1);
    final k = (exact - i0).clamp(0.0, 1.0);
    for (var b = 0; b < bandCount; b++) {
      final srcB = b < kBandCount ? b : kBandCount - 1;
      final a = table.bands[i0 * kBandCount + srcB] / 255;
      final c = table.bands[i1 * kBandCount + srcB] / 255;
      outBands[b] = a + (c - a) * k;
    }
    for (var w = 0; w < waveCount; w++) {
      final srcW = w < kWavCount ? w : kWavCount - 1;
      final a = table.wave[i0 * kWavCount + srcW] / 127;
      final c = table.wave[i1 * kWavCount + srcW] / 127;
      outWave[w] = (a + (c - a) * k).clamp(-1.0, 1.0);
    }
  }
}
