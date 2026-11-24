// lib/ui/sleep_bar.dart
//
// 迷你休眠条：休眠声景离开页面后继续在后台放（睡前场景本来就要放着睡着），
// 音乐页必须交代「现在还在响的是哪一段」—— 否则一条看不见的声音会让人以为
// 播放器坏了。
//
// 这条 = 状态（点 + 月亮「助眠」/ 曲名 / 质地）+ 三个动作：点主体回助眠页、
// 播放暂停、关闭。与 React `src/components/MiniSleep.tsx` 成对：
// 高度 46、圆角 14、左右 16 的外边距、字号与字距逐项对齐 ——
// **尺寸以电台条（RadioBar）为准**，两张快捷卡在手机 / 桌面都同宽同高。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../sleep/sleep_state.dart';
import '../theme/app_tokens.dart';
import 'sleep_moon.dart';

class SleepBar extends StatelessWidget {
  const SleepBar({required this.onOpen, super.key});

  /// 回休眠页（不重新生成，页面直接显示当前曲目）。
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final sleep = context.watch<SleepState>();
    final track = sleep.current;
    // 没选过曲目（或已经关闭）就不占位：这条只在「后台确实有声景」时存在。
    if (track == null) return const SizedBox.shrink();

    final playing = sleep.playing;
    final loading = sleep.loading;
    // 尺寸完全跟随 RadioBar：手机与桌面同为 46 高、左右 16 外边距、28 圆钮。
    // 两条快捷卡上下并排，任一档都不能一长一短、一高一矮。
    const height = 46.0;
    const margin = EdgeInsets.fromLTRB(16, 0, 16, 10);
    const button = 28.0;
    return Semantics(
      container: true,
      label: '助眠 ${track.name}',
      child: Container(
        height: height,
        margin: margin,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tokens.border),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [tokens.tint1, tokens.surface],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                key: const Key('sleep-bar-open'),
                behavior: HitTestBehavior.opaque,
                onTap: onOpen,
                child: Semantics(
                  button: true,
                  label: '回到助眠页 ${track.name}',
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
                                : (playing ? tokens.accent : tokens.textFaint),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SleepMoonIcon(
                              size: 9,
                              color: tokens.accent.withValues(alpha: 0.88),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '助眠',
                              style: TextStyle(
                                fontSize: 8.5,
                                height: 1.1,
                                letterSpacing: 1.8,
                                color: tokens.accent.withValues(alpha: 0.88),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            track.name,
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
                            track.detail,
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
              key: const Key('sleep-bar-toggle'),
              label: playing ? '暂停助眠声景' : '继续播放助眠声景',
              onTap: sleep.toggle,
              size: button,
              child: CustomPaint(
                size: const Size.square(13),
                painter: _SleepBarGlyphPainter(
                  color: tokens.text,
                  glyph: playing ? _SleepBarGlyph.pause : _SleepBarGlyph.play,
                ),
              ),
            ),
            _BarButton(
              key: const Key('sleep-bar-stop'),
              label: '关闭助眠声景',
              onTap: sleep.stop,
              size: button,
              child: CustomPaint(
                size: const Size.square(12),
                painter: _SleepBarGlyphPainter(
                  color: tokens.textDim,
                  glyph: _SleepBarGlyph.close,
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

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.onTap,
    required this.child,
    required this.size,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;
  final double size;

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
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}

enum _SleepBarGlyph { play, pause, close }

class _SleepBarGlyphPainter extends CustomPainter {
  const _SleepBarGlyphPainter({required this.color, required this.glyph});

  final Color color;
  final _SleepBarGlyph glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    switch (glyph) {
      case _SleepBarGlyph.play:
        final path = Path()
          ..moveTo(size.width * 0.30, size.height * 0.18)
          ..lineTo(size.width * 0.30, size.height * 0.82)
          ..lineTo(size.width * 0.82, size.height * 0.50)
          ..close();
        canvas.drawPath(path, paint);
      case _SleepBarGlyph.pause:
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
      case _SleepBarGlyph.close:
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
  bool shouldRepaint(covariant _SleepBarGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.glyph != glyph;
}
