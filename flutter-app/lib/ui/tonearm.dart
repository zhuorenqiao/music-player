// lib/ui/tonearm.dart
//
// 唱臂（M3 T13）：对译 React `src/App.tsx:454-485` 的 SVG 与 app.css:836-860
// 的 `.stage__tonearm`。
//
//   * 支点 transform-origin: 97% 3%；暂停 -45°、播放 -17°（唱头落在标签与
//     外圈之间的纹路正中间）；
//   * 过冲曲线 `0.75s cubic-bezier(0.34, 1.56, 0.64, 1)`（落到 -17° 前先
//     略微多探一点再回退）—— Flutter 侧用 [Curves.easeOutBack] 近似：
//     (0.34,1.56,0.64,1) 的 out-back 族，实测曲线形状同族（1.56 为过冲强度）；
//   * 落针时薄荷微光（drop-shadow accent 0.18）。
//
// SVG path 逐字：支点底座 circle (97,3) r3.6 + 轴心 r0.75（accent）、
// 臂杆贝塞尔 M95.6 4.6 C 91 12, 85 21, 78.5 29.5 四层描边、唱头 rotate(-45)。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 唱臂角度（度）：暂停摆出 / 播放落在纹路中间带。
const double kTonearmRestDeg = -45;
const double kTonearmPlayDeg = -17;

/// 唱臂 widget：[spinning] 为真时落在 -17°，为假摆到 -45°。
class Tonearm extends StatefulWidget {
  const Tonearm({required this.spinning, required this.size, super.key});

  final bool spinning;
  final double size;

  @override
  State<Tonearm> createState() => _TonearmState();
}

class _TonearmState extends State<Tonearm> with SingleTickerProviderStateMixin {
  late final AnimationController _arm = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
    // 过冲曲线（cubic-bezier(0.34, 1.56, 0.64, 1) 的 out-back 族近似）。
    value: 0,
  );

  late final Animation<double> _armCurved = CurvedAnimation(
    parent: _arm,
    curve: const Cubic(0.34, 1.56, 0.64, 1),
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning && !MediaQuery.disableAnimationsOf(context)) {
      _arm.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant Tonearm old) {
    super.didUpdateWidget(old);
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (widget.spinning == old.spinning) return;
    if (reduced) {
      _arm.value = widget.spinning ? 1 : 0;
      return;
    }
    // 过冲曲线（cubic-bezier(0.34, 1.56, 0.64, 1) 的 out-back 族近似）。
    if (widget.spinning) {
      _arm.forward(from: _arm.value);
    } else {
      _arm.reverse(from: _arm.value);
    }
  }

  @override
  void dispose() {
    _arm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return AnimatedBuilder(
      animation: _arm,
      builder: (context, _) {
        final deg = kTonearmRestDeg +
            (kTonearmPlayDeg - kTonearmRestDeg) * _armCurved.value;
        return Transform.rotate(
          angle: deg * math.pi / 180,
          alignment: const Alignment(0.94, -0.94), // 97% 3%
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _TonearmPainter(accent: tokens.accent),
          ),
        );
      },
    );
  }
}

/// 唱臂 SVG 逐字（App.tsx:455-485 的 viewBox 0 0 100 100）。
class _TonearmPainter extends CustomPainter {
  const _TonearmPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100;
    canvas.scale(s, s);

    // 支点底座：深色同心盘（radialGradient #39424a→#171c20→#0a0e11 的近似）。
    final basePaint = Paint()
      ..shader = ui.Gradient.radial(
        const Offset(97 * 0.42, 3 * 0.38),
        3.6,
        const [Color(0xFF39424A), Color(0xFF171C20), Color(0xFF0A0E11)],
        const [0, 0.62, 1],
      );
    canvas.drawCircle(const Offset(97, 3), 3.6, basePaint);
    canvas.drawCircle(
      const Offset(97, 3),
      3.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = const Color(0x4DFFFFFF),
    );
    // 轴心：accent 圆点。
    canvas.drawCircle(const Offset(97, 3), 0.75, Paint()..color = accent);

    // 臂杆四层描边（外投影 → 深色轮廓 → 金属内芯 → 顶部高光）。
    final armPath = Path()
      ..moveTo(95.6, 4.6)
      ..cubicTo(91, 12, 85, 21, 78.5, 29.5);
    canvas.drawPath(
      armPath,
      Paint()
        ..color = const Color(0x8C000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
    );
    canvas.drawPath(
      armPath,
      Paint()
        ..color = const Color(0xFF0A0E11)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      armPath,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(97, 3),
          const Offset(78.5, 29.5),
          const [Color(0xFFE4E9ED), Color(0xFF97A2AA), Color(0xFF525B62)],
          const [0, 0.5, 1],
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      armPath,
      Paint()
        ..color = const Color(0x80FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..strokeCap = StrokeCap.round,
    );

    // 唱头：深色壳体 + accent 识别线（rotate(-45 78.5 29.5)）。
    canvas.save();
    canvas.translate(78.5, 29.5);
    canvas.rotate(-math.pi / 4);
    canvas.translate(-78.5, -29.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(75, 27.5, 7, 4),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFF12181C),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(75, 27.5, 7, 4),
        const Radius.circular(2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.4
        ..color = const Color(0x42FFFFFF),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(76.4, 28.9, 4.2, 1.1),
        const Radius.circular(0.55),
      ),
      Paint()..color = accent.withValues(alpha: 0.9),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TonearmPainter oldDelegate) => oldDelegate.accent != accent;
}
