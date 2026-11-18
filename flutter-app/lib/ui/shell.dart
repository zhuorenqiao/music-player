// lib/ui/shell.dart
//
// 应用骨架：对译 `src/styles/app.css` 的两档结构（`.app` + `.app__main`）。
//
//   - 宽 ≥900：外层 padding 24/28/28；左右两列**融合成一张卡**
//     （`app.css` 桌面档把边框 / 圆角 / 玻璃底 / 磨砂搬到了 `.app__main`），
//     左列是固定 400px 的面板、右列是曲目区 + 控制区，中间一条 1px 竖线
//     （[FusedDivider]，上下各留 18px），两列同顶同底 —— 原版「控制区底边与
//     左栏面板底边对齐」那条验收；
//   - 宽 <900：单列，只有那张 `.player` 卡（曲目区吃掉封面/信息区以外的高度，
//     控制条贴在卡内底部），padding 16/14/14、gap 14。列表面板按 React
//     `App.tsx:1714` 的 `{!compact && <Panel/>}` 收进底部弹层，窄屏不再常驻
//     一张中间卡片 —— 这是 React 窄屏截图与旧三段式布局最大的差别。
//
// 两档共用一条宽度上限，分三档放宽：`.app { max-width: 1180px }`，大屏
// 抬到 1360（≥1280）、1680（≥1680）—— 原版「大屏适配」那一段就是为了
// 避免 1920 窗口两侧留下两三百像素空场。封顶加在 padding **里面**，边距量的是
// 窗口而不是内容框 —— 1920 的窗口里内容 1680 居中，1200 的窗口里内容仍占满
// 1200-56 且 24/28/28 的边距不变。
//
// 沉浸模式（完整歌词页）在大屏（≥1280）把列表面板放回左列，与右列那张播放卡
// 同住一张融合卡（`body.is-lyrics-page .panel`，app.css:5003-5018）；中小屏仍是
// 歌词页独占整宽、列表靠控制条入口唤出弹层。
//
// **只管摆放，不碰业务**：四个区域由调用方传入，后续任务只换子 widget，
// 这个文件的结构不再改。
import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import 'fused_card.dart';
import 'player_card.dart';

/// 内容最大宽度：`.app { max-width: 1180px }`（配合 `margin: 0 auto` 居中）。
///
/// 大屏两档由 `contentMaxWidth()` 逐级放宽到 1360 / 1680（见 [Breaks]）。
const double kMaxContentWidth = 1180;

/// 桌面外层边距：`padding: 24px 28px 28px`。
const EdgeInsets kDesktopPadding = EdgeInsets.fromLTRB(28, 24, 28, 28);

/// 满宽档外层边距：`padding: 28px 32px 32px`（app.css:5061-5064）。
const EdgeInsets kUltraPadding = EdgeInsets.fromLTRB(32, 28, 32, 32);

/// 窄屏外层边距：`padding: 16px 14px 14px`（app.css:419）。
///
/// 底边 14 是原版那句注释的所在：「底部留白：整张播放卡浮在页面里，底边圆角与
/// 边距都要露出来」。之前这里写 0，是把它和 `.transport { position: sticky;
/// bottom: 0 }` 混成了一件事 —— 卡底边于是直接贴在窗口底边、24px 圆角被切掉，
/// 小屏上看着就是「底部留白没了」。控制条自己的 `12px`（+ 安全区）内边距在
/// [TransportBar] 里，和这层页面留白是两码事。
const EdgeInsets kNarrowPadding = EdgeInsets.fromLTRB(14, 16, 14, 14);

/// 桌面左列（列表面板）的固定宽度：`grid-template-columns: 400px minmax(0, 1fr)`。
const double kDesktopPanelWidth = 400;

/// 桌面：左列（面板）、右列（曲目区 + 控制区），两列同高。
class HomeLayout extends StatelessWidget {
  const HomeLayout({
    required this.header,
    required this.stage,
    required this.panel,
    required this.transport,
    this.coverPath = '',
    this.frostLevel = 0,
    this.glassLevel = 1,
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

  /// 卡面不透明度（ThemeState.glassLevel）；融合卡整张底色的 alpha 缩放。
  final double glassLevel;

  /// 盖住「曲目区 + 面板」的可选整块内容（T19 的全屏歌词页）。
  ///
  /// 只在**内容区**替换，不碰骨架：头部仍在上、`transport` 仍在卡内最底
  /// （原版 `App.tsx:1707` 是把 `<LyricsPage>` 与 `<Stage>` 二选一渲染，
  /// 控制条在两者之外、但**同在那张 `.player` 卡里**，所以切到歌词页时播放
  /// 控制既可见可操作、又不会多冒出一张卡）。
  ///
  /// 两档的替换范围不同，随各自骨架走，但都收进**同一张卡**：
  ///   - 桌面：替换整个 `Row`（左右两列一起让位），只剩一张融合卡，
  ///     卡内是 `歌词页 → 控制条`；**大屏（≥1280）例外** —— 左列把播放列表
  ///     放回来（`body.is-lyrics-page .panel`），卡内是 `列表 | 竖线 | 歌词页 → 控制条`；
  ///   - 窄屏：替换 `stage + panel`，那张 `.player` 卡里是 `歌词页 → 控制条`。
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final desktop = isDesktop(width);
        // 大屏档（≥1280）：沉浸模式把列表面板放回左列 ——
        // `body.is-lyrics-page .panel:not(.panel--sheet) { display: flex; grid-area: panel }`
        // 与 `--panel-width: clamp(300px, 26vw, 400px)` 那一档
        // （app.css:5003-5018）。窄屏 / 中等屏维持原样：歌词页独占整宽，
        // 列表靠控制条那颗入口唤出弹层。
        final wideLyrics = isWide(MediaQuery.sizeOf(context).width);
        final ultra = isUltraWide(MediaQuery.sizeOf(context).width);
        // 公共字段不参与类型提升，先取到局部变量（`overlay != null` 之后才好用）。
        final overlay = this.overlay;
        // `.player`：曲目区与控制区合成一张卡（app.css:427-518）。两档都用它，
        // 差异只在「卡外还有没有一张常驻面板」。
        Widget playerCard(Widget content) => PlayerCard(
          coverPath: coverPath,
          frostLevel: frostLevel,
          glassLevel: glassLevel,
          children: [
            Expanded(child: content),
            transport,
          ],
        );
        // 面板 + 竖线 + 播放卡：两张子卡同住在一张融合卡里，中间一条 1px 竖线
        // （`.panel::after` / [FusedDivider]）。简约模式左列固定 400，沉浸模式
        // 换成随视口伸缩的 clamp（见 [lyricsDockedPanelWidth]）。
        Widget fusedColumns({required double panelWidth, required Widget player}) =>
            Row(
              key: const Key('desktop-grid'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: panelWidth, child: panel),
                const FusedDivider(),
                Expanded(child: player),
              ],
            );
        return SafeArea(
          child: Padding(
            padding: ultra
                ? kUltraPadding
                : (desktop ? kDesktopPadding : kNarrowPadding),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: desktop
                      ? contentMaxWidth(MediaQuery.sizeOf(context).width)
                      : kMaxContentWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    SizedBox(height: desktop ? 18 : 14),
                    if (desktop)
                      if (overlay != null)
                        // 沉浸模式（完整歌词页）也只剩**一张卡**：歌词页与控制条
                        // 同住在这张卡里，卡面 chrome（边框 / 圆角 / 玻璃底 /
                        // 磨砂）由外层融合卡承担、与简约模式那张卡一模一样。
                        //
                        // 大屏（≥1280）左列把播放列表放回来 —— 1920 这类宽屏上
                        // 歌词页原本两侧空出几百像素，列表放回左侧正好补上
                        // （app.css:4980-5024）。歌词与控制条仍是右列那张
                        // 播放卡里的两段，左列面板与它同住一张融合卡。
                        Expanded(
                          child: FusedCard(
                            coverPath: coverPath,
                            frostLevel: frostLevel,
                            glassLevel: glassLevel,
                            child: wideLyrics
                                ? fusedColumns(
                                    panelWidth: lyricsDockedPanelWidth(
                                      MediaQuery.sizeOf(context).width,
                                    ),
                                    player: playerCard(overlay),
                                  )
                                : playerCard(overlay),
                          ),
                        )
                      else
                        Expanded(
                          // 双栏融合成一张卡：外层 [FusedCard] 画边框 / 圆角 / 玻璃底
                          // / 磨砂，里面才是「面板 + 竖线 + 播放卡」，两张子卡各自
                          // 只留内容（`FusedCardScope`）。宽度仍是面板固定 400、
                          // 播放卡吃掉余量（`grid-template-columns: 400px 1px minmax(0,1fr)`）。
                          child: FusedCard(
                            coverPath: coverPath,
                            frostLevel: frostLevel,
                            glassLevel: glassLevel,
                            child: fusedColumns(
                              panelWidth: kDesktopPanelWidth,
                              player: playerCard(stage),
                            ),
                          ),
                        )
                    else if (overlay != null)
                      // 窄屏：歌词页与控制条同在那一张 `.player` 卡里
                      // （中间不再留 14px 缝 —— 原版此处也是同一张卡的两段）。
                      Expanded(child: playerCard(overlay))
                    else
                      // 窄屏无 overlay：只有一张 `.player` 卡吃掉全部可用高度。
                      // 面板按 React `App.tsx:1714` 收进底部弹层，这里不渲染。
                      Expanded(child: playerCard(stage)),
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
