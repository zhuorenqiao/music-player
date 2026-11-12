// lib/ui/glass_frost.dart
//
// 磨砂玻璃层（M3 T7）：对译 app.css:461-504 的 `.player::before, .panel::before`
// （磨砂膜五层背景）与 `.glass-frost`（玻璃后封面垫）。
//
// 结构（frostLevel>0 时挂进播放卡 / 面板的 Stack）：
//   1. BackdropFilter：blur(16 + frost*26)、saturate(1 + frost*0.65)（:450-455 逐字）
//   2. 膜层（opacity = frostLevel）：sheen 线性渐变 + veil 渐变 + bloom 径向
//      + frostTint 径向（噪点颗粒在 Flutter 侧以 CustomPainter 白点近似，
//      视觉验收真机比对——计划 Global Constraints 的裁定）
//   3. 玻璃后封面垫（z 序在膜之下、卡面之上）：当前封面模糊图，
//      opacity = frostLevel * frostCoverOpacity，blur/sat/brightness 走 token。
//
// glassLevel（透明度）不在本件：它是卡面渐变色的 alpha 缩放，直接在
// 播放卡 / 面板的 DecoratedBox 里对 cardA/cardB 做 withValues(alpha: × level)。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';

/// 磨砂层组合件：包住 child（卡面本体），frost==0 时原样返回（零开销）。
///
/// [frostLevel] 与 [glassLevel] 由调用方注入（Stage/Panel 从 ThemeState 读；
/// 纯展示组件不依赖 provider —— M2b 的「无 provider 也能画」契约延续）。
class GlassFrostLayer extends StatelessWidget {
  const GlassFrostLayer({
    required this.child,
    required this.coverPath,
    this.frostLevel = 0,
    super.key,
  });

  final Widget child;

  /// 玻璃后垫的封面路径（coverForDisplay 的当前那张）；空串不垫。
  final String coverPath;

  /// 磨砂强度 0~1（ThemeState.frostLevel）；0 = 不挂磨砂层。
  final double frostLevel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final frost = frostLevel.clamp(0.0, 1.0);
    if (frost <= 0) return child;

    final blurSigma = 16 + frost * 26;
    final saturate = 1 + frost * 0.65;
    return ClipRRect(
      borderRadius: BorderRadius.circular(kRadiusXl),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 玻璃后封面垫（`.glass-frost { z-index: -2 }`，app.css:481-489）：
          // 当前封面模糊图，垫在卡面之下。
          if (coverPath.isNotEmpty)
            Opacity(
              opacity: (frost * tokens.frostCoverOpacity).clamp(0.0, 1.0),
              child: Image.file(
                File(coverPath),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
              ),
            ),
          // 背景模糊 + 饱和（`backdrop-filter: blur(16px+frost*26) saturate(1+frost*0.65)`，
          // app.css:450-455 逐字）。CSS 的两个滤镜按书写顺序串联等价于
          // `outer(inner(source))`，所以 blur 是 inner、saturate 是 outer：
          //   ImageFilter.compose(outer: 饱和度矩阵, inner: 高斯模糊)
          BackdropFilter(
            filter: ui.ImageFilter.compose(
              outer: ui.ColorFilter.saturation(saturate),
              inner: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            ),
            child: const SizedBox.expand(),
          ),
          // 磨砂膜（`::before { z-index: -1 }`，app.css:461-477）：
          // sheen + veil + bloom + tint，opacity=frostLevel。
          IgnorePointer(
            child: Opacity(
              opacity: frost,
              child: CustomPaint(
                painter: _FrostMembranePainter(tokens: tokens),
                isComplex: true,
                willChange: false,
              ),
            ),
          ),
          // 卡面本体（内容）必须**画在最后**：CSS 里那两层都是负 z-index，
          // 压在卡面之下；早期实现把 child 放在 Stack 首位，于是 frost>0 时
          // 封面垫 + 膜层把整卡内容糊死（只剩一团模糊封面，文字全被盖住）。
          child,
        ],
      ),
    );
  }
}

/// 磨砂膜 painter：sheen 线性渐变 + veil + 左上 bloom + 右下 frostTint +
/// 颗粒白点（frost-noise 的近似）。
class _FrostMembranePainter extends CustomPainter {
  _FrostMembranePainter({required this.tokens});

  final AppTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    // 1) sheen：160deg 线性渐变（左上→右下，乳白 0.1→0.03）。
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, size.height),
          [tokens.frostSheenA, tokens.frostSheenB],
        ),
    );
    // 2) veil：再叠一层（深色压暗 / 浅色提亮的薄纱）。
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, size.height),
          [tokens.frostVeilA, tokens.frostVeilB],
        ),
    );
    // 3) bloom：左上径向白光 0.18。
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width * 0.18, size.height * 0.12),
          size.longestSide * 0.7,
          [tokens.frostBloom, tokens.frostBloom.withValues(alpha: 0)],
        ),
    );
    // 4) frostTint：右下主题色晕染（rgb(accent/0.1)）。
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width, size.height),
          size.longestSide * 0.7,
          [tokens.frostTint, tokens.frostTint.withValues(alpha: 0)],
        ),
    );
    // 5) 颗粒：确定性白点（frost-noise 的 SVG feTurbulence 近似——
    //    8×8 网格内按哈希散布白点，密度约 8%）。
    //
    //    **一次 drawRawPoints 画完，不再逐点 drawCircle**：早先在 700×560 的
    //    卡片上这段循环会发出 ~2400 次 drawCircle，每一次都是一份独立的绘制
    //    指令；BackdropFilter 让这张膜在磨砂开启时参与整卡重绘，于是这 2400 条
    //    指令每帧都要重新走一遍光栅化。同样的点、同样的视觉，合成一条
    //    PointMode.points 之后只剩一次调用。
    final dots = _noisePoints(size);
    if (dots.isNotEmpty) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        dots,
        Paint()
          ..color = const Color(0x14FFFFFF)
          ..strokeWidth = 1.2
          ..strokeCap = ui.StrokeCap.round,
      );
    }
  }

  /// 颗粒点集（缓存在 painter 实例上）。
  ///
  /// `shouldRepaint` 只在 token 变时才换 painter，所以稳态下这一个实例会跟着
  /// RenderCustomPaint 一直活着 —— 点集算一次，之后每帧直接复用。缓存按 `size`
  /// 校验：窗口缩放会换尺寸，但那是低频事件。
  Float32List _noisePoints(Size size) {
    final cached = _dots;
    if (cached != null && _dotsSize == size) return cached;
    const cell = 8.0;
    final out = <double>[];
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        final hash = (x.toInt() * 73856093) ^ (y.toInt() * 19349663);
        if (hash.isOdd) continue;
        out.add(x + (hash % 100) / 100 * cell);
        out.add(y + ((hash >> 7) % 100) / 100 * cell);
      }
    }
    final points = Float32List.fromList(out);
    _dots = points;
    _dotsSize = size;
    return points;
  }

  Float32List? _dots;
  Size? _dotsSize;

  @override
  bool shouldRepaint(_FrostMembranePainter oldDelegate) =>
      oldDelegate.tokens != tokens;
}
