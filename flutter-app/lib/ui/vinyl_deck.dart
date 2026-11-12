// lib/ui/vinyl_deck.dart
//
// 唱机碟面：黑胶外圈（跟着唱片转）+ 中间的标签封面（同一相位一起转）+ 固定不动的
// 斜向反光。对译 `src/styles/app.css` 的 `.stage__cover-wrap` / `.stage__vinyl` /
// `.stage__vinyl-disc` / `.stage__cover`（:789-999）与 `src/App.tsx` 的封面结构：
//
//   * **三层结构，顺序与原版一致**（原版靠 DOM 次序 + 定位定层级）：
//     1. 盘面（转）：细密纹路 + 两处柔和高光 + 一道很淡的弧形高光
//     2. 斜向反光（**不转**）：像灯光扫在黑胶上，固定不随唱片转（app.css:815 的注释）
//     3. 标签封面（转）：唱片中间那张标签，占碟面 **62%**（`--vinyl-label`）
//     反光夹在盘面与标签之间 —— 与原版 `.stage__vinyl::after` 被盖在封面下、
//     压在盘面上同一层级关系一致。
//   * 旋转：`cover-rotate 24s linear infinite`；**暂停不摘动画、只冻在当前
//     角度**（CSS `animation-play-state: paused` 的语义）—— 这里用
//     AnimationController.stop/resume + 取当前值，恢复时接着转不跳回 0°。
//     盘面与标签共用**同一个控制器、同一个角度** → 严丝合缝，不会错位。
//   * 播放中光晕呼吸（`.stage__cover-wrap::before` + glow 4.2s，:939-964）。
//
// **纹路是同心环，转起来本身看不出来** —— 真正让人看出「在转」的是那两处柔和高光
// 与那道很淡的弧形高光（唱片轻微翘起时扫过的那道光），它们随盘面转过去。
//
// 封面一律走 `Image.file`：指向缓存目录里的封面文件（见 metadata 层的
// `cover_image.dart`）。文件不存在 / 读不出来都退回生成卡 / 占位碟，**绝不空着**。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../cover/generated_cover.dart';
import '../theme/app_tokens.dart';
import '../theme/vinyl_palette.dart';
import 'generated_cover_view.dart';

/// 标签封面占碟面的比例（`--vinyl-label: 62%`，app.css:773）。
const double _kVinylLabelRatio = 0.62;

/// 细纹的间距与线宽（`--vinyl-low 0 0.6px / 透明 0.6~1.7px`，app.css:797-801）。
const double _kFineGroovePitch = 1.7;
const double _kFineGrooveWidth = 0.6;

class CoverDisc extends StatefulWidget {
  const CoverDisc({
    required this.coverPath,
    required this.size,
    required this.spinning,
    this.vinyl = true,
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

  /// 是否画黑胶外圈（唱机形态）。歌词页那种「只有封面、没有外圈」的形态传 false。
  final bool vinyl;

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
    // 这里**只建控制器**：播放与否依赖 `MediaQuery.disableAnimationsOf`，
    // 而任何 InheritedWidget 依赖都不能在 initState() 里取（框架会抛
    // 「dependOnInheritedWidgetOfExactType<MediaQuery>() was called before
    // _CoverDiscState.initState() completed」红屏）。统一挪到
    // didChangeDependencies() 里同步，见下。
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
  }

  bool get _reducedMotion => MediaQuery.disableAnimationsOf(context);

  /// 把「该不该转」同步到控制器。initState 之后由
  /// [didChangeDependencies]（首次挂载 / MediaQuery 变化）与 [didUpdateWidget]
  /// （spinning 变化）共同调用，避免两处口径分叉。
  void _syncSpin() {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (widget.spinning && !reduced) {
      if (!_spin.isAnimating) {
        // 从暂停恢复：接着当前角度转，不跳回 0°（冻 play-state 的语义）。
        // repeat() 会以 _spin.value 作为 _RepeatingSimulation 的初始相位，
        // 循环区间仍是完整 0→1；不能传 min: _spin.value，那会把循环缩成
        // [当前角度, 1.0]，转一圈就跳回当前角度。
        _spin.repeat();
      }
    } else if (_spin.isAnimating) {
      // 暂停 / 减少动态效果：停在当前角度（不 reset）。
      _spin.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 依赖只能在这里取（initState 里 dependOnInherited 会抛）。
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant CoverDisc old) {
    super.didUpdateWidget(old);
    _syncSpin();
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
    // 唱机形态：封面是唱片中间的标签位（62%）；非唱机形态：封面铺满整张碟。
    final labelSize =
        widget.vinyl ? widget.size * _kVinylLabelRatio : widget.size;

    // 标签封面（转的那部分之一）。唱机形态带一圈暗环 + 落影
    // （app.css:975-978 的 box-shadow：0 0 0 4px #0a0b0d / 0 0 0 5px vinyl-mid
    // / 0 12px 26px -14px rgba(0,0,0,.95)）。
    final label = SizedBox(
      key: const Key('vinyl-label'),
      width: labelSize,
      height: labelSize,
      child: DecoratedBox(
        decoration: widget.vinyl
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tokens.vinylLine, width: 1),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: VinylPalette.grooveC,
                    spreadRadius: 4,
                  ),
                  BoxShadow(
                    color: tokens.vinylMid,
                    spreadRadius: 5,
                  ),
                  BoxShadow(
                    color: VinylPalette.labelShadow,
                    blurRadius: 26,
                    spreadRadius: -14,
                    offset: const Offset(0, 12),
                  ),
                ],
              )
            : const BoxDecoration(shape: BoxShape.circle),
        child: ClipOval(
          child: RepaintBoundary(
            child: SizedBox(
              width: labelSize,
              height: labelSize,
              child: hasFile
                  ? Image.file(
                      File(widget.coverPath),
                      fit: BoxFit.cover,
                      // 碟面按圆形显示尺寸 × 设备像素比解码：一张 500×500
                      // 的图缩到 300 逻辑像素画，没必要留全幅解码位图。
                      cacheWidth: _decodePx(context, labelSize),
                      cacheHeight: _decodePx(context, labelSize),
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
                          size: labelSize,
                        )
                      : const _DiscPlaceholder(),
            ),
          ),
        ),
      ),
    );

    // 盘面（转的那部分之二）：纹路 + 两处柔和高光 + 一道很淡的弧形高光。
    final disc = widget.vinyl
        ? RepaintBoundary(
            child: CustomPaint(
              key: const Key('vinyl-disc-paint'),
              size: Size.square(widget.size),
              painter: _VinylDiscPainter(
                grooveA: VinylPalette.grooveA,
                grooveB: VinylPalette.grooveB,
                grooveC: VinylPalette.grooveC,
                vinylLow: tokens.vinylLow,
                vinylHi: tokens.vinylHi,
                arc: VinylPalette.arc,
              ),
            ),
          )
        : const SizedBox.shrink();

    // 斜向反光（不转）：灯不随唱片转（app.css:815-833）。
    final reflection = widget.vinyl
        ? Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                key: const Key('vinyl-reflection-paint'),
                painter: _VinylReflectionPainter(
                  reflection: VinylPalette.reflection,
                  vinylLow: tokens.vinylLow,
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 播放中的光晕呼吸（::before：accent-rgb 0.42 径向 + blur20，
          // glow 4.2s opacity 0.4↔0.85，播放时 0.7；reduced 保留 0.5 静态）。
          if (widget.spinning)
            Positioned.fill(
              child: _BreathingGlow(accent: tokens.accent, reduced: _reducedMotion),
            ),
          // 碟体落影（不转）：原版 `.stage__vinyl` 的 0 30px 60px -30px。
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: tokens.shadowCard,
            ),
            child: const SizedBox.expand(),
          ),
          /**
           * 转动的那部分：盘面与标签封面用**同一个角度**（同一个控制器、同一次读取）
           * → 同一相位，两层严丝合缝地一起转，中间那道标签位与外圈不会错位。
           *
           * **RepaintBoundary 是这里的性能承重点**：碟面内容（细密纹路）与封面图
           * 本身都是静止的，每帧真正变的只有「转到哪个角度」。不隔离的话，旋转会把
           * 整棵子树标脏，60fps 下每一帧都要重新走一遍布局 + 光栅化；隔离之后引擎
           * 只缓存一次位图，之后每帧只做一次合成变换。
           */
          AnimatedBuilder(
            animation: _spin,
            builder: (context, _) {
              final angle = _spin.value * 2 * math.pi;
              return Stack(
                alignment: Alignment.center,
                children: [
                  Transform.rotate(angle: angle, child: disc),
                  // 反光夹在盘面与标签之间：与原版层级一致（压在盘面上、盖在封面下）。
                  reflection,
                  Transform.rotate(angle: angle, child: label),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 盘面（跟着唱片转的那层）：细密纹路 + 两处柔和高光 + 一道很淡的弧形高光。
///
/// 逐字对译 app.css 的 `.stage__vinyl-disc`（:806-838）与 `.stage__vinyl`（:789-800）：
///   * 细纹 `--vinyl-low 0 0.6px / 透明 0.6~1.7px`（repeating-radial 的第一层）
///   * 粗纹 `#0b0c0e 0~2px / #14161a 2~3px / #0a0b0d 3~4.4px`（第二层）
///   * 两处柔和高光：`circle at 30% 25%`（--vinyl-hi）、`circle at 72% 80%`（--vinyl-low）
///   * 弧形高光：`conic-gradient(from 0deg, transparent 0, rgba(255,255,255,.07) 22deg,
///     transparent 88deg)` —— 很淡，转起来才看得出盘面在动
///   * 内圈亮边 `inset 0 0 0 1px --vinyl-hi` 与暗角 `inset 0 0 38px --vinyl-low`
///
/// 颜色全走参数（来自 [VinylPalette] 与 `context.tokens`）：本文件不出现颜色字面量
/// （ui/ 内的规矩）。
class _VinylDiscPainter extends CustomPainter {
  const _VinylDiscPainter({
    required this.grooveA,
    required this.grooveB,
    required this.grooveC,
    required this.vinylLow,
    required this.vinylHi,
    required this.arc,
  });

  final Color grooveA;
  final Color grooveB;
  final Color grooveC;
  final Color vinylLow;
  final Color vinylHi;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.shortestSide / 2;
    if (radius <= 0) {
      return;
    }

    // 底色：粗纹的深色起点。
    canvas.drawCircle(center, radius, Paint()..color = grooveA);

    // 粗纹：2px / 1px / 1.4px 三色循环（app.css:802-807）。
    // 层级与 CSS 一致：粗纹在下、细纹压在上面（app.css:794-807 的背景列表顺序，
    // 越靠前越在上）。
    final bands = <(double, Color)>[
      (2.0, grooveA),
      (1.0, grooveB),
      (1.4, grooveC),
    ];
    var cursor = 0.0;
    var bandIndex = 0;
    while (cursor < radius) {
      final (width, color) = bands[bandIndex % bands.length];
      final mid = cursor + width / 2;
      if (mid < radius) {
        canvas.drawCircle(
          center,
          mid,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..color = color,
        );
      }
      cursor += width;
      bandIndex++;
    }

    // 细纹：0.6px 的浅色环，每 1.7px 一道（压在粗纹上面）。
    final fine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kFineGrooveWidth
      ..color = vinylLow;
    for (var r = _kFineGroovePitch; r <= radius; r += _kFineGroovePitch) {
      canvas.drawCircle(center, r, fine);
    }

    // 两处柔和高光：CSS 的 `circle at 30% 25%` / `circle at 72% 80%`，
    // 半径 46% / 44%（farthest-corner 的百分比，见 app.css:795-796）。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.5),
          radius: 0.47,
          colors: [vinylHi, vinylHi.withValues(alpha: 0)],
        ).createShader(rect),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.44, 0.6),
          radius: 0.47,
          colors: [vinylLow, vinylLow.withValues(alpha: 0)],
        ).createShader(rect),
    );

    // 暗角：`inset 0 0 38px --vinyl-low`（边缘一圈柔白）—— 用径向渐变近似。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [vinylLow.withValues(alpha: 0), vinylLow],
          stops: const [0.62, 1.0],
        ).createShader(rect),
    );

    // 弧形高光：很淡的一道，转起来才看得出盘面在动。
    // CSS 的 conic 0deg = 12 点方向；Flutter 的 SweepGradient 从 3 点方向起算，
    // 所以起点挪 -π/2。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: math.pi * 3 / 2,
          colors: [
            Colors.transparent,
            arc,
            Colors.transparent,
            Colors.transparent,
          ],
          stops: const [0.0, 22 / 360, 88 / 360, 1.0],
        ).createShader(rect),
    );

    // 内圈亮边：`inset 0 0 0 1px --vinyl-hi`。
    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = vinylHi,
    );
  }

  @override
  bool shouldRepaint(covariant _VinylDiscPainter old) =>
      old.grooveA != grooveA ||
      old.grooveB != grooveB ||
      old.grooveC != grooveC ||
      old.vinylLow != vinylLow ||
      old.vinylHi != vinylHi ||
      old.arc != arc;
}

/// 斜向反光（固定不随唱片转）：`conic-gradient(from 205deg, transparent 0deg,
/// rgba(255,255,255,.085) 34deg, transparent 78deg, transparent 220deg,
/// var(--vinyl-low) 268deg, transparent 320deg)`，`mix-blend-mode: screen`、
/// `opacity: .85`（app.css:816-833）。
class _VinylReflectionPainter extends CustomPainter {
  const _VinylReflectionPainter({
    required this.reflection,
    required this.vinylLow,
  });

  final Color reflection;
  final Color vinylLow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.shortestSide / 2;
    if (radius <= 0) {
      return;
    }
    // opacity: .85 折进每个色标（CSS 的 opacity 作用在整层上）。
    Color dim(Color c) => c.withValues(alpha: c.a * 0.85);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = SweepGradient(
          // CSS 的 205deg 从 12 点方向起算；Flutter 从 3 点方向起算 → 挪 -90deg。
          startAngle: math.pi * (205 - 90) / 180,
          endAngle: math.pi * (205 - 90) / 180 + math.pi * 2,
          colors: [
            Colors.transparent,
            dim(reflection),
            Colors.transparent,
            Colors.transparent,
            dim(vinylLow),
            Colors.transparent,
            Colors.transparent,
          ],
          stops: const [
            0.0,
            34 / 360,
            78 / 360,
            220 / 360,
            268 / 360,
            320 / 360,
            1.0,
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _VinylReflectionPainter old) =>
      old.reflection != reflection || old.vinylLow != vinylLow;
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

/// 目标解码边长：显示尺寸 × 设备像素比，夹在 [64, 512]。
///
/// 碟面最大也就 ~340 逻辑像素，封面文件普遍 ≤500px；按显示尺寸解码能省下
/// 解码时间、图像缓存占用与每帧采样成本，而 2× 上限保证高分屏上不吃亏。
int _decodePx(BuildContext context, double logicalSize) {
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  final px = (logicalSize * dpr).round();
  return px.clamp(64, 512);
}

/// 没有封面且无生成卡信息时的占位碟：与盘面同形的暗底 + 一个音符。
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
