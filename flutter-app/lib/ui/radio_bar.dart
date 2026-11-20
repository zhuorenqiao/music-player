// lib/ui/radio_bar.dart
//
// 迷你电台条（T31）：电台在后台继续放时，贴在音乐页控制条正上方的一条。
//
// 为什么需要它：电台离开页面后**不停流**（用户要求「退到播放器后台继续放」），
// 那么音乐页必须给出「现在还在响的是什么」的交代 —— 否则一条看不见的直播流
// 会让人以为播放器坏了。这条 = 状态（点 + 电台 / 台名 / 频率）+ 三个动作：
// 点主体回电台页、播放暂停、关闭。
//
// 与 React `src/components/MiniRadio.tsx` 成对：高度 46、圆角 14、左右 16 的
// 外边距、字号与字距逐项对齐；颜色全走 token。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../radio/radio_state.dart';
import '../theme/app_tokens.dart';

class RadioBar extends StatelessWidget {
  const RadioBar({required this.onOpen, super.key});

  /// 回电台页（不重新开流，页面直接显示当前台）。
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radio = context.watch<RadioState>();
    final station = radio.current;
    // 没选过台（或已经关闭）就不占位：这条只在「后台确实有电台」时存在。
    if (station == null) return const SizedBox.shrink();

    final playing = radio.playing;
    final loading = radio.loading;
    return Semantics(
      container: true,
      label: '电台 ${station.name}',
      child: Container(
        height: 46,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tokens.accentLine),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [tokens.accentSoft, tokens.surface],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                key: const Key('radio-bar-open'),
                behavior: HitTestBehavior.opaque,
                onTap: onOpen,
                child: Semantics(
                  button: true,
                  label: '回到电台页 ${station.name}',
                  excludeSemantics: true,
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: loading
                                ? tokens.textFaint
                                : (playing
                                      ? tokens.accent
                                      : tokens.textFaint),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '电台',
                          style: TextStyle(
                            fontSize: 8.5,
                            height: 1.1,
                            letterSpacing: 1.8,
                            color: tokens.accent.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            station.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.1,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.4,
                              color: tokens.text,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            station.detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.1,
                              color: tokens.textDim,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _BarButton(
              key: const Key('radio-bar-toggle'),
              label: playing ? '暂停电台' : '继续播放电台',
              onTap: radio.toggle,
              child: CustomPaint(
                size: const Size.square(13),
                painter: _BarGlyphPainter(
                  color: tokens.text,
                  glyph: playing ? _BarGlyph.pause : _BarGlyph.play,
                ),
              ),
            ),
            _BarButton(
              key: const Key('radio-bar-stop'),
              label: '关闭电台',
              onTap: radio.stop,
              child: CustomPaint(
                size: const Size.square(12),
                painter: _BarGlyphPainter(
                  color: tokens.textDim,
                  glyph: _BarGlyph.close,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// 条上的小圆钮：28×28 命中区，无底色（悬停才浮一层极淡的 accent）。
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.onTap,
    required this.child,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(child: child),
        ),
      ),
    );
  }
}

enum _BarGlyph { play, pause, close }

class _BarGlyphPainter extends CustomPainter {
  const _BarGlyphPainter({required this.color, required this.glyph});

  final Color color;
  final _BarGlyph glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    switch (glyph) {
      case _BarGlyph.play:
        final path = Path()
          ..moveTo(size.width * 0.30, size.height * 0.18)
          ..lineTo(size.width * 0.30, size.height * 0.82)
          ..lineTo(size.width * 0.82, size.height * 0.50)
          ..close();
        canvas.drawPath(path, paint);
      case _BarGlyph.pause:
        final barWidth = size.width * 0.17;
        final barHeight = size.height * 0.66;
        final top = (size.height - barHeight) / 2;
        for (final left in [size.width * 0.28, size.width * 0.55]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(left, top, barWidth, barHeight),
              Radius.circular(barWidth / 2),
            ),
            paint,
          );
        }
      case _BarGlyph.close:
        final stroke = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round;
        final inset = size.width * 0.28;
        canvas.drawLine(
          Offset(inset, inset),
          Offset(size.width - inset, size.height - inset),
          stroke,
        );
        canvas.drawLine(
          Offset(size.width - inset, inset),
          Offset(inset, size.height - inset),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _BarGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.glyph != glyph;
}
