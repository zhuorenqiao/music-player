// lib/ui/lyrics_page.dart
//
// 全屏歌词页：对译 React 版 `src/App.tsx:1019-1156` 的 `LyricsPage` 组件与
// `src/styles/app.css` 的 `.lyrics-page` 一族（:2032-2330 的骨架、
// :2990-3090 的封面/状态/脚注、:3167-3230 的空态与重试）。
//
// 结构与原版逐块对齐：
//   * 头部 `.lyrics-page__head`：左侧 `.lyrics-page__meta`（歌名 + 双语开关一行、
//     `artist · album` 一行），**紧跟着三颗工具按钮**（「T」/毛玻璃/睡眠定时器，
//     沉浸模式里从控制条搬上来的），**右上角是 `WaveStylePicker`**（M3 D.4 补上）；
//   * 正文 `.lyrics-page__body`：宽 ≥900 两列 `minmax(0, 560px) clamp(240px, 26vw,
//     360px)`、gap 32、顶上一道 `border-top`；窄屏单列且**整块封面不出现**
//     （原版靠 `@media` 把 `.lyrics-page__art` 藏掉）；
//   * 左列是「状态块 或 歌词」，**二选一**（原版 :1106-1113）：`loading` / `missing` /
//     `error` 三态给居中的一句话 + 重试按钮，其余情况才渲染 `LyricsView(full)`。
//
// 与原版的两处有意差异（改之前先读）：
//
// 1. **没有「返回」按钮，与原版一致**（早先版本在头部左侧加过一颗，已按原版
//    的感受去掉）。桌面退出走全局快捷键：Esc / L（`src/App.tsx:1595` 的
//    `Escape`、`:1603` 的 `KeyL`，Flutter 侧在 `core/shortcuts.dart` 的
//    `CloseOverlayIntent` / `ToggleLyricsPageIntent`），以及顶栏那颗开合按钮本身。
//    **手机上没有键盘**，所以窄屏（<900）另加一条手势：点整页任意空白处
//    （歌名那条带、歌词周围的留白，以及控制条上那行工具周围的空白）即切回
//    简约模式（[_maybeTapToRestore]）；点歌词行仍是定位播放、点频谱条不触发。
//
// 2. **状态行用 T16 的 `LyricsStatusLine`，位置从右栏脚注挪到左列顶部**。
//    原版那句 `.lyrics-page__status--art`（`:1146`）挂在右栏封面下方；本工程窄屏
//    会藏掉整个右栏，脚注也就跟着消失 —— 而「正在匹配歌词…」恰恰是窄屏最需要看见
//    的一句。放在左列顶部（歌词之上）两档都在。**两种情况都保留**：状态块与
//    `LyricsView` 之上都挂着它（只要 `note || status` 非空）。
//
// 三处跨任务的接口约束（T16 / T17 的 reviewer 都警告过，这里逐条兑现）：
//   * `BilingualToggle` 是**纯展示**、永远不 return null：「只在非中文歌词时出现」
//     这个条件必须由本页写（`bilingual.translatable ? BilingualToggle(...) : null`）；
//   * `LyricsView(variant: full)` 自己从 provider 读 `LyricsState` / `BilingualState` /
//     `PlayerState` 三份，本页不替它算行，也不把进度传进去；
//   * `LyricsStatusLine` 的 `loading` / `failed` / `showRetry` 是**三个独立标量**，
//     从 `LyricsState` 的枚举映射出来（见 [_statusBlock]）。
//
// 关闭后焦点还给曲目区（`:1085-1090` 的 `onClose` 语义）：本页自己不再提供
// 「关闭」入口（原版就没有这颗按钮，退出靠 Esc / L），所以也不需要在页内搬焦点。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../cover/generated_cover.dart';
import '../playback/track.dart';
import '../state/bilingual_state.dart';
import '../state/cover_state.dart';
import '../state/lightbox_controller.dart';
import '../state/lyrics_page_controller.dart';
import '../state/lyrics_state.dart';
import '../theme/app_tokens.dart';
import 'bilingual_toggle.dart';
import 'generated_cover_view.dart';
import 'lyrics_status.dart';
import 'lyrics_view.dart';
import 'player_card.dart';
import 'tool_buttons.dart';
import 'tool_panel.dart';
import 'wave_style_picker.dart';

// -- 规格常量（逐字取自 app.css，不要顺手改） ------------------------------

/// 页面内边距：`padding: 16px 16px 6px`（:2042）；
/// 桌面档 `18px 20px 6px`（≥900，app.css:4944-4949）—— 卡片一大，左右
/// 16 就显得贴边，原版在这一档把上 / 左右都收了一档。
const EdgeInsets _kPagePadding = EdgeInsets.fromLTRB(16, 16, 16, 6);

/// 桌面档页面内边距。
const EdgeInsets _kPagePaddingDesktop = EdgeInsets.fromLTRB(20, 18, 20, 6);

/// 取当前宽度档的页面内边距。
EdgeInsets _pagePadding(double viewportWidth) => viewportWidth >= Breaks.desktop
    ? _kPagePaddingDesktop
    : _kPagePadding;

/// 页面容器与内容之间的间距：`gap: 10px`（:2036）。
const double _kPageGap = 10;

/// 圆角 `--radius-xl: 24px`。
const double kLyricsPageRadius = 24;

/// 头部与正文的间距：`.lyrics-page__head { gap: 12px }`（:2054）。
const double _kHeadGap = 12;

/// 歌名与「双语」的间距：`.lyrics-page__title-row { gap: 8px }`（:2291）。
const double _kTitleRowGap = 8;

/// 歌名规格：`font-size: 18px; font-weight: 650`（:2300-2308）。
const double _kTitleFontSize = 18;
const FontWeight _kTitleWeight = FontWeight.w600;

/// `artist · album`：`margin-top: 3px; font-size: 12px`（:2310-2318）。
const double _kArtistMarginTop = 3;
const double _kArtistFontSize = 12;

/// 正文：`gap: 32px`、`padding-top: 20px`（:2322-2340）。
const double _kBodyGap = 32;
const double _kBodyPaddingTop = 20;

/// 左列（歌词）的宽度上限：`minmax(0, 560px)`（:2328）。
///
/// 大屏两档各自放宽（[`_columnMaxWidth`]）：
///   - ≥1280：`minmax(0, 640px)`（app.css:5048-5052，左列放宽的同时
///     `.lyrics-page .lyrics--full { max-width: 640px }` 也放开）；
///   - ≥1680：`minmax(0, 800px)`（app.css:5076-5080）。
const double _kColumnMaxWidth = 560;

/// 右栏封面宽度：`clamp(240px, 26vw, 360px)`（:2328）。
///
/// 大屏两档：≥1280 `clamp(280px, 24vw, 400px)`（app.css:5045-5048）、
/// ≥1680 `clamp(360px, 25vw, 480px)`（app.css:5072-5075）。
const double _kCoverMinWidth = 240;
const double _kCoverMaxWidth = 360;

/// 右栏封面宽度的视口系数（26vw）。
const double _kCoverViewportRatio = 0.26;

/// 空态状态块：`gap: 14px; max-width: 380px; padding: 24px 16px`（:3206-3220）。
const double _kEmptyGap = 14;
const double _kEmptyMaxWidth = 380;
const EdgeInsets _kEmptyPadding = EdgeInsets.symmetric(
  horizontal: 16,
  vertical: 24,
);

/// 空态标题：`font-size: 15px; line-height: 1.6`（:3221-3228）。
const double _kEmptyTitleFontSize = 15;
const double _kEmptyTitleLineHeight = 1.6;

/// 空态里的重试按钮比状态行那颗大一号：`min-height: 32px; padding: 0 16px;
/// font-size: 13px`（`.lyrics-page__empty .lyrics-page__retry`，:3230-3234）。
const double _kEmptyRetryMinHeight = 32;
const double _kEmptyRetryHorizontalPadding = 16;
const double _kEmptyRetryFontSize = 13;

/// 状态行与正文之间的间距（T16 的 `LyricsStatusLine` 自带 bottom 4，
/// 这里再补一点，免得贴着第一行歌词）。
const double _kStatusLineBottomGap = 6;

/// 全屏歌词页。由 `HomeLayout.overlay` 槽挂上，开合由 `LyricsPageController` 决定。
class LyricsPage extends StatefulWidget {
  const LyricsPage({super.key});

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final lyrics = context.watch<LyricsState>();
    final bilingual = context.watch<BilingualState>();
    final track = lyrics.track;
    // 宽 ≥900 才两列；窄屏整块右栏（含封面）不出现。
    final desktop = isDesktop(MediaQuery.sizeOf(context).width);

    final titleRow = Row(
      // mainAxisSize.min：这一行按内容宽收缩（React 的 .lyrics-page__meta 是
      // `flex: 0 1 auto`，收缩到内容宽），于是页头里的三颗工具按钮能**紧跟在
      // 歌名后面**，而不是被撑到最右（那是 .wave-style 的地盘）。
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            track?.title ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _kTitleFontSize,
              fontWeight: _kTitleWeight,
              letterSpacing: 0.01,
              color: tokens.text,
            ),
          ),
        ),
        if (bilingual.translatable) ...[
          const SizedBox(width: _kTitleRowGap),
          // 「只在非中文歌词时出现」由这里判 —— T16 的 BilingualToggle 是纯展示的，
          // 它自己不会返回 null（这是 T16 reviewer 明确警告过的下游陷阱）。
          BilingualToggle(
            enabled: bilingual.enabled,
            onChanged: bilingual.setEnabled,
            tooltip: _tooltipFor(bilingual),
          ),
        ],
      ],
    );

    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        titleRow,
        const SizedBox(height: _kArtistMarginTop),
        Text(
          _artistAlbum(track),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: _kArtistFontSize, color: tokens.textFaint),
        ),
      ],
    );

    // 在 [PlayerCard] 里：`.player > .lyrics-page` 要把边框 / 圆角 / 渐变 /
    // 阴影全剥掉（app.css:510-518），卡面只留**一张** —— 沉浸模式与简约模式
    // 因此长得一样（原版截图里歌词页与控制条同在一张卡里，卡内没有第二道缝）。
    // 纯展示 / 测试没有 scope 时仍是独立卡（既有几何断言不破）。
    //
    // 小屏：**整页（含歌名那条带）**都是「点哪儿都切回简约模式」的热区，
    // 所以包装在最外层 —— 从前的热区只包正文，点页头（歌名 / artist）没反应。
    // 里层的按钮与歌词行各有自己的识别器，仍按原样工作（见 [_maybeTapToRestore]）。
    final body = _maybeTapToRestore(
      enabled: !desktop,
      child: Padding(
        key: const Key('lyrics-page-body'),
        padding: _pagePadding(MediaQuery.sizeOf(context).width),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // 窄屏那颗 ⋯ 浮在卡片右上角（`shell.dart` 里那条 `Positioned`），
              // 歌名行给它让出 42px：长歌名在图标左边省略，而不是钻到图标底下
              // （Web 的 `body.is-lyrics-page .lyrics-page__head { padding-right: 42px }`）。
              padding: EdgeInsets.only(right: desktop ? 0 : 42),
              child: Row(
                // 富余空间全落在「左组」与下拉之间 —— 这就是 React 那道
                // `margin-left: auto`（app.css 的 .wave-style）：按钮紧跟歌名，
                // 下拉贴最右。
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 左组：歌名块 + 三颗工具按钮（原版 `header.lyrics-page__head`
                  // 就是 meta → ToolButtons → WaveStylePicker 三个孩子，没有返回按钮）。
                  // 组内用 mainAxisSize.min —— 组不撑开，宽度由内容决定。
                  // 窄屏（<900）：这一组连同右边的下拉一起下移到频谱条上方
                  // （见 `transport.dart` 的 `_WaveRow`，对译 app.css 的
                  // `.transport__lyric-row`），页头只剩歌名 —— 手机上一只手够不到顶端。
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: meta),
                        if (desktop) ...[
                          const SizedBox(width: _kHeadGap),
                          // 「T」/毛玻璃/睡眠定时器：桌面沉浸模式里从控制条挪到这一格
                          // （歌名右边、下拉左边），面板随之改向下弹。
                          const ToolButtons(side: ToolPanelSide.below),
                        ],
                      ],
                    ),
                  ),
                  if (desktop) ...[
                    // M3 D.4：右上角是波形样式下拉（原版 App.tsx:1100 的
                    // WaveStylePicker）。面板用 Overlay 挂在更上层，不会被歌词页的
                    // 裁剪/圆角切掉。
                    // 与左侧工具按钮之间补头部 gap（React `.lyrics-page__head { gap: 12px }`）：
                    // 这一行是 spaceBetween，空间紧张时左组会把下拉挤到贴住工具按钮，
                    // 没有这段固定间距两颗控件边框会相贴。
                    const SizedBox(width: _kHeadGap),
                    const WaveStylePicker(),
                  ],
                ],
              ),
            ),
            const SizedBox(height: _kPageGap),
            // 正文不再是热区本身：热区已经包在整页外面（见 [body] 与
            // [_maybeTapToRestore]），点页头那一带同样能切回简约模式。
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: tokens.border)),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: _kBodyPaddingTop),
                  child: desktop
                      ? _desktopBody(lyrics: lyrics, bilingual: bilingual)
                      : _narrowBody(lyrics: lyrics, bilingual: bilingual),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (PlayerCardScope.maybeOf(context) != null) {
      return body;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        // `background: linear-gradient(170deg, var(--card-a), var(--card-b))`
        gradient: LinearGradient(
          begin: const Alignment(0, -0.85),
          end: const Alignment(0.35, 1),
          colors: [tokens.cardA, tokens.cardB],
        ),
        borderRadius: BorderRadius.circular(kLyricsPageRadius),
        border: Border.all(color: tokens.border),
        boxShadow: tokens.shadowCard,
      ),
      child: body,
    );
  }

  /// 窄屏（<900）里「点卡片任意处 → 切回简约模式（封面页）」的热区。
  ///
  /// 为什么需要：手机上没有 Esc / L，页内也不再放「返回」胶囊（见文件头），
  /// 退出只剩顶栏那颗模式按钮 —— 手指要够到右上角，还是个小图标。
  /// 于是把**整页**（歌名那条带 + 正文，即 `.lyrics-page__head` 与
  /// `.lyrics-page__body`）做成热区：点哪儿都 `LyricsPageController.close()`，
  /// 回到封面页。控制条上那行工具（`.transport__lyric-row`）在 `transport.dart`
  /// 里另挂一个同样的热区 —— 那一行不在本页子树内。
  ///
  /// 三处**有意排除**（改之前先读）：
  ///   * 歌词行自己那颗 `GestureDetector`（点击定位播放）留在里层 —— 内层识别器
  ///     在竞技场里先入先赢，点文字仍然是定位，不会误退出；
  ///   * 页头的按钮（「双语」开关 / 三颗工具按钮 / 波形下拉）同样是内层识别器，
  ///     点它们照旧弹面板；只有它们周围的空白算热区；
  ///   * 频谱条在控制条的 `transport__wave` 行里，根本不在本页子树内，
  ///     点它不触发（频谱是纯装饰）。
  ///
  /// 只在窄屏生效：桌面有 Esc / L，鼠标还容易误点留白，不做这个热区。
  Widget _maybeTapToRestore({required bool enabled, required Widget child}) {
    final controller = context.read<LyricsPageController?>();
    if (!enabled || controller == null) return child;
    return GestureDetector(
      key: const Key('lyrics-tap-to-simple'),
      // opaque：两行歌词之间的留白、页头两侧的内边距也算热区
      // （子树没底的像素同样要能点到）。
      behavior: HitTestBehavior.opaque,
      onTap: controller.close,
      child: child,
    );
  }

  /// 桌面：左歌词、右封面，两列作为整体居中（`justify-content: center`）。
  ///
  /// 列宽逐字对译 CSS 的 `grid-template-columns: minmax(0, 560px)
  /// clamp(240px, 26vw, 360px)`（:2328），大屏两档各自放宽
  /// （[`_columnMaxWidth`] / [`_coverWidth`] / [`_bodyColumnGap`]）：
  ///   * 左列上限 560 / 640（≥1280）/ 800（≥1680）（`minmax(0, N)` 的下界 0
  ///     由 [Flexible] 承担 —— 窗口变窄时它先缩，不会把两列撑破）；
  ///   * 右列固定 `clamp(...)`；
  ///   * 两者一起居中，所以左边距与右边距相等（原版注释专门写过：左列以前是
  ///     `1fr`，词块在轨道里再居中，结果左侧多出一截、右侧封面却贴边）。
  Widget _desktopBody({
    required LyricsState lyrics,
    required BilingualState bilingual,
  }) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final artWidth = _coverWidth(viewportWidth);
    final columnMax = _columnMaxWidth(viewportWidth);
    final columnGap = _bodyColumnGap(viewportWidth);
    final track = lyrics.track;
    // M2b T10：封面源走 resolver（四级兜底；CoverState 可空 watch，同
    // stage.dart 的容错模式 —— 测试环境没注册时退回 M1 的内嵌路径）。
    final cover = context.watch<CoverState?>();
    final displayPath = cover == null || track == null
        ? (track?.cover ?? '')
        : cover.coverForDisplay(
            cover: track.cover,
            artist: track.artist,
            title: track.title,
            trackId: track.id,
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: columnMax),
            child: _leftColumn(lyrics: lyrics, bilingual: bilingual),
          ),
        ),
        SizedBox(width: columnGap),
        SizedBox(
          width: artWidth,
          child: _ArtColumn(
            coverPath: displayPath,
            fallbackArtist: track?.artist ?? '',
            fallbackTitle: track?.title ?? '',
            // M2b T11：原版封面外壳是按钮（art-btn，App.tsx:1121-1137），
            // 点它开灯箱；控制器缺省（纯展示测试）时传 null 不参与竞技场。
            onOpenLightbox: context.read<LightboxController?>()?.open,
          ),
        ),
      ],
    );
  }

  /// 窄屏：单列，右栏整块不出现（原版的 `@media` 隐藏）。
  Widget _narrowBody({
    required LyricsState lyrics,
    required BilingualState bilingual,
  }) => _leftColumn(lyrics: lyrics, bilingual: bilingual);

  /// 左列：状态行 +（状态块 或 歌词）。
  Widget _leftColumn({
    required LyricsState lyrics,
    required BilingualState bilingual,
  }) {
    final note = bilingual.note;
    final status = lyrics.status;
    final hasLines = lyrics.cues.isNotEmpty || lyrics.plainLines.isNotEmpty;
    final showBlock = _isFailedState(lyrics.state) && !hasLines;

    // 状态块与状态行**不要同时念同一句话**：原版这两处本就互斥（空态块用
    // `status`，右栏脚注只在 `state === 'ready'` 时出现，App.tsx:1109 / :1146）。
    // 这里两者都在，于是让状态行在「有状态块」时只承担 `note`（译文说明），
    // 空态块自己负责 `status`；没有状态块时再退回 `note → status` 的原顺序。
    final statusText = note.isNotEmpty
        ? note
        : (showBlock ? '' : status);
    final showStatusLine = statusText.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showStatusLine)
          LyricsStatusLine(
            status: statusText,
            loading: lyrics.state == LyricsLoad.loading,
            failed: _isFailedState(lyrics.state),
            showRetry: lyrics.showRetry,
            onRetry: lyrics.retry,
          ),
        if (showBlock)
          Expanded(
            child: _EmptyState(
              title: status.isNotEmpty ? status : '正在加载歌词…',
              showRetry: lyrics.showRetry,
              onRetry: lyrics.retry,
            ),
          )
        else ...[
          if (showStatusLine) const SizedBox(height: _kStatusLineBottomGap),
          const Expanded(child: LyricsView(variant: LyricsVariant.full)),
        ],
      ],
    );
  }
}

/// `loading` / `missing` / `error` 三态共用同一套「状态块」判据。
///
/// 注意 `failed` 覆盖 missing 与 error（T16 的 `LyricsStatusLine.failed` 语义），
/// 与 `showRetry` 是**两个独立标量** —— 离线那档是 missing 却不给重试。
bool _isFailedState(LyricsLoad state) =>
    state == LyricsLoad.missing || state == LyricsLoad.error;

/// 封面宽度：`clamp(240px, 26vw, 360px)`；大屏两档各自放宽
/// （≥1280 `clamp(280, 24vw, 400)`、≥1680 `clamp(360, 25vw, 480)`）。
double _coverWidth(double viewportWidth) {
  if (viewportWidth >= Breaks.ultra) {
    return _clamp(360, viewportWidth * 0.25, 480);
  }
  if (viewportWidth >= Breaks.wide) {
    return _clamp(280, viewportWidth * 0.24, 400);
  }
  return _clamp(
    _kCoverMinWidth,
    viewportWidth * _kCoverViewportRatio,
    _kCoverMaxWidth,
  );
}

/// 左列上限：560 / 640（≥1280）/ 800（≥1680）。
double _columnMaxWidth(double viewportWidth) {
  if (viewportWidth >= Breaks.ultra) return 800;
  if (viewportWidth >= Breaks.wide) return 640;
  return _kColumnMaxWidth;
}

/// 两列间距：`gap: 32px`；≥1280 抬到 40、≥1680 抬到 56（阅读列放宽后要跟上）。
double _bodyColumnGap(double viewportWidth) {
  if (viewportWidth >= Breaks.ultra) return 56;
  if (viewportWidth >= Breaks.wide) return 40;
  return _kBodyGap;
}

double _clamp(double min, double value, double max) =>
    value < min ? min : (value > max ? max : value);

/// `[artist, album].filter(Boolean).join(' · ') || '未知歌手'`（App.tsx:1101）。
String _artistAlbum(Track? track) {
  if (track == null) return '未知歌手';
  final parts = <String>[
    if (track.artist.isNotEmpty) track.artist,
    if (track.album.isNotEmpty) track.album,
  ];
  return parts.isEmpty ? '未知歌手' : parts.join(' · ');
}

/// 右栏：封面（原版外壳是按钮 —— 点它开灯箱，App.tsx:1121-1137 的
/// `art-btn`；[onOpenLightbox] 为 null 时保持 M2a 的不可点容器）+ 来源脚注。
class _ArtColumn extends StatelessWidget {
  const _ArtColumn({
    required this.coverPath,
    this.fallbackArtist = '',
    this.fallbackTitle = '',
    this.onOpenLightbox,
  });

  final String coverPath;

  /// 生成卡派生字段（M2b T10）：无封面文件时碟面画生成卡。
  final String fallbackArtist;
  final String fallbackTitle;

  /// 点封面开灯箱（M2b T11）；null = 不可点（纯展示测试的退路）。
  final VoidCallback? onOpenLightbox;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 方图（`aspect-ratio: 1 / 1`），与右栏宽度一致。
          final size = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : _kCoverMaxWidth;
          // **不是黑胶碟面**：原版的 `.lyrics-page__cover` 是一张
          // 「1px 描边 + 24px 圆角 + 落影」的方图（app.css:3318-3327），
          // 没有 `.stage__vinyl` 那圈唱机外圈，也不是正圆。
          // 从前这里复用 [CoverDisc]，于是画成了圆形碟面 —— 与原版差一截。
          final art = ClipRRect(
            borderRadius: BorderRadius.circular(kRadiusXl),
            child: Container(
              key: const Key('lyrics-page-cover'),
              width: size,
              height: size,
              decoration: BoxDecoration(
                border: Border.all(color: tokens.borderStrong),
                borderRadius: BorderRadius.circular(kRadiusXl),
                color: tokens.tint1,
                boxShadow: tokens.shadowCard,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(kRadiusXl - 1),
                child: coverPath.isNotEmpty
                    ? Image.file(
                        File(coverPath),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stack) =>
                            _GeneratedCover(artist: fallbackArtist, title: fallbackTitle),
                      )
                    : _GeneratedCover(artist: fallbackArtist, title: fallbackTitle),
              ),
            ),
          );
          if (onOpenLightbox == null) return art;
          return Semantics(
            button: true,
            label: '放大封面图片',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpenLightbox,
              child: Focus(
                canRequestFocus: true,
                child: art,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 无封面文件时的生成卡（与 [CoverImage] 同一套派生）。
class _GeneratedCover extends StatelessWidget {
  const _GeneratedCover({required this.artist, required this.title});

  final String artist;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (artist.isEmpty) {
      return ColoredBox(
        color: context.tokens.progressTrack,
        child: Center(
          child: Icon(
            Icons.music_note,
            size: 28,
            color: context.tokens.textFaint,
          ),
        ),
      );
    }
    return GeneratedCoverView(
      spec: generatedCoverSpec(artist, title),
      size: double.infinity,
    );
  }
}

/// 空态块：居中的一句话 + 重试按钮（`.lyrics-page__empty`，:3206-3234）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.showRetry,
    required this.onRetry,
  });

  final String title;
  final bool showRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kEmptyMaxWidth),
        child: Padding(
          padding: _kEmptyPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: _kEmptyTitleFontSize,
                  height: _kEmptyTitleLineHeight,
                  color: tokens.textDim,
                ),
              ),
              if (showRetry) ...[
                const SizedBox(height: _kEmptyGap),
                TextButton(
                  key: const Key('lyrics-retry'),
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, _kEmptyRetryMinHeight),
                    padding: const EdgeInsets.symmetric(
                      horizontal: _kEmptyRetryHorizontalPadding,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: tokens.accentLight,
                    backgroundColor: tokens.accentSoft,
                    textStyle: const TextStyle(fontSize: _kEmptyRetryFontSize),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                      side: BorderSide(color: tokens.accentLine),
                    ),
                  ),
                  child: const Text('重试'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 双语开关的 tooltip（四档，逐字对译 `BilingualToggle.tsx:26-31`）。
///
/// T14 只产出 `note`，四档的组合规则在调用方 —— 这里就是那一层。
String _tooltipFor(BilingualState bilingual) {
  switch (bilingual.state) {
    case TranslationState.loading:
      return '正在获取中文译文…';
    case TranslationState.none:
      return '译文库里没有这首歌的中文译文';
    case TranslationState.unavailable:
      return '中文译文依赖本地代理服务（npm run dev）';
    case TranslationState.error:
      // 原版 `transNote || '中文译文获取失败'`：有 note 用它，没有就兜底。
      return bilingual.note.isNotEmpty ? bilingual.note : '中文译文获取失败';
    case TranslationState.idle:
    case TranslationState.ready:
    case TranslationState.off:
      return bilingual.enabled ? '关闭中文译文对照' : '开启中文译文对照';
  }
}
