// lib/wave/wave_styles.dart
//
// 17 个波形样式的注册表（M3 T10）：对译 React `src/lib/wave-styles.ts`（1042 行）。
//
// 每个样式一个 draw 闭包，只读 [WaveFrame]（bands/wave/level/phase），不碰
// 音频链路；数据从哪来（真实频谱还是装饰信号）由 wave_signal 决定，样式层
// 不关心。配色三条 hue ramp（允许 >360 跨红端）+ 单色模式（歌词高亮色族）。
//
// Canvas 等价取舍（计划 Global Constraints 裁定）：CSS shadowBlur 用
// MaskFilter.blur 近似；feTurbulence 噪点在 T7 的膜层已有白点近似；其余
// 几何（fillRect/arc/path/smooth 遍数/alpha/freq/cols）逐参数对表。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/color_utils.dart';
import 'wave_signal.dart';

// ---------------------------------------------------------------------------
// hue ramps（wave-styles.ts:25-32 逐字；hue 允许 >360，取色时 %360）
// ---------------------------------------------------------------------------

enum WaveRamp { sunset, ember, neon }

const Map<WaveRamp, List<(double, double)>> _hueRamps = {
  // 紫 → 品红 → 玫红 → 橙 → 金（参考图主色）
  WaveRamp.sunset: [(0, 272), (0.26, 312), (0.5, 344), (0.74, 376), (1, 404)],
  // 玫红 → 橙 → 金（暖色那几张）
  WaveRamp.ember: [(0, 340), (0.34, 368), (0.66, 386), (1, 406)],
  // 青绿 → 蓝 → 紫 → 品红 → 红（现有频谱条那条，接得住 --accent）
  WaveRamp.neon: [
    (0, 148), (0.16, 178), (0.34, 212), (0.52, 262),
    (0.68, 300), (0.82, 340), (0.93, 372), (1, 456),
  ],
};

double _hueAt(WaveRamp ramp, double t) {
  final stops = _hueRamps[ramp]!;
  final x = t.clamp(0.0, 1.0);
  for (var i = 1; i < stops.length; i++) {
    if (x <= stops[i].$1 || i == stops.length - 1) {
      final o0 = stops[i - 1].$1, h0 = stops[i - 1].$2;
      final o1 = stops[i].$1, h1 = stops[i].$2;
      final span = o1 - o0;
      final k = span > 0 ? (x - o0) / span : 0.0;
      return h0 + (h1 - h0) * k.clamp(0.0, 1.0);
    }
  }
  return stops.first.$2;
}

/// 取渐变上某一点的实色（wave-styles.ts:50-53）。
Color rampColor(WaveRamp ramp, double t, {double sat = 92, double light = 58}) {
  final hue = ((_hueAt(ramp, t) % 360) + 360) % 360;
  return hslToColor(hue, sat, light);
}

/// 单色模式取色（wave-styles.ts:71-76 逐字）：
/// 映射到「深薄荷 → 高亮薄荷」这一段亮度，色相/饱和来自高亮色。
Color monoColor(double light, {required Hsl accent}) {
  final l = math.max(46.0, math.min(90.0, 52 + (light - 56) * 1.8));
  return hslToColor(accent.h, accent.s, l);
}

/// 波形高亮色（wave-styles.ts:98-102）：用户选的 hex → HSL，
/// 饱和取 (s + 78)/2；无用户色时回退 accent 的 HSL。
Hsl waveAccentOf({required Color accent, required String lyricColor}) {
  if (lyricColor.isNotEmpty) {
    final c = parseHexColor(lyricColor);
    if (c != null) {
      final hsl = colorToHsl(c);
      return Hsl(h: hsl.h, s: math.min(100, (hsl.s + 78) / 2), l: hsl.l);
    }
  }
  final hsl = colorToHsl(accent);
  return Hsl(h: hsl.h, s: math.min(100, (hsl.s + 78) / 2), l: hsl.l);
}

/// 彩色 / 单色的取色组合（wavePalette :162-175 对译）。
class WavePalette {
  const WavePalette({
    required this.ramp,
    required this.colored,
    required this.accent,
  });

  final WaveRamp ramp;
  final bool colored;

  /// 高亮色语义（含默认回退），单色模式用它。
  final Hsl accent;

  Color colorAt(double t, {double sat = 92, double light = 58}) {
    if (colored) return rampColor(ramp, t, sat: sat, light: light);
    return monoColor(light, accent: accent);
  }

  /// 横向渐变（彩色 24 段 / 单色 12 段，buildGradient :55-87）。
  ///
  /// `ui.Gradient.linear` 无 colorStops 时严格要求恰 2 个颜色——24 段的
  /// React 语义必须带 colorStops 一起传。
  Shader shaderFor(double width, {double sat = 92, double light = 58}) {
    final steps = colored ? 24 : 12;
    final colors = <Color>[
      for (var i = 0; i <= steps; i++)
        colored
            ? rampColor(ramp, i / steps, sat: sat, light: light)
            : _monoGradientStop(i / steps),
    ];
    final stops = <double>[for (var i = 0; i <= steps; i++) i / steps];
    return ui.Gradient.linear(
      Offset.zero,
      Offset(width, 0),
      colors,
      stops,
    );
  }

  Color _monoGradientStop(double t) {
    final l = (88 - 30 * t).clamp(46.0, 90.0);
    return hslToColor(accent.h, accent.s, l);
  }
}

/// stableNoise（wave-styles.ts:264-270 的稳定伪随机）。
double stableNoise(String seed, int i) {
  final h = waveHash('$seed#$i');
  return (h % 1000) / 1000;
}

/// 相邻均值平滑（React 各样式的 smooth N 遍）。
Float32List smoothSeries(Float32List src, int passes) {
  var cur = Float32List.fromList(src);
  for (var p = 0; p < passes; p++) {
    final next = Float32List(cur.length);
    for (var i = 0; i < cur.length; i++) {
      if (i == 0) {
        next[i] = (cur[0] * 2 + cur[1]) / 3;
      } else if (i == cur.length - 1) {
        next[i] = (cur[i] * 2 + cur[i - 1]) / 3;
      } else {
        next[i] = (cur[i - 1] + cur[i] * 2 + cur[i + 1]) / 4;
      }
    }
    cur = next;
  }
  return cur;
}

// ---------------------------------------------------------------------------
// 样式注册表
// ---------------------------------------------------------------------------

/// 样式条目（wave-styles.ts:287-294 同构）。
class WaveStyle {
  const WaveStyle({
    required this.id,
    required this.name,
    required this.ramp,
    this.usesPeaks = false,
    required this.draw,
  });

  final String id;
  final String name;
  final WaveRamp ramp;
  final bool usesPeaks;
  final void Function(Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) draw;
}

WaveStyle _spectrum() => WaveStyle(
  id: 'spectrum',
  name: '彩虹频谱',
  ramp: WaveRamp.neon,
  usesPeaks: true,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final count = frame.bands.length;
    if (count == 0) return;
    final baseline = h - 8;
    final maxAmp = baseline - 8;
    final step = w / count;
    final barWidth = math.max(1.0, step - 1);
    final paint = Paint()
      ..shader = palette.shaderFor(w)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    for (var i = 0; i < count; i++) {
      final amp = frame.bands[i] * maxAmp;
      canvas.drawRect(
        Rect.fromLTWH(i * step, baseline - amp, barWidth, amp),
        paint,
      );
      peaks[i] = math.max(amp, peaks[i]);
    }
    final dot = Paint()..color = const Color(0x8CFFFFFF);
    for (var i = 0; i < count; i += 3) {
      if (peaks[i] <= 0) continue;
      canvas.drawCircle(
        Offset(i * step + barWidth / 2, baseline - peaks[i] - 6),
        1,
        dot,
      );
    }
  },
);

WaveStyle _ribbon() => WaveStyle(
  id: 'ribbon',
  name: '渐变彩带',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final wave = smoothSeries(frame.wave, 10);
    final amps = [0.24, 0.21, 0.18];
    final freqs = [1.5, 2.1, 1.05];
    final alphas = [0.92, 0.78, 0.62];
    for (var s = 0; s < 3; s++) {
      final path = Path();
      for (var i = 0; i < wave.length; i++) {
        final x = w * i / (wave.length - 1);
        final y = h / 2 +
            wave[i] * h * amps[s] +
            math.sin(i / wave.length * math.pi * 2 * freqs[s] + frame.phase) * 4;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..shader = palette.shaderFor(w)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..color = palette.colorAt(s / 3).withValues(alpha: alphas[s]),
      );
    }
  },
);

WaveStyle _hairline() => WaveStyle(
  id: 'hairline',
  name: '细线爆发',
  ramp: WaveRamp.ember,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final bands = smoothSeries(frame.bands, 2);
    if (bands.isEmpty) return;
    final baseline = h;
    final paint = Paint()..shader = palette.shaderFor(w);
    for (var x = 0.0; x < w; x += 2) {
      final idx = (x / w * (bands.length - 1)).round();
      final amp = bands[idx] * h * 0.92;
      canvas.drawLine(Offset(x, baseline), Offset(x, baseline - amp), paint);
    }
  },
);

WaveStyle _sine() => WaveStyle(
  id: 'sine',
  name: '双正弦线',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final wave = smoothSeries(frame.wave, 12);
    final root = waveHash(frame.seed.isEmpty ? 'unknown' : frame.seed);
    final f1 = 1.4 + (root % 5) * 0.3;
    final f2 = 2.6 + ((root >> 2) % 4) * 0.35;
    final mid = h / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(w, mid),
      Paint()
        ..color = palette.colorAt(0.5).withValues(alpha: 0.55)
        ..strokeWidth = 1,
    );
    for (final f in [f1, f2, f1 * 0.55]) {
      final path = Path();
      for (var i = 0; i < wave.length; i++) {
        final x = w * i / (wave.length - 1);
        final y = mid +
            (wave[i] + math.sin(i / wave.length * math.pi * 2 * f + frame.phase * 0.6)) *
                h *
                0.18;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..shader = palette.shaderFor(w)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
  },
);

WaveStyle _roundBars() => WaveStyle(
  id: 'roundBars',
  name: '对称胶囊柱',
  ramp: WaveRamp.sunset,
  usesPeaks: true,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final cols = math.max(9, (w / 14).round());
    final barWidth = (w / cols * 0.62).clamp(3.0, 5.5);
    final mid = h / 2;
    for (var c = 0; c < cols; c++) {
      final idx = (c / cols * (frame.bands.length - 1)).round();
      final amp = frame.bands[idx] * h * 0.42;
      final x = w * (c + 0.5) / cols - barWidth / 2;
      final paint = Paint()
        ..color = c.isEven
            ? palette.colorAt(c / cols)
            : palette.colorAt(c / cols, sat: 84, light: 64);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - amp, barWidth, amp * 2),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
      peaks[idx] = math.max(frame.bands[idx], peaks[idx]);
      if (peaks[idx] > 0.62) {
        canvas.drawCircle(Offset(x + barWidth / 2, mid - amp - 6), 1.2, paint);
      }
    }
  },
);

WaveStyle _blob() => WaveStyle(
  id: 'blob',
  name: '平滑胖包络',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final bands = smoothSeries(frame.bands, 5);
    final mid = h / 2;
    for (final scale in [1.0, 0.42]) {
      final path = Path()..moveTo(0, mid);
      for (var i = 0; i < bands.length; i++) {
        final x = w * i / (bands.length - 1);
        path.lineTo(x, mid - bands[i] * h * 0.46 * scale);
      }
      path.lineTo(w, mid);
      canvas.drawPath(
        path,
        Paint()
          ..shader = palette.shaderFor(w)
          ..style = PaintingStyle.fill,
      );
    }
  },
);

WaveStyle _strands() => WaveStyle(
  id: 'strands',
  name: '多股细线',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final wave = smoothSeries(frame.wave, 9);
    for (var s = 0; s < 9; s++) {
      final spread = h * 0.34;
      final offset = (s - 4) * spread / 4;
      final path = Path();
      for (var i = 0; i < wave.length; i++) {
        final x = w * i / (wave.length - 1);
        final y = h / 2 + wave[i] * spread + offset;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..shader = palette.shaderFor(w)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
    }
  },
);

WaveStyle _noise() => WaveStyle(
  id: 'noise',
  name: '尖刺噪声',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final mid = h / 2;
    final paint = Paint()..shader = palette.shaderFor(w);
    if (frame.wave.isEmpty) return;
    for (var x = 0.0; x < w; x += 1) {
      final idx = (x / w * (frame.wave.length - 1)).round();
      final amp = frame.wave[idx].abs() * h * 0.46;
      canvas.drawLine(Offset(x, mid - amp), Offset(x, mid + amp), paint);
    }
    canvas.drawLine(
      Offset(0, mid),
      Offset(w, mid),
      Paint()
        ..color = const Color(0xE6FFFFFF)
        ..strokeWidth = 1.4,
    );
  },
);

WaveStyle _histogram() => WaveStyle(
  id: 'histogram',
  name: '底部柱状',
  ramp: WaveRamp.sunset,
  usesPeaks: true,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final cols = math.max(14, (w / 6).round());
    final baseline = h - 4;
    for (var c = 0; c < cols; c++) {
      final idx = (c / cols * (frame.bands.length - 1)).round();
      final amp = frame.bands[idx] * (h - 10);
      final x = w * c / cols + 1;
      final bw = w / cols - 2;
      final r = Radius.circular(bw / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, baseline - amp, bw, amp),
          r,
        ),
        Paint()..shader = palette.shaderFor(w),
      );
      peaks[idx] = math.max(frame.bands[idx], peaks[idx]);
      canvas.drawCircle(
        Offset(x + bw / 2, baseline - frame.bands[idx] * (h - 10) - 3),
        1,
        Paint()..color = const Color(0x8CFFFFFF),
      );
    }
  },
);

WaveStyle _mirrorArea() => WaveStyle(
  id: 'mirrorArea',
  name: '镜像平滑山',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final wave = smoothSeries(frame.wave, 26);
    final mid = h / 2;
    final path = Path()..moveTo(0, mid);
    for (var i = 0; i < wave.length; i++) {
      final x = w * i / (wave.length - 1);
      path.lineTo(x, mid - wave[i] * h * 0.22 * 2.2);
    }
    path.lineTo(w, mid);
    canvas.drawPath(
      path,
      Paint()..shader = palette.shaderFor(w),
    );
    final mirror = Path()..moveTo(0, mid);
    for (var i = 0; i < wave.length; i++) {
      final x = w * i / (wave.length - 1);
      mirror.lineTo(x, mid + wave[i] * h * 0.22 * 2.2);
    }
    mirror.lineTo(w, mid);
    canvas.drawPath(
      mirror,
      Paint()
        ..shader = palette.shaderFor(w)
        ..color = (palette.colorAt(0.5)).withValues(alpha: 0.35),
    );
  },
);

WaveStyle _jagged() => WaveStyle(
  id: 'jagged',
  name: '锯齿折线',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final mid = h / 2;
    Path pathOf(double alphaMul) {
      final p = Path();
      for (var i = 0; i < frame.wave.length; i++) {
        final x = w * i / (frame.wave.length - 1);
        final y = mid + frame.wave[i] * h * 0.4 * alphaMul;
        if (i == 0) {
          p.moveTo(x, y);
        } else {
          p.lineTo(x, y);
        }
      }
      return p;
    }

    canvas.drawPath(
      pathOf(0.7),
      Paint()
        ..color = palette.colorAt(0.5).withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.drawPath(
      pathOf(1.0),
      Paint()
        ..shader = palette.shaderFor(w)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  },
);

WaveStyle _hatch() => WaveStyle(
  id: 'hatch',
  name: '白描边竖纹',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final baseline = h - 2;
    final paint = Paint()..shader = palette.shaderFor(w);
    final edge = Paint()
      ..color = const Color(0xE6FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (var x = 0.0; x < w; x += 4) {
      final idx = (x / w * (frame.bands.length - 1)).round();
      final amp = frame.bands[idx] * (h - 8);
      final rect = Rect.fromLTWH(x, baseline - amp, 2, amp);
      canvas.drawRect(rect, paint);
      canvas.drawRect(rect, edge);
    }
  },
);

WaveStyle _spikes() => WaveStyle(
  id: 'spikes',
  name: '尖峰镜像',
  ramp: WaveRamp.ember,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final cols = math.max(10, (w / 13).round());
    final mid = h / 2;
    for (var c = 0; c < cols; c++) {
      final idx = (c / cols * (frame.bands.length - 1)).round();
      final amp = frame.bands[idx] * h * 0.44;
      final x = w * (c + 0.5) / cols;
      final path = Path()
        ..moveTo(x - w / cols / 2 + 1, mid)
        ..lineTo(x, mid - amp)
        ..lineTo(x + w / cols / 2 - 1, mid)
        ..lineTo(x, mid + amp)
        ..close();
      canvas.drawPath(path, Paint()..shader = palette.shaderFor(w));
    }
    canvas.drawLine(
      Offset(0, mid),
      Offset(w, mid),
      Paint()
        ..color = const Color(0xF2FFF6E8)
        ..strokeWidth = 1.6,
    );
  },
);

WaveStyle _led() => WaveStyle(
  id: 'led',
  name: '点阵 LED',
  ramp: WaveRamp.sunset,
  usesPeaks: true,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    const pitch = 4.0, cell = 3.0;
    final cols = math.max(12, (w / 4).round());
    final rows = (h / pitch).floor();
    for (var c = 0; c < cols; c++) {
      final idx = (c / cols * (frame.bands.length - 1)).round();
      final amp = frame.bands[idx];
      final litRows = (amp * rows).round();
      peaks[idx] = math.max(amp, peaks[idx]);
      final peakRows = (peaks[idx] * rows).round();
      for (var r = 0; r < rows; r++) {
        final rowFromBottom = rows - 1 - r;
        final isLit = rowFromBottom < litRows;
        final isPeak = rowFromBottom == peakRows - 1;
        final color = isLit
            ? palette.colorAt(c / cols, light: 62)
            : isPeak
                ? palette.colorAt(c / cols, light: 74)
                : palette.colorAt(c / cols, light: 62).withValues(alpha: 0.12);
        canvas.drawRect(
          Rect.fromLTWH(c * pitch + 0.5, r * pitch + 0.5, cell, cell),
          Paint()..color = color,
        );
      }
    }
  },
);

WaveStyle _flow() => WaveStyle(
  id: 'flow',
  name: '平行波纹线',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final wave = smoothSeries(frame.wave, 12);
    for (var s = 0; s < 7; s++) {
      final path = Path();
      final yBase = h * (s + 1) / 8;
      for (var i = 0; i < wave.length; i++) {
        final x = w * i / (wave.length - 1);
        final y = yBase + wave[i] * h * 0.12;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..shader = palette.shaderFor(w)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  },
);

WaveStyle _dots() => WaveStyle(
  id: 'dots',
  name: '点阵包络',
  ramp: WaveRamp.sunset,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    const pitch = 5.0;
    final cols = (w / pitch).floor();
    for (var c = 0; c < cols; c++) {
      final idx = (c / cols * (frame.bands.length - 1)).round();
      final v = frame.bands[idx];
      final count = 1 + (v * 3).round();
      for (var d = 0; d < count; d++) {
        final n = stableNoise(frame.seed, c * 4 + d);
        canvas.drawCircle(
          Offset(
            c * pitch + pitch / 2,
            h * 0.15 + n * h * 0.7 * (v + 0.2),
          ),
          1.3,
          Paint()..shader = palette.shaderFor(w),
        );
      }
    }
  },
);

WaveStyle _hills() => WaveStyle(
  id: 'hills',
  name: '层叠山峰',
  ramp: WaveRamp.ember,
  draw: (canvas, frame, palette, peaks) {
    final w = frame.width, h = frame.height;
    final layers = [
      (passes: 3, scale: 1.0, shift: 0.0, alpha: 0.45),
      (passes: 3, scale: 0.78, shift: 0.12, alpha: 0.58),
      (passes: 2, scale: 0.58, shift: -0.1, alpha: 0.72),
      (passes: 2, scale: 0.4, shift: 0.22, alpha: 0.88),
    ];
    for (final layer in layers) {
      final bands = smoothSeries(frame.bands, layer.passes);
      final path = Path()..moveTo(0, h);
      for (var i = 0; i < bands.length; i++) {
        final x = w * i / (bands.length - 1);
        path.lineTo(
          x,
          h - bands[i] * h * 0.7 * layer.scale -
              layer.shift * h,
        );
      }
      path.lineTo(w, h);
      canvas.drawPath(
        path,
        Paint()
          ..shader = palette.shaderFor(w)
          ..color = palette.colorAt(layer.scale * 0.6).withValues(alpha: layer.alpha),
      );
    }
  },
);

/// 17 个样式（wave-styles.ts:1018-1036 顺序即下拉顺序），一个都不减。
final List<WaveStyle> kWaveStyles = <WaveStyle>[
  _spectrum(),
  _ribbon(),
  _hairline(),
  _sine(),
  _roundBars(),
  _blob(),
  _strands(),
  _noise(),
  _histogram(),
  _mirrorArea(),
  _jagged(),
  _hatch(),
  _spikes(),
  _led(),
  _flow(),
  _dots(),
  _hills(),
];

const String kDefaultWaveStyleId = 'spectrum';

/// 按 id 找样式；不存在（样式增删过的旧存档）兜回默认那条。
WaveStyle findWaveStyle(String? id) =>
    kWaveStyles.firstWhere((s) => s.id == id, orElse: () => kWaveStyles.first);
