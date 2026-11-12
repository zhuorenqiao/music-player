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

import '../cover/generated_cover.dart';
import '../theme/app_tokens.dart';
import 'generated_cover_view.dart';

/// 行内缩略图：10 圆角、1px `progressTrack` 描边。
///
/// 封面源三级（M2b T10）：[path] 文件在 → `Image.file`；不在（或空）→
/// [fallbackArtist] 非空时画**生成卡**（离线、确定性，同歌手恒同图，
/// 对译 React `coverForDisplay` 的第 4 级）；再退音符图标（[fallbackArtist]
/// 为空 = 调用方没给生成卡信息，M1 原行为，测试与旧调用点不受影响）。
///
/// 文件可能被清（缓存目录不是数据目录）：先同步判存在，`errorBuilder`
/// 再兜一道解码失败 —— 路径坏了绝不抛。
class CoverThumb extends StatelessWidget {
  const CoverThumb({
    required this.path,
    required this.size,
    this.fallbackArtist = '',
    this.fallbackTitle = '',
    super.key,
  });

  /// 封面文件绝对路径；空串表示没有封面。
  final String path;

  /// 边长（列表行 44、最近行 40）。
  final double size;

  /// 生成卡派生字段（resolver 第 4 级）；空串 = 不画生成卡，退音符。
  final String fallbackArtist;
  final String fallbackTitle;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final hasFile = path.isNotEmpty && _existsCached(path);
    final useGenerated = !hasFile && fallbackArtist.isNotEmpty;
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
              // 缩略图按**显示尺寸的 2 倍**解码，别把 500×500 的原图整幅塞进
              // 记忆缓存再缩到 44 逻辑像素画：解码开销、内存与每帧的采样成本
              // 都按面积走，列表一滚就是几十张。设备像素比高时 2× 仍是清晰
              // 上限，再大肉眼也看不出来。
              cacheWidth: _decodePx(context, size),
              cacheHeight: _decodePx(context, size),
              // 切歌时保留上一帧，避免缩略图闪成白块
              gaplessPlayback: true,
              errorBuilder: (imageContext, error, stack) => fallback,
            )
          : useGenerated
              ? GeneratedCoverView(
                  spec: generatedCoverSpec(fallbackArtist, fallbackTitle),
                  size: size,
                )
              : fallback,
    );
  }
}

/// `path` 是否真的在磁盘上，结果按路径缓存在会话级的小表里。
///
/// **`existsSync` 是同步 `stat` 系统调用**，而本件是列表行里的一颗缩略图：
/// 面板会因为换肤滑块、封面到货、播放态变化等无关原因重建，每次重建都要对每
/// 一行重跑一遍 `stat` —— 一屏 12 行、播放中每秒数次，就是每秒几十次系统调用
/// 落在 UI 线程上。封面缓存目录里的文件一旦落盘在本进程生命周期内不会被改写
/// （同名文件是哈希命名，内容变了就是新名字），所以缓存「存在」是安全的。
///
/// **只缓存正结果**：阴性结果不缓存 —— 线上预取正在往这个目录里写文件，
/// 「此刻还没有」不代表「以后也没有」，缓存它会永远显示占位图。
/// 文件真的在运行中被删掉时，`errorBuilder` 仍然兜得住（见上方的构造）。
final Map<String, bool> _existsMemo = <String, bool>{};

bool _existsCached(String path) {
  final known = _existsMemo[path];
  if (known == true) return true;
  final exists = File(path).existsSync();
  if (exists) _existsMemo[path] = true;
  return exists;
}

/// 目标解码边长：显示尺寸 × 设备像素比，夹在 [32, 512]。
///
/// 上界 512 是为了两件事：封面文件普遍 ≤500px（原图再大也裁不出更多细节），
/// 以及同一个文件在「行内缩略图 / 灯箱」两处复用时不会因为 cacheWidth 差别太大
/// 而各解码一份（Flutter 的图像缓存键含 cacheWidth/Height）。
int _decodePx(BuildContext context, double logicalSize) {
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  final px = (logicalSize * dpr).round();
  return px.clamp(32, 512);
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
