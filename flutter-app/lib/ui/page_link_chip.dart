// lib/ui/page_link_chip.dart
//
// 页面之间互跳的那几颗胶囊：图标 + 文案，窄屏收起文字、只留图标。
//
// 休眠页的「电台」（广播波）、电台页的「休眠」（月亮），以及两页都有的
// 「音乐」回退，外壳是同一个 —— 高度 36 / 32、999 圆角、12.5px 字号、
// 16px 图标与 8px 间距，与 React `.sleep-head__radio` / `.radio-head__sleep` /
// `.__back` 那一档逐项对齐；改一处必须改另一处。
//
// 三页（音乐 / 休眠 / 电台）的右上角是同一排按钮：去电台的带 accent 描边 + 淡渐变底
// （[PageLinkTone.accent]），去休眠的带淡渐变底（[PageLinkTone.accentIcon]），
// 工具入口是素壳（[PageLinkTone.neutral]）。所有尺寸下文字统一走 text，
// 图标与「更多」同用中性 token，不跟随主题色；窄屏收成 32×32 的无壳图标。
//
// 月亮不在这里：它由 `sleep_moon.dart` 的 [SleepMoonIcon] 提供，顶栏入口、
// 页面 logo 与列表缩略图共用同一枚。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

/// 胶囊的三种身份色，与 React 顶栏 `.app__radio` / `.app__sleep` / `.btn` 一一对应。
enum PageLinkTone {
  /// 素壳：工具型入口（「音乐」回播放器、另一页的「更多」）。
  neutral,

  /// accent 描边 + 淡渐变底：去电台。
  accent,

  /// 素描边 + 淡渐变底：去休眠、回音乐播放器。
  accentIcon,
}

/// 页面互跳胶囊：[chipKey] 供测试定位，[iconBuilder] 按尺寸与颜色画图标。
class PageLinkChip extends StatelessWidget {
  const PageLinkChip({
    required this.chipKey,
    required this.semanticLabel,
    required this.label,
    required this.iconBuilder,
    required this.onTap,
    this.tone = PageLinkTone.neutral,
    this.narrowIconSize = 18,
    super.key,
  });

  final Key chipKey;
  final String semanticLabel;
  final String label;
  final Widget Function(double size, Color color) iconBuilder;
  final VoidCallback onTap;

  /// 身份色，见 [PageLinkTone]。
  final PageLinkTone tone;

  /// 窄屏（只剩图标）时的图标边长：电台 18（与音乐页顶栏那颗同档）、
  /// 休眠 16（月亮与顶栏那颗同档）、音乐 16。
  final double narrowIconSize;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final narrow = !isDesktop(MediaQuery.sizeOf(context).width);
    final accent = tone == PageLinkTone.accent;
    final iconColor = narrow ? tokens.textDim : tokens.text;
    final labelColor = tokens.text;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: chipKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: Container(
          height: narrow ? 32 : 36,
          width: narrow ? 32 : null,
          padding: narrow
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 12),
          decoration: narrow
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: accent ? tokens.accentLine : tokens.border,
                  ),
                  color: tone == PageLinkTone.neutral ? tokens.surface : null,
                  gradient: tone == PageLinkTone.neutral
                      ? null
                      : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            accent
                                ? tokens.accentSoft
                                : tokens.accent.withValues(alpha: 0.10),
                            tokens.surface,
                          ],
                        ),
                ),
          alignment: Alignment.center,
          child: narrow
              ? iconBuilder(narrowIconSize, iconColor)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconBuilder(16, iconColor),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(fontSize: 12.5, color: labelColor),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 广播图标：下方实心点 + 上方三道同心弧（与 React `BroadcastIcon` 同一条路径）。
///
/// 电台页的 logo（20px）与休眠页那颗「电台」入口（16 / 18px）共用。
class BroadcastPainter extends CustomPainter {
  const BroadcastPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final center = Offset(12 * s, 17.2 * s);
    canvas.drawCircle(center, 1.9 * s, Paint()..color = color);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.6 * s;
    for (final radius in const [4.6, 7.2, 9.8]) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * s),
        math.pi,
        math.pi,
        false,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BroadcastPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 音符图标（回音乐播放器）：与 React `MusicNoteIcon` 同一条路径。
class MusicNotePainter extends CustomPainter {
  const MusicNotePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(9 * s, 16.6 * s)
      ..lineTo(9 * s, 5.4 * s)
      ..lineTo(18 * s, 3.8 * s)
      ..lineTo(18 * s, 14.2 * s);
    canvas.drawPath(path, stroke);
    canvas.drawCircle(Offset(6.6 * s, 16.8 * s), 2.6 * s, stroke);
    canvas.drawCircle(Offset(15.6 * s, 14.4 * s), 2.6 * s, stroke);
  }

  @override
  bool shouldRepaint(covariant MusicNotePainter oldDelegate) =>
      oldDelegate.color != color;
}
