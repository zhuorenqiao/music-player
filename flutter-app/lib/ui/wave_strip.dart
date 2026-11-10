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
    this.width = double.infinity,
    super.key,
  });

  /// 当前曲目的频谱帧表；null = 走装饰回退。
  final SpectrumFrameTable? frameTable;

  /// 当前曲目（装饰种子的来源）。
  final Track? track;

  final bool playing;
  final double positionSeconds;
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
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (widget.playing && !reduced) {
      _ticker.start();
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
    final tokens = context.tokens;
    final theme = context.watch<ThemeState>();
    final style = findWaveStyle(theme.waveStyleId);
    return ExcludeSemantics(
      child: LayoutBuilder(
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
            positionSeconds: widget.positionSeconds,
            phase: _phase,
            dt: 1 / 60,
            track: widget.track,
            bandCount: bandCount,
            waveCount: math.min(512, math.max(120, w.round())),
            width: w,
            height: kWaveStripHeight,
          );
          return SizedBox(
            width: w,
            height: kWaveStripHeight,
            child: CustomPaint(
              size: Size(w, kWaveStripHeight),
              painter: _WavePainter(
                style: style,
                frame: reduced ? _staticFrame(frame, bandCount, w) : frame,
                palette: buildWavePalette(
                  ramp: style.ramp,
                  colored: theme.colored,
                  accent: tokens.accent,
                  lyricColor: theme.lyricColor,
                  width: w,
                ),
                peaks: _peaks,
              ),
            ),
          );
        },
      ),
    );
  }

  /// reduced-motion：静态一帧（phase 冻在当前值——画一次不推进）。
  WaveFrame _staticFrame(WaveFrame frame, int bandCount, double w) => frame;
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.style,
    required this.frame,
    required this.palette,
    required this.peaks,
  });

  final WaveStyle style;
  final WaveFrame frame;
  final WavePalette palette;
  final Float32List peaks;

  @override
  void paint(Canvas canvas, Size size) {
    style.draw(canvas, frame, palette, peaks);
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.style.id != style.id ||
      old.frame.phase != frame.phase ||
      old.frame.seed != frame.seed ||
      old.palette.colored != palette.colored;
}
