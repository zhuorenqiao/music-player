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
///
/// 每帧真正变动的只有 `phase`（wobble 那两条正弦）；`bell * jitter * edge`
/// 只依赖 (seed, count)，是**纯静态系数** —— 逐帧重算等于每帧做 count 次
/// 字符串拼接 + FNV 哈希 + exp。频谱条是常驻 60fps 的叶子，这一项在真机上
/// 就是「有时掉帧」的来源之一，所以按 (seed, count) 记忆一层。
void fallbackBands(String seed, int count, double phase, Float32List out) {
  final root = waveHash(seed.isEmpty ? 'unknown' : seed);
  final center = 0.38 + (root % 25) / 100;
  final spread = 0.16 + ((root >> 5) % 10) / 100;
  final factors = _bandFactors(seed, count, root, center, spread);
  for (var i = 0; i < count; i++) {
    final wobble =
        1 + (math.sin(phase * 2.2 + i * 0.35) + math.sin(phase * 1.4 + i * 0.11)) * 0.12;
    out[i] = math.min(1, math.max(0.03, factors[i] * wobble));
  }
}

/// (seed, count) 的静态系数缓存（单条即可：同一时刻只有一首歌在放）。
String _factorsSeed = '\u0000';
int _factorsCount = -1;
Float64List _factors = Float64List(0);

Float64List _bandFactors(
  String seed,
  int count,
  int root,
  double center,
  double spread,
) {
  if (_factorsSeed == seed && _factorsCount == count) return _factors;
  final factors = Float64List(count);
  for (var i = 0; i < count; i++) {
    final t = i / math.max(1, count - 1);
    final bell = math.exp(-_sqr(t - center) / (2 * spread * spread));
    final jitter = 0.72 + ((waveHash('$seed#$i') % 1000) / 1000) * 0.45;
    // 两端强制压低，形成「中间高、两头贴地」。
    final edge = math.min(1, math.sin(math.pi * math.min(1, t * 1.04 + 0.02)) * 1.8);
    factors[i] = bell * jitter * edge;
  }
  _factorsSeed = seed;
  _factorsCount = count;
  _factors = factors;
  return factors;
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

/// 取帧用的「视觉进度」时钟。
///
/// **为什么不能直接拿播放器上报的进度去取帧**：mpv 的 `time-pos` 是事件式上报
/// 的（间隔不固定，几十一百毫秒到一整秒都有），直接把它当帧时间用，每两次上报
/// 之间进度就是个常数 —— 频谱会「卡住不动」，下一次上报又整段跳过去，看起来
/// 就是「有时候不律动 / 有时候抖一下」。旧实现用「锚点 + 最多外推 0.5s」补：
/// 上报间隔一旦超过 0.5s，多出来的那段仍然是冻结的，而且新值一来是**硬跳**。
///
/// 这里的做法是把两者结合成一条平滑时钟：
///   * 每帧按**真实经过时间**前进（dt 来自 vsync），所以上报之间不会冻住；
///   * 上报值只用来做**纠偏**：落后就按一阶低通（[correctionTauSeconds]）加速追，
///     单帧最多 [maxPullRate] 倍速，所以不是「啪」地跳一格；永远不会倒放；
///   * 偏差超过 [snapThresholdSeconds] 视为 seek / 切歌，直接对齐（这种大跳是
///     用户主动操作，渐变反而拖沓）；
///   * 允许**领跑**音频最多 [maxLeadSeconds] —— 事件式上报天然滞后，这一点领跑
///     正是「上报之间照常推进」的来源；超过它说明音频真的停了（缓冲/卡死），
///     就地停住等，既不失真也不倒退。
class WaveClock {
  /// 一阶纠偏的时间常数（秒）：落后时误差基本在这个时间尺度内被吃掉。
  static const double correctionTauSeconds = 0.22;

  /// 追帧的倍速上限（相对真实时间），防止「一次补齐」变成跳帧。
  static const double maxPullRate = 1.5;

  /// 偏差超过这个值就认为发生了 seek / 切歌，直接对齐而不是渐变。
  static const double snapThresholdSeconds = 1.0;

  /// 允许领跑音频多久（秒）。
  ///
  /// 事件式上报（mpv 的 `time-pos`）间隔常在 0.1~1s，节奏很不均匀。领跑额度
  /// 必须比常见的最长间隔大，否则每次上报前的那一段都会被「封顶」成静止——那
  /// 还是回到「有时候不律动」。1.25s 既覆盖 1s 级别的间隔，又能在真卡住时
  /// 一小时以内停住。
  static const double maxLeadSeconds = 1.25;

  bool _has = false;
  double _visual = 0;

  /// 最近一次前进量（测试据此判断「有没有冻结」）。
  double get lastStep => _lastStep;
  double _lastStep = 0;

  /// 当前视觉进度（没有值时为 0）。
  double get value => _visual;

  /// 换曲 / 暂停后恢复：丢掉旧锚点，下一次 [advance] 直接对齐。
  void reset() {
    _has = false;
    _lastStep = 0;
  }

  /// 推进一步，返回这一帧该用的进度（秒）。
  ///
  /// [raw] 是播放器上报的进度（不可用就传 NaN），[dt] 是距上一帧的秒数。
  double advance({required double raw, required double dt}) {
    final step = (!dt.isFinite || dt <= 0)
        ? 1 / 60
        : (dt > 0.1 ? 0.1 : dt);
    if (!raw.isFinite) {
      _lastStep = 0;
      return _visual;
    }
    if (!_has) {
      _has = true;
      _visual = raw;
      _lastStep = 0;
      return raw;
    }
    // 落后太多（seek 往后 / 刚切歌）：直接对齐。这里比较的是「下一帧本该到哪」
    // 与上报值。
    if (raw - _visual > snapThresholdSeconds) {
      final jump = raw - _visual;
      _visual = raw;
      _lastStep = jump;
      return raw;
    }
    // 反过来：如果我们比音频超前**超过领跑额度**，那不可能是「音频暂时没上报」
    // （那种情况领跑被封顶在 maxLeadSeconds），只能是 seek 往前 / 换曲把进度
    // 归零了 —— 也必须直接对齐，不然画面会卡在上一首的尾巴上。
    if (_visual - raw > maxLeadSeconds) {
      final jump = raw - _visual;
      _visual = raw;
      _lastStep = jump;
      return raw;
    }
    final ceiling = raw + maxLeadSeconds;
    if (_visual >= ceiling) {
      // 已经领跑到上限：音频大概真的停了（缓冲/上报卡死），停住等它，不倒放。
      _lastStep = 0;
      return _visual;
    }
    var next = _visual + step;
    if (next > ceiling) next = ceiling;
    // 落后时加速追（一阶纠偏，单帧最多 maxPullRate 倍时间）。
    final err = raw - next;
    if (err > 0) {
      final gain = 1 - math.exp(-step / correctionTauSeconds);
      var pull = err * gain;
      final limit = step * maxPullRate;
      if (pull > limit) pull = limit;
      next += pull;
      if (next > ceiling) next = ceiling;
    }
    _lastStep = next - _visual;
    _visual = next;
    return next;
  }
}

/// 帧表读取器：挂一张 [SpectrumFrameTable]（可空），按 positionSeconds 插值
/// 取帧；暂停冻结；无帧表走装饰。
///
/// 取帧用的进度由 [WaveClock] 提供（见那边的注释：上报值不能直接当帧时间用）。
class WaveSource {
  SpectrumFrameTable? _table;
  String? _tableKey;

  /// 是否已经算出过「真实的一帧」。
  ///
  /// 暂停时直接复用上一次算出来的缓冲就是「冻结」—— 旧实现每帧再拷一份
  /// `_frozenBands/_frozenWave`，等于 60fps × 两次数百元素的分配+拷贝；
  /// 而暂停期间根本没人写这两个缓冲（位置不动就不会重算），复用即可。
  bool _haveLive = false;

  /// 当前挂的曲目 id（换歌时冻结帧作废）。
  String? _trackId;

  /// 每帧复用的输出缓冲（尺寸变化时才重建）。
  Float32List _bands = Float32List(0);
  Float32List _wave = Float32List(0);

  /// 帧表是否就位（live 判据）。
  bool get hasTable => _table != null;

  /// 挂帧表（解析完成 / 从缓存读回）。换曲目时旧的冻结帧作废。
  void attach(SpectrumFrameTable table, String trackId) {
    if (_tableKey == '$trackId|${table.frameCount}|${table.frameMs}') return;
    _table = table;
    _tableKey = '$trackId|${table.frameCount}|${table.frameMs}';
    _haveLive = false;
    _trackId = trackId;
  }

  void detach() {
    _table = null;
    _tableKey = null;
    _haveLive = false;
    _trackId = null;
  }

  /// 读取一帧（wave-signal.ts:168-205 的 read 对译）。
  ///
  /// 返回的 [WaveFrame] 与其 bands/wave **只在本次绘制内有效**：两个数组是
  /// 复用的缓冲，下一帧会被覆盖（宿主不得缓存）。
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
    if (_bands.length != bandCount) _bands = Float32List(bandCount);
    if (_wave.length != waveCount) _wave = Float32List(waveCount);
    final outBands = _bands;
    final outWave = _wave;

    final table = _table;
    final hasTable = table != null && _trackId == seed && seed.isNotEmpty;
    if (hasTable) {
      if (playing || !_haveLive) {
        _readReal(table, positionSeconds, bandCount, waveCount, outBands, outWave);
        _haveLive = true;
      }
      // playing == false 且已经有过真实帧：缓冲里就是「最后一帧」，直接复用。
    } else {
      _haveLive = false;
      fallbackBands(seed, bandCount, phase, outBands);
      fallbackWave(seed, waveCount, phase, outWave);
    }

    var sum = 0.0;
    for (var i = 0; i < outBands.length; i++) {
      sum += outBands[i];
    }
    return WaveFrame(
      bands: outBands,
      wave: outWave,
      level: outBands.isEmpty ? 0 : sum / outBands.length,
      phase: phase,
      dt: dt,
      width: width,
      height: height,
      live: hasTable,
      seed: seed,
    );
  }

  /// 按 positionSeconds 从帧表插值取帧（帧 i 覆盖 [i*frameMs,(i+1)*frameMs)）。
  ///
  /// 两维插值：
  ///   * 时间维：相邻两帧按帧内进度线性插值（帧表 20fps，界面 60fps 取帧，
  ///     不插就会一跳一跳）；
  ///   * 频维：帧表只有 [kBandCount] 段（64），条子有 `bandCount ≈ 宽/4` 列
  ///     （1200px 时 ~300 列）。段本身是对数分频，所以**段号线性插值**就等于
  ///     React `readBands` 里 `bin = pow(maxBin, t)` 的铺满方式。
  ///
  ///     v1 的实现是 `srcB = b < 64 ? b : 63` —— 第 64 段以后每列都是同一个
  ///     字节值，约 78% 的宽度复制成同一根柱：形状被「一片等高格子」取代，
  ///     这就是用户看到的「假频谱」。
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
    final rowA = i0 * kBandCount;
    final rowB = i1 * kBandCount;
    for (var b = 0; b < bandCount; b++) {
      final t = bandCount > 1 ? b / (bandCount - 1) : 0.0;
      final at = t * (kBandCount - 1);
      final s0 = at.floor().clamp(0, kBandCount - 1);
      final s1 = math.min(kBandCount - 1, s0 + 1);
      final f = at - s0;
      final va = table.bands[rowA + s0] / 255 +
          (table.bands[rowA + s1] / 255 - table.bands[rowA + s0] / 255) * f;
      final vb = table.bands[rowB + s0] / 255 +
          (table.bands[rowB + s1] / 255 - table.bands[rowB + s0] / 255) * f;
      outBands[b] = va + (vb - va) * k;
    }
    final wA = i0 * kWavCount;
    final wB = i1 * kWavCount;
    for (var w = 0; w < waveCount; w++) {
      final t = waveCount > 1 ? w / (waveCount - 1) : 0.0;
      final at = t * (kWavCount - 1);
      final s0 = at.floor().clamp(0, kWavCount - 1);
      final s1 = math.min(kWavCount - 1, s0 + 1);
      final f = at - s0;
      final va = table.wave[wA + s0] / 127 +
          (table.wave[wA + s1] / 127 - table.wave[wA + s0] / 127) * f;
      final vb = table.wave[wB + s0] / 127 +
          (table.wave[wB + s1] / 127 - table.wave[wB + s0] / 127) * f;
      outWave[w] = (va + (vb - va) * k).clamp(-1.0, 1.0);
    }
  }
}
