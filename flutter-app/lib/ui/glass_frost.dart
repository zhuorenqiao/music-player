// lib/ui/glass_frost.dart
//
// 玻璃卡（M4 重建）：逐条对译 `src/styles/app.css` 的 `.player` / `.panel` /
// `.app__main` 那三套「透明 + 磨砂」，**按 CSS 的绘制层序**重排。
//
// ---- CSS 事实（app.css:430-507 / 4797-4873 / 1422-1449）----
//   · `.player` / `.panel` / `.app__main` 自己画：卡面渐变（165deg / 170deg）、
//     1px 描边、`--shadow-card`、`inset 0 1px 0 rgb(255 255 255 / frost*0.22)`、
//     `backdrop-filter: blur(16px+frost*26px) saturate(100%+frost*65%)`。
//   · `.glass-frost`（z-index:-2，元素里第一个子节点）：当前封面 `<img>`，
//     `inset:-12% / 124%`、`filter: blur(44px) saturate(1.6) brightness(0.7)`、
//     `opacity: frost*--frost-cover-opacity`。
//   · `::before`（z-index:-1）：磨砂膜，`opacity: frost`，五层背景
//     （150deg sheen / 160deg veil / 左上 bloom 椭圆 / 右下 tint 椭圆 / 160px 颗粒）。
//   · 负 z-index 子节点画在**元素的背景之上、内容之下**，所以真实层序是：
//         页面底色 → 卡面渐变 → 模糊封面色雾 → 磨砂膜 → 内容
//
// ---- 旧实现错在哪（用户「透明和磨砂的效果很差」）----
//   1. 整个玻璃层是 `GlassFrostLayer(child: 已经画好渐变的卡片)` —— 卡面渐变
//      最后画，把色雾与磨砂膜全压在下面：磨砂调得再高也只是一层几乎看不见的雾。
//   2. 封面 `<img>` 只是 `Image.file` 原图，`blur(44px) saturate brightness`
//      三个滤镜**一个都没接**（token 里有 `frostCoverBlur/Sat/Brightness` 但没人用）：
//      玻璃后面是一张锐利照片在 50% 透明度下透出来，而不是 React 那种一片色雾。
//   3. 少了 `inset 0 1px 0` 顶部高光；渐变角度写成 135deg（CSS 是 165/170deg）。
//   4. 颗粒用 8px 网格的稀疏白点，观感是「脏点」而不是胶片颗粒。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

/// CSS 角度（0deg = 朝上，顺时针）→ Flutter 的渐变轴。
///
/// `linear-gradient(<deg>, …)` 的方向向量在屏幕坐标（x 向右、y 向下）里是
/// `(sin θ, -cos θ)`；`begin/end` 取这条轴的 ±，Flutter 会按盒子把两端映射成
/// 对齐点。旧实现一律写 `topLeft→bottomRight`（= 135deg），与 165/170deg
/// 差出来的那点倾角正是「卡面看着不像 React」的来源之一。
({Alignment begin, Alignment end}) cssGradientAxis(double degrees) {
  final rad = degrees * math.pi / 180;
  final dx = math.sin(rad);
  final dy = -math.cos(rad);
  return (
    begin: Alignment(-dx, -dy),
    end: Alignment(dx, dy),
  );
}

/// `saturate()` + `brightness()` 合成为一个 4×5 颜色矩阵（先饱和后乘亮度，
/// 与 CSS 滤镜列表从左到右的作用顺序一致）。
List<double> saturateBrightnessMatrix(double saturate, double brightness) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722; // Rec.709 亮度权重（CSS/浏览器同口径）
  final sr = (1 - saturate) * lr;
  final sg = (1 - saturate) * lg;
  final sb = (1 - saturate) * lb;
  final b = brightness;
  return <double>[
    (sr + saturate) * b, sg * b, sb * b, 0, 0, //
    sr * b, (sg + saturate) * b, sb * b, 0, 0, //
    sr * b, sg * b, (sb + saturate) * b, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// 磨砂玻璃卡：卡面渐变 + 模糊封面色雾 + 磨砂膜 + 顶部高光，全部按 CSS 层序。
///
/// [frostLevel] == 0 且不给 [colorA]/[colorB] 时原样返回 child（零开销，
/// 纯展示 / 测试 harness 的既有契约）。
class GlassFrostLayer extends StatelessWidget {
  const GlassFrostLayer({
    required this.child,
    required this.coverPath,
    this.frostLevel = 0,
    this.glassLevel = 1,
    this.colorA,
    this.colorB,
    this.gradientDegrees = 165,
    this.shadow,
    super.key,
  });

  final Widget child;

  /// 玻璃后垫的封面路径（`coverForDisplay` 的当前那张）；空串不垫。
  final String coverPath;

  /// 磨砂强度 0~1（ThemeState.frostLevel）。
  final double frostLevel;

  /// 卡面不透明度 0~1（ThemeState.glassLevel）：卡面渐变色的 alpha 按它缩放
  /// （CSS `color-mix(in srgb, --card-a calc(--glass-level * 100%), transparent)`）。
  final double glassLevel;

  /// 卡面渐变两端色（**未缩放**的 token 原色，如 `cardA/cardB`）。
  /// 传了就由本层在磨砂层之下画卡面；不传就沿用调用方自己画好的卡面。
  final Color? colorA;
  final Color? colorB;

  /// 卡面渐变角度（`.player` = 165、`.panel` = 170，app.css:444/:1435）。
  final double gradientDegrees;

  /// 卡外投影（CSS `box-shadow: var(--shadow-card)`）。
  ///
  /// **必须由本层在最外层画**：卡面渐变已经搬到本层内部，投影若还留在调用方的
  /// 装饰里，就会画在卡面/磨砂层之上（实测表现为播放列上盖着一块灰色板）。
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final frost = frostLevel.clamp(0.0, 1.0);
    final level = glassLevel.clamp(0.0, 1.0);
    final hasFace = colorA != null && colorB != null;
    if (frost <= 0 && !hasFace) return child;

    final axis = cssGradientAxis(gradientDegrees);
    final face = hasFace
        ? DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: axis.begin,
                end: axis.end,
                colors: [
                  colorA!.withValues(alpha: colorA!.a * level),
                  colorB!.withValues(alpha: colorB!.a * level),
                ],
              ),
            ),
          )
        : null;

    // 1~5 全是**静态**装饰：卡面渐变、背景模糊、封面雾、磨砂膜、上沿高光。
    // 它们单独装进一个 RepaintBoundary —— 内容层（黑胶旋转、频谱、歌词滚动）
    // 逐帧重绘时不会把它们带着一起重绘。
    //
    // 这条对 Windows 端是决定性的一步：`BackdropFilter` 的整卡大半径高斯模糊
    // （sigma 16+frost*26，覆盖一整张卡）是栅格化阶段才执行的图层，它所在的
    // 边界一旦被重绘，模糊就每帧重算一遍。原来装饰层和内容层同在一个 Stack、
    // 同一个边界里，于是播放（黑胶/频谱逐帧）、滚动列表、拖动缩放窗口这三种
    // 情况都会让整卡重做一次模糊 —— 核显机型上正好把 GPU 顶到接近满载。
    // 隔开边界之后，模糊只在窗口尺寸/主题变化时重算一次，播放中每帧只剩
    // 黑胶和频谱自己那块小面积绘制。
    final decorations = Stack(
      children: [
        // 1 · 背景模糊：`backdrop-filter: blur(16+frost*26) saturate(100%+frost*65%)`
        //     （app.css:453-458）。放在最底：它只能糊到卡片**后面**的页面底色。
        //     frost=0 时不挂（CSS 在 frost=0 时 blur 恒为 16px，但卡面本身
        //     84% 不透明，那 16px 在整屏平滑渐变上不可见；省一层全屏滤镜）。
        if (frost > 0)
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.compose(
                outer: ui.ColorFilter.saturation(1 + frost * 0.65),
                inner: ui.ImageFilter.blur(
                  sigmaX: 16 + frost * 26,
                  sigmaY: 16 + frost * 26,
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        // 2 · 卡面渐变（alpha 跟「透明」滑杆）
        if (face != null) Positioned.fill(child: face),
        // 3 · 玻璃后封面雾（`.glass-frost`，z-index -2）
        if (frost > 0 && coverPath.isNotEmpty)
          Positioned.fill(
            child: Opacity(
              opacity: (frost * tokens.frostCoverOpacity).clamp(0.0, 1.0),
              child: _CoverFog(path: coverPath, tokens: tokens),
            ),
          ),
        // 4 · 磨砂膜（`::before`，z-index -1）
        if (frost > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: frost,
                // 膜本身是静态画面：单独栅格化一次，之后每帧只做图层合成。
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _FrostMembranePainter(tokens: tokens),
                    isComplex: true,
                    willChange: false,
                  ),
                ),
              ),
            ),
          ),
        // 5 · `inset 0 1px 0 rgb(255 255 255 / frost*0.22)`：玻璃上沿那道细高光
        if (frost > 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 1,
            child: IgnorePointer(
              child: ColoredBox(
                key: const Key('glass-top-highlight'),
                color: const Color(0xFFFFFFFF).withValues(alpha: frost * 0.22),
              ),
            ),
          ),
      ],
    );

    final surface = ClipRRect(
      borderRadius: BorderRadius.circular(kRadiusXl),
      child: Stack(
        // 内容（最后一个非定位子节点）决定盒子大小；装饰层用 Positioned.fill
        // 铺满它 —— 这样窄屏「高度由内容决定」的卡片也不会拿到无界约束。
        // （内层 Stack 只有定位子节点，会直接取满 tighten 后的约束。）
        children: [
          Positioned.fill(child: RepaintBoundary(child: decorations)),
          // 6 · 内容（画在最后 = 最上层）
          child,
        ],
      ),
    );

    // 卡外投影：**只画在盒子外面**（CSS `box-shadow` 的语义）。
    //
    // Flutter 的 BoxShadow 是「把整个盒子填一遍再模糊」，盒子内部那块会被
    // 卡面（半透明渐变）透出来 —— 透明度调高时整列会长出一块灰板，而 CSS 里
    // 盒子下面根本没有阴影。所以这里自己画「盒子外那一圈」。
    // 卡外投影同样是静态的：60px 的大半径阴影（sigma≈30）盖住一整块环，每帧
    // 重画一次也不便宜，所以和装饰层一样单独栅格化一次。它画在卡面**之后**
    // （z 更靠下），顺序与原来的 CustomPaint(child: surface) 一致。
    if (shadow == null || shadow!.isEmpty) return surface;
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _OutsideShadowPainter(shadows: shadow!)),
          ),
        ),
        surface,
      ],
    );
  }
}

/// 把 `box-shadow` 画成盒子外面的环：盒子内部留空（挖掉圆角矩形）。
class _OutsideShadowPainter extends CustomPainter {
  const _OutsideShadowPainter({required this.shadows});

  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    // 卡片在换主题/换档位的那一帧可能拿到 0 尺寸；负 spread 会把空盒子再缩成
    // 负宽高，RRect 构造直接断言失败（debug 下崩在这一帧）。
    if (size.isEmpty) return;
    final box = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(math.min(kRadiusXl, size.shortestSide / 2)),
    );
    final hole = Path()..addRRect(box);
    for (final s in shadows) {
      final spread = s.spreadRadius;
      final rect = (Offset.zero & size).shift(s.offset).inflate(spread);
      if (rect.width <= 0 || rect.height <= 0) continue;
      final radius = math.max(0.0, kRadiusXl + spread);
      final shape = Path()
        ..addRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(math.min(radius, rect.shortestSide / 2)),
          ),
        );
      final ring = Path.combine(PathOperation.difference, shape, hole);
      final paint = Paint()..color = s.color;
      if (s.blurRadius > 0) {
        // Skia 的 BoxShadow 模糊半径 ≈ 2σ。
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurRadius / 2);
      }
      canvas.drawPath(ring, paint);
    }
  }

  @override
  bool shouldRepaint(_OutsideShadowPainter old) => old.shadows != shadows;
}

/// `.glass-frost img`：当前封面 → 一片色雾。
///
/// CSS 是 `<img>` 铺到 124%（inset -12%）再套 `blur(44px) saturate(1.6)
/// brightness(0.7)`。这里同样 1.24 倍外扩，模糊 + 饱和/亮度矩阵走
/// `ImageFiltered`（先模糊、后调色，与 CSS 滤镜顺序一致）。解码按 256px 宽
/// 预缩：44px 的高斯模糊本来就把细节抹平了，省掉一次大图解码。
class _CoverFog extends StatelessWidget {
  const _CoverFog({required this.path, required this.tokens});

  final String path;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.compose(
          outer: ui.ColorFilter.matrix(
            saturateBrightnessMatrix(tokens.frostCoverSat, tokens.frostCoverBrightness),
          ),
          inner: ui.ImageFilter.blur(
            sigmaX: tokens.frostCoverBlur,
            sigmaY: tokens.frostCoverBlur,
          ),
        ),
        child: Transform.scale(
          scale: 1.24,
          child: Image.file(
            File(path),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            cacheWidth: 256,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// 磨砂膜 painter：`::before` 的五层背景，逐条对译 app.css:473-479。
class _FrostMembranePainter extends CustomPainter {
  _FrostMembranePainter({required this.tokens});

  final AppTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 1) sheen：`linear-gradient(150deg, sheen-a, sheen-b 58%, transparent)`
    final sheenAxis = cssGradientAxis(150);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          _point(size, sheenAxis.begin),
          _point(size, sheenAxis.end),
          [tokens.frostSheenA, tokens.frostSheenB, tokens.frostSheenA.withValues(alpha: 0)],
          [0, 0.58, 1],
        ),
    );
    // 2) veil：`linear-gradient(160deg, veil-a, veil-b)`
    final veilAxis = cssGradientAxis(160);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          _point(size, veilAxis.begin),
          _point(size, veilAxis.end),
          [tokens.frostVeilA, tokens.frostVeilB],
        ),
    );
    // 3) bloom：`radial-gradient(120% 90% at 16% 0%, bloom, transparent 62%)`
    _ellipseRadial(
      canvas,
      size,
      center: Offset(size.width * 0.16, 0),
      rx: size.width * 1.2,
      ry: size.height * 0.9,
      color: tokens.frostBloom,
      stop: 0.62,
    );
    // 4) tint：`radial-gradient(90% 80% at 100% 100%, tint, transparent 64%)`
    _ellipseRadial(
      canvas,
      size,
      center: Offset(size.width, size.height),
      rx: size.width * 0.9,
      ry: size.height * 0.8,
      color: tokens.frostTint,
      stop: 0.64,
    );
    // 5) 颗粒：CSS 是 160px 平铺的 feTurbulence 灰度噪点（两层 0.5 不透明度）。
    //    这里用确定性的明/暗点成对铺满（网格 4px），比旧版 8px 稀疏白点更像胶片颗粒。
    _paintGrain(canvas, size);
  }

  /// CSS 的 `at 16% 0%` 之类是**椭圆**径向：Flutter 的 radial 只有圆，所以
  /// 先把画布按 ry/rx 压扁，再按 rx 画圆。
  void _ellipseRadial(
    Canvas canvas,
    Size size, {
    required Offset center,
    required double rx,
    required double ry,
    required Color color,
    required double stop,
  }) {
    if (rx <= 0 || ry <= 0) return;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1, ry / rx);
    final paint = Paint()
      ..shader = ui.Gradient.radial(
        Offset.zero,
        rx,
        [color, color.withValues(alpha: 0)],
        [0, stop],
      );
    // 压扁后的坐标系里铺一张足够大的矩形；shader 默认 clamp，超出即全透明。
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: size.width * 3, height: size.height * 3 * (rx / ry)),
      paint,
    );
    canvas.restore();
  }

  void _paintGrain(Canvas canvas, Size size) {
    final light = <double>[];
    final dark = <double>[];
    const cell = 4.0;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        // 确定性伪随机（同一坐标恒同一结果）：线性同余，不引第三方随机源。
        final h = (x.toInt() * 73856093) ^ (y.toInt() * 19349663);
        final v = (h.abs() % 1000) / 1000.0;
        if (v > 0.55) continue; // 45% 的格子留空，避免糊成一层灰纱
        final px = x + ((h >> 3) % 100) / 100 * cell;
        final py = y + ((h >> 9) % 100) / 100 * cell;
        (v < 0.275 ? light : dark).addAll([px, py]);
      }
    }
    if (light.isNotEmpty) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(light),
        Paint()
          ..color = const Color(0x18FFFFFF)
          ..strokeWidth = 1.1
          ..strokeCap = ui.StrokeCap.round,
      );
    }
    if (dark.isNotEmpty) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(dark),
        Paint()
          ..color = const Color(0x10000000)
          ..strokeWidth = 1.1
          ..strokeCap = ui.StrokeCap.round,
      );
    }
  }

  Offset _point(Size size, Alignment a) => Offset(
    (a.x + 1) / 2 * size.width,
    (a.y + 1) / 2 * size.height,
  );

  @override
  bool shouldRepaint(_FrostMembranePainter oldDelegate) => oldDelegate.tokens != tokens;
}
