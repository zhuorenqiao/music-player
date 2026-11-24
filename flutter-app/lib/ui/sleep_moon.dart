// lib/ui/sleep_moon.dart
//
// 休眠的月亮图标：顶栏入口、页面 logo、列表缩略图与迷你条共用同一枚。
//
// 形状与 React `MoonIcon`（Feather moon 的实体路径）逐点一致：
//   M21 12.79 A9 9 0 1 1 11.21 3 A7 7 0 0 0 21 12.79 z
// 用两段圆弧围出月牙，fill 实心；不依赖 Material 的 nightlight（那枚带脸，
// 而且轮廓对不上）。
import 'package:flutter/material.dart';

class SleepMoonIcon extends StatelessWidget {
  const SleepMoonIcon({required this.size, required this.color, super.key});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MoonPainter(color: color),
        size: Size.square(size),
      ),
    );
  }
}

class _MoonPainter extends CustomPainter {
  const _MoonPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final path = Path()
      ..moveTo(21 * s, 12.79 * s)
      ..arcToPoint(
        Offset(11.21 * s, 3 * s),
        radius: Radius.circular(9 * s),
        largeArc: true,
        clockwise: true,
      )
      ..arcToPoint(
        Offset(21 * s, 12.79 * s),
        radius: Radius.circular(7 * s),
        clockwise: false,
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _MoonPainter oldDelegate) =>
      oldDelegate.color != color;
}
