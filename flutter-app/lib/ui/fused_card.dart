// lib/ui/fused_card.dart
//
// 桌面双栏那张「融合卡」：对译 `src/styles/app.css` 桌面档里搬到
// `.app__main` 上的那套外观（边框 / 圆角 / 玻璃底 / 阴影 / 磨砂膜）。
//
// 融合前播放卡与列表面板各是一张独立卡（各自一套边框、圆角、磨砂），
// 中间留 18px 缝；融合后只剩**一张卡**，两张子卡只留排版，靠一条
// 1px 竖线分隔 —— 与 React 简约模式、沉浸模式的表现一致。
//
// 本件只负责「外面那张卡」：卡面 chrome + 磨砂层 + 一个标记，
// 子卡通过 [FusedCardScope] 得知自己已经被融合，从而剥掉自己的卡面。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'glass_frost.dart';

/// 「我在这张融合卡里面」的标记。
///
/// 与 [PlayerCardScope] 同一套思路：用 InheritedWidget 而不是改构造参数，
/// 纯展示 / 独立 pumped 的 [Panel] 与 [PlayerCard] 保持原来的独立卡片外观，
/// 既有几何断言不破。
class FusedCardScope extends InheritedWidget {
  const FusedCardScope({required super.child, super.key});

  static bool isFused(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FusedCardScope>() != null;

  @override
  bool updateShouldNotify(FusedCardScope oldWidget) => false;
}

/// 一整张融合卡：卡面 chrome + 磨砂层，内部由调用方摆（面板 + 竖线 + 播放卡）。
class FusedCard extends StatelessWidget {
  const FusedCard({
    required this.coverPath,
    required this.frostLevel,
    this.glassLevel = 1,
    required this.child,
    super.key,
  });

  /// 玻璃后垫的封面路径（`.glass-frost` 的模糊底）；空串不垫。
  final String coverPath;

  /// 磨砂强度（ThemeState.frostLevel）。
  final double frostLevel;

  /// 卡面不透明度（ThemeState.glassLevel）：与 CSS 的
  /// `color-mix(in srgb, --card-a/−card-b calc(--glass-level * 100%), transparent)` 同义。
  final double glassLevel;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 与 [PlayerCard] 一致：没有 AppTokensData（测试 harness）时退回最简卡面，
    // 保证骨架几何仍可断言。
    final tokens = Theme.of(context).extension<AppTokensData>()?.tokens;
    // 卡面渐变交给 GlassFrostLayer：CSS 里卡面渐变要压在**磨砂膜与色雾之下**，
    // 画在这一层（孩子的装饰）就会把玻璃层盖掉（见 glass_frost.dart 顶部说明）。
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(kRadiusXl),
      border: tokens == null ? null : Border.all(color: tokens.border),
    );
    // DecoratedBox + ClipRRect 而不是 Container：Container 会把边框宽度算成
    // 内边距，两个子区的几何就整体缩进 1px（shell_test 量得到）。
    final card = DecoratedBox(
      decoration: decoration,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kRadiusXl),
        child: child,
      ),
    );
    return FusedCardScope(
      child: tokens == null
          ? card
          : GlassFrostLayer(
              coverPath: coverPath,
              frostLevel: frostLevel,
              glassLevel: glassLevel,
              colorA: tokens.cardA,
              colorB: tokens.cardB,
              // `.app__main { background: linear-gradient(165deg, …) }`（app.css:4815）
              gradientDegrees: 165,
              // 卡外投影归玻璃层（画在卡面之下）
              shadow: tokens.shadowCard,
              child: card,
            ),
    );
  }
}

/// 两列之间那条竖线：1px、上下各留 18px，不顶满整卡高度。
///
/// 用 `borderStrong` 而不是 `border`：融合后两侧是同一块底色，
/// 7% 白的分隔线几乎看不见（app.css 桌面档同款取舍）。
class FusedDivider extends StatelessWidget {
  const FusedDivider({super.key});

  static const double inset = 18;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokensData>()?.tokens;
    // 外层只负责那 18px 的上下余量（撑满整卡高度），真正的 1px 线在内层 ——
    // 几何断言量的是 `fused-divider-line`，不是这层 Padding。
    return Padding(
      key: const Key('fused-divider'),
      padding: const EdgeInsets.symmetric(vertical: inset),
      child: SizedBox(
        width: 1,
        child: ColoredBox(
          key: const Key('fused-divider-line'),
          color: tokens?.borderStrong ?? const Color(0x2BFFFFFF),
        ),
      ),
    );
  }
}
