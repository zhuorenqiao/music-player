// lib/ui/player_card.dart
//
// 播放卡（对译 `src/styles/app.css:427-518` 的 `.player`）：
// 曲目区（[Stage]）与控制区（[TransportBar]）合在**同一张卡**里，只留一套
// 圆角 / 边框 / 玻璃底 / 阴影，内部两块各自把卡片外观剥掉（`:510-518`），
// 否则中间会多出一道缝 —— 这正是 React 窄屏截图与旧 Flutter 三段式卡片
// 最直观的差别。
//
// 为了让「纯展示」的 StagePreview / TransportBar.preview 在测试里仍能被单独
// pump，脱壳不是无条件做的：本卡通过 [PlayerCardScope] 往子树里放一个标记，
// 子卡只在检测到标记时才去掉自己的 chrome。没有装配 [PlayerCard] 的调用点
// （widget 测试、预览）保持原来的独立卡片外观，既有几何断言一律不破。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../theme/app_tokens.dart';
import 'fused_card.dart';
import 'glass_frost.dart';

/// 把「我在一张 .player 卡内部」传给子树。
///
/// 只传两个值：封面路径（玻璃后垫要用）与是否需要脱壳。用 InheritedWidget
/// 而不是构造参数，是为了不改动 [Stage] / [TransportBar] 的公开签名与所有
/// 既有调用点。
class PlayerCardScope extends InheritedWidget {
  const PlayerCardScope({
    required this.coverPath,
    required this.frostLevel,
    required super.child,
    super.key,
  });

  /// 当前曲目封面（`.glass-frost` 的模糊底）；空串不垫。
  final String coverPath;

  /// 磨砂强度，与 [GlassFrostLayer] 同源。
  final double frostLevel;

  static PlayerCardScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerCardScope>();

  @override
  bool updateShouldNotify(PlayerCardScope oldWidget) =>
      coverPath != oldWidget.coverPath ||
      frostLevel != oldWidget.frostLevel;
}

/// 一整张播放卡：卡面 chrome + 磨砂层 + 竖直堆叠的 [children]。
///
/// [children] 由调用方按档位给：桌面是 `stage → transport`，窄屏同样是
/// `stage → transport`（列表面板收进底部弹层，不占常驻位）。
///
/// 桌面双栏融合之后，这张卡住在 [FusedCard] 里，卡面 chrome 与磨砂层由外层
/// 那张整卡承担 —— 检测到 [FusedCardScope] 时就只留内容，否则一张卡里会浮出
/// 第二层边框（与 CSS 里 `.player` 剥掉边框/圆角/磨砂同一件事）。
class PlayerCard extends StatelessWidget {
  const PlayerCard({
    required this.coverPath,
    required this.frostLevel,
    this.glassLevel = 1,
    this.radius = kRadiusXl,
    this.contentInsets = EdgeInsets.zero,
    required this.children,
    super.key,
  });

  final String coverPath;
  final double frostLevel;

  /// 卡面不透明度（ThemeState.glassLevel）：`.player` 的 `color-mix` 那一档。
  final double glassLevel;

  /// 卡面圆角；`0` = 铺满档（窄屏）。
  ///
  /// 铺满时边框与卡外投影一并去掉 —— React 小屏那一档是
  /// `@media (max-width: 899px) { .player { border: none; border-radius: 0 } }`，
  /// 直角一直铺到视口边缘，形状由外层窗口 / 屏幕的圆角决定。
  final double radius;

  /// 卡内内容的安全区内缩（窄屏铺满档用；桌面档恒为 [EdgeInsets.zero]）。
  ///
  /// 卡面（玻璃底 / 渐变）**自己**铺满整屏，只有卡里的内容按系统栏内缩。
  /// 这个差别是必须的：把 `SafeArea` 加在卡外，卡就铺不到屏幕顶边，状态栏
  /// 底下会留一条没被背景盖住的系统栏底色 —— 也就是那条黑边。
  final EdgeInsets contentInsets;

  final List<Widget> children;

  /// 卡内的竖直堆叠（[children]）。卡面 chrome 由外层画，安全区内缩由调用处
  /// 包的那层 [Padding] 给，这里只管排版。
  Widget _content() => Column(
    mainAxisSize: MainAxisSize.max,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );

  @override
  Widget build(BuildContext context) {
    // 铺满档：直角、无描边、无卡外投影，只留玻璃底与内容。
    final fullBleed = radius <= 0;
    // 融合卡里：外层那张整卡已经有边框 / 圆角 / 玻璃底 / 磨砂，本卡只留内容。
    // PlayerCardScope 照旧放出去 —— Stage / TransportBar 仍要据此剥掉自己那层
    // 卡片外观，否则融合卡里会再冒出两道内框。
    if (FusedCardScope.isFused(context)) {
      return PlayerCardScope(
        coverPath: coverPath,
        frostLevel: frostLevel,
        child: Padding(padding: contentInsets, child: _content()),
      );
    }
    // 容错：测试 harness / 旧调用点可能没装 AppTokensData（`context.tokens`
    // 会空指针）。缺 token 时用一套最简卡面（无色边框 + 圆角），
    // 保证骨架几何仍可被断言，不因缺主题而炸。
    final data = Theme.of(context).extension<AppTokensData>();
    final tokens = data?.tokens;
    final cardRadius = BorderRadius.circular(radius);
    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: cardRadius,
        border: (tokens == null || fullBleed)
            ? null
            : Border.all(color: tokens.border),
      ),
      child: ClipRRect(
        borderRadius: cardRadius,
        child: Padding(padding: contentInsets, child: _content()),
      ),
    );
    return PlayerCardScope(
      coverPath: coverPath,
      frostLevel: frostLevel,
      child: tokens == null
          ? card
          : GlassFrostLayer(
              coverPath: coverPath,
              frostLevel: frostLevel,
              glassLevel: glassLevel,
              radius: radius,
              colorA: tokens.cardA,
              colorB: tokens.cardB,
              // `.player { background: linear-gradient(165deg, …) }`（app.css:444）
              gradientDegrees: 165,
              // 卡外投影归玻璃层（画在卡面之下）；铺满档贴到视口边缘，投影无处可落
              shadow: fullBleed ? null : tokens.shadowCard,
              child: card,
            ),
    );
  }
}
