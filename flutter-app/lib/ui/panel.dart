// lib/ui/panel.dart
//
// 播放列表 / 最近播放面板（T28）：对译 `src/App.tsx:678-830` 与
// `src/styles/app.css` 的 `.panel*` 一族（:1350-1730）。
//
//   ┌───────────────────────────────────────────────┐
//   │ (播放列表)  (最近)                        [×] │  ← 固定行
//   │ (🔍 搜索歌名                            ×)    │  ← 固定行，36 高
//   │ 2 首 · 总时长 07:32                           │  ← 固定行
//   │ [常驻提示条：被拦 / 熔断 + 继续播放]           │  ← 固定行，位置在列表之上
//   │ ┌───────────────────────────────────────────┐ │
//   │ │ 列表（播放列表 tab / 最近 tab 共用这块）   │ │  ← 唯一可伸缩的区域
//   │ └───────────────────────────────────────────┘ │
//   └───────────────────────────────────────────────┘
//
// 四条硬约束：
//   1. **一个搜索框管两个 tab，只搜歌名**。输入即时回显，过滤值走
//      [LibraryState.filteredTracks]（200ms 防抖后的生效值）；清空立刻生效，
//      所以「删到空」不会先闪一帧空态。
//   2. **统计行跟着生效值走**：过滤时 `找到 N 首 · 共 M 首`，否则
//      `M 首 · 总时长 mm:ss`。用原始输入判断会让统计行比列表早一拍跳变。
//   3. **错误常驻在列表上方**：自动播放被拦 / 全列表失败这类事不该用会消失的
//      toast；熔断时只留文案（自动跳已停手，没有可重试的目标）。
//   4. **空态只是说明**：两行文字居中，无虚线框、无图标（见 [EmptyState]）。
//
// 只做布局与接线：没有 Scaffold、没有路由，T29 的弹层直接复用同一个 [Panel]。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../core/format_time.dart';
import '../library/recent_store.dart' show formatRelativeTime, kRecentLimit;
import '../playback/track.dart';
import '../state/library_state.dart';
import '../state/panel_controller.dart';
import '../state/player_state.dart';
import '../state/recent_state.dart';
import '../theme/app_tokens.dart';
import 'empty_state.dart';
import 'recent_row.dart';
import 'track_row.dart';

/// 播放列表 / 最近播放面板。
class Panel extends StatelessWidget {
  const Panel({super.key, this.onClose, this.tickerEnabled = true});

  /// 收起按钮；弹层里才有（侧栏里面板是常驻的，不需要收起）。
  final VoidCallback? onClose;

  /// 音柱 ticker 开关。弹层在后台保留面板（offstage）时由 T29 传 false：
  /// 看不见的面板不该继续按 60fps 走动画。侧栏里恒为 true。
  final bool tickerEnabled;

  /// 「舒适高度」下限。低于它就切到 [Panel] 的兜底布局（整块可滚）。
  ///
  /// 固定行本身就要 120 上下：表头 30 + 10 + 搜索 36 + 8 + 统计 ~20，
  /// 还要放得下一行列表。比这更矮的窗口里硬摆 Column 只会把内容裁掉
  /// （800×600 的窗口就是这么挤出来的），所以改由外层滚动兜住。
  static const double minComfortableHeight = 240;

  /// 兜底布局里给列表的固定高度：列表在这块里自己滚，外层滚冒出来的其余行。
  static const double compactBodyHeight = 240;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final library = context.watch<LibraryState>();
    final player = context.watch<PlayerState>();
    final recent = context.watch<RecentState>();
    final tab = context.select<PanelController, PanelTab>((c) => c.tab);
    final controller = context.read<PanelController>();
    final notice = player.circuitOpen || player.blockedMessage != null
        ? PanelNotice(
            message: player.circuitOpen
                ? '连续多首无法播放，已停止自动切歌'
                : player.blockedMessage!,
            actionLabel: player.circuitOpen ? null : '继续播放',
            onAction: player.circuitOpen
                ? null
                : () => unawaited(player.userGesture()),
          )
        : null;
    final body = TickerMode(
      enabled: tickerEnabled,
      child: switch (tab) {
        PanelTab.playlist => _PlaylistBody(library: library, player: player),
        PanelTab.recent => _RecentBody(
          recent: recent,
          library: library,
          player: player,
        ),
      },
    );
    // 固定行：表头 / 搜索 / 统计 / 常驻提示。高度不吃伸缩，收缩的只有列表。
    final fixed = <Widget>[
      _Header(
        tab: tab,
        onTab: (next) => controller.tab = next,
        onClose: onClose,
      ),
      const SizedBox(height: 10),
      const _SearchBox(),
      const SizedBox(height: 8),
      const _StatsRow(),
      ?notice,
    ];
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusXl),
        border: Border.all(color: tokens.border),
        // `.panel` 的 170deg 玻璃：panel-a → panel-b
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.panelA, tokens.panelB],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxHeight < minComfortableHeight) {
            // 兜底：固定行摆不下时整块可滚，任何一项都不被裁掉
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...fixed,
                  SizedBox(height: compactBodyHeight, child: body),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...fixed, Expanded(child: body)],
          );
        },
      ),
    );
  }
}

/// 表头：两个 tab（选中项铺 `accentSoft` 底、字 `accentLight`）+ 可选的收起按钮。
///
/// 高度固定 30：过滤 / 切 tab 都不许改变这一行的高度（列表才是收缩的那一块）。
class _Header extends StatelessWidget {
  const _Header({required this.tab, required this.onTab, this.onClose});

  final PanelTab tab;
  final ValueChanged<PanelTab> onTab;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      key: const Key('panel-header'),
      children: [
        for (final item in PanelTab.values) ...[
          _TabButton(
            key: Key('panel-tab-${item.name}'),
            label: item == PanelTab.playlist ? '播放列表' : '最近',
            selected: item == tab,
            onTap: () => onTab(item),
            tokens: tokens,
          ),
          const SizedBox(width: 6),
        ],
        const Spacer(),
        if (onClose != null) _CloseButton(onClose: onClose!, tokens: tokens),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.tokens,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        hoverColor: tokens.border,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: selected ? tokens.accentSoft : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: selected ? tokens.accentLight : tokens.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// 收起按钮（弹层里才有）：视觉 28，语义文案固定「收起播放列表」。
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onClose, required this.tokens});

  final VoidCallback onClose;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '收起播放列表',
      excludeSemantics: true,
      onTap: onClose,
      child: Tooltip(
        message: '收起',
        child: InkWell(
          onTap: onClose,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(Icons.close, size: 16, color: tokens.textDim),
          ),
        ),
      ),
    );
  }
}

/// 搜索框：36 高胶囊，聚焦时描边转 `accentLine`；清空按钮只在有输入时出现。
class _SearchBox extends StatefulWidget {
  const _SearchBox();

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final library = context.watch<LibraryState>();
    return Container(
      height: 36,
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: _focus.hasFocus ? tokens.accentLine : tokens.border,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 15, color: tokens.textFaint),
          const SizedBox(width: 8),
          Expanded(
            // 读屏名固定「搜索歌名」：占位文字用自绘的 hint（`ExcludeSemantics`
            // 掉它自己的文字语义），否则 InputDecorator 会把 hintText 也并进
            // label，读屏会念两遍同一句。
            child: Semantics(
              label: '搜索歌名',
              child: TextField(
                key: const Key('panel-search'),
                controller: library.searchController,
                focusNode: _focus,
                cursorColor: tokens.accent,
                textAlignVertical: TextAlignVertical.center,
                style: TextStyle(fontSize: 12.5, color: tokens.text),
                // 输入即时回显；生效值（过滤）由 LibraryState 防抖 200ms
                onChanged: (value) => library.keyword = value,
                decoration: InputDecoration(
                  hint: ExcludeSemantics(
                    child: Text(
                      '搜索歌名',
                      style: TextStyle(fontSize: 12.5, color: tokens.textFaint),
                    ),
                  ),
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          if (library.keyword.isNotEmpty)
            Semantics(
              button: true,
              label: '清空搜索',
              excludeSemantics: true,
              onTap: () => library.keyword = '',
              child: InkWell(
                key: const Key('panel-search-clear'),
                onTap: () => library.keyword = '',
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 14, color: tokens.textFaint),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 统计行：未过滤 `M 首 · 总时长 mm:ss`，过滤中 `找到 N 首 · 共 M 首`。
class _StatsRow extends StatelessWidget {
  const _StatsRow();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final library = context.watch<LibraryState>();
    final total = library.tracks.length;
    final text = library.effectiveKeyword.isEmpty
        ? '$total 首 · 总时长 ${formatTotal(library.totalSeconds.toDouble())}'
        : '找到 ${library.filteredTracks.length} 首 · 共 $total 首';
    // 固定行高：列表再长也只让列表滚，别把统计行按比例挤扁裁字
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          color: tokens.textFaint,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 播放列表 tab。
class _PlaylistBody extends StatelessWidget {
  const _PlaylistBody({required this.library, required this.player});

  final LibraryState library;
  final PlayerState player;

  @override
  Widget build(BuildContext context) {
    final tracks = library.filteredTracks;
    if (tracks.isEmpty) {
      // 两种空态：列表本来就没有歌 vs 搜索没命中（原版分开写文案）
      return library.tracks.isEmpty
          ? const EmptyState(
              title: '播放列表是空的',
              hint: '点击「添加音乐」，或把音频文件拖到页面上',
            )
          : EmptyState(
              title: '没有找到《${library.keyword.trim()}》',
              hint: '换个关键词试试',
            );
    }
    return ListView.builder(
      key: const Key('playlist-list'),
      padding: EdgeInsets.zero,
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return TrackRow(
          key: ValueKey<String>(track.id),
          title: track.title,
          artistLine: _artistLine(track),
          duration: formatTime(track.duration),
          coverPath: track.cover,
          active: library.currentId == track.id,
          playing: player.playing,
          broken: track.broken,
          onPlay: () => unawaited(player.playTrack(track.id)),
          onRemove: () => unawaited(library.removeTrack(track.id)),
        );
      },
    );
  }

  /// 副行：`歌手 · 专辑`，缺哪段就少哪段（与原版 join(' · ') 一致）。
  static String _artistLine(Track track) => [
    track.artist,
    track.album,
  ].where((part) => part.isNotEmpty).join(' · ');
}

/// 最近播放 tab：26 高的说明行 + 列表 / 空态。
class _RecentBody extends StatelessWidget {
  const _RecentBody({
    required this.recent,
    required this.library,
    required this.player,
  });

  final RecentState recent;
  final LibraryState library;
  final PlayerState player;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final entries = recent.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 26,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '按播放时间排序，最多保留 $kRecentLimit 首',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: tokens.textFaint),
                ),
              ),
              TextButton(
                key: const Key('recent-clear'),
                onPressed: entries.isEmpty
                    ? null
                    : () => unawaited(recent.clear()),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: tokens.textDim,
                  disabledForegroundColor: tokens.textFaint,
                ),
                child: const Text('清空历史', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const EmptyState(
                  title: '还没有播放记录',
                  hint: '播放过的歌会自动出现在这里',
                )
              : ListView.builder(
                  key: const Key('recent-list'),
                  padding: EdgeInsets.zero,
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return RecentRow(
                      key: ValueKey<String>(entry.id),
                      title: entry.title,
                      artist: entry.artist,
                      relativeTime: formatRelativeTime(entry.at),
                      duration: formatTime(entry.duration),
                      coverPath: entry.cover,
                      inPlaylist: entry.inPlaylist,
                      active: library.currentId == entry.id,
                      // 已失效的记录不静默失败：给一条提示，绝不假装播放
                      onTap: () => entry.inPlaylist
                          ? unawaited(player.playTrack(entry.id))
                          : library.toastMissingInPlaylist(),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 常驻提示条：被拦 / 熔断。位置在列表之上，内容 12.5 的 `dangerInk`。
///
/// [actionLabel] 为 null 时只显示文案（熔断：自动跳已停手，没有可重试目标）。
class PanelNotice extends StatelessWidget {
  const PanelNotice({
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: tokens.dangerSoft,
        border: Border.all(color: tokens.dangerLine),
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: tokens.dangerInk,
              ),
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: 10),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: tokens.dangerInk,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: tokens.dangerLine),
                ),
              ),
              child: Text(actionLabel!, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}
