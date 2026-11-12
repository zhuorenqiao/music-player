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
/// [children] 由调用方按档位给：桌面是 `stage → transport`（右栏面板在这张卡
/// 之外），窄屏同样是 `stage → transport`（列表面板收进底部弹层，不占常驻位）。
class PlayerCard extends StatelessWidget {
  const PlayerCard({
    required this.coverPath,
    required this.frostLevel,
    required this.children,
    super.key,
  });

  final String coverPath;
  final double frostLevel;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // 容错：测试 harness / 旧调用点可能没装 AppTokensData（`context.tokens`
    // 会空指针）。缺 token 时用一套最简卡面（无色边框 + 圆角），
    // 保证骨架几何仍可被断言，不因缺主题而炸。
    final data = Theme.of(context).extension<AppTokensData>();
    final tokens = data?.tokens;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusXl),
        border: tokens == null ? null : Border.all(color: tokens.border),
        gradient: tokens == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [tokens.cardA, tokens.cardB],
              ),
        boxShadow: tokens?.shadowCard,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kRadiusXl),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
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
              child: card,
            ),
    );
  }
}
