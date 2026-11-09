// lib/ui/stage.dart
//
// 播放卡：对译 `src/styles/app.css` 的 `.stage` 一族（`.stage__cover-wrap`、
// `.stage__title-row`、`.stage__title`、`.stage__artist`、`.stage__album`、
// `.stage__meta`、`.stage__lyrics`）与 React `src/App.tsx:380-533` 的 `Stage` 组件。
//
//   ┌──────────────────────────────┐
//   │           圆碟封面            │  ← 独立热区（M2b 打开灯箱）
//   │           曲名 ←→ 双语开关     │  ┐
//   │           歌手                │  ├ 一整块热区（进歌词页）
//   │           专辑（有才显示）      │  │
//   │           ── 歌词条 ──         │  ┘
//   │          当前 / 总时长（贴底）  │
//   └──────────────────────────────┘
//
// 四条硬约束：
//   1. 进度不进 `ChangeNotifier`。整卡只在语义变化时重建，`player.position`
//      只被时间行那一层 `ValueListenableBuilder` 订阅 —— 一秒四次的重绘必须
//      只落在那一行 `Text` 上。
//   2. [StagePreview] 保持**纯展示**：T18 新增的 `lyrics` / `titleTrailing` /
//      `onOpenLyrics` 三个参数默认 null，null 时一律退回 M1 的原样。状态层的
//      接线全在 [Stage] 里，widget 脱离状态层仍可独立测（既有 286 行用例）。
//   3. 颜色一律 `context.tokens`，本文件不出现颜色字面量。
//   4. 歌词区高度是 CSS 的 `clamp(112px, 15vh, 132px)`（app.css:1903-1906），
//      用 [compactLyricsHeight] 现算，不再是 M1 那个固定 66。
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../core/format_time.dart';
import '../state/bilingual_state.dart';
import '../state/lyrics_page_controller.dart';
import '../state/lyrics_state.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import 'bilingual_toggle.dart';
import 'lyrics_status.dart';
// T17 并行产出；本文件只用到 `LyricsView(variant: LyricsVariant.compact)`。
import 'lyrics_view.dart';
import 'swipe_to_switch.dart';
import 'vinyl_deck.dart';

/// 空态标题（原版 `IDLE_TITLE`）。
const String kIdleStageTitle = '未选择曲目';

/// 空态副标题（原版 `IDLE_ARTIST`）。
const String kIdleStageArtist = '从播放列表选一首开始';

/// 曲目没有歌手名时的占位。
const String kUnknownStageArtist = '未知歌手';

/// 歌词条高度：CSS `height: clamp(112px, 15vh, 132px)`（app.css:1903-1906）。
///
/// 原版注释：「桌面留给歌词的高度由封面与信息区挤出来，随视口高度伸缩，且不顶破
/// stage」。三档钳位是字面的 `clamp`：低视口给足 112（约 4 行）、高视口封顶 132。
double compactLyricsHeight(double viewportHeight) =>
    (viewportHeight * 0.15).clamp(112.0, 132.0);

/// 窄屏断点：`@media (max-width: 899px)`（app.css:3940，CSS 的 max-width 含等号，
/// 所以是 `< 900`）。窄屏 ready 态隐藏状态行，见 [_StageLyrics]。
const double _kNarrowWidth = 900;

/// 旧占位块的高度（M1 的 66）。只在调用方**没给** `lyrics` 时用。
///
/// 保留它而不是直接删掉这个占位：`StagePreview` 是纯展示组件，既有调用点
/// （预览、老用例、T18 之前写下的 widget 测试）不传 `lyrics` 时必须还是原样。
const double _kLegacyLyricsSlotHeight = 66;

/// 真实入口：从状态层取当前曲目、歌词与双语开关状态。
class Stage extends StatelessWidget {
  const Stage({super.key});

  @override
  Widget build(BuildContext context) {
    // 只订阅语义变化（切歌 / 播放 / 损坏…）；position 单独走 ValueListenable
    final player = context.watch<PlayerState>();
    // 这三个 provider 由 `app.dart` 注册（`LyricsState` / `BilingualState` 归 T15，
    // `LyricsPageController` 归 T18）。写成可空泛型 `watch<T?>()`：provider 包的
    // `Provider.of<T?>` 在「没有注册这个类型」时返回 null 而不是抛
    // （provider.dart 的 `null is! T` 守卫），这样 T18 单独落地、T15 还没接上时
    // 播放卡照常能画（歌词区退回占位、开关不出现、点热区不打开页面）。
    final lyricsState = context.watch<LyricsState?>();
    final bilingual = context.watch<BilingualState?>();
    final page = context.read<LyricsPageController?>();
    final track = player.view.value.current;
    // 总时长的两级取值（终审 minor 3，与 `TransportBar._totalOf` 同一思路）：
    // 标签里有时长就以标签为准（那是权威元数据，内核报的往往晚到），
    // 标签没有（ID3v1-only / 无标签文件 / 探测失败）就回退内核那个
    // `transport.duration` 的 ValueNotifier —— 从前这里只读标签，于是这类
    // 曲目即使内核早就知道多长，卡片也一直挂着 `--:--`（ledger T26）。
    // 两处都不知道才是 `--:--`。
    final labeled = track != null && track.hasDuration ? track.duration : null;

    final preview = StagePreview(
      title: track?.title ?? kIdleStageTitle,
      artist: switch (track) {
        null => kIdleStageArtist,
        final t when t.artist.isEmpty => kUnknownStageArtist,
        final t => t.artist,
      },
      album: track?.album ?? '',
      total: formatTime(labeled),
      // 标签有时长时不订阅内核那一路：免得内核报的旧值盖掉权威元数据。
      totalFromKernel: labeled == null ? player.duration : null,
      position: player.position,
      coverPath: track?.cover ?? '',
      broken: track?.broken ?? false,
      // 点曲目区任意留白进歌词页（原版 `App.tsx:410-421` 的 onStageClick）。
      // 没有控制器时给 null，`StagePreview` 退回 M1 的空实现。
      onOpenLyrics: page?.open,
      // 标题行尾部：只有非中文歌词才出「双语」开关（原版组件里那句
      // `if (!translatable) return null`，由调用方判 —— 见 bilingual_toggle.dart）。
      titleTrailing: bilingual != null && bilingual.translatable
          ? BilingualToggle(
              enabled: bilingual.enabled,
              onChanged: bilingual.setEnabled,
              tooltip: _toggleTooltip(bilingual),
            )
          : null,
      lyrics: _StageLyrics(state: lyricsState, bilingual: bilingual),
    );

    // 左右滑切歌（原版 `App.tsx:332-378` 的 useTrackSwipe，挂在 `<section.stage>` 上）。
    // `next()` / `previous()` 返回 Future<void>，这里包一层 lambda 当 VoidCallback。
    return SwipeToSwitchTrack(
      onPrev: () => player.previous(),
      onNext: () => player.next(),
      child: preview,
    );
  }
}

/// 「双语」开关的读屏说明，逐字对译 `BilingualToggle.tsx:26-38` 的 `titleMap`。
///
/// 四档取 [BilingualState.state]（`TranslationState`），其余落回开关自身的开 / 关
/// 说明。`error` 档优先用 [BilingualState.note]（原版 `transNote || '中文译文获取失败'`）。
String _toggleTooltip(BilingualState b) => switch (b.state) {
  TranslationState.loading => '正在获取中文译文…',
  TranslationState.none => '译文库里没有这首歌的中文译文',
  TranslationState.unavailable => '中文译文依赖本地代理服务（npm run dev）',
  TranslationState.error => b.note.isNotEmpty ? b.note : '中文译文获取失败',
  _ => b.enabled ? '关闭中文译文对照' : '开启中文译文对照',
};

/// 播放卡内的歌词条整块：状态行 + 固定高度的紧凑歌词视图。
///
/// 对译 `App.tsx:498-530` 的 `<div className="stage__lyrics">`：
///   * 状态行只在「有话要说」时出现 —— 原版是
///     `{(transNote || status) && <p ...>}`，译文说明优先于歌词状态（`:499-502`）；
///   * 窄屏（`< 900`）的 ready 态隐藏状态行（app.css:3988-3990：
///     「小屏不显示『歌词自动匹配自…』这行来源说明；加载 / 失败状态仍保留」），
///     所以要判 `width < 900` 且只在非加载、非失败时藏。
///
/// 状态为空（ready 且无译文说明）时整块 `SizedBox.shrink()` —— 但**歌词本体仍要
/// 占位**，原版 `.lyrics--compact` 的高度是写死的 clamp，不随状态行有无伸缩。
class _StageLyrics extends StatelessWidget {
  const _StageLyrics({required this.state, required this.bilingual});

  final LyricsState? state;
  final BilingualState? bilingual;

  @override
  Widget build(BuildContext context) {
    final lyrics = state;
    // provider 还没接上（T15 之前的装配）：保留 M1 的占位块，不闪不塌。
    if (lyrics == null) return const _LyricsSlot();

    final note = bilingual?.note ?? '';
    final status = note.isNotEmpty ? note : lyrics.status;
    final loading = lyrics.state == LyricsLoad.loading;
    final failed =
        lyrics.state == LyricsLoad.missing || lyrics.state == LyricsLoad.error;
    final narrow = MediaQuery.sizeOf(context).width < _kNarrowWidth;
    // 窄屏 ready 态藏状态行（CSS 只在 `[data-state="ready"]` 上隐藏，加载 / 失败
    // 两档照旧显示）。译文说明非空时不算 ready —— 它有话要说，必须显示。
    final hiddenOnNarrow = narrow && !loading && !failed && note.isEmpty;
    final showStatus = status.isNotEmpty && !hiddenOnNarrow;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showStatus)
          LyricsStatusLine(
            status: status,
            loading: loading,
            failed: failed,
            showRetry: lyrics.showRetry,
            onRetry: lyrics.retry,
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            // CSS 的 clamp(112px, 15vh, 132px) 是**上限**，不是硬高度：桌面
            // 卡片被拉满左列时留白充足，照它给；矮视口（例如测试里常见的
            // 152px 卡片）下父级给不了 112，就按可用高度收缩，绝不把整列
            // RenderFlex 顶溢出。T15 接上 provider 之前走的是 M1 的 66 占位，
            // 所以这条守卫只在真实歌词条路径上生效。
            // CSS 的 clamp(112px, 15vh, 132px) 是**上限**，不是硬高度。矮视口
            //（测试里常见 584~800px）下 112 的地板会把整列顶溢出，所以再按
            // 视口高度的 15% 钳一次：正常桌面（≥900px）下 15vh ≥ 135，取 132
            // 与 CSS 完全一致；小视口下退成 15vh，歌词条不至于挤掉控制条。
            final viewport = MediaQuery.sizeOf(context).height;
            final wanted = math.min(
              compactLyricsHeight(viewport),
              viewport * 0.15,
            );
            final height = constraints.hasBoundedHeight
                ? math.min(wanted, constraints.maxHeight)
                : wanted;
            return SizedBox(
              height: height,
              child: const LyricsView(variant: LyricsVariant.compact),
            );
          },
        ),
      ],
    );
  }
}

/// 纯展示的播放卡：测试与预览用它，不依赖任何状态层。
class StagePreview extends StatelessWidget {
  const StagePreview({
    required this.title,
    required this.artist,
    required this.album,
    required this.total,
    this.elapsed = kTimeUnknown,
    this.position,
    this.totalFromKernel,
    this.coverPath = '',
    this.broken = false,
    this.lyrics,
    this.titleTrailing,
    this.onOpenLyrics,
    super.key,
  });

  final String title;
  final String artist;
  final String album;

  /// 静态的当前时间；给了 [position] 就不用它（实时值以 [position] 为准）。
  final String elapsed;

  /// 总时长文案，已格式化（未知时 `--:--`）。
  ///
  /// 标签里有时长时走这里；没有时由 [totalFromKernel] 现场换算（终审 minor 3）。
  final String total;

  /// 内核报的总时长（秒）；标签没时长时用它，实时值以它为准。
  /// null = 标签已经有时长（元数据是权威，不被内核的旧读数盖掉）。
  final ValueListenable<double?>? totalFromKernel;

  /// 实时进度（秒）：只有时间行订阅它。
  final ValueListenable<double>? position;

  final String coverPath;
  final bool broken;

  /// 歌词区整块（T18 由 [Stage] 传进来：状态行 + 紧凑歌词视图）。
  ///
  /// null 时退回 M1 的占位块（66px + 一个波形图标）—— 纯展示组件不许假设
  /// 状态层存在，否则既有的预览用例与 T18 之前的调用点会全部要改。
  final Widget? lyrics;

  /// 标题行尾部槽（T18：放「双语」开关）。
  ///
  /// null 时这一行只有歌名、居中位置不变（原版 css 注释：「没有译文开关时
  /// 这一行只有歌名，居中位置不变」）。
  final Widget? titleTrailing;

  /// 点曲目区进歌词页。null 时保持 M1 的空实现（点了不抛、也不做事）。
  final VoidCallback? onOpenLyrics;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final viewport = MediaQuery.sizeOf(context);
    final coverSize = kCoverSize(
      viewport.width,
      viewportHeight: viewport.height,
    );

    final cover = Semantics(
      key: const Key('cover-disc'),
      button: true,
      label: broken ? '$title（无法播放）封面' : '$title 封面',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // M2b：打开封面灯箱（原版 stage__cover-wrap 的点击）
        onTap: () {},
        child: CoverDisc(
          coverPath: coverPath,
          size: coverSize,
          spinning: false, // M1 黑胶静止，旋转在 M3
        ),
      ),
    );

    final info = Semantics(
      key: const Key('stage-hit-area'),
      button: true,
      label: '查看歌词：$title',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 进完整歌词页（原版 `onStageClick` 派发 app:open-lyrics-page）。
        // null 时不给回调：GestureDetector 在 onTap 为 null 时不参与竞技场，
        // 与 M1 那个空实现的可观察行为一致（点了不抛、也不做事）。
        onTap: onOpenLyrics,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleRow(tokens),
            const SizedBox(height: 4),
            Text(
              artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: tokens.textDim),
            ),
            if (album.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                album,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: tokens.textFaint),
              ),
            ],
            const SizedBox(height: 10),
            // 状态层还没接上（或纯展示的调用点没给）时，退回 M1 的占位块。
            lyrics ?? const _LyricsSlot(),
          ],
        ),
      ),
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: cover),
        const SizedBox(height: 14),
        info,
      ],
    );

    final timeLine = _TimeLine(
      elapsed: elapsed,
      total: total,
      position: position,
      totalFromKernel: totalFromKernel,
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusXl),
        border: Border.all(color: tokens.border),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.cardA, tokens.cardB],
        ),
        boxShadow: tokens.shadowCard,
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄屏档（<900）里卡片在 Column 里拿到的是无界高度，不能放 Expanded；
          // 桌面档卡片被拉满左列，内容居中、时间行贴底。
          if (!constraints.hasBoundedHeight) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [content, const SizedBox(height: 10), timeLine],
            );
          }
          return Column(
            children: [
              // T18 起歌词区是 clamp(112px, 15vh, 132px)，比 M1 那个固定 66 的
              // 占位高。矮视口（测试里常见 152px 卡片）下 content 的自然高度会
              // 超过 Expanded 给的空间，Center 只居中、不会压缩，整列就溢出。
              // 用 SizedBox 给足宽度（content 是 crossAxisAlignment.stretch，
              // 需要有限宽），再让 FittedBox 等比缩到可用高度里；桌面正常视口
              // 留白充足，scaleDown 不动任何尺寸。
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: content,
                  ),
                ),
              ),
              timeLine,
            ],
          );
        },
      ),
    );
  }

  /// 曲名行：歌名居中省略号截断，右侧依次挂「双语」开关与「损坏」角标。
  ///
  /// 对译 `.stage__title-row`（app.css:1039-1044）：`align-items: center` +
  /// `justify-content: center` + `gap: 10px`；没有尾部槽时这一行只有歌名、
  /// 居中位置不变。
  Widget _titleRow(AppTokens tokens) {
    final trailing = titleTrailing;
    final hasSlot = trailing != null || broken;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: tokens.text,
            ),
          ),
        ),
        if (hasSlot) const SizedBox(width: 10),
        ?trailing,
        if (broken) ...[
          if (trailing != null) const SizedBox(width: 8),
          const _BrokenBadge(),
        ],
      ],
    );
  }
}

/// 「损坏」角标：`.stage__badge`（danger-soft 底色 + danger-line 描边）。
class _BrokenBadge extends StatelessWidget {
  const _BrokenBadge();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: tokens.dangerSoft,
        border: Border.all(color: tokens.dangerLine),
      ),
      child: Text(
        '损坏',
        style: TextStyle(fontSize: 10, color: tokens.dangerInk),
      ),
    );
  }
}

/// M1 的歌词占位块：66px + 一个波形图标。
///
/// 只在调用方**没给** `lyrics` 时用（纯展示的调用点、T18 之前的预览与用例，
/// 以及 T15 还没把 provider 接上时的降级态）。T18 之后的真实入口走
/// [_StageLyrics]。
class _LyricsSlot extends StatelessWidget {
  const _LyricsSlot();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      height: _kLegacyLyricsSlotHeight,
      child: Center(
        child: Icon(Icons.graphic_eq, size: 20, color: tokens.progressTrack),
      ),
    );
  }
}

/// `当前 / 总时长` 一行。
///
/// 有 [position] 时只有这一行的 [Text] 跟着 tick 重建 —— 卡片其余部分
/// （封面、曲名、歌词位）不参与重绘。
///
/// 总时长有两条来源（终审 minor 3）：标签里有时长时 [total] 就是定值、
/// [totalFromKernel] 为空；标签没有时 [totalFromKernel] 非空，这一行同时订阅
/// 内核那个 ValueNotifier —— 时长到货时只有这一行 Text 重建，卡片不动。
class _TimeLine extends StatelessWidget {
  const _TimeLine({
    required this.elapsed,
    required this.total,
    required this.position,
    this.totalFromKernel,
  });

  final String elapsed;
  final String total;
  final ValueListenable<double>? position;

  /// 内核报的总时长；null 表示标签已有时长，不必再订阅内核那一路。
  final ValueListenable<double?>? totalFromKernel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = TextStyle(
      fontSize: 11.5,
      color: tokens.textFaint,
      // 等宽数字：时间跳动时行宽不抖
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    /// 一行文字：总长文案由外层决定（标签定值或内核实时值）。
    Widget line(String totalText) {
      final source = position;
      if (source == null) {
        return Text('$elapsed / $totalText', textAlign: TextAlign.center, style: style);
      }
      return ValueListenableBuilder<double>(
        valueListenable: source,
        builder: (context, value, child) => Text(
          '${formatTime(value)} / $totalText',
          textAlign: TextAlign.center,
          style: style,
        ),
      );
    }

    final kernel = totalFromKernel;
    if (kernel == null) return line(total);
    return ValueListenableBuilder<double?>(
      valueListenable: kernel,
      // 内核报 0 / NaN 都算「还不知道」：不许把 --:-- 换成 00:00 那种假象
      builder: (context, value, child) =>
          line(formatTime(value != null && value > 0 ? value : null)),
    );
  }
}
