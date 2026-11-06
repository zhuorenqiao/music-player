// lib/ui/home_page.dart
//
// 首页：把 [HomeLayout] 的四个区域接到业务 widget 上的薄壳。
//
// T25 起头部是真的 [AppHeader]（品牌 + 菜单抽屉），其余三个区域仍是 token
// 着色的占位块，由后续任务逐个替换 —— T26 曲目区、T28 列表面板、T29 控制条。
// **结构不再改**：后续任务只替换传给 [HomeLayout] 的子 widget，`shell.dart`
// 与这里的接线不动。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/breakpoints.dart';
import '../core/file_picking.dart';
import '../core/format_time.dart';
import '../playback/play_mode.dart';
import '../state/library_state.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import 'header.dart';
import 'shell.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 抽屉的动作要落在同一份曲库状态上；先取出来，回调触发时再 await，
    // 不在 await 之后碰 context。
    final library = context.read<LibraryState>();
    return Scaffold(
      backgroundColor: tokens.bg,
      // `body::before`：一整面对角渐变，不参与滚动
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.bgGradA, tokens.bgGradB],
          ),
        ),
        child: HomeLayout(
          header: AppHeader(
            onAddFiles: () => _addFiles(library),
            onAddFolder: () => _addFolder(library),
            onClearPlaylist: library.clearPlaylist,
          ),
          stage: const _StageSlot(), // T26 换成曲目区（封面、歌名、歌词）
          panel: const _PanelSlot(), // T28 换成播放列表 / 最近两个 tab 的面板
          transport: const _TransportSlot(), // T29 换成播放控制条（进度、按钮、音量）
        ),
      ),
    );
  }

  /// 「添加音乐」：选完文件再交给状态层。取消（空结果）什么都不做 ——
  /// 导入服务自己会挡掉不支持的格式与空结果，这里不弹提示。
  Future<void> _addFiles(LibraryState library) async {
    final paths = await pickAudioFiles();
    if (paths.isEmpty) return;
    await library.importPaths(paths);
  }

  /// 「添加整个文件夹」：同理，取消不提示。
  Future<void> _addFolder(LibraryState library) async {
    final folder = await pickAudioFolder();
    if (folder == null) return;
    await library.importDirectory(folder);
  }
}

/// 曲目区占位（T26 替换）：空态文案与原版 `IDLE_TITLE` / `IDLE_ARTIST` 一致。
class _StageSlot extends StatelessWidget {
  const _StageSlot();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusXl),
        border: Border.all(color: tokens.border),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.cardA, tokens.cardB],
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.album_outlined, size: 44, color: tokens.textFaint),
          const SizedBox(height: 14),
          Text(
            '未选择曲目',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: tokens.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '从播放列表选一首开始',
            style: TextStyle(fontSize: 12.8, color: tokens.textDim),
          ),
        ],
      ),
    );
  }
}

/// 列表面板占位（T28 替换）：只画两个 tab 标签与空列表底。
class _PanelSlot extends StatelessWidget {
  const _PanelSlot();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusXl),
        border: Border.all(color: tokens.border),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.panelA, tokens.panelB],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '播放列表',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: tokens.accent,
                ),
              ),
              const SizedBox(width: 18),
              Text(
                '最近',
                style: TextStyle(fontSize: 13.5, color: tokens.textDim),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(height: 1, color: tokens.border),
          const Expanded(child: SizedBox.shrink()),
        ],
      ),
    );
  }
}

/// 控制条占位（T29 替换）：模式文案 + 五个 40px 圆钮 + `--:-- / --:--`。
class _TransportSlot extends StatelessWidget {
  const _TransportSlot();

  /// 模式 / 上一首 / 播放 / 下一首 / 静音的图标位（暂时不可点）。
  static const List<IconData> _buttons = [
    Icons.repeat,
    Icons.skip_previous,
    Icons.play_arrow,
    Icons.skip_next,
    Icons.volume_up,
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 模式文案读真实状态：存档里是单曲循环时，占位条也不该写「列表循环」
    final mode = context.watch<PlayerState>().view.value.mode;
    final time = '${formatTime(null)} / ${formatTime(null)}';
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.border),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(kRadiusXl),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.barA, tokens.barB],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            time,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.8,
              color: tokens.textDim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          // 换行而不是溢出：≤480 时按钮行本来就该折行（原版 .controls 换行）
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                playModeLabel(mode),
                style: TextStyle(fontSize: 12.8, color: tokens.textDim),
              ),
              for (final icon in _buttons) _SlotButton(icon: icon),
            ],
          ),
        ],
      ),
    );
  }
}

/// 控制条上的圆钮位（T29 换成真正的按钮）。
class _SlotButton extends StatelessWidget {
  const _SlotButton({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      width: kButtonSize,
      height: kButtonSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tokens.cardB,
        border: Border.all(color: tokens.border),
      ),
      child: Icon(icon, size: 20, color: tokens.textDim),
    );
  }
}
