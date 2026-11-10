// lib/wave/wave_styles.dart
//
// 17 个波形样式 painter + 三条 hue ramp + 彩色/单色调色系统（M3 T10）。
// 逐段对译 React `src/lib/wave-styles.ts`（1042 行）——每条样式的平滑遍数、
// alpha、cols 公式、峰值行为都按 TS 源码逐参数对表；Canvas API 的等价取舍
// 见文件尾的「偏差说明」。
//
// 数据只来自 [WaveFrame]（bands/wave/level/phase），峰值数组 [peaks] 由宿主
// 维护（每帧先按 pow(0.03, dt) 衰减再传入），usesPeaks 样式读/写它。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Color, HSLColor;

import '../theme/color_utils.dart';
import 'wave_signal.dart';

const double _tau = math.pi * 2;

// ---------------------------------------------------------------------------
// hue ramp（wave-styles.ts:25-47 逐字）
// ---------------------------------------------------------------------------

enum WaveRamp { sunset, ember, neon }

/// 色标里的 hue 允许超过 360，344°→16° 这种「跨过红端」的过渡不会倒着走。
const Map<WaveRamp, List<List<double>>> _hueRamps = {
  // 紫 → 品红 → 玫红 → 橙 → 金（参考图主色）
  WaveRamp.sunset: [
    [0, 272], [0.26, 312], [0.5, 344], [0.74, 376], [1, 404],
  ],
  // 玫红 → 橙 → 金（暖色那几张）
  WaveRamp.ember: [
    [0, 340], [0.34, 368], [0.66, 386], [1, 406],
  ],
  // 青绿 → 蓝 → 紫 → 品红 → 红（现有频谱条那条，接得住 --accent）
  WaveRamp.neon: [
    [0, 148], [0.16, 178], [0.34, 212], [0.52, 262],
    [0.68, 300], [0.82, 340], [0.93, 372], [1, 456],
  ],
};

double _hueAt(WaveRamp ramp, double t) {
  final stops = _hueRamps[ramp]!;
  final x = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
  for (var i = 1; i < stops.length; i++) {
    if (x <= stops[i][0] || i == stops.length - 1) {
      final o0 = stops[i - 1][0];
      final h0 = stops[i - 1][1];
      final o1 = stops[i][0];
      final h1 = stops[i][1];
      final span = o1 - o0;
      final k = span > 0 ? (x - o0) / span : 0.0;
      final kk = k < 0 ? 0.0 : (k > 1 ? 1.0 : k);
      return h0 + (h1 - h0) * kk;
    }
  }
  return stops[0][1];
}

/// 取渐变上某一点的实色，供逐柱 / 逐线着色（rampColor，:50-53 逐字）。
Color rampColor(WaveRamp ramp, double t, {double sat = 92, double light = 58}) {
  final hue = ((_hueAt(ramp, t) % 360) + 360) % 360;
  return HSLColor.fromAHSL(1.0, hue, sat / 100, light / 100).toColor();
}

// ---------------------------------------------------------------------------
// 单色取色（monoColor，:71-76 + setWaveAccent，:98-102 逐字公式）
// ---------------------------------------------------------------------------

/// 单色模式的取色：换成高亮色那一族，只保留亮度层次。
/// 样式传进来的 [light] 一般在 56~76：映射到「深薄荷 → 高亮薄荷」这一段。
/// 公式逐字：`l = clamp(52 + (light - 56) * 1.8, 46, 90)`。
Color monoColor(double light, {required Hsl accent}) {
  final l = (52 + (light - 56) * 1.8).clamp(46.0, 90.0);
  return HSLColor.fromAHSL(1.0, accent.h, accent.s / 100, l / 100).toColor();
}

// ---------------------------------------------------------------------------
// 调色板（wavePalette，:162-175 同构）
// ---------------------------------------------------------------------------

/// 一套配色：横向渐变 + 逐点取色。
/// 彩色走样式自带的色带；单色只是把同一套亮度拿来用，
/// 所以 17 种样式都能一键换成高亮色族。
class WavePalette {
  const WavePalette({required this.grad, required this.colorAt, required this.colored});

  /// 横向渐变（宿主按当前宽度和样式色带建好）；单色模式下也有。
  final ui.Gradient? grad;

  /// 逐点取色：彩色 = rampColor(ramp, t)；单色 = monoColor(light)。
  final Color Function(double t, {double sat, double light}) colorAt;

  final bool colored;
}

/// 彩色模式：24 段的横向渐变（buildGradient :55-68）。
ui.Gradient _buildGradient(WaveRamp ramp, double width, {double sat = 92, double light = 58}) {
  final colors = <Color>[];
  final stops = <double>[];
  for (var i = 0; i <= 24; i++) {
    final t = i / 24;
    colors.add(rampColor(ramp, t, sat: sat, light: light));
    stops.add(t);
  }
  return ui.Gradient.linear(ui.Offset.zero, ui.Offset(width, 0), colors, stops);
}

/// 单色模式：12 段 `88 - 30*t` 的横向渐变，左浅右深（buildMonoGradient :79-87）。
ui.Gradient _buildMonoGradient(Hsl accent, double width) {
  final colors = <Color>[];
  final stops = <double>[];
  for (var i = 0; i <= 12; i++) {
    final t = i / 12;
    final l = (88 - 30 * t).clamp(0.0, 100.0);
    colors.add(HSLColor.fromAHSL(1.0, accent.h, accent.s / 100, l / 100).toColor());
    stops.add(t);
  }
  return ui.Gradient.linear(ui.Offset.zero, ui.Offset(width, 0), colors, stops);
}

/// 建一套当前样式可用的调色板。
///
/// 单色模式的 h/s 来自高亮色语义（wave-styles.ts:98-102 的 setWaveAccent）：
/// [lyricColor] 有值 → hexToHsl 后 `s = min(100, (s + 78) / 2)`；
/// 无值 → 用 [accent] 的 HSL；都取不到回退 `{h:160, s:85}`。
WavePalette buildWavePalette({
  required WaveRamp ramp,
  required bool colored,
  required Color accent,
  required String lyricColor,
  required double width,
}) {
  if (colored) {
    return WavePalette(
      grad: _buildGradient(ramp, width),
      colorAt: (t, {sat = 92, light = 58}) => rampColor(ramp, t, sat: sat, light: light),
      colored: true,
    );
  }
  final Hsl hsl;
  final fromLyric = lyricColor.isNotEmpty ? parseHexColor(lyricColor) : null;
  if (fromLyric != null) {
    final raw = colorToHsl(fromLyric);
    hsl = Hsl(h: raw.h, s: math.min(100, (raw.s + 78) / 2), l: raw.l);
  } else if (lyricColor.isEmpty) {
    // 回退主题 accentLight 的一族；#b9ffe9 这类高亮色偏淡，
    // 饱和度取它和 accent 之间的中间值，免得整条发白。
    final raw = colorToHsl(accent);
    hsl = raw.s > 0 || raw.l > 0 && raw.l < 100
        ? Hsl(h: raw.h, s: math.min(100, (raw.s + 78) / 2), l: raw.l)
        : const Hsl(h: 160, s: 85, l: 75);
  } else {
    // lyricColor 有值但解析失败：走默认回退。
    hsl = const Hsl(h: 160, s: 85, l: 75);
  }
  return WavePalette(
    grad: _buildMonoGradient(hsl, width),
    colorAt: (t, {sat = 92, light = 58}) => monoColor(light, accent: hsl),
    colored: false,
  );
}

// ---------------------------------------------------------------------------
// 画布小工具（wave-styles.ts:181-304 逐字）
// ---------------------------------------------------------------------------

double _sampleAt(Float32List arr, double t) {
  final n = arr.length;
  if (n == 0) return 0;
  if (n == 1) return arr[0];
  final x = (t < 0 ? 0.0 : (t > 1 ? 1.0 : t)) * (n - 1);
  final i = x.floor();
  final a = arr[i];
  final b = arr[math.min(n - 1, i + 1)];
  return a + (b - a) * (x - i);
}

/// 三点加权滑动平均，[passes] 越大越圆润（彩带、山形要多遍，尖刺类一遍都不做）。
Float32List smoothSeries(Float32List src, int passes) {
  var out = src;
  for (var p = 0; p < passes; p++) {
    final next = Float32List(out.length);
    for (var i = 0; i < out.length; i++) {
      final a = out[math.max(0, i - 1)];
      final b = out[i];
      final c = out[math.min(out.length - 1, i + 1)];
      next[i] = (a + b * 2 + c) / 4;
    }
    out = next;
  }
  return out;
}

/// 稳定伪随机：同一个 (列, 序号) 永远抖到同一个位置（stableNoise :264-270 逐字）。
/// 算术用 32 位环回模拟 JS 的位运算语义。
double stableNoise(int col, int index) {
  var h = (col * 0x9e3779b1) ^ (index * 0x85ebca6b);
  h = _toI32(h);
  h ^= _logicalShiftRight(h, 13);
  h = _toI32(_imul(h, 0xc2b2ae35));
  h ^= _logicalShiftRight(h, 16);
  return _u32(h) / 0xffffffff;
}

int _toI32(int v) => v.toSigned(32);

int _u32(int v) => v & 0xFFFFFFFF;

int _logicalShiftRight(int v, int s) => _u32(v) >> s;

/// JS Math.imul 的 32 位环回乘法。
int _imul(int a, int b) {
  final ah = _u32(a) & 0xFFFF;
  final al = _u32(a) >> 16;
  final bh = _u32(b) & 0xFFFF;
  final bl = _u32(b) >> 16;
  final high = (ah * bl + al * bh) & 0xFFFFFFFF;
  final low = (_u32(a) * _u32(b)) & 0xFFFFFFFF;
  return _toI32(((high << 16) + low) & 0xFFFFFFFF);
}

/// 两端收拢、中间张开，参考图里的波形几乎都有这个「纺锤」轮廓（:258-261）。
double _spindle(double t, [double power = 1]) {
  final s = math.sin(math.pi * t);
  return power == 1 ? s : math.pow(s, power).toDouble();
}

/// 沿 x 前进的一列中心点 + 一半厚度 → 一条带子的闭合多边形（:235-255）。
ui.Path _ribbonPolygon(Float32List center, Float32List thick, double step) {
  final path = ui.Path();
  for (var i = 0; i < center.length; i++) {
    final x = i * step;
    final y = center[i] - thick[i];
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  for (var i = center.length - 1; i >= 0; i--) {
    path.lineTo(i * step, center[i] + thick[i]);
  }
  path.close();
  return path;
}

/// 把 bands 抽稀成指定列数的采样点，同时保证 peaks 下标仍落在原数组上（:297-304）。
List<int> _strideIndexes(int count, int cols) {
  final stride = math.max(1, (count / cols).round());
  final out = <int>[];
  for (var i = 0; i < count; i += stride) {
    out.add(i);
  }
  return out;
}

ui.Paint _paint(ui.Gradient? grad, Color color) => ui.Paint()
  ..color = color
  ..shader = grad;

// ---------------------------------------------------------------------------
// 样式注册表（StyleEnv 等价：签名 (canvas, frame, palette, peaks)）
// ---------------------------------------------------------------------------

/// 一个样式：宿主维护 peaks（每帧先按 pow(0.03, dt) 衰减），
/// usesPeaks 的样式在 draw 里读/写。
class WaveStyle {
  const WaveStyle({
    required this.id,
    required this.name,
    required this.ramp,
    required this.usesPeaks,
    required this.draw,
  });

  final String id;
  final String name;
  final WaveRamp ramp;
  final bool usesPeaks;
  final void Function(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) draw;
}

/// 0 · 项目原有的彩虹频谱柱 + 悬空峰值点（:311-347）。
const WaveStyle spectrumStyle = WaveStyle(
  id: 'spectrum',
  name: '彩虹频谱',
  ramp: WaveRamp.neon,
  usesPeaks: true,
  draw: _drawSpectrum,
);

void _drawSpectrum(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final bands = frame.bands;
  final count = bands.length;
  if (count == 0) return;
  final baseline = h - 8;
  final maxAmp = baseline - 8;
  final step = w / count;
  final barWidth = math.max(1.0, step - 1);

  final fill = _paint(palette.grad, palette.colorAt(0));
  // shadowBlur 6（rgba(255,255,255,0.3)）→ MaskFilter.blur sigma=3。
  fill.maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
  for (var i = 0; i < count; i++) {
    final amp = bands[i] * maxAmp;
    canvas.drawRect(
      ui.Rect.fromLTWH(i * step, baseline - amp, barWidth, amp),
      fill,
    );
    if (amp > peaks[i]) peaks[i] = amp;
  }
  final dot = ui.Paint()..color = const Color(0x8CFFFFFF); // rgba(255,255,255,0.55)
  for (var i = 0; i < count; i += 3) {
    if (peaks[i] <= 0) continue;
    canvas.drawCircle(
      ui.Offset(i * step + barWidth / 2, baseline - peaks[i] - 6),
      1,
      dot,
    );
  }
}

/// 1 · 彩带：几条互相交叠的平滑缎带（:350-393）。
const WaveStyle ribbonStyle = WaveStyle(
  id: 'ribbon',
  name: '渐变彩带',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawRibbon,
);

void _drawRibbon(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid;
  final line = smoothSeries(frame.wave, 10);
  final points = math.max(24, math.min(72, (w / 4).round()));
  final step = w / points;
  final strands = [
    (amp: 0.24, freq: 1.5, off: -0.14, thick: 0.16, alpha: 0.92),
    (amp: 0.21, freq: 2.1, off: 0.0, thick: 0.12, alpha: 0.78),
    (amp: 0.18, freq: 1.05, off: 0.14, thick: 0.09, alpha: 0.62),
  ];
  // 三条缎带对称排在中线两侧，整体才不会整块偏到上半栏。
  final limit = amp - 2;
  final phase = frame.phase;
  final level = frame.level;
  final bands = frame.bands;

  for (var k = 0; k < strands.length; k++) {
    final s = strands[k];
    final center = Float32List(points + 1);
    final thick = Float32List(points + 1);
    for (var i = 0; i <= points; i++) {
      final t = i / points;
      final env = 0.28 + 0.72 * _spindle(t);
      final shape = math.sin(t * _tau * s.freq + phase * 1.5 + k * 1.15) * 0.62 +
          math.sin(t * _tau * s.freq * 2.1 - phase * 1.1 + k * 0.7) * 0.38;
      final v = shape * (0.4 + 0.6 * level) + _sampleAt(line, t) * 0.5;
      final th = (1.4 + s.thick * h * 0.5) * (0.3 + 0.7 * _sampleAt(bands, t));
      final y = mid + v * s.amp * h * env + s.off * h;
      center[i] = math.max(mid - limit, math.min(mid + limit, y));
      thick[i] = math.min(th, limit - (center[i] - mid).abs());
    }
    final paint = _paint(palette.grad, palette.colorAt(0))
      ..color = palette.colorAt(0).withValues(alpha: s.alpha);
    canvas.drawPath(_ribbonPolygon(center, thick, step), paint);
  }
}

/// 2 · 密集细线：一根根发丝竖线，跟着响度包络鼓包（:396-420）。
const WaveStyle hairlineStyle = WaveStyle(
  id: 'hairline',
  name: '细线爆发',
  ramp: WaveRamp.ember,
  usesPeaks: false,
  draw: _drawHairline,
);

void _drawHairline(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 3;
  final env = smoothSeries(frame.bands, 2);

  final paint = _paint(palette.grad, palette.colorAt(0))
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1
    ..color = palette.colorAt(0).withValues(alpha: 0.92);
  final path = ui.Path();
  for (var x = 0.0; x < w; x += 2) {
    final t = x / w;
    final a = math.max(0.6, _sampleAt(env, t) * amp);
    path.moveTo(x + 0.5, mid - a);
    path.lineTo(x + 0.5, mid + a);
  }
  canvas.drawPath(path, paint);
}

/// 3 · 双正弦：一条基准线 + 两三条不同频率的平滑正弦（:423-475）。
const WaveStyle sineStyle = WaveStyle(
  id: 'sine',
  name: '双正弦线',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawSine,
);

void _drawSine(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 3;
  final line = smoothSeries(frame.wave, 12);
  final seed = frame.seed;
  final root = seed.isNotEmpty ? seed.codeUnitAt(0) + seed.length : 7;
  final f1 = 1.4 + (root % 5) * 0.3;
  final f2 = 2.6 + ((root >> 2) % 4) * 0.35;
  final phase = frame.phase;
  final level = frame.level;

  // 基准线（alpha 0.55、lineWidth 1.2）。
  final base = _paint(palette.grad, palette.colorAt(0))
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..color = palette.colorAt(0).withValues(alpha: 0.55);
  canvas.drawLine(ui.Offset(0, mid + 0.5), ui.Offset(w, mid + 0.5), base);

  final curves = [
    (f: f1, speed: 1.6, weight: 0.78, width: 2.4, alpha: 0.95, useGrad: true, t: 0.0),
    (f: f2, speed: -1.1, weight: 0.5, width: 1.6, alpha: 0.8, useGrad: false, t: 0.18),
    (f: f1 * 0.55, speed: 0.7, weight: 0.34, width: 1.2, alpha: 0.45, useGrad: false, t: 0.72),
  ];
  final points = math.max(28, (w / 4).round());
  for (final c in curves) {
    final paint = _paint(c.useGrad ? palette.grad : null, palette.colorAt(c.t))
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = c.width
      ..color = palette.colorAt(c.t).withValues(alpha: c.alpha);
    final path = ui.Path();
    for (var i = 0; i <= points; i++) {
      final t = i / points;
      final x = t * w;
      final shape = math.sin(t * _tau * c.f + phase * c.speed) * 0.8 +
          _sampleAt(line, t) * 0.6;
      final y = mid + shape * amp * (0.5 + 0.5 * level) * _spindle(t, 0.6);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }
}

/// 4 · 圆头对称柱：上下对称的胶囊柱，峰值处再甩一颗孤点（:478-513）。
const WaveStyle roundBarsStyle = WaveStyle(
  id: 'roundBars',
  name: '对称胶囊柱',
  ramp: WaveRamp.sunset,
  usesPeaks: true,
  draw: _drawRoundBars,
);

void _drawRoundBars(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final bands = frame.bands;
  final mid = h / 2;
  final amp = mid - 4;
  final cols = math.max(9, (w / 14).round());
  final idx = _strideIndexes(bands.length, cols);
  if (idx.isEmpty) return;
  final step = w / idx.length;
  final barWidth = math.max(3.0, math.min(5.5, step * 0.42));

  final gradPaint = _paint(palette.grad, palette.colorAt(0))
    ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2.5);
  for (var k = 0; k < idx.length; k++) {
    final bandIndex = idx[k];
    final t = bandIndex / math.max(1, bands.length - 1);
    final v = bands[bandIndex];
    final a = math.max(barWidth / 2, v * amp);
    final x = k * step + (step - barWidth) / 2;
    if (k % 2 == 0) {
      // grad 与单色渐变都是 shader；奇列走逐点取色。
      canvas.drawPath(
        _roundBarPath(x, mid - a, barWidth, a * 2, barWidth / 2),
        gradPaint,
      );
    } else {
      canvas.drawPath(
        _roundBarPath(x, mid - a, barWidth, a * 2, barWidth / 2),
        _paint(null, palette.colorAt(t, sat: 90, light: 64)),
      );
    }
    if (a > peaks[bandIndex]) peaks[bandIndex] = a;
    if (peaks[bandIndex] > amp * 0.62) {
      canvas.drawCircle(
        ui.Offset(x + barWidth / 2, mid - peaks[bandIndex] - 4),
        1.4,
        _paint(null, palette.colorAt(t, sat: 92, light: 70)),
      );
    }
  }
}

ui.Path _roundBarPath(double x, double y, double w, double h, double r) {
  final radius = math.max(0.0, math.min(r, math.min(w / 2, h / 2)));
  final path = ui.Path()
    ..moveTo(x + radius, y)
    ..lineTo(x + w - radius, y)
    ..arcToPoint(ui.Offset(x + w, y + radius), radius: ui.Radius.circular(radius))
    ..lineTo(x + w, y + h - radius)
    ..arcToPoint(ui.Offset(x + w - radius, y + h), radius: ui.Radius.circular(radius))
    ..lineTo(x + radius, y + h)
    ..arcToPoint(ui.Offset(x, y + h - radius), radius: ui.Radius.circular(radius))
    ..lineTo(x, y + radius)
    ..arcToPoint(ui.Offset(x + radius, y), radius: ui.Radius.circular(radius))
    ..close();
  return path;
}

/// 5 · 胖包络：整条糊成一坨平滑的、上下镜像的能量块（:516-565）。
const WaveStyle blobStyle = WaveStyle(
  id: 'blob',
  name: '平滑胖包络',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawBlob,
);

void _drawBlob(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 3;
  final env = smoothSeries(frame.bands, 5);
  final points = math.max(24, (w / 4).round());
  final step = w / points;

  (Float32List, Float32List) edge(double scale, double offset) {
    final top = Float32List(points + 1);
    final bottom = Float32List(points + 1);
    for (var i = 0; i <= points; i++) {
      final a = _sampleAt(env, i / points) * amp * scale + offset;
      top[i] = mid - a;
      bottom[i] = mid + a;
    }
    return (top, bottom);
  }

  void paintBlob(Float32List top, Float32List bottom, double alpha) {
    final path = ui.Path()..moveTo(0, top[0]);
    for (var i = 1; i <= points; i++) {
      path.lineTo(i * step, top[i]);
    }
    for (var i = points; i >= 0; i--) {
      path.lineTo(i * step, bottom[i]);
    }
    path.close();
    final paint = _paint(palette.grad, palette.colorAt(0))
      ..color = palette.colorAt(0).withValues(alpha: alpha);
    canvas.drawPath(path, paint);
  }

  final (t1, b1) = edge(1, 1);
  paintBlob(t1, b1, 0.8);
  final (t2, b2) = edge(0.42, 0.5);
  paintBlob(t2, b2, 0.9);
}

/// 6 · 多股细线：一束平行曲线，两端收拢、中间张开（:568-607）。
const WaveStyle strandsStyle = WaveStyle(
  id: 'strands',
  name: '多股细线',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawStrands,
);

void _drawStrands(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final line = smoothSeries(frame.wave, 9);
  const count = 9;
  final points = math.max(28, (w / 4).round());
  final spread = h * 0.34;
  final phase = frame.phase;
  final level = frame.level;

  for (var k = 0; k < count; k++) {
    final rel = (k - (count - 1) / 2) / ((count - 1) / 2);
    final paint = _paint(null, palette.colorAt(k / (count - 1), light: 56 + (k % 3) * 5))
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = palette
          .colorAt(k / (count - 1), light: 56 + (k % 3) * 5)
          .withValues(alpha: 0.62 + 0.3 * (1 - rel.abs()));
    final path = ui.Path();
    for (var i = 0; i <= points; i++) {
      final t = i / points;
      final x = t * w;
      final shape = _sampleAt(line, t) * 0.75 +
          math.sin(t * _tau * 2.2 + phase * 1.8 + k * 0.4) * 0.25;
      final y = mid +
          shape * h * 0.3 * (0.4 + 0.6 * level) +
          rel * spread * _spindle(t, 0.8);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }
}

/// 7 · 尖刺噪声：一像素一根的密集毛刺，中间压一条白芯（:610-645）。
const WaveStyle noiseStyle = WaveStyle(
  id: 'noise',
  name: '尖刺噪声',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawNoise,
);

void _drawNoise(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 2;
  final env = smoothSeries(frame.bands, 3);
  final wave = frame.wave;

  final paint = _paint(palette.grad, palette.colorAt(0))
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1
    ..color = palette.colorAt(0).withValues(alpha: 0.9);
  final path = ui.Path();
  for (var x = 0.0; x < w; x += 1) {
    final t = x / w;
    final spike = _sampleAt(wave, t).abs();
    final a = math.max(0.5, spike * amp * (0.45 + 0.9 * _sampleAt(env, t)));
    path.moveTo(x + 0.5, mid - a);
    path.lineTo(x + 0.5, mid + a);
  }
  canvas.drawPath(path, paint);

  final core = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.4
    ..color = const Color(0xE6FFFFFF).withValues(alpha: 0.9); // rgba(255,255,255,0.9)
  canvas.drawLine(ui.Offset(0, mid), ui.Offset(w, mid), core);
}

/// 8 · 底部柱状：从底边起立的圆头柱，柱顶悬一颗峰值点（:648-684）。
const WaveStyle histogramStyle = WaveStyle(
  id: 'histogram',
  name: '底部柱状',
  ramp: WaveRamp.sunset,
  usesPeaks: true,
  draw: _drawHistogram,
);

void _drawHistogram(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final bands = frame.bands;
  final baseline = h - 2;
  final maxAmp = h - 8;
  final cols = math.max(14, (w / 6).round());
  final idx = _strideIndexes(bands.length, cols);
  if (idx.isEmpty) return;
  final step = w / idx.length;
  final barWidth = math.max(2.0, step - 2.4);

  final fill = _paint(palette.grad, palette.colorAt(0));
  for (var k = 0; k < idx.length; k++) {
    final bandIndex = idx[k];
    final amp = math.max(1.5, bands[bandIndex] * maxAmp);
    final x = k * step + (step - barWidth) / 2;
    canvas.drawPath(
      _roundBarPath(x, baseline - amp, barWidth, amp, barWidth / 2),
      fill,
    );
    if (amp > peaks[bandIndex]) peaks[bandIndex] = amp;
  }
  final dot = ui.Paint()..color = const Color(0x80FFFFFF); // rgba(255,255,255,0.5)
  for (var k = 0; k < idx.length; k++) {
    final bandIndex = idx[k];
    if (peaks[bandIndex] <= 0) continue;
    canvas.drawCircle(
      ui.Offset(k * step + step / 2, baseline - peaks[bandIndex] - 4),
      1,
      dot,
    );
  }
}

/// 9 · 镜像平滑山：以中线为轴，平滑曲线一会儿鼓上一会儿鼓下（:687-716）。
const WaveStyle mirrorAreaStyle = WaveStyle(
  id: 'mirrorArea',
  name: '镜像平滑山',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawMirrorArea,
);

void _drawMirrorArea(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 3;
  final line = smoothSeries(frame.wave, 26);
  final points = math.max(24, (w / 4).round());
  final step = w / points;
  final level = frame.level;

  final paint = _paint(palette.grad, palette.colorAt(0))
    ..color = palette.colorAt(0).withValues(alpha: 0.92);
  final path = ui.Path()..moveTo(0, mid);
  for (var i = 0; i <= points; i++) {
    final t = i / points;
    final v = _sampleAt(line, t) * (0.45 + 0.55 * level) * 2.2;
    path.lineTo(i * step, mid - v * amp);
  }
  path.lineTo(w, mid);
  path.close();
  canvas.drawPath(path, paint);
}

/// 10 · 锯齿折线：时域信号直接连线，背后留一道重影（:719-758）。
const WaveStyle jaggedStyle = WaveStyle(
  id: 'jagged',
  name: '锯齿折线',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawJagged,
);

void _drawJagged(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 3;
  final env = smoothSeries(frame.bands, 3);
  final wave = frame.wave;
  final level = frame.level;

  ui.Path trace(double scale, double offset) {
    final path = ui.Path();
    for (var x = 0.0; x <= w; x += 2) {
      final t = x / w;
      final v = _sampleAt(wave, t) *
          scale *
          (0.4 + 0.6 * level) *
          2 *
          (0.35 + 0.8 * _sampleAt(env, t));
      final y = mid + offset - v * amp;
      if (x == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path;
  }

  // 重影（alpha 0.28、lineWidth 1）。
  final ghost = _paint(palette.grad, palette.colorAt(0))
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1
    ..strokeJoin = ui.StrokeJoin.round
    ..color = palette.colorAt(0).withValues(alpha: 0.28);
  canvas.drawPath(trace(0.7, 3), ghost);

  // 主线（alpha 0.95、lineWidth 1.6）。
  final main = _paint(palette.grad, palette.colorAt(0))
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..strokeJoin = ui.StrokeJoin.round
    ..color = palette.colorAt(0).withValues(alpha: 0.95);
  canvas.drawPath(trace(1, 0), main);
}

/// 11 · 白描边竖纹：外面一圈白描边，里面 clip 出竖向条纹（:761-813）。
const WaveStyle hatchStyle = WaveStyle(
  id: 'hatch',
  name: '白描边竖纹',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawHatch,
);

void _drawHatch(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 3;
  final line = smoothSeries(frame.wave, 14);
  final env = smoothSeries(frame.bands, 3);
  final points = math.max(24, (w / 4).round());
  final step = w / points;

  ui.Path build() {
    final path = ui.Path();
    for (var i = 0; i <= points; i++) {
      final t = i / points;
      final v = _sampleAt(line, t).abs() * 1.8 * (0.3 + 0.7 * _sampleAt(env, t)) + 0.06;
      final a = math.min(amp, v * amp);
      if (i == 0) {
        path.moveTo(0, mid - a);
      } else {
        path.lineTo(i * step, mid - a);
      }
    }
    for (var i = points; i >= 0; i--) {
      final t = i / points;
      final v = _sampleAt(line, t).abs() * 1.8 * (0.3 + 0.7 * _sampleAt(env, t)) + 0.06;
      path.lineTo(i * step, mid + math.min(amp, v * amp));
    }
    path.close();
    return path;
  }

  // 竖纹条：包络 Path 当剪裁区（ctx.clip 的等价）。
  final stripe = _paint(palette.grad, palette.colorAt(0))
    ..color = palette.colorAt(0).withValues(alpha: 0.95);
  final stripesPath = ui.Path();
  for (var x = 0.0; x < w; x += 4) {
    stripesPath.addRect(ui.Rect.fromLTWH(x, 0, 2, h));
  }
  canvas.save();
  canvas.clipPath(build());
  canvas.drawPath(stripesPath, stripe);
  canvas.restore();

  // 白描边（alpha 0.92、lineWidth 1.5）。
  final stroke = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = const Color(0xEBFFFFFF).withValues(alpha: 0.92);
  canvas.drawPath(build(), stroke);
}

/// 12 · 尖峰镜像：不做任何平滑，锐角三角峰上下镜像，中间一条亮线（:816-859）。
const WaveStyle spikesStyle = WaveStyle(
  id: 'spikes',
  name: '尖峰镜像',
  ramp: WaveRamp.ember,
  usesPeaks: false,
  draw: _drawSpikes,
);

void _drawSpikes(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final bands = frame.bands;
  final mid = h / 2;
  final amp = mid - 2;
  if (bands.isEmpty) return;
  // 参考图是二三十根粗尖峰，直接按频段画会糊成一片毛刺。
  final cols = math.max(10, (w / 13).round());
  final idx = _strideIndexes(bands.length, cols);
  if (idx.isEmpty) return;
  final step = w / idx.length;

  final paint = _paint(palette.grad, palette.colorAt(0))
    ..color = palette.colorAt(0).withValues(alpha: 0.9);
  final path = ui.Path();
  for (var k = 0; k < idx.length; k++) {
    final bandIndex = idx[k];
    final v = bands[bandIndex];
    final x = k * step;
    path.moveTo(x, mid);
    path.lineTo(x + step / 2, mid - v * amp);
    path.lineTo(x + step, mid);
    path.moveTo(x, mid);
    path.lineTo(x + step / 2, mid + v * amp * 0.8);
    path.lineTo(x + step, mid);
  }
  canvas.drawPath(path, paint);

  final line = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..color = const Color(0xFFFFF6E8).withValues(alpha: 0.95 * 0.85); // rgba(255,246,232,0.95) × globalAlpha 0.85
  canvas.drawLine(ui.Offset(0, mid), ui.Offset(w, mid), line);
}

/// 13 · 点阵 LED：方格堆出来的柱状图，最高一格单独留一颗余辉（:862-896）。
const WaveStyle ledStyle = WaveStyle(
  id: 'led',
  name: '点阵 LED',
  ramp: WaveRamp.sunset,
  usesPeaks: true,
  draw: _drawLed,
);

void _drawLed(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final bands = frame.bands;
  const pitch = 4.0;
  const cell = 3.0;
  final cols = math.max(12, (w / pitch).floor());
  final idx = _strideIndexes(bands.length, cols);
  if (idx.isEmpty) return;
  final baseline = h - 2;
  final rows = ((baseline - 2) / pitch).floor();

  for (var k = 0; k < idx.length; k++) {
    final bandIndex = idx[k];
    final t = bandIndex / math.max(1, bands.length - 1);
    final lit = (bands[bandIndex] * rows).round();
    final x = k * pitch;
    final paint = _paint(null, palette.colorAt(t, sat: 92, light: 58));
    for (var r = 0; r < lit; r++) {
      canvas.drawRect(
        ui.Rect.fromLTWH(x, baseline - (r + 1) * pitch + cell, cell, cell),
        paint,
      );
    }
    final p = peaks[bandIndex];
    if (lit > p) peaks[bandIndex] = lit.toDouble();
    final peak = peaks[bandIndex].round();
    if (peak > 0 && peak < rows) {
      canvas.drawRect(
        ui.Rect.fromLTWH(x, baseline - (peak + 1) * pitch + cell, cell, cell),
        _paint(null, palette.colorAt(t, sat: 96, light: 76)),
      );
    }
  }
}

/// 14 · 平行波纹线：一摞水平波浪线，跟着同一个形状一起摆（:899-937）。
const WaveStyle flowStyle = WaveStyle(
  id: 'flow',
  name: '平行波纹线',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawFlow,
);

void _drawFlow(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final line = smoothSeries(frame.wave, 12);
  const count = 7;
  final gap = (h * 0.66) / count;
  final points = math.max(28, (w / 4).round());
  final phase = frame.phase;
  final level = frame.level;

  for (var k = 0; k < count; k++) {
    final rel = (k - (count - 1) / 2) / ((count - 1) / 2);
    final paint = _paint(null, palette.colorAt(k / (count - 1)))
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = palette
          .colorAt(k / (count - 1))
          .withValues(alpha: 0.7 + 0.3 * (1 - rel.abs()));
    final path = ui.Path();
    for (var i = 0; i <= points; i++) {
      final t = i / points;
      final x = t * w;
      final shape = _sampleAt(line, t) * 1.6 + math.sin(t * _tau * 2.6 + phase * 1.4) * 0.2;
      final y = mid +
          rel * gap * (count / 2) * _spindle(t, 0.7) +
          shape * h * 0.16 * (0.4 + 0.6 * level);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }
}

/// 15 · 点阵包络：用散点堆出上下镜像的包络，中间密两头疏（:940-975）。
const WaveStyle dotsStyle = WaveStyle(
  id: 'dots',
  name: '点阵包络',
  ramp: WaveRamp.sunset,
  usesPeaks: false,
  draw: _drawDots,
);

void _drawDots(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final mid = h / 2;
  final amp = mid - 2;
  final env = smoothSeries(frame.bands, 2);
  const pitch = 5.0;

  var col = 0;
  for (var x = pitch / 2; x < w; x += pitch, col++) {
    final t = x / math.max(1, w - 1);
    final v = _sampleAt(env, t);
    final hh = math.max(2.0, v * amp);
    // 宁疏勿密：一列最多三四颗，散在包络内部而不是糊成一片。
    final dots = 1 + (v * 3).round();
    final paint = _paint(null, palette.colorAt(t, light: 56 + (col % 3) * 7));
    for (var d = 0; d < dots; d++) {
      final fy = 0.2 + 0.8 * stableNoise(col, d);
      final fx = (stableNoise(col + 512, d) - 0.5) * pitch * 0.9;
      final y = hh * fy;
      canvas.drawCircle(ui.Offset(x + fx, mid - y), 1.2, paint);
      canvas.drawCircle(ui.Offset(x + fx, mid + y), 1.2, paint);
    }
  }
}

/// 16 · 层叠山峰：从底边叠上来的几层半透明平滑山（:978-1016）。
const WaveStyle hillsStyle = WaveStyle(
  id: 'hills',
  name: '层叠山峰',
  ramp: WaveRamp.ember,
  usesPeaks: false,
  draw: _drawHills,
);

void _drawHills(ui.Canvas canvas, WaveFrame frame, WavePalette palette, Float32List peaks) {
  final w = frame.width;
  final h = frame.height;
  final bands = frame.bands;
  final baseline = h;
  // 平滑遍数一多，四层会塌成同一座山；靠「各自错开一点」拉开前后层次。
  const layers = [
    (passes: 3, scale: 1.0, shift: 0.0, alpha: 0.45),
    (passes: 3, scale: 0.78, shift: 0.12, alpha: 0.58),
    (passes: 2, scale: 0.58, shift: -0.1, alpha: 0.72),
    (passes: 2, scale: 0.4, shift: 0.22, alpha: 0.88),
  ];
  final points = math.max(24, (w / 4).round());
  final step = w / points;

  for (var k = 0; k < layers.length; k++) {
    final layer = layers[k];
    final env = smoothSeries(bands, layer.passes);
    final paint = _paint(palette.grad, palette.colorAt(0))
      ..color = palette.colorAt(0).withValues(alpha: layer.alpha);
    final path = ui.Path()..moveTo(0, baseline);
    for (var i = 0; i <= points; i++) {
      final t = i / points;
      final shifted = (t + layer.shift + 1) % 1;
      final v = _sampleAt(env, shifted) * layer.scale * (h - 6 - k * 2);
      path.lineTo(i * step, baseline - math.max(2.0, v));
    }
    path.lineTo(w, baseline);
    path.close();
    canvas.drawPath(path, paint);
  }
}

// ---------------------------------------------------------------------------
// 注册表（:1018-1042 逐字）
// ---------------------------------------------------------------------------

/// 17 个样式一个不减，顺序与 React 版完全一致。
const List<WaveStyle> kWaveStyles = [
  spectrumStyle,
  ribbonStyle,
  hairlineStyle,
  sineStyle,
  roundBarsStyle,
  blobStyle,
  strandsStyle,
  noiseStyle,
  histogramStyle,
  mirrorAreaStyle,
  jaggedStyle,
  hatchStyle,
  spikesStyle,
  ledStyle,
  flowStyle,
  dotsStyle,
  hillsStyle,
];

const String kDefaultWaveStyleId = 'spectrum';

/// 按 id 找样式；未知 id 兜回第 0 条（spectrum）。
WaveStyle findWaveStyle(String? id) {
  for (final s in kWaveStyles) {
    if (s.id == id) return s;
  }
  return kWaveStyles[0];
}

// ---------------------------------------------------------------------------
// 偏差说明（Canvas → Flutter 等价取舍）
// ---------------------------------------------------------------------------
//
// * shadowBlur：Canvas 的模糊是「白色半透明阴影」，Flutter 没有 ctx.shadow*。
//   视觉上它只是给柱体加一圈柔光，这里在唯一重度依赖它的样式（spectrum）
//   上用 MaskFilter.blur(sigma=blur/2) 近似（6→3）；其余样式的 shadowBlur
//   都 ≤6 且作用在 stroke 上，按计划允许省略——省略后唯一可见差异是
//   深色底上少一圈 halo。
// * ctx.clip()：hatch 用 canvas.clipPath 等价实现，剪裁语义一致。
// * ctx.globalAlpha：改为 Paint.color 的 withValues(alpha:)（同一个数值）。
// * arcTo：Path.arcToPoint（同样四角圆角语义）；fillRect → drawRect；
//   arc → drawCircle；stroke → Path + stroke paint。
// * monoColor 的 light 参数语义：TS 签名是 (t, sat, light)，样式调用里
//   只有 light 会影响单色输出（h/s 来自 setWaveAccent），对译成
//   monoColor(light, accent:)，WavePalette.colorAt 的签名保持三参不变。
// * buildWavePalette 的 accent 回退：React 是「取不到计算样式就 {h:160,s:85}」，
//   Flutter 的 accent 总有值，所以只在 accent 无彩色信息（s==0 且 l 为 0/100，
//   即纯黑/纯白）时落回 {h:160, s:85}；正常 accent 走 (s+78)/2 公式。
