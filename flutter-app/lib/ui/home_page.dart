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
import '../state/library_state.dart';
import '../theme/app_tokens.dart';
import 'header.dart';
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
          stage: const Stage(), // T26 起是真的播放卡
          panel: const Panel(), // T28 起是真的播放列表 / 最近面板
          transport: const TransportBar(), // T29：进度、五个按钮、音量与窄屏列表入口
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
