// lib/ui/shell.dart
//
// 应用骨架：对译 `src/styles/app.css` 的两档结构（`.app` + `.app__main`）。
//
//   - 宽 ≥900：外层 padding 24/28/28、gap 18，左列 `minmax(0, 1.02fr)` 是一整张
//     `.player` 卡（曲目区 + 控制区同卡，见 [PlayerCard]），右列 `minmax(0, 1fr)`
//     是面板，两列同顶同底 —— 原版「控制区底边与右栏面板底边对齐」那条验收；
//   - 宽 <900：单列，只有那张 `.player` 卡（曲目区吃掉封面/信息区以外的高度，
//     控制条贴在卡内底部），padding 16/14/14、gap 14。列表面板按 React
//     `App.tsx:1714` 的 `{!compact && <Panel/>}` 收进底部弹层，窄屏不再常驻
//     一张中间卡片 —— 这是 React 窄屏截图与旧三段式布局最大的差别。
//
// 两档共用一条宽度上限：`.app { max-width: 1180px; margin: 0 auto }`。封顶加在
// padding **里面**，边距量的是窗口而不是内容框 —— 1920 的窗口里内容 1180 居中，
// 1200 的窗口里内容仍占满 1200-56 且 24/28/28 的边距不变。
//
// **只管摆放，不碰业务**：四个区域由调用方传入，后续任务只换子 widget，
// 这个文件的结构不再改。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import 'player_card.dart';

/// 内容最大宽度：`.app { max-width: 1180px }`（配合 `margin: 0 auto` 居中）。
const double kMaxContentWidth = 1180;

/// 桌面外层边距：`padding: 24px 28px 28px`。
const EdgeInsets kDesktopPadding = EdgeInsets.fromLTRB(28, 24, 28, 28);

/// 窄屏外层边距：`padding: 16px 14px 14px`。
///
/// 底边是 0 而不是 14：原版控制条 `position: sticky; bottom: 0`，它自己带
/// `padding: 14px 16px calc(12px + env(safe-area-inset-bottom))`，外层再留
/// 14px 会把吸底的那条顶离视口底边 14px（test/ui/shell_test.dart 量得到）。
const EdgeInsets kNarrowPadding = EdgeInsets.fromLTRB(14, 16, 14, 0);

/// 桌面：左列（曲目区 + 控制区）、右列（面板），两列同高。
class HomeLayout extends StatelessWidget {
  const HomeLayout({
    required this.header,
    required this.stage,
    required this.panel,
    required this.transport,
    this.coverPath = '',
    this.frostLevel = 0,
    this.overlay,
    super.key,
  });

  final Widget header;
  final Widget stage;
  final Widget panel;
  final Widget transport;

  /// 播放卡玻璃后垫的封面路径（React `.glass-frost` 用 `useCover(current)`）。
  /// 由 [HomePage] 注入；不传时为空串（纯展示 / 测试）。
  final String coverPath;

  /// 磨砂强度（ThemeState.frostLevel）；不传按 0（普通卡面）。
  final double frostLevel;

  /// 盖住「曲目区 + 面板」的可选整块内容（T19 的全屏歌词页）。
  ///
  /// 只在**内容区**替换，不碰骨架：头部仍在上、`transport` 仍在最后
  /// （原版 `App.tsx:1707` 是把 `<LyricsPage>` 与 `<Stage>` 二选一渲染，
  /// 控制条在两者之外，所以切到歌词页时播放控制仍然可见可操作）。
  ///
  /// 两档的替换范围不同，随各自骨架走：
  ///   - 桌面：替换整个 `Row`（左右两列一起让位）；
  ///   - 窄屏：替换 `stage + panel` 那一串（`transport` 本来就贴底，仍留在最后）。
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = isDesktop(constraints.maxWidth);
        // 公共字段不参与类型提升，先取到局部变量（`overlay != null` 之后才好用）。
        final overlay = this.overlay;
        // `.player`：曲目区与控制区合成一张卡（app.css:427-518）。两档都用它，
        // 差异只在「卡外还有没有一张常驻面板」。
        Widget playerCard(Widget content) => PlayerCard(
          coverPath: coverPath,
          frostLevel: frostLevel,
          children: [
            Expanded(child: content),
            transport,
          ],
        );
        return SafeArea(
          child: Padding(
            padding: desktop ? kDesktopPadding : kNarrowPadding,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    SizedBox(height: desktop ? 18 : 14),
                    if (desktop)
                      if (overlay != null) ...[
                        // 桌面有 overlay：两列一起让位，但 `transport` 必须留下 ——
                        // 「切到歌词页时播放控制仍可见可操作」（原版 `App.tsx:1707`
                        // 也是 `<LyricsPage>` / `<Stage>` 二选一，控制条在两者之外）。
                        Expanded(child: overlay),
                        const SizedBox(height: 18),
                        transport,
                      ] else
                        Expanded(
                          child: Row(
                            key: const Key('desktop-grid'),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                // minmax(0, 1.02fr) / minmax(0, 1fr) 按 102 : 100 取整
                                flex: 102,
                                child: playerCard(stage),
                              ),
                              const SizedBox(width: 18),
                              Expanded(flex: 100, child: panel),
                            ],
                          ),
                        )
                    else if (overlay != null) ...[
                      // 窄屏：歌词页吃掉整块内容区，控制条仍留在最底。
                      Expanded(child: overlay),
                      const SizedBox(height: 14),
                      transport,
                    ] else ...[
                      // 窄屏无 overlay：只有一张 `.player` 卡吃掉全部可用高度。
                      // 面板按 React `App.tsx:1714` 收进底部弹层，这里不渲染。
                      Expanded(child: playerCard(stage)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
