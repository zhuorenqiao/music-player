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

/// 画布高度（CSS 像素，WaveStrip.tsx:26）。
const double kWaveStripHeight = 48;

/// 相位推进速度（弧度/秒，WaveStrip.tsx:32）。
const double kWavePhaseSpeed = 3;

/// 峰值每秒的保持比例（越小落得越快，WaveStrip.tsx:35）。
const double kWavePeakDecayPerSec = 0.03;

/// 频谱条本体。real 帧表由调用方（装配层）从 [SpectrumPipeline] 注入。
class WaveStrip extends StatefulWidget {
  const WaveStrip({
    required this.frameTable,
    required this.track,
    required this.playing,
    required this.positionSeconds,
    this.positionListenable,
    this.width = double.infinity,
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

  @override
  State<WaveStrip> createState() => _WaveStripState();
}

class _WaveStripState extends State<WaveStrip>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _phase = 0;
  double _lastTickAt = 0;
  Float32List _peaks = Float32List(0);
  final WaveSource _source = WaveSource();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 依赖只能在 didChangeDependencies 取（initState 里
    // dependOnInherited 会抛）。播放且未开启 reduced-motion 才推进
    //（WaveStrip.tsx:158-163）。
    //
    // 这里**必须**先判 isActive：didChangeDependencies 在挂载之后还会因
    // 依赖变化再跑（外层布局/主题变动都会），而 Ticker 已经 active 时再
    // start() 会抛「A ticker was started twice」—— 之前因为没有这层守卫，
    // 只要上面某层重建一次（例如播放卡合成、Material 插入）就整屏红。
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (widget.playing && !reduced) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final now = elapsed.inMicroseconds / 1e6;
    final dt = _lastTickAt == 0 ? 1 / 60 : math.min(0.1, now - _lastTickAt);
    _lastTickAt = now;
    setState(() => _phase += dt * kWavePhaseSpeed);
  }

  @override
  void didUpdateWidget(covariant WaveStrip old) {
    super.didUpdateWidget(old);
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (widget.playing && !reduced) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = widget.positionListenable;
    if (notifier != null) {
      // 只有频谱条这一片叶子跟着进度重建（真实帧表按 positionSeconds 取帧）。
      return ValueListenableBuilder<double>(
        valueListenable: notifier,
        builder: (context, position, _) =>
            ExcludeSemantics(child: _layout(context, position)),
      );
    }
    return ExcludeSemantics(child: _layout(context, widget.positionSeconds));
  }

  /// 条子本体：[positionSeconds] 由调用方给（订阅进度时是 notifier 的实时值）。
  Widget _layout(BuildContext context, double positionSeconds) {
    final tokens = context.tokens;
    final theme = context.watch<ThemeState>();
    final style = findWaveStyle(theme.waveStyleId);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 240.0;
        final bandCount = math.max(24, (w / 4).round());
        if (_peaks.length != bandCount) {
          _peaks = Float32List(bandCount);
        }
        final reduced = MediaQuery.disableAnimationsOf(context);
        // 峰值回落用墙钟 dt（WaveStrip.tsx:113-118）。
        //
        // **这一步必须留在 build 之外会更好，但它依赖 dt 而 dt 由 ticker
        // 给；折中是「每帧一次 O(bandCount) 的乘」**（bandCount ≈ w/4，
        // 1200px 时 300 次乘），相对下面的 palette 与频谱点集是小事。
        if (style.usesPeaks) {
          final decay = math.pow(kWavePeakDecayPerSec, 1 / 60).toDouble();
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
          positionSeconds: positionSeconds,
          phase: _phase,
          dt: 1 / 60,
          track: widget.track,
          bandCount: bandCount,
          waveCount: math.min(512, math.max(120, w.round())),
          width: w,
          height: kWaveStripHeight,
        );
        // **调色板按输入记忆，不逐帧重建**：`buildWavePalette` 会算一条
        // 25 色的色带（单色档还要 13 次 HSLColor.toColor）并造一个新的
        // ui.Gradient —— 而它只依赖「样式 / 配色开关 / 强调色 / 歌词色 /
        // 宽度」这五个低频量，逐帧重算纯属白烧 UI 线程。
        final palette = _paletteFor(
          style: style,
          colored: theme.colored,
          accent: tokens.accent,
          lyricColor: theme.lyricColor,
          width: w,
        );
        return SizedBox(
          width: w,
          height: kWaveStripHeight,
          // 频谱条每帧自画，外面又没别的图层要跟着变 —— 隔离出来，
          // 别让这条 60fps 的重绘把播放卡上的 ClipRRect / 磨砂层拖下去。
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size(w, kWaveStripHeight),
              painter: _WavePainter(
                style: style,
                frame: reduced ? _staticFrame(frame, bandCount, w) : frame,
                palette: palette,
                peaks: _peaks,
                // 帧表身份与 live 标志也参与判重绘：暂停时 ticker 不跑、
                // phase 冻住，若只看 phase/seed，异步到货的真实帧表永远画
                // 不出来（界面会一直停在装饰形状）。
                table: table,
                live: frame.live,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 上一次算出的调色板与它的输入指纹（见 [build] 里的那段解释）。
  WavePalette? _palette;
  Object? _paletteKey;

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

  /// reduced-motion：静态一帧（phase 冻在当前值——画一次不推进）。
  WaveFrame _staticFrame(WaveFrame frame, int bandCount, double w) => frame;
}class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.style,
    required this.frame,
    required this.palette,
    required this.peaks,
    required this.table,
    required this.live,
  });

  final WaveStyle style;
  final WaveFrame frame;
  final WavePalette palette;
  final Float32List peaks;

  /// 当前挂的帧表（null = 装饰回退）。见 [shouldRepaint] 的说明。
  final SpectrumFrameTable? table;
  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    style.draw(canvas, frame, palette, peaks);
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.style.id != style.id ||
      old.frame.phase != frame.phase ||
      old.frame.seed != frame.seed ||
      old.palette.colored != palette.colored ||
      // 帧表到货 / 被清掉 / 换了一首：即使暂停（phase 冻住）也要重画，
      // 否则「打开歌词页 → 解析完成」这一下界面永远不更新。
      !identical(old.table, table) ||
      old.live != live;
}
