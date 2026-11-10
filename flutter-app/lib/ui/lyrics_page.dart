// lib/ui/lyrics_page.dart
//
// 全屏歌词页：对译 React 版 `src/App.tsx:1019-1156` 的 `LyricsPage` 组件与
// `src/styles/app.css` 的 `.lyrics-page` 一族（:2032-2330 的骨架、
// :2990-3090 的封面/状态/脚注、:3167-3230 的空态与重试）。
//
// 结构与原版逐块对齐：
//   * 头部 `.lyrics-page__head`：左侧 `.lyrics-page__meta`（歌名 + 双语开关一行、
//     `artist · album` 一行），**右上角本段留空** —— 原版那里是 `WaveStylePicker`，
//     属于 M3，不在这里凭空造一个；
//   * 正文 `.lyrics-page__body`：宽 ≥900 两列 `minmax(0, 560px) clamp(240px, 26vw,
//     360px)`、gap 32、顶上一道 `border-top`；窄屏单列且**整块封面不出现**
//     （原版靠 `@media` 把 `.lyrics-page__art` 藏掉）；
//   * 左列是「状态块 或 歌词」，**二选一**（原版 :1106-1113）：`loading` / `missing` /
//     `error` 三态给居中的一句话 + 重试按钮，其余情况才渲染 `LyricsView(full)`。
//
// 与原版的两处有意差异（改之前先读）：
//
// 1. **返回按钮放在左上角，原版没有这颗按钮**。原版靠「点歌词以外的空白」
//    （`:1074-1083` 的 `onBlankClick`）+ Esc 关闭；M2a 的布局里歌词页占满内容区，
//    触屏与读屏用户需要一个明确的出口，所以计划在头部左侧加一颗「返回」。
//    读屏名固定「关闭歌词页」（图标 + 文案，`Semantics(button: true)`）。
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
// 关闭后焦点还给曲目区（`:1085-1090` 的 `onClose` 语义）：打开时记住当前焦点，
// 关闭时 `requestFocus`；拿不到就退到 `stage-hit-area` 那个语义节点。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../playback/track.dart';
import '../state/bilingual_state.dart';
import '../state/cover_state.dart';
import '../state/lyrics_page_controller.dart';
import '../state/lightbox_controller.dart';
import '../state/lyrics_state.dart';
import '../theme/app_tokens.dart';
import 'bilingual_toggle.dart';
import 'lyrics_status.dart';
import 'lyrics_view.dart';
import 'vinyl_deck.dart';

// -- 规格常量（逐字取自 app.css，不要顺手改） ------------------------------

/// 页面内边距：`padding: 16px 16px 6px`（:2042）。
const EdgeInsets _kPagePadding = EdgeInsets.fromLTRB(16, 16, 16, 6);

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
const double _kColumnMaxWidth = 560;

/// 右栏封面宽度：`clamp(240px, 26vw, 360px)`（:2328）。
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

/// 「返回」按钮：与原版 `--radius-pill` 同族的胶囊，高度跟头部一行走（36）。
const double _kBackHeight = 36;
const double _kBackHorizontalPadding = 12;
const double _kBackFontSize = 12.5;
const double _kBackIconSize = 16;

/// 状态行与正文之间的间距（T16 的 `LyricsStatusLine` 自带 bottom 4，
/// 这里再补一点，免得贴着第一行歌词）。
const double _kStatusLineBottomGap = 6;

/// 曲目区语义节点的 key（T18 的 `stage.dart` 用的是同一个字面量）。
///
/// 关闭歌词页后如果原来的焦点节点已经没了，理论上该回落到这里；但 Flutter 没有
/// 「按 Key 取 FocusNode」的公开 API，而曲目区那块的可点区域也不持有可注入的
/// 节点 —— 所以本页只做「还回原焦点」，剩下的交给快捷键宿主的 autofocus。
/// 这条常量留着是为了让 T20 验收时能一眼看出「回落到哪里」的约定。
const Key kStageHitAreaKey = Key('stage-hit-area');

/// 全屏歌词页。由 `HomeLayout.overlay` 槽挂上，开合由 `LyricsPageController` 决定。
class LyricsPage extends StatefulWidget {
  const LyricsPage({this.onClose, super.key});

  /// 关闭动作。装配层传 `LyricsPageController.close`；测试可注入别的实现。
  /// 给了它就用它，没给就直接调 provider 上的控制器。
  final VoidCallback? onClose;

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  /// 打开这一页时页面焦点所在（关闭后要还回去）。
  ///
  /// 原版没有这一步（它没有返回按钮，关闭靠空白点击 / Esc，焦点本来就还在
  /// 曲目区上）。M2a 加了返回按钮，点它之后焦点落在这颗按钮上，直接关掉会
  /// 悬空 —— 所以进页面时记一份、关时还一份。
  FocusNode? _returnFocus;

  @override
  void initState() {
    super.initState();
    _returnFocus = FocusManager.instance.primaryFocus;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final lyrics = context.watch<LyricsState>();
    final bilingual = context.watch<BilingualState>();
    final track = lyrics.track;
    // 宽 ≥900 才两列；窄屏整块右栏（含封面）不出现。
    final desktop = isDesktop(MediaQuery.sizeOf(context).width);

    final titleRow = Row(
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
      child: Padding(
        padding: _kPagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _BackButton(onTap: _close),
                const SizedBox(width: _kHeadGap),
                Expanded(child: meta),
                // 右上角本段留空：原版是 WaveStylePicker，属 M3（不要凭空造）。
              ],
            ),
            const SizedBox(height: _kPageGap),
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
  }

  /// 桌面：左歌词、右封面，两列作为整体居中（`justify-content: center`）。
  ///
  /// 列宽逐字对译 CSS 的 `grid-template-columns: minmax(0, 560px)
  /// clamp(240px, 26vw, 360px)`（:2328）：
  ///   * 左列上限 560（`minmax(0, 560px)` 的下界 0 由 [Flexible] 承担 —— 窗口
  ///     变窄时它先缩，不会把两列撑破）；
  ///   * 右列固定 `clamp(240, 26vw, 360)`；
  ///   * 两者一起居中，所以左边距与右边距相等（原版注释专门写过：左列以前是
  ///     `1fr`，词块在轨道里再居中，结果左侧多出一截、右侧封面却贴边）。
  Widget _desktopBody({
    required LyricsState lyrics,
    required BilingualState bilingual,
  }) {
    final artWidth = _coverWidth(MediaQuery.sizeOf(context).width);
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
            constraints: const BoxConstraints(maxWidth: _kColumnMaxWidth),
            child: _leftColumn(lyrics: lyrics, bilingual: bilingual),
          ),
        ),
        const SizedBox(width: _kBodyGap),
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

  /// 关页：先让控制器翻掉（`HomeLayout.overlay` 随之摘掉），再把焦点还回去。
  void _close() {
    final injected = widget.onClose;
    if (injected != null) {
      injected();
    } else {
      context.read<LyricsPageController>().close();
    }
    _restoreFocus();
  }

  void _restoreFocus() {
    final previous = _returnFocus;
    // 还焦点必须在页面被摘掉之后：这一页里的按钮还在焦点域里时 requestFocus
    // 会被它抢回去。排到下一帧（overlay 已经换成原来的 stage）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 原来的焦点节点还活着就还给它（`context` 是节点是否仍挂载的判据）。
      if (previous != null && previous.context != null) {
        previous.requestFocus();
      }
      // 拿不到就什么都不做：焦点会回落到快捷键宿主的 autofocus 节点
      // （`AppShortcuts` 里那个 `autofocus: true` 的 Focus），
      // 键盘操作照常可用。原版也没有更强的「回焦到曲目区」保证。
    });
  }
}

/// `loading` / `missing` / `error` 三态共用同一套「状态块」判据。
///
/// 注意 `failed` 覆盖 missing 与 error（T16 的 `LyricsStatusLine.failed` 语义），
/// 与 `showRetry` 是**两个独立标量** —— 离线那档是 missing 却不给重试。
bool _isFailedState(LyricsLoad state) =>
    state == LyricsLoad.missing || state == LyricsLoad.error;

/// 封面宽度：`clamp(240px, 26vw, 360px)`。
double _coverWidth(double viewportWidth) =>
    (viewportWidth * _kCoverViewportRatio).clamp(
      _kCoverMinWidth,
      _kCoverMaxWidth,
    );

/// `[artist, album].filter(Boolean).join(' · ') || '未知歌手'`（App.tsx:1101）。
String _artistAlbum(Track? track) {
  if (track == null) return '未知歌手';
  final parts = <String>[
    if (track.artist.isNotEmpty) track.artist,
    if (track.album.isNotEmpty) track.album,
  ];
  return parts.isEmpty ? '未知歌手' : parts.join(' · ');
}

/// 「返回」胶囊：图标 + 文案，读屏名「关闭歌词页」。
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: '关闭歌词页',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: tokens.tint1,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          overlayColor: WidgetStatePropertyAll<Color>(tokens.accentSoft),
          child: Container(
            height: _kBackHeight,
            padding: const EdgeInsets.symmetric(
              horizontal: _kBackHorizontalPadding,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: tokens.progressTrack),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_back_ios_new,
                  size: _kBackIconSize,
                  color: tokens.textDim,
                ),
                const SizedBox(width: 4),
                Text(
                  '返回',
                  style: TextStyle(
                    fontSize: _kBackFontSize,
                    color: tokens.textDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 圆碟按可用宽度收，与右栏宽度一致（`aspect-ratio: 1 / 1` 的等价写法）。
          final size = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : _kCoverMaxWidth;
          final disc = SizedBox(
            key: const Key('lyrics-page-cover'),
            width: size,
            height: size,
            // 静态、不转：M1 的 CoverDisc 就这个形态（spinning 恒 false）。
            child: CoverDisc(
              coverPath: coverPath,
              size: size,
              spinning: false,
              fallbackArtist: fallbackArtist,
              fallbackTitle: fallbackTitle,
            ),
          );
          if (onOpenLightbox == null) return disc;
          return Semantics(
            button: true,
            label: '放大封面图片',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpenLightbox,
              child: Focus(
                canRequestFocus: true,
                child: disc,
              ),
            ),
          );
        },
      ),
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
