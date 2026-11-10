// lib/theme/color_utils.dart
//
// 颜色工具：浅色主题下把用户选的高亮色压到「白底上也读得清」。
// 对译 React `src/state/theme.tsx:160-219` 逐字公式：
//
//   * channelLum：sRGB 线性化，`v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)^2.4`；
//   * luminance：0.2126 R + 0.7152 G + 0.0722 B；
//   * contrastOnWhite：`(白点亮度 + 0.05) / (色亮度 + 0.05)`；
//   * highlightOnLight：已达标原样返回；否则每步 RGB 各乘 0.94（压 6%），
//     最多压到 12% 亮度，达标即停；都不达标返回最暗一档。
//
// 调用点：① 歌词当前行配色（浅色 + 用户自选色才压，theme.tsx:66）；
// ② T 色板的预览（LyricColorButton.tsx:36，所见即所得）。
// 黄金数值（node 现算）见 test/theme/color_utils_test.dart。
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 对白底的对比度（WCAG 相对亮度）。
double contrastOnWhite(Color c) => 1.05 / (_luminance(c) + 0.05);

double _luminance(Color c) =>
    0.2126 * _channelLum(_ch(c.r)) + 0.7152 * _channelLum(_ch(c.g)) + 0.0722 * _channelLum(_ch(c.b));

/// double 通道 → 0~255 的 int（Flutter 3.27+ 的 Color 通道是 double）。
int _ch(double v) => (v * 255.0).round().clamp(0, 255);

double _channelLum(int channel8) {
  final v = channel8 / 255;
  return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

/// 浅色主题下的高亮色：保持色相、按比例压暗，直到对白底对比度 ≥ [min]。
///
/// 返回 [Color]；输入不透明度原样保留（压暗只动 RGB）。
Color highlightOnLight(Color color, {double min = 4.5}) {
  if (contrastOnWhite(color) >= min) {
    return color;
  }
  var best = color;
  for (var factor = 0.94; factor >= 0.12; factor -= 0.06) {
    best = Color.fromARGB(
      _ch(color.a),
      (_ch(color.r) * factor).round(),
      (_ch(color.g) * factor).round(),
      (_ch(color.b) * factor).round(),
    );
    if (contrastOnWhite(best) >= min) {
      break;
    }
  }
  return best;
}

/// `#rrggbb` → Color（alpha 255）；非法输入返回 null。
Color? parseHexColor(String hex) {
  final match = RegExp(r'^#([0-9a-f]{6})$', caseSensitive: false).firstMatch(hex.trim());
  if (match == null) return null;
  final value = int.parse(match.group(1)!, radix: 16);
  return Color(0xFF000000 | value);
}

/// Color → `#rrggbb`（不含 alpha，对齐 React 的 toHex——高亮色只走不透明色）。
String toHexString(Color color) {
  String two(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${two(_ch(color.r))}${two(_ch(color.g))}${two(_ch(color.b))}';
}

/// HSL 三元组（h 0-360，s/l 0-100）。
class Hsl {
  const Hsl({required this.h, required this.s, required this.l});
  final double h;
  final double s;
  final double l;
}

/// Color → HSL（标准公式）。
Hsl colorToHsl(Color color) {
  final r = color.r, g = color.g, b = color.b;
  final max = math.max(r, math.max(g, b));
  final min = math.min(r, math.min(g, b));
  final delta = max - min;
  var h = 0.0;
  if (delta != 0) {
    if (max == r) {
      h = ((g - b) / delta) % 6;
    } else if (max == g) {
      h = (b - r) / delta + 2;
    } else {
      h = (r - g) / delta + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
  }
  final l = (max + min) / 2;
  final s = delta == 0 ? 0.0 : delta / (1 - (2 * l - 1).abs());
  return Hsl(h: h, s: s * 100, l: l * 100);
}

/// HSL → Color（alpha 固定 255）。h 可以为任意实数（内部归一）。
Color hslToColor(double h, double s, double l) {
  final hn = (h % 360) / 360;
  final sn = (s / 100).clamp(0.0, 1.0);
  final ln = (l / 100).clamp(0.0, 1.0);
  if (sn == 0) {
    final v = (ln * 255).round();
    return Color.fromARGB(255, v, v, v);
  }
  final q = ln < 0.5 ? ln * (1 + sn) : ln + sn - ln * sn;
  final p = 2 * ln - q;
  double channel(double t) {
    var tt = t;
    if (tt < 0) tt += 1;
    if (tt > 1) tt -= 1;
    if (tt < 1 / 6) return p + (q - p) * 6 * tt;
    if (tt < 1 / 2) return q;
    if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
    return p;
  }

  return Color.fromARGB(
    255,
    (channel(hn + 1 / 3) * 255).round(),
    (channel(hn) * 255).round(),
    (channel(hn - 1 / 3) * 255).round(),
  );
}
