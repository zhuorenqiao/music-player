// lib/ui/home_page.dart
//
// 首页：把 [HomeLayout] 的四个区域接到业务 widget 上的薄壳。
//
// T25 起头部是真的 [AppHeader]（品牌 + 菜单抽屉），T26 换了曲目区，T28 换了
// 列表面板，T29 换了控制条（进度、五个按钮、音量、窄屏列表入口）—— 四个槽
// 全是真 widget 了。
// **结构不再改**：后续任务只替换传给 [HomeLayout] 的子 widget，`shell.dart`
// 与这里的接线不动。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/file_picking.dart';
import '../state/cover_state.dart';
import '../state/library_state.dart';
import '../state/lightbox_controller.dart';
import '../state/lyrics_page_controller.dart';
import '../state/player_state.dart';
import '../theme/app_tokens.dart';
import '../theme/theme_state.dart';
import 'cover_lightbox.dart';
import 'header.dart';
import 'lyrics_page.dart';
import 'panel.dart';
import 'shell.dart';
import 'stage.dart';
import 'transport.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 抽屉的动作要落在同一份曲库状态上；先取出来，回调触发时再 await，
    // 不在 await 之后碰 context。
    final library = context.read<LibraryState>();
    // 歌词页开合（T18 的控制器）：开着时把整块内容区换成 [LyricsPage]，
    // 头部与控制条两档都留着（见 [HomeLayout.overlay] 的注释）。
    final page = context.watch<LyricsPageController>();
    // 灯箱开合（M2b T9/T11）：叠在**最顶层**（歌词页保持其下渲染 ——
    // App.tsx:1707 的 lyricsPage 与 :1406 的 Lightbox 是两层独立结构）。
    final lightbox = context.watch<LightboxController>();
    // 封面 resolver：Stage/Panel 内部各自 watch；这里额外取一次当前封面，
    // 给 `.player` 卡的玻璃后垫（React `App.tsx:1483` 的 playerCover）。
    final cover = context.watch<CoverState>();
    final player = context.watch<PlayerState>();
    final current = player.view.value.current;
    final coverPath = current == null
        ? ''
        : cover.coverForDisplay(
            cover: current.cover,
            artist: current.artist,
            title: current.title,
            trackId: current.id,
          );
    final frostLevel = context.watch<ThemeState?>()?.frostLevel ?? 0.0;
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
        child: Stack(
          children: [
            HomeLayout(
              header: AppHeader(
                onAddFiles: () => _addFiles(library),
                onAddFolder: () => _addFolder(library),
                onClearPlaylist: library.clearPlaylist,
                // React `App.tsx:1700` 的 onSwitchView：在封面页 / 完整歌词页
                // 之间切，与「点曲目区进歌词页」共用同一个控制器。
                onSwitchView: page.toggle,
                immersive: page.isOpen,
              ),
              stage: const Stage(), // T26 起是真的播放卡
              panel: Panel(
                // M3 D.6：面板与播放卡共用同一套磨砂膜（`.panel::before`）。
                coverPath: coverPath,
                frostLevel: frostLevel,
              ),
              transport: const TransportBar(), // T29：进度、五个按钮、音量与窄屏列表入口
              coverPath: coverPath,
              frostLevel: frostLevel,
              overlay: page.isOpen ? const LyricsPage() : null,
            ),
            // 放大层（M2b T11）：全屏 Stack 顶层；关闭走 controller.close
            //（焦点归还给封面热区，T11 的入口接线）。
            if (lightbox.isOpen)
              Positioned.fill(
                child: CoverLightbox(onClose: lightbox.close),
              ),
          ],
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
