// lib/ui/stage.dart
//
// 播放卡：对译 `src/styles/app.css` 的 `.stage` 一族（`.stage__cover-wrap`、
// `.stage__title`、`.stage__artist`、`.stage__album`）。
//
//   ┌──────────────────────────────┐
//   │           圆碟封面            │  ← 独立热区（M2 打开灯箱）
//   │           曲名 + 损坏角标      │  ┐
//   │           歌手                │  ├ 一整块热区（M2 进歌词页）
//   │           专辑（有才显示）      │  │
//   │           ── 歌词占位 66px ──  │  ┘
//   │          当前 / 总时长（贴底）  │
//   └──────────────────────────────┘
//
// 两条硬约束：
//   1. 进度不进 `ChangeNotifier`。整卡只在语义变化时重建，`player.position`
//      只被时间行那一层 `ValueListenableBuilder` 订阅 —— 一秒四次的重绘必须
//      只落在那一行 `Text` 上。
//   2. M1 不做歌词。歌词位按 M2 的真实高度留出来（固定 66），两块热区的回调
//      现在是空实现，注释里标了 M2 的去向。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../core/format_time.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import 'vinyl_deck.dart';

/// 空态标题（原版 `IDLE_TITLE`）。
const String kIdleStageTitle = '未选择曲目';

/// 空态副标题（原版 `IDLE_ARTIST`）。
const String kIdleStageArtist = '从播放列表选一首开始';

/// 曲目没有歌手名时的占位。
const String kUnknownStageArtist = '未知歌手';

/// 歌词位高度：M2 的歌词预览按这个高度设计，换实现不改卡片布局。
const double kLyricsSlotHeight = 66;

/// 真实入口：从 [PlayerState] 取当前曲目与进度。
class Stage extends StatelessWidget {
  const Stage({super.key});

  @override
  Widget build(BuildContext context) {
    // 只订阅语义变化（切歌 / 播放 / 损坏…）；position 单独走 ValueListenable
    final player = context.watch<PlayerState>();
    final track = player.view.value.current;
    // 总时长的两级取值（终审 minor 3，与 `TransportBar._totalOf` 同一思路）：
    // 标签里有时长就以标签为准（那是权威元数据，内核报的往往晚到），
    // 标签没有（ID3v1-only / 无标签文件 / 探测失败）就回退内核那个
    // `transport.duration` 的 ValueNotifier —— 从前这里只读标签，于是这类
    // 曲目即使内核早就知道多长，卡片也一直挂着 `--:--`（ledger T26）。
    // 两处都不知道才是 `--:--`。
    final labeled = track != null && track.hasDuration ? track.duration : null;
    return StagePreview(
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
        // M2：打开封面灯箱（原版 stage__cover-wrap 的点击）
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
        // M2：进入完整歌词页
        onTap: () {},
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
            const _LyricsSlot(),
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
              Expanded(child: Center(child: content)),
              timeLine,
            ],
          );
        },
      ),
    );
  }

  /// 曲名行：长曲名省略号截断，「损坏」角标挂在右侧。
  Widget _titleRow(AppTokens tokens) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
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
        if (broken) ...[const SizedBox(width: 8), const _BrokenBadge()],
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

/// 歌词位（M2 填充）：高度先按真实预览留好，不给布局返工的机会。
class _LyricsSlot extends StatelessWidget {
  const _LyricsSlot();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      height: kLyricsSlotHeight,
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
