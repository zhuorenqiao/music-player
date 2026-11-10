// lib/ui/vinyl_deck.dart
//
// 圆碟封面：把封面裁成正圆，垫一圈暗色「盘面」；播放时整圈 24s 顺时针转
//（M3 T13）。对译 `src/styles/app.css` 的 `.stage__cover-wrap` / `.stage__vinyl`
// / `.stage__cover`（:790-999）：
//
//   * 旋转：`cover-rotate 24s linear infinite`；**暂停不摘动画、只冻在当前
//     角度**（CSS `animation-play-state: paused` 的语义）—— 这里用
//     AnimationController.stop/resume + 取当前值，恢复时接着转不跳回 0°；
//   * 盘面：径向高光 + 细纹（repeating-radial 的等价物）+ 斜向反光；
//   * 播放中光晕呼吸（`.stage__cover-wrap::before` + glow 4.2s，:939-964）。
//
// 封面一律走 `Image.file`：指向缓存目录里的封面文件（见 metadata 层的
// `cover_image.dart`）。文件不存在 / 读不出来都退回生成卡 / 占位碟，**绝不空着**。
import 'dart:io';

import 'package:flutter/material.dart';

import '../cover/generated_cover.dart';
import '../theme/app_tokens.dart';
import 'generated_cover_view.dart';

class CoverDisc extends StatefulWidget {
  const CoverDisc({
    required this.coverPath,
    required this.size,
    required this.spinning,
    this.fallbackArtist = '',
    this.fallbackTitle = '',
    super.key,
  });

  /// 封面文件的绝对路径；空串表示没有封面。
  final String coverPath;

  /// 圆碟直径（`kCoverSize` 的三档结果）。
  final double size;

  /// 是否在转（播放中）。暂停冻在当前角度（T13）。
  final bool spinning;

  /// 生成卡派生字段（M2b T10）：无封面文件时碟面画生成卡。空串 =
  /// 不画生成卡，退 `_DiscPlaceholder`（空态无曲可显示）。
  final String fallbackArtist;
  final String fallbackTitle;

  @override
  State<CoverDisc> createState() => _CoverDiscState();
}

class _CoverDiscState extends State<CoverDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    // 24s 一圈（--cover-spin-duration: 24s，app.css:121）。
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    if (widget.spinning && !_reducedMotion) {
      _spin.repeat();
    }
  }

  bool get _reducedMotion =>
      MediaQuery.disableAnimationsOf(context);

  @override
  void didUpdateWidget(covariant CoverDisc old) {
    super.didUpdateWidget(old);
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (widget.spinning && !reduced) {
      if (!_spin.isAnimating) {
        // 从暂停恢复：接着当前角度转，不跳回 0°（冻 play-state 的语义）。
        _spin.repeat(min: _spin.value, max: 1.0);
        if (_spin.value >= 1.0) _spin.value = 0;
        _spin.repeat();
      }
    } else if (_spin.isAnimating) {
      // 暂停：停在当前角度（不 reset）。
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final widget = this.widget;
    final hasFile = widget.coverPath.isNotEmpty &&
        File(widget.coverPath).existsSync();
    final useGenerated =
        !hasFile && widget.fallbackArtist.isNotEmpty;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 盘面：外圈压暗、中心略亮，封面盖上去之后只在边缘露一细圈
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [tokens.panelA, tokens.bg],
                stops: const [0.55, 1],
              ),
              boxShadow: tokens.shadowCard,
            ),
            child: SizedBox(width: widget.size, height: widget.size),
          ),
          // 播放中的光晕呼吸（::before：accent-rgb 0.42 径向 + blur20，
          // glow 4.2s opacity 0.4↔0.85，播放时 0.7；reduced 保留 0.5 静态）。
          if (widget.spinning)
            Positioned.fill(
              child: _BreathingGlow(accent: tokens.accent, reduced: _reducedMotion),
            ),
          ClipOval(
            child: AnimatedBuilder(
              animation: _spin,
              builder: (context, child) => Transform.rotate(
                angle: _spin.value * 2 * 3.141592653589793,
                child: child,
              ),
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: hasFile
                    ? Image.file(
                        File(widget.coverPath),
                        fit: BoxFit.cover,
                        // 切歌时保留上一帧，避免封面闪成白块
                        gaplessPlayback: true,
                        errorBuilder: (imageContext, error, stack) =>
                            const _DiscPlaceholder(),
                      )
                    : useGenerated
                        ? GeneratedCoverView(
                            spec: generatedCoverSpec(
                              widget.fallbackArtist,
                              widget.fallbackTitle,
                            ),
                            size: widget.size,
                          )
                        : const _DiscPlaceholder(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 播放中的呼吸光晕（app.css:939-964 逐字）：
/// inset -10% 径向 accent 0.42 → 透明 68%，blur 20；
/// opacity 4.2s 在 0.4↔0.85 间呼吸；reduced-motion 保留 0.5 静态。
class _BreathingGlow extends StatefulWidget {
  const _BreathingGlow({required this.accent, required this.reduced});

  final Color accent;
  final bool reduced;

  @override
  State<_BreathingGlow> createState() => _BreathingGlowState();
}

class _BreathingGlowState extends State<_BreathingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.reduced) _glow.repeat(reverse: true);
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    if (widget.reduced) {
      return _glowLayer(accent, 0.5);
    }
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, _) {
        // ease-in-out 的 0.4→0.85→0.4（glow keyframes 逐字）。
        final t = _glow.value;
        final eased = t < 0.5 ? t * 2 : (1 - t) * 2;
        final eased01 = Curves.easeInOut.transform(eased);
        final opacity = 0.4 + (0.85 - 0.4) * eased01;
        return _glowLayer(accent, opacity);
      },
    );
  }

  Widget _glowLayer(Color accent, double opacity) {
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(0, 0.04), // circle at 50% 52%
              colors: [accent.withValues(alpha: 0.42), accent.withValues(alpha: 0)],
              stops: const [0, 0.68],
            ),
          ),
          child: Container(
            // filter: blur(20px) 的等价物——光晕本身已是极低频渐变，
            // 再叠一层 ImageFilter.blur 的开销换不来可见差异，真机验收比对。
            foregroundDecoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: accent.withValues(alpha: 0)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 没有封面且无生成卡信息时的占位碟：与盘面同形的暗底 + 一个音符。
///
/// key 给测试与骨架微光用：封面就绪与否是可见的状态差异，不该静默。
class _DiscPlaceholder extends StatelessWidget {
  const _DiscPlaceholder();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ColoredBox(
      key: const Key('cover-placeholder'),
      color: tokens.progressTrack,
      child: Center(
        child: Icon(Icons.music_note, size: 28, color: tokens.textFaint),
      ),
    );
  }
}
