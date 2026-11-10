// M3 T15 对比度实测：浅色主题歌词三档 + highlightOnLight 产物（spec §9/§16）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/color_utils.dart';

double contrast(Color a, Color b) {
  double lum(Color c) {
    double ch(double v) {
      return v <= 0.03928 ? v / 12.92 : _p((v + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }
  final la = lum(a), lb = lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
double _p(double x, double y) {
  var r = 1.0;
  for (var i = 0; i < y; i++) { r *= x; }
  return r;
}

void main() {
  test('浅色主题歌词三档对比度（README：当前 5.31 / 未唱 5.11 / 已唱 4.35）', () {
    final t = AppTokens.lightMint;
    final white = const Color(0xFFFFFFFF);
    // 当前行 = accent-light（#0a7a5d）。
    final current = contrast(t.accentLight, white);
    // 未唱行 = text（#16202b）。
    final unplayed = contrast(t.text, white);
    // 已唱行 = text-dim × pastOpacity 0.82（合到白底）。
    final dimmed = Color.fromARGB(
      (0.82 * 255).round(),
      (t.textDim.r * 255).round(),
      (t.textDim.g * 255).round(),
      (t.textDim.b * 255).round(),
    );
    final played = contrast(dimmed, white);
    // ignore: avoid_print
    print('当前行 $current 未唱 $unplayed 已唱 $played');
    expect(current, greaterThanOrEqualTo(4.5));
    expect(unplayed, greaterThanOrEqualTo(4.5));
    expect(played, greaterThanOrEqualTo(4.3), reason: 'README 4.35');
  });

  test('highlightOnLight 产物全部达标 ≥4.5', () {
    for (final hex in const [
      '#7de3ff', '#8aa9ff', '#b98cff', '#ff8fc7', '#ffb066', '#ffe066', '#f2f7fb',
    ]) {
      final out = highlightOnLight(parseHexColor(hex)!);
      final c = contrast(out, const Color(0xFFFFFFFF));
      // ignore: avoid_print
      print('$hex → $out = ${c.toStringAsFixed(2)}');
      expect(c, greaterThanOrEqualTo(4.5));
    }
  });
}
