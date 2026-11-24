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
import 'radio_bar.dart';
import 'radio_page.dart';
import 'shell.dart';
import 'sleep_bar.dart';
import 'sleep_page.dart';
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
    final glassLevel = context.watch<ThemeState?>()?.glassLevel ?? 1.0;
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
                // 「电台」入口（T31）：整页切过去；回来时电台继续在后台放，
                // 由控制条上方那条迷你电台条交代状态（见 RadioBar）。
                onOpenRadio: () => _openRadio(context),
                // 「休眠」入口（T32）：整页切过去；回来时声景继续在后台放，
                // 由控制条上方那条迷你休眠条交代状态（见 SleepBar）。
                onOpenSleep: () => _openSleep(context),
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
              // 迷你条：休眠声景在后台放时贴在最上面，电台条在其下。
              // 两条都自己判空，没在响的那一条不占位。
              radioBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SleepBar(onOpen: () => _openSleep(context)),
                  RadioBar(onOpen: () => _openRadio(context)),
                ],
              ),
              coverPath: coverPath,
              frostLevel: frostLevel,
              // 融合卡整张底色的 alpha 缩放（`.app__main` 的 color-mix）
              glassLevel: glassLevel,
              overlay: page.isOpen ? const LyricsPage() : null,
            ),
            // 放大层（M2b T11）：全屏 Stack 顶层；关闭走 controller.close
            //（焦点归还给封面热区，T11 的入口接线）。
            if (lightbox.isOpen)
              Positioned.fill(child: CoverLightbox(onClose: lightbox.close)),
          ],
        ),
      ),
    );
  }

  /// 「电台」：整页切到电台页（淡入，与开屏同一节奏）。
  ///
  /// 页面是**独立路由**而不是同一棵树里的第 4 个区域：电台页有自己的顶栏
  ///（标题 + 回音乐按钮）和自己的滚动区，塞进 [HomeLayout] 的槽位只会把
  /// 两套骨架搅在一起。
  ///
  /// 返回后**不停台**：电台继续在后台放，音乐页底部那条 [RadioBar] 接着交代
  ///「还在响的是哪一台」，点它就能回到电台页。关掉只有两条路：条上的暂停 /
  /// 关闭，或者在音乐页按下播放（音乐一开声，电台自动让位）。
  Future<void> _openRadio(BuildContext context) async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, _, _) => RadioPage(
          onBack: navigator.pop,
          // 「休眠」互跳：先让这一页退场，下一帧再从音乐页推休眠页。两页永远是
          // 同一层路由，来回切几次也不会把返回栈越压越深。
          onOpenSleep: () {
            navigator.pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) _openSleep(context);
            });
          },
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  /// 「休眠」：整页切到休眠页（淡入，与电台页同一节奏）。
  ///
  /// 与电台页同一条「独立路由」的做法；区别是**返回后不停声** —— 睡前声景要
  /// 一直放到睡着，音乐页底部那条 [SleepBar] 接着交代「还在响的是哪一段」，
  /// 点它回页面，暂停 / 关闭在条上。
  Future<void> _openSleep(BuildContext context) async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, _, _) => SleepPage(
          onBack: navigator.pop,
          // 「电台」互跳：与电台页那颗「休眠」同一套 —— 先退场，下一帧再推，
          // 保证页面上永远只有一层子页面。
          onOpenRadio: () {
            navigator.pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) _openRadio(context);
            });
          },
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
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
  ///
  /// Android 给的是 SAF `content://` 树 URI，走原生桥接复制成本地文件再导入；
  /// 桌面给的是 `file` URI，按本地目录扫描导入。
  Future<void> _addFolder(LibraryState library) async {
    final uri = await pickAudioFolder();
    if (uri == null) return;
    if (uri.isScheme('content')) {
      await library.importSafTree(uri.toString());
    } else {
      await library.importDirectory(uri.toFilePath());
    }
  }
}
