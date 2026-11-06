// lib/ui/cover_thumb.dart
//
// 行内小封面 + 音柱。
//
// 对译 `src/styles/app.css` 的 `.track__cover` / `.recent__cover`（:3503、:3420）与
// `.track__bars` / `@keyframes bars`（:3601-3647）。
//
// 两条取舍：
//   - 封面一律走 `Image.file`，先同步看一眼文件在不在：封面在缓存目录里，可能被
//     清掉。`errorBuilder` 再兜一道解码失败 —— 路径坏了只退音符图标，绝不抛
//     （列表里一条坏数据不该把整页带崩）。
//   - 音柱在「播放中」才建动画对象（一秒一轮，三根各延迟 0/180/360ms，高度
//     4→13px）；静止时直接给 CSS 的 5 / 9 / 6 三档固定高度。
//     `MediaQuery.disableAnimations`（系统「减少动态效果」）下连动画对象都不建。
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 行内缩略图：10 圆角、1px `progressTrack` 描边；没有图就退音符图标。
class CoverThumb extends StatelessWidget {
  const CoverThumb({required this.path, required this.size, super.key});

  /// 封面文件绝对路径；空串表示没有封面。
  final String path;

  /// 边长（列表行 44、最近行 40）。
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final hasFile = path.isNotEmpty && File(path).existsSync();
    final fallback = Icon(
      Icons.music_note,
      size: size * 0.4,
      color: tokens.textFaint,
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.progressTrack),
        color: tokens.progressTrack,
      ),
      child: hasFile
          ? Image.file(
              File(path),
              fit: BoxFit.cover,
              // 切歌时保留上一帧，避免缩略图闪成白块
              gaplessPlayback: true,
              errorBuilder: (imageContext, error, stack) => fallback,
            )
          : fallback,
    );
  }
}

/// 三根 2.5px 音柱，只在当前曲目那一行的歌手行尾出现。
///
/// 静止高度 5 / 9 / 6 逐根对齐 `.track__bars i:nth-child(n)`；播放中按
/// `@keyframes bars`（0%/100% 4px、50% 13px）起伏，三根依次错开 180ms。
class BarsIndicator extends StatelessWidget {
  const BarsIndicator({required this.playing, super.key});

  final bool playing;

  /// 静止高度（CSS `.track__bars i:nth-child(n)`）。
  static const List<double> restHeights = <double>[5, 9, 6];

  /// 动画两端（CSS `@keyframes bars`）。
  static const double minHeight = 4;
  static const double maxHeight = 13;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 减少动态效果：不建动画，直接静止 —— 与「播放中」与否无关
    final animate = playing && !MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      key: const Key('bars-indicator'),
      width: 12,
      height: maxHeight,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: animate
            ? _AnimatedBars(
                key: const Key('bars-animation'),
                color: tokens.accent,
              )
            : _Bars(heights: restHeights, color: tokens.accent),
      ),
    );
  }
}

/// 一组音柱：`gap: 2px`、底部对齐，宽度合计 11.5（CSS 的 3×2.5 + 2×2）。
class _Bars extends StatelessWidget {
  const _Bars({required this.heights, required this.color});

  final List<double> heights;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < heights.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          SizedBox(
            key: Key('bar-$i'),
            width: 2.5,
            height: heights[i],
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 播放中的音柱：一个 1s 循环的控制器，三根各错开一个相位。
class _AnimatedBars extends StatefulWidget {
  const _AnimatedBars({required this.color, super.key});

  final Color color;

  @override
  State<_AnimatedBars> createState() => _AnimatedBarsState();
}

class _AnimatedBarsState extends State<_AnimatedBars>
    with SingleTickerProviderStateMixin {
  /// CSS 的 `animation-delay`：0 / 0.18s / 0.36s（周期 1s → 换成相位偏移）。
  static const List<double> _delays = <double>[0, 0.18, 0.36];

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// `@keyframes bars`：0% / 100% 低、50% 高，段内 ease-in-out。
  double _heightAt(int index) {
    final phase = (_controller.value - _delays[index]) % 1;
    final ramp = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    final eased = Curves.easeInOut.transform(ramp);
    return BarsIndicator.minHeight +
        (BarsIndicator.maxHeight - BarsIndicator.minHeight) * eased;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => _Bars(
        heights: [for (var i = 0; i < _delays.length; i++) _heightAt(i)],
        color: widget.color,
      ),
    );
  }
}
