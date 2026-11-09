// lib/ui/lyrics_status.dart
//
// 歌词状态行：对译 `src/styles/app.css` 的 `.stage__lyrics-status` 一族
// （:876-933，含加载态的 `::before` 转圈与 `.stage__lyrics-retry`）。播放卡与歌词页
// 两处共用同一条状态行。
//
// 规格逐字：min-height 18、margin-bottom 4、字号 11.5、行高 1.4、`text-faint`
// （`data-state="missing" | "error"` 时换 `dangerInk`）；正文单行省略；与重试按钮
// 间距 8。加载圈 10×10、边框 1.5px、顶边 accent + 其余 accentSoft、0.9s 一圈
// （CSS 是 `border-top-color` + `spin` 关键帧，这里等价画成「整圈 + 一段亮弧」再整体
// 旋转）。重试按钮 min-height 24、左右 padding 9、字号 11.5、accentLight 文字 +
// accentLine 描边 + accentSoft 底、999 圆角。
//
// 本组件是**纯展示**的：不吃 `LyricsState`，只吃 [status] / [loading] / [failed] /
// [showRetry] / [onRetry] 五个标量。状态到这几个标量的映射在调用方，widget 因此能
// 脱离状态层独立测（T16 的设计）。
//
// 与项目既有约定一致的一条：`MediaQuery.disableAnimations`（系统「减少动态效果」）下
// 不建 AnimationController —— 转圈换成同一形状的静止一帧（亮弧停在正上方），不留
// 常驻 ticker（见 `ui/transport.dart` 的加载态与 README 的 reduced-motion 一节）。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 状态行最小高度（CSS `min-height: 18px`）。
const double _kMinHeight = 18;

/// 与下方的间距（CSS `margin: 0 0 4px`）。
const double _kBottomMargin = 4;

/// 字号 / 行高（CSS `font-size: 11.5px; line-height: 1.4`）。
const double _kFontSize = 11.5;
const double _kLineHeight = 1.4;

/// 状态行与重试按钮之间的间距（CSS 容器的 `gap: 8px`）。
const double _kRetryGap = 8;

/// 转圈与正文之间的间距（CSS `::before` 的 `margin-right: 6px`）。
const double _kSpinnerGap = 6;

/// 转圈直径与描边（CSS `width/height: 10px`、`border: 1.5px`）。
const double _kSpinnerSize = 10;
const double _kSpinnerStroke = 1.5;

/// 转一圈的时长（CSS `animation: spin 0.9s linear infinite`）。
const Duration _kSpinPeriod = Duration(milliseconds: 900);

/// 重试按钮规格（CSS `.stage__lyrics-retry`：`min-height: 24px; padding: 0 9px;
/// font-size: 11.5px; border-radius: var(--radius-pill)`）。
const double _kRetryMinHeight = 24;
const double _kRetryHorizontalPadding = 9;
const double _kPillRadius = 999;

/// 歌词状态行。一处状态、一处重试按钮，两处界面共用。
///
/// [loading] 为真时在正文前显示 10×10 转圈；[failed] 为真时正文换 `dangerInk`；
/// [showRetry] 为真时才出现「重试」按钮（原版只在 missing / error 两档给）。
class LyricsStatusLine extends StatelessWidget {
  const LyricsStatusLine({
    required this.status,
    required this.loading,
    required this.failed,
    required this.showRetry,
    required this.onRetry,
    super.key,
  });

  final String status;
  final bool loading;
  final bool failed;
  final bool showRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: _kBottomMargin),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kMinHeight),
        child: Row(
          // CSS 是 `justify-content: center`：两处界面都把状态行居中摆。
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading) ...[
                    SizedBox(
                      key: const Key('lyrics-status-spinner'),
                      width: _kSpinnerSize,
                      height: _kSpinnerSize,
                      child: _Spinner(
                        trackColor: tokens.accentSoft,
                        headColor: tokens.accent,
                      ),
                    ),
                    const SizedBox(width: _kSpinnerGap),
                  ],
                  Flexible(
                    child: Text(
                      status,
                      maxLines: 1,
                      // CSS 的 `overflow: hidden; text-overflow: ellipsis;
                      // white-space: nowrap`：单行、放不下就省略号。
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _kFontSize,
                        height: _kLineHeight,
                        color: failed ? tokens.dangerInk : tokens.textFaint,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (showRetry) ...[
              const SizedBox(width: _kRetryGap),
              _RetryButton(onTap: onRetry),
            ],
          ],
        ),
      ),
    );
  }
}

/// 重试按钮：胶囊、描边 + 浅底，与原版 `.stage__lyrics-retry` 一致。
class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return TextButton(
      key: const Key('lyrics-retry'),
      onPressed: onTap,
      style: TextButton.styleFrom(
        // 最小高 24（不是 Material 默认的 40）；左右 9 由 padding 给，
        // shrinkWrap 让按钮不被撑到 44 的触控最小尺寸 —— 原版就是这个高度，
        // 这里要的是像素一致而不是更大的热区。
        minimumSize: const Size(0, _kRetryMinHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: _kRetryHorizontalPadding,
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: tokens.accentLight,
        backgroundColor: tokens.accentSoft,
        textStyle: const TextStyle(fontSize: _kFontSize),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_kPillRadius),
          side: BorderSide(color: tokens.accentLine),
        ),
      ),
      child: const Text('重试'),
    );
  }
}

/// 加载圈：一整圈 `accentSoft` 轨道 + 正上方一段 90° 的 `accent` 亮弧，整体旋转。
///
/// 原版是「border 三边 35% 强调色 + 顶边全强调色」再 `rotate(360deg)`；两者视觉
/// 等价（CSS 圆环的四条 border 各占 90° 弧），而这里能精确控制 1.5px 描边。
class _Spinner extends StatefulWidget {
  const _Spinner({required this.trackColor, required this.headColor});

  final Color trackColor;
  final Color headColor;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 减少动态效果：不建控制器，直接用 0 相位的那一帧（亮弧停在正上方）。
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller?.dispose();
      _controller = null;
    } else {
      // 只在首次进到「有动画」时建；didChangeDependencies 会因主题等变化重复调用。
      _controller ??= AnimationController(vsync: this, duration: _kSpinPeriod)
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = CustomPaint(
      size: const Size.square(_kSpinnerSize),
      painter: _RingPainter(track: widget.trackColor, head: widget.headColor),
    );
    final controller = _controller;
    if (controller == null) return ring;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) => Transform.rotate(
        angle: 2 * math.pi * controller.value,
        child: child,
      ),
      child: ring,
    );
  }
}

/// 静止的一帧：整圈轨道 + 正上方 90° 亮弧（`-90°` 到 `0°`）。
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.track, required this.head});

  final Color track;
  final Color head;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // 描边居中压在半径上，减掉半个描边宽才不会把圆环画出边界。
    final radius = (size.shortestSide - _kSpinnerStroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kSpinnerStroke;
    canvas.drawCircle(center, radius, trackPaint);

    final headPaint = Paint()
      ..color = head
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kSpinnerStroke
      // 弧的端头要圆：CSS 的四段 border 在圆环上接缝是斜切的，但 1.5px 下肉眼
      // 不可分；圆头更接近 `border-radius: 50%` 的连续观感。
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, math.pi / 2, false, headPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.track != track || oldDelegate.head != head;
}
