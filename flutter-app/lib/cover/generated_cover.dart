// lib/cover/generated_cover.dart
//
// 本地生成歌手封面卡（封面四级兜底的第四级）——派生量 + Painter。
//
// 对译 React 版 `src/lib/generated-cover.js`（156 行）逐字公式：
//   * FNV-1a 32 位哈希（:23-30）：按 **UTF-16 码元** 遍历（JS charCodeAt 的
//     等价物是 Dart 的 codeUnits，emoji 代理对拆成两个码元参与哈希）；
//   * normalizeArtist（:37-44）与 initialsOf（:65-79）；
//   * 派生量 seed/hue/hue2/rotation（:89-92）与 27 根声波柱高（:98-113）。
//
// **有意差异**（M2b 计划裁定第 4 条）：React 生成 SVG 字符串再 encode 成
// data URL；Dart 侧不引 flutter_svg，改为 `CustomPainter` 按同一套几何直绘。
// 派生量与黄金数值逐位一致（黄金表见 test/cover/generated_cover_test.dart），
// 视觉结果等价。画面几何（:115-144）：
//
//   600×600 画布；内容全部落在内切圆内（「安全圆」）——
//   * 线性渐变底 + 径向白光；三个同心装饰圆（圆心 (300,228)）；
//   * 首字居中 (300,228)：CJK 1 字号 216，拉丁 2 字号 168；
//   * 27 根柱：中线 y=360，横向只占中间 68%（barSpan=408）；
//   * 歌手名 y=450（28 号）、曲名 y=507（18 号，仅非空时画）。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// FNV-1a 32 位哈希（generated-cover.js:23-30）。
///
/// 初值 `0x811C9DC5`，每轮 `value ^= codeUnit`、`value = (value *
/// 0x01000193) & 0xFFFFFFFF`（Dart 的 `& 0xFFFFFFFF` 等价 JS `Math.imul`
/// 的无符号截断），返回无符号 32 位整数。
int fnv1aHash(String text) {
  var value = 0x811C9DC5;
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    value ^= units[i];
    value = (value * 0x01000193) & 0xFFFFFFFF;
  }
  return value;
}

/// 归一化歌手名（generated-cover.js:37-44）：大小写、空白、全角空格与
/// 尾部连字符差异都并到同一张图上。
String normalizeArtistForCover(String artist) {
  var value = artist.trim().toLowerCase();
  value = value.replaceAll(RegExp(r'\s+'), ' ');
  value = value.replaceAll('\u3000', ' ');
  return value.replaceFirst(RegExp(r'\s*[-–—]\s*$'), '');
}

final RegExp _coverInitialsCjk = RegExp(
  r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]',
);

/// 取首字（generated-cover.js:65-79）：CJK 用一个字（「周」），拉丁取
/// 最多两个首字母（「JAY CHOU」→「JC」）；空或全标点 → `♪`。
String initialsOfArtist(String artist) {
  final value = artist.trim();
  if (value.isEmpty) return '♪';
  // `replace(/[^\p{L}\p{N}]/gu, ' ')`：unicode 开关必须开，\p{L} 才生效。
  final cleaned = value.replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    ' ',
  );
  final chars = <String>[];
  for (final rune in cleaned.runes) {
    final ch = String.fromCharCode(rune);
    if (ch.trim().isNotEmpty) chars.add(ch);
  }
  if (chars.isEmpty) return '♪';
  final first = chars.first;
  if (_coverInitialsCjk.hasMatch(first)) return first;
  return chars
      .take(2)
      .map((c) => c.toUpperCase())
      .join('');
}

/// 生成卡的确定性派生结构（与画面一一对应，供测试断言与 Painter 消费）。
class GeneratedCoverSpec {
  const GeneratedCoverSpec({
    required this.key,
    required this.seed,
    required this.hue,
    required this.hue2,
    required this.rotation,
    required this.initials,
    required this.label,
    required this.sub,
    required this.showSub,
    required this.bars,
  });

  /// 归一化后的哈希键（空歌手 → `'unknown'`）。
  final String key;
  final int seed;
  final int hue;
  final int hue2;
  final int rotation;
  final String initials;

  /// 底部歌手名（截 14 字；空歌手 → `未知歌手`）。
  final String label;

  /// 底部曲名小字（截 16 字）。
  final String sub;
  final bool showSub;

  /// 27 根声波柱的柱高（px）。
  final List<int> bars;

  @override
  bool operator ==(Object other) =>
      other is GeneratedCoverSpec &&
      other.key == key &&
      other.seed == seed &&
      other.hue == hue &&
      other.hue2 == hue2 &&
      other.rotation == rotation &&
      other.initials == initials &&
      other.label == label &&
      other.sub == sub &&
      other.showSub == showSub &&
      _listEquals(other.bars, bars);

  @override
  int get hashCode => Object.hash(
        key, seed, hue, hue2, rotation, initials, label, sub, showSub,
        Object.hashAll(bars),
      );

  @override
  String toString() =>
      'GeneratedCoverSpec($key, seed=$seed, hue=$hue, hue2=$hue2, '
      'rotation=$rotation, initials=$initials)';

  static bool _listEquals(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 生成派生结构（generated-cover.js:87-113）。
GeneratedCoverSpec generatedCoverSpec(String artist, String title) {
  final key = normalizeArtistForCover(artist);
  final seed = fnv1aHash(key.isEmpty ? 'unknown' : key);
  final hue = seed % 360;
  final hue2 = (hue + 32 + seed % 26) % 360;
  final rotation = seed % 4;
  final initials = initialsOfArtist(artist);
  final trimmedArtist = artist.trim();
  final labelSource = trimmedArtist.isEmpty ? '未知歌手' : trimmedArtist;
  final label = labelSource.length > 14
      ? labelSource.substring(0, 14)
      : labelSource;
  final subSource = title.trim();
  final sub = subSource.length > 16 ? subSource.substring(0, 16) : subSource;

  // 声波柱（generated-cover.js:98-102）：确定性柱高，换歌手就换形状。
  final bars = List<int>.generate(27, (index) {
    final wave =
        math.sin((index + 1) * (1 + seed % 5) * 0.6) * 0.5 + 0.5;
    final jitter = (fnv1aHash('${key.isEmpty ? 'unknown' : key}#$index') %
            100) /
        100 *
        0.5;
    return 18 + ((wave + jitter) * 46).round();
  });

  return GeneratedCoverSpec(
    key: key.isEmpty ? 'unknown' : key,
    seed: seed,
    hue: hue,
    hue2: hue2,
    rotation: rotation,
    initials: initials,
    label: label,
    sub: sub,
    showSub: sub.isNotEmpty,
    bars: bars,
  );
}

/// 生成卡 Painter（generated-cover.js:115-144 的画面结构，600×600）。
///
/// 内容全部落在「安全圆」内：界面把封面裁成正圆（外层 `ClipOval`）后，
/// 靠边和靠底的像素会被剪掉 —— 横向柱列只占中间 68%，文字纵向最远到
/// y=507，全部在内切圆内。Painter 画**方图**，圆裁归调用方。
class GeneratedCoverPainter extends CustomPainter {
  const GeneratedCoverPainter(this.spec);

  final GeneratedCoverSpec spec;

  /// HSL → 不透明色（h 0-360 度，s/l 0-1，alpha 恒 255）。标准 HSL→RGB
  /// 公式；与 CSS 的 `hsl(h s% l%)` 语义一致（生成卡模板 :118-121 / :111
  /// 的颜色档）。半透明的白与柱色不在这里派生，直接写字面量。
  static Color _hsl(double h, double s, double l) {
    final c = (1 - (2 * l - 1).abs()) * s;
    final hp = (h % 360) / 60;
    final x = c * (1 - (hp % 2 - 1).abs());
    final m = l - c / 2;
    double r = 0, g = 0, b = 0;
    if (hp < 1) {
      r = c;
      g = x;
    } else if (hp < 2) {
      r = x;
      g = c;
    } else if (hp < 3) {
      g = c;
      b = x;
    } else if (hp < 4) {
      g = x;
      b = c;
    } else if (hp < 5) {
      r = x;
      b = c;
    } else {
      r = c;
      b = x;
    }
    int to255(double v) => ((v + m) * 255).round().clamp(0, 255);
    return Color.fromARGB(255, to255(r), to255(g), to255(b));
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 600×600 逻辑坐标系：任何正方形尺寸都按比例缩放绘制。
    const design = 600.0;
    if (size.width <= 0 || size.height <= 0) return;
    canvas.scale(size.width / design, size.height / design);

    // 1) 线性渐变底（:117-121）：rotation 奇数横跨对角，偶数收在 0.35。
    final bgRect = Rect.fromLTWH(0, 0, design, design);
    canvas.drawRect(
      bgRect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(spec.rotation % 2 == 1 ? design : design * 0.35, design),
          [
            _hsl(spec.hue.toDouble(), 0.68, 0.22),
            _hsl(spec.hue2.toDouble(), 0.72, 0.34),
            _hsl((spec.hue2 + 18) % 360.toDouble(), 0.78, 0.48),
          ],
          const [0.0, 0.55, 1.0],
        ),
    );

    // 2) 径向白光（:122-125）：cx .5 cy .42 r .62，白 22% → 0。
    canvas.drawRect(
      bgRect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(design / 2, design * 0.42),
          design * 0.62,
          [
            const Color(0x38FFFFFF),
            const Color(0x00FFFFFF),
          ],
        ),
    );

    // 3) 三个同心装饰圆（:129-133）：白 12% 描边。
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x1FFFFFFF);
    for (final r in const [150.0, 196.0, 242.0]) {
      canvas.drawCircle(Offset(design / 2, design * 0.38), r, ringPaint);
    }

    // 4) 首字（:134-137）：居中于 (300,228)，字号 2 字 168 / 1 字 216。
    final initialsFontSize = spec.initials.length > 1 ? 168.0 : 216.0;
    _drawCenteredText(
      canvas,
      text: spec.initials,
      center: Offset(design / 2, design * 0.38),
      fontSize: initialsFontSize,
      fontWeight: FontWeight.w700,
      color: const Color(0xEBFFFFFF),
    );

    // 5) 27 根声波柱（:108-113）：中线 y=360，胶囊形。
    const barSpan = design * 0.68;
    final barStart = (design - barSpan) / 2;
    final barWidth = barSpan / (spec.bars.length * 1.9);
    final barPaint = Paint()
      ..color = _hsl(spec.hue2.toDouble(), 0.85, 0.62).withValues(alpha: 0.5);
    for (var index = 0; index < spec.bars.length; index++) {
      final height = spec.bars[index].toDouble();
      final x = barStart +
          index * barSpan / (spec.bars.length - 1) -
          barWidth / 2;
      final y = design * 0.6 - height / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        barPaint,
      );
    }

    // 6) 歌手名（:139-142）：y=450，28 号 w600，白 86%。
    _drawCenteredText(
      canvas,
      text: spec.label,
      center: Offset(design / 2, design * 0.75),
      fontSize: 28,
      fontWeight: FontWeight.w600,
      color: const Color(0xDBFFFFFF),
      letterSpacing: 1,
    );

    // 7) 曲名小字（:143）：y=507，18 号，白 55%，仅非空时画。
    if (spec.showSub) {
      _drawCenteredText(
        canvas,
        text: spec.sub,
        center: Offset(design / 2, design * 0.845),
        fontSize: 18,
        fontWeight: FontWeight.w400,
        color: const Color(0x8CFFFFFF),
      );
    }
  }

  void _drawCenteredText(
    Canvas canvas, {
    required String text,
    required Offset center,
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
    double letterSpacing = 0,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          letterSpacing: letterSpacing,
          color: color,
          fontFamily: 'sans-serif',
          fontFamilyFallback: const [
            'Microsoft YaHei',
            'Noto Sans SC',
            'PingFang SC',
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(GeneratedCoverPainter oldDelegate) =>
      oldDelegate.spec != spec;
}
