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

/// 窄屏外层边距：`padding: 0`。
///
/// 小屏（<900）现在「页面铺满」：React 侧把 `.app { padding: 16px 14px 14px }`
/// 改成了 `padding: 0`，同时 `.player { border: none; border-radius: 0 }`，
/// 边角交给外层容器（窗口 / 手机屏幕）去裁 —— 不再有「卡片套在窗口里」的
/// 双层留白。原来那句「底部留白：整张播放卡浮在页面里，底边圆角与边距都要
/// 露出来」随铺满作废，控制条自己补 30px 底内边距（见 [TransportBar]）。
const EdgeInsets kNarrowPadding = EdgeInsets.zero;

/// 桌面左列（列表面板）的固定宽度：`grid-template-columns: 400px minmax(0, 1fr)`。
const double kDesktopPanelWidth = 400;

/// 桌面：左列（面板）、右列（曲目区 + 控制区），两列同高。
class HomeLayout extends StatelessWidget {
  const HomeLayout({
    required this.header,
    required this.stage,
    required this.panel,
    required this.transport,
    this.radioBar,
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

  /// 迷你电台条（T31）：电台在后台放时，贴在控制条**正上方**的那一条。
  ///
  /// 位置刻意放在卡内最底、紧邻控制条：窄屏上它就是「播放器底部的一条迷你条」
  /// （与流媒体 App 的下栏同位），桌面则落在右列控制区上方 —— 两档都不需要
  /// 另起一行动骨架，卡还是同一张卡。[RadioBar] 自己在无当前台时返回空，
  /// 所以这里不必判空。
  final Widget? radioBar;

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
        // 系统栏占位（状态栏 / 手势条 / 刘海）。窄屏铺满时卡面要一直画到屏幕
        // 四边（见 [PlayerCard.contentInsets]），所以这里先取一份原始 insets，
        // 交给卡内内容与右上角那颗 ⋯ 各自内缩。
        final insets = MediaQuery.paddingOf(context);
        // 公共字段不参与类型提升，先取到局部变量（`overlay != null` 之后才好用）。
        final overlay = this.overlay;
        // `.player`：曲目区与控制区合成一张卡（app.css:427-518）。两档都用它，
        // 差异只在「卡外还有没有一张常驻面板」。
        //
        // 窄屏铺满：`radius` 传 0，卡面只留玻璃底、边框与卡外投影一并去掉
        // （React `@media (max-width: 899px) { .player { border: none;
        // border-radius: 0 } }`）。
        //
        // [contentInsets] 是「卡面铺满、内容让位」的那一半：卡面（玻璃底 +
        // 渐变）一直铺到屏幕四边 —— 状态栏 / 手势条底下也是卡面，系统栏透明
        // 之后就看不到那条没被背景盖住的黑边；卡里的内容再按 insets 内缩，
        // 文字与按钮不会钻到系统栏下面。把 SafeArea 加在卡外做不到这一点：
        // 卡本身会被挤离屏幕顶边（那正是顶部那块黑色的来路）。
        Widget playerCard(
          Widget content, {
          EdgeInsets contentInsets = EdgeInsets.zero,
        }) => PlayerCard(
          coverPath: coverPath,
          frostLevel: frostLevel,
          glassLevel: glassLevel,
          radius: desktop ? kRadiusXl : 0,
          contentInsets: contentInsets,
          children: [
            Expanded(child: content),
            ?radioBar,
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
        // 安全区：桌面档整块让出（窗口里的 insets 通常为 0，只当装饰性边距）；
        // **窄屏不让位** —— 卡面要铺到屏幕四边（状态栏 / 手势条底下也是卡面），
        // 内缩交给 [PlayerCard.contentInsets] 与右上角那颗 ⋯（见下面的
        // `Positioned`）。四条全 false 时 SafeArea 只剩透明的一层，等于原样。
        return SafeArea(
          top: desktop,
          bottom: desktop,
          left: desktop,
          right: desktop,
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
                    // 窄屏的顶栏不再占一行：简约 / 沉浸两种模式都只有「电台 / 更多」
                    // 两颗图标，位置由下面 Stack 里那一条 `Positioned` 统一给 ——
                    // 贴卡片（= 视口）右上角、右侧内缩 10px，纵向 = 安全区 + 12
                    // （三页同一口径：按钮上缘 12、图标中心 28；对译 app.css 小屏媒体块的
                    //  `body:not(.is-lyrics-page) .app__header,
                    //   body.is-lyrics-page .app__header { top: 12px;
                    //   right: 0; padding: 0 10px }`）。
                    // 从前沉浸模式的顶栏在流内（10 + 32 + 14 间距）：切模式时那颗 ⋯
                    // 会跟着上下跳一截，卡片也被推下去；现在两处都浮在卡上、同源落位。
                    if (desktop) ...[
                      header,
                      const SizedBox(height: 18),
                    ],
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
                    else
                      // 窄屏：两种模式共用同一套 —— 卡片铺满整屏（歌词页的歌词与
                      // 控制条也在这一张卡里），顶栏那颗 ⋯ 浮在卡片右上角。
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned.fill(
                              // 卡面铺满整屏（含系统栏底下），内容按 insets 内缩。
                              child: playerCard(
                                overlay ?? stage,
                                contentInsets: insets,
                              ),
                            ),
                            // 顶栏贴视口右上角、右侧内侧 10px，纵向 = 安全区 + 12
                            // （三页同一口径：按钮上缘 12、图标中心 28，与电台 / 休眠
                            //   两页右上角那几颗同一条水平线；对译 app.css 小屏媒体块的
                            //  `body:not(.is-lyrics-page) .app__header,
                            //   body.is-lyrics-page .app__header { top: 12px;
                            //   right: 0; padding: 0 10px }`）。
                            Positioned(
                              top: insets.top + 12,
                              right: insets.right + 10,
                              child: header,
                            ),
                          ],
                        ),
                      ),
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
