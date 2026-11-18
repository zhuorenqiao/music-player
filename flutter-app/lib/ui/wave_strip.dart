// lib/ui/wave_strip.dart
//
// 频谱条（M3 T11）：对译 React `src/components/WaveStrip.tsx`。
//
// 一条自绘 canvas（CustomPaint），样式由 ThemeState.waveStyleId 切换，
// 播放时优先用真实频谱帧表（T8/T9 的管线），不可用时退回装饰形状。
// 两种模式都在暂停时冻结。纯装饰，对读屏隐藏（ExcludeSemantics）；
// reduced-motion 下不跑动画只画静态一帧。
//
// 常量逐字：HEIGHT=48、PHASE_SPEED=3、PEAK_DECAY_PER_SEC=0.03、
// bandCount=max(24, w/4)、waveCount=clamp(round(w), 120, 512)。
//
// —— 帧预算（2026-11 真机掉帧那一轮）——
// 这条条子是**唯一常驻 60fps 的叶子**，所以每帧花的每一微秒都按屏幕刷新率
// 付钱。旧实现把「取帧 + 峰值回落 + 建 painter」全放在 build 里，于是每个
// vsync 都要重建 LayoutBuilder / ShaderMask / CustomPaint 一整棵子树，还要
// 重新 `createShader` 造蒙版；120Hz 屏上等于双倍开销，实测真机上就是「有时
// 候掉帧」。现在改成：
//   * 动画只推 [CustomPainter] 的 `repaint`，**widget 不重建**（只在换样式、
//     换配色、换帧表、换曲目、改宽度这些低频事件上重建）；
//   * 每帧的取帧走 [WaveSource] 的复用缓冲（零分配）；
//   * 两次重绘之间至少隔 [kMinRepaintGapSeconds]，120Hz 屏上按 60fps 画；
//   * 两端淡出的蒙版 shader 按尺寸记忆，不再逐帧造渐变色。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../playback/track.dart';
import '../theme/app_tokens.dart';
import '../theme/theme_state.dart';
import '../wave/spectrum_pipeline.dart';
import '../wave/wave_signal.dart';
import '../wave/wave_styles.dart';

/// 画布高度（CSS 像素，WaveStrip.tsx:26 / app.css:2488-2494 的
/// `.lyrics-page__wave { height: 48px }`）。满宽档（≥1680）抬到 56
/// （app.css:5098-5100），由调用方按视口宽度传 [WaveStrip.height]。
const double kWaveStripHeight = 48;

/// 满宽档（≥1680）的画布高度：`.lyrics-page__wave { height: 56px }`。
const double kWaveStripHeightUltra = 56;

/// 每根柱子的**显示下限**（0..1 的段值）：0.09 × 32px 振幅 ≈ 2.9px。
///
/// 帧表的段值下限是 0.02（`foldBands` 里对 `pow(value/255,1.35)*tilt*1.05`
/// 夹的下界，与 React 的 `Math.max(0.02, …)` 同值）。数字静音的帧整帧都是
/// 这个下限，画到 48px 的画布上只有 0.6px —— 看上去整条频谱「消失」。
/// React 那侧读的是实时 AnalyserNode（永远带一点噪声底），加上若干样式自己
/// 还夹了 `Math.max(2, …)` 的像素下限，所以不会整条空掉；Flutter 这侧读的是
/// 离线帧表，必须在显示端补上同一层保险。
const double kWaveBandDisplayFloor = 0.09;

/// 把段值抬到 [kWaveBandDisplayFloor]（就地改写 [bands]，它是每帧复用的缓冲）。
void applyBandDisplayFloor(Float32List bands) {
  for (var i = 0; i < bands.length; i++) {
    if (bands[i] < kWaveBandDisplayFloor) bands[i] = kWaveBandDisplayFloor;
  }
}

/// 相位推进速度（弧度/秒，WaveStrip.tsx:32）。
const double kWavePhaseSpeed = 3;

/// 两端淡出的起点 / 终点（0~1 的横向比例）。
///
/// CSS `.lyrics-page__wave { mask-image: linear-gradient(90deg,
/// transparent 0, #000 10%, #000 90%, transparent 100%) }`（app.css:2492-2493），
/// 注释写明用意：「两端用蒙版淡出，避免彩虹条在栏边生硬截断」。
const double kWaveFadeStop = 0.10;

/// 两次重绘的最小间隔（秒）。
///
/// 频谱的数据源是 50ms 一帧的离线帧表（20fps），画面靠插值补到满帧；再往上
/// 堆到 120fps 只是把同一段插值画两遍，GPU/合成开销却翻倍 —— 真机上掉帧正是
/// 从这种「预算被翻倍」的地方出来的。13.3ms 的阈值只在单帧间隔**明显小于**
/// 1/75 秒时才丢 tick：60Hz 屏（16.7ms）与 90Hz 屏（11.1ms）都照常逐帧画，
 /// 120Hz 屏（8.3ms）会隔一帧画一次 → 稳定 60fps。
const double kMinRepaintGapSeconds = 1 / 75;

/// 频谱条的横向淡出蒙版（[kWaveFadeStop] 那两条 stop 的 Dart 版）。
///
/// 用 [BlendMode.dstIn] 乘进 alpha：两端线性渐隐，中间原样保留。
Shader waveFadeMaskShader(Rect bounds) => LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: const [
    Color(0x00FFFFFF),
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
    Color(0x00FFFFFF),
  ],
  stops: const [0, kWaveFadeStop, 1 - kWaveFadeStop, 1],
).createShader(bounds);

/// 峰值每秒的保持比例（越小落得越快，WaveStrip.tsx:35）。
const double kWavePeakDecayPerSec = 0.03;

/// 帧表还没到时的替身动画相位倍率（0~~1，越小越"安静"）。
///
/// 装饰波形是**整条一起扫过去**的正弦行波（±24%、约 1Hz，见
/// [fallbackBands]）—— 拿它顶上真实频谱，看起来就是「刚切歌那一下律动得
/// 很厉害、有点假」。真实帧表没到之前让它按 1/5 速度慢慢呼吸：画面有生气，
/// 但不会被误读成"音乐在动"。表一到倍率回 1，因为相位是连续累加的，所以
/// 切换那一下不会跳。
const double kWaveFallbackPhaseScale = 0.2;

/// 频谱条本体。real 帧表由调用方（装配层）从 [SpectrumPipeline] 注入。
class WaveStrip extends StatefulWidget {
  const WaveStrip({
    required this.frameTable,
    required this.track,
    required this.playing,
    required this.positionSeconds,
    this.positionListenable,
    this.width = double.infinity,
    this.height = kWaveStripHeight,
    super.key,
  });

  /// 当前曲目的频谱帧表；null = 走装饰回退。
  final SpectrumFrameTable? frameTable;

  /// 当前曲目（装饰种子的来源）。
  final Track? track;

  final bool playing;
  final double positionSeconds;

  /// 进度 notifier（可选）：给了就**频谱条这一片叶子**自己订阅进度，
  /// 不把整条控制条带着 4Hz 重建（真实帧表按 positionSeconds 取帧，
  /// 所以频谱条必须跟着进度走）。
  final ValueListenable<double>? positionListenable;

  final double width;

  /// 画布高度：随视口档位取 [kWaveStripHeight] / [kWaveStripHeightUltra]。
  final double height;

  @override
  State<WaveStrip> createState() => _WaveStripState();
}

/// 动画脉冲：只通知画笔重绘，不触发任何 widget 重建。
class _WavePulse extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _WaveStripState extends State<WaveStrip>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// 画笔的 repaint 句柄（见类头「帧预算」）。
  final _WavePulse _pulse = _WavePulse();
  final WaveSource _source = WaveSource();

  /// 上一个 ticker 时刻（算 dt 与帧率上限都靠它）。
  double _lastTickAt = 0;

  /// 累计的动画相位（弧度），只喂给样式/装饰波形用。
  double _phase = 0;

  /// 上一帧的 tick 间隔（峰值回落与 frame.dt 都用它，而不是写死 1/60）。
  double _dt = 1 / 60;

  Float32List _peaks = Float32List(0);

  /// 取帧用的视觉进度（见 [WaveClock] 的类注释：上报的进度不能直接当帧时间）。
  final WaveClock _clock = WaveClock();

  /// 当前布局算出来的画布宽度 / 列数（只在 build 里更新）。
  double _layoutWidth = 0;
  int _bandCount = 0;
  int _waveCount = 0;

  /// 当前样式与调色板（只在 build 里更新，画笔每帧只读）。
  WaveStyle _style = kWaveStyles.first;
  WavePalette? _palette;
  Object? _paletteKey;

  /// reduced-motion：不跑 ticker，只画静态帧。
  bool _reduced = false;

  /// 已经绑上监听的进度 notifier（避免重复订阅 / 换对象时漏摘）。
  ValueListenable<double>? _boundPosition;

  @override
  void initState() {
    super.initState();
    _bindPosition();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 依赖只能在这里取（initState 里 dependOnInherited 会抛）。
    // 播放且未开启 reduced-motion 才推进（WaveStrip.tsx:158-163）。
    //
    // 这里**必须**先判 isActive：didChangeDependencies 在挂载之后还会因依赖
    // 变化再跑（外层布局/主题变动都会），而 Ticker 已经 active 时再 start() 会
    // 抛「A ticker was started twice」。
    _reduced = MediaQuery.disableAnimationsOf(context);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant WaveStrip old) {
    super.didUpdateWidget(old);
    if (!identical(old.positionListenable, widget.positionListenable)) {
      _bindPosition();
    }
    if (old.playing != widget.playing) {
      // 暂停 → 播放：视觉进度必须按「恢复那一刻」重新起算，
      // 否则暂停期间的那几十秒会被当成已播时间外推进去。
      _clock.reset();
      // 播放态一变，冻结/实时两种语义跟着变，补画一帧（暂停时 ticker 不再跑）。
      _pulse.tick();
    }
    if (!identical(old.frameTable, widget.frameTable) ||
        old.track?.id != widget.track?.id) {
      // 帧表到货 / 换曲：取帧区间整体变了，视觉进度重新对齐，
      // 即使暂停（ticker 停着）也要重画。
      _clock.reset();
      _pulse.tick();
    }
    _syncTicker();
  }

  void _syncTicker() {
    final shouldRun = widget.playing && !_reduced;
    if (shouldRun) {
      if (!_ticker.isActive) {
        // 每次 start() 的 elapsed 都从 0 重新计，旧时刻必须作废。
        _lastTickAt = 0;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _bindPosition() {
    _boundPosition?.removeListener(_onPositionChanged);
    _boundPosition = widget.positionListenable;
    _boundPosition?.addListener(_onPositionChanged);
  }

  void _onPositionChanged() {
    // 播放中 ticker 会自己重绘；只有「不跑 ticker」（暂停 / reduced-motion）
    // 时才需要靠这条通知把画面推到新位置。
    if (!_ticker.isActive) _pulse.tick();
  }

  void _onTick(Duration elapsed) {
    final now = elapsed.inMicroseconds / 1e6;
    // 帧率上限：120Hz 屏上每两帧画一次（见 kMinRepaintGapSeconds）。
    if (_lastTickAt > 0 && now - _lastTickAt < kMinRepaintGapSeconds) return;
    // Ticker 每次 start() 的 elapsed 都从 0 重新计，暂停再播放时
    // `now - _lastTickAt` 会是负数 —— 非正一律按 1 帧算。
    final raw = _lastTickAt == 0 ? 1 / 60 : now - _lastTickAt;
    final dt = raw <= 0 ? 1 / 60 : math.min(0.1, raw);
    _lastTickAt = now;
    _dt = dt;
    // 相位推进速度按「有没有真实帧表」分档（见 [kWaveFallbackPhaseScale]）。
    _phase += dt * kWavePhaseSpeed *
        (widget.frameTable == null ? kWaveFallbackPhaseScale : 1.0);
    _pulse.tick();
  }

  /// 这一帧该按哪个进度取帧。
  ///
  /// 播放中用 [WaveClock] 把「事件式上报的进度」补成一条连续时钟：上报间隔再
  /// 稀也不会冻住画面，偏差靠纠偏吃掉、不硬跳（详见 [WaveClock] 的类注释）。
  /// 暂停时就是这个上报值本身 —— 暂停本来就要冻结在那一帧上。
  double _positionNow() {
    final notifier = widget.positionListenable;
    final raw = notifier != null ? notifier.value : widget.positionSeconds;
    if (!widget.playing || notifier == null) {
      _clock.reset();
      return raw;
    }
    return _clock.advance(raw: raw, dt: _dt);
  }

  @override
  void dispose() {
    _boundPosition?.removeListener(_onPositionChanged);
    _ticker.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = context.watch<ThemeState>();
    final style = findWaveStyle(theme.waveStyleId);
    _style = style;
    _reduced = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 240.0;
        final bandCount = math.max(24, (w / 4).round());
        if (_peaks.length != bandCount) {
          _peaks = Float32List(bandCount);
        }
        _layoutWidth = w;
        _bandCount = bandCount;
        _waveCount = math.min(512, math.max(120, w.round()));
        // **调色板按输入记忆，不逐帧重建**：`buildWavePalette` 会算一条
        // 25 色的色带（单色档还要 13 次 HSLColor.toColor）并造一个新的
        // ui.Gradient —— 而它只依赖「样式 / 配色开关 / 强调色 / 歌词色 /
        // 宽度」这五个低频量。
        _palette = _paletteFor(
          style: style,
          colored: theme.colored,
          accent: tokens.accent,
          lyricColor: theme.lyricColor,
          width: w,
        );
        // painter 的判重指纹：这些量任一变，重建后的 painter 才需要真正重画。
        // 进度值**不在**里面 —— 它由 ticker / notifier 直接推动重绘。
        final configKey = (
          style.id,
          _paletteKey,
          widget.frameTable,
          widget.track?.id,
          widget.playing,
          // 没有 notifier 时进度只能随父级重建送进来，必须参与判重。
          widget.positionListenable == null ? widget.positionSeconds : null,
          w,
          widget.height,
          _reduced,
        );
        return ExcludeSemantics(
          child: SizedBox(
            width: w,
            height: widget.height,
            // 频谱条每帧自画，外面又没别的图层要跟着变 —— 隔离出来，
            // 别让这条 60fps 的重绘把播放卡上的 ClipRRect / 磨砂层拖下去。
            child: RepaintBoundary(
              // 两端淡出：CSS 那条 `mask-image` 的等价物（见 [kWaveFadeStop]）。
              // 没有它，彩虹条会在卡片左右内边距处被生硬切断，看着像「画歪了」。
              child: ShaderMask(
                key: const Key('wave-fade-mask'),
                blendMode: BlendMode.dstIn,
                shaderCallback: _fadeShader,
                child: CustomPaint(
                  size: Size(w, widget.height),
                  // willChange：这张图每帧都变，别让光栅缓存白折腾。
                  willChange: true,
                  painter: _WavePainter(state: this, configKey: configKey),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 蒙版 shader 按尺寸记忆：`ShaderMask` 每次 paint 都会调 `shaderCallback`，
  /// 逐帧造一条 LinearGradient + createShader 是纯粹的浪费。
  Size? _fadeSize;
  Shader? _fadeShaderCache;

  Shader _fadeShader(Rect bounds) {
    final size = bounds.size;
    final cached = _fadeShaderCache;
    if (cached != null && _fadeSize == size) return cached;
    final shader = waveFadeMaskShader(bounds);
    _fadeSize = size;
    _fadeShaderCache = shader;
    return shader;
  }

  /// 上一次算出的调色板与它的输入指纹（见 [build] 里的那段解释）。
  WavePalette _paletteFor({
    required WaveStyle style,
    required bool colored,
    required Color accent,
    required String lyricColor,
    required double width,
  }) {
    // 指纹用 record：字段少、比较是逐字段值比较，不需要再手写 equals。
    final key = (style.id, colored, accent, lyricColor, width);
    final cached = _palette;
    if (cached != null && _paletteKey == key) return cached;
    final built = buildWavePalette(
      ramp: style.ramp,
      colored: colored,
      accent: accent,
      lyricColor: lyricColor,
      width: width,
    );
    _palette = built;
    _paletteKey = key;
    return built;
  }

  /// 画一帧（由 [_WavePainter.paint] 调用；不重建 widget）。
  void paintWave(Canvas canvas, Size size) {
    final palette = _palette;
    if (palette == null) return;
    final style = _style;
    final bandCount = _bandCount <= 0 ? math.max(24, (size.width / 4).round()) : _bandCount;
    final waveCount = _waveCount <= 0 ? math.min(512, math.max(120, size.width.round())) : _waveCount;
    if (_peaks.length != bandCount) _peaks = Float32List(bandCount);

    // 峰值回落用墙钟 dt（WaveStrip.tsx:113-118）。每帧 O(bandCount) 的乘，
    // 相对调色板与点集是小事。
    if (style.usesPeaks) {
      final decay = math.pow(kWavePeakDecayPerSec, _dt).toDouble();
      for (var i = 0; i < _peaks.length; i++) {
        _peaks[i] *= decay;
      }
    }
    // 挂帧表（换曲目时 WaveSource 自己作废冻结帧）。
    final table = widget.frameTable;
    if (table != null) {
      _source.attach(table, widget.track?.id ?? '');
    } else {
      _source.detach();
    }
    final frame = _source.read(
      playing: widget.playing,
      positionSeconds: _positionNow(),
      phase: _phase,
      dt: _dt,
      track: widget.track,
      bandCount: bandCount,
      waveCount: waveCount,
      width: _layoutWidth > 0 ? _layoutWidth : size.width,
      height: widget.height,
    );
    // 静音帧在画布上等于「消失」：帧表的段值是 0..255 的字节，而
    // `foldBands` 的下限只有 0.02 —— 在 48px 高的条子上就是 0.6px，
    // 一条细到看不见的发丝。数字静音段（前奏、间奏、淡出）整帧都贴在这个
    // 下限上，用户看到的就是「音谱有的时候会消失不见」。
    // 这里给一个**显示下限**（约 1.8px 等效高度）：数据本身不动，只保证
    // 画出来的每一列至少有这么高，任何时刻都看得见条子。
    applyBandDisplayFloor(frame.bands);
    style.draw(canvas, frame, palette, _peaks);
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.state, required this.configKey})
    : super(repaint: state._pulse);

  /// 宿主 State：每帧的取帧与绘制都回到它身上，painter 本身不持有每帧数据。
  final _WaveStripState state;

  /// 配置指纹（样式 / 配色 / 帧表 / 曲目 / 播放态 / 宽度 / 高度 / reduced）。
  final Object? configKey;

  @override
  void paint(Canvas canvas, Size size) => state.paintWave(canvas, size);

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.state != state || old.configKey != configKey;
}
