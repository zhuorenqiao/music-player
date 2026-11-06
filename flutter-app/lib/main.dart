// lib/main.dart
//
// 组合根：所有平台对象在这里连线并预热，然后才 runApp。
//
// 三件事必须发生在首帧之前（spec §9 首帧不闪、§7.2 媒体会话）：
//   1. `AppPrefs.ready()`：shared_preferences 的读取是同步的，句柄没预热时
//      读到的是「没有存档」，界面会先画一帧默认态再跳变；
//   2. `ensureNotificationPermission()`：Android 13+ 的弹窗要绑在启动时，
//      被拒也不阻断播放，只是通知栏控件拿不到（界面另给 info 级提示）；
//   3. 曲库还原（`library.restore()`）：列表没就位就 attach 媒体会话，推给
//      系统的是空快照，通知栏会先闪一下「没有在播」。
//
// 界面层不 new 任何业务对象：`LightMusicApp(bootstrap: ...)` 拿到的是建好的
// 三个状态层与提示条，并在应用根注册给 provider。T24 会把 `LightMusicApp` /
// `AppBootstrap` 搬到 `lib/app.dart`，并用 `HomePage`/`HomeLayout` 的双栏骨架
// 替换下面这个占位 home；状态层本身不再改动。
import 'package:flutter/material.dart';
// 只取 MediaKit.ensureInitialized：包里的 Playlist 与我们的歌单模型重名。
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'core/app_prefs.dart';
import 'core/platform_services.dart';
import 'library/import_service.dart';
import 'library/library_repository.dart';
import 'library/recent_store.dart';
import 'metadata/cover_image.dart';
import 'playback/audio_driver.dart';
import 'playback/audio_player.dart';
import 'playback/flutter_media_session_bridge.dart';
import 'playback/media_kit_driver.dart';
import 'playback/media_session_bridge.dart';
import 'playback/playlist.dart';
import 'playback/transport_controller.dart';
import 'state/library_state.dart';
import 'state/player_state.dart';
import 'state/recent_state.dart';
import 'state/toast_state.dart';
import 'theme/app_theme.dart';
import 'theme/app_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 的原生库要在创建 Player 之前初始化。
  MediaKit.ensureInitialized();
  final prefs = await AppPrefs.ready();
  final notificationGranted = await ensureNotificationPermission();
  final support = await getApplicationSupportDirectory();
  final bootstrap = await buildBootstrap(
    prefs: prefs,
    dataDirectory: support.path,
    driver: MediaKitDriver(),
    bridge: FlutterMediaSessionBridge(),
    notificationGranted: notificationGranted,
  );
  runApp(LightMusicApp(bootstrap: bootstrap));
}

/// 组合根的构造结果。界面层从这里取对象，不自己 new 业务单例。
class AppBootstrap {
  AppBootstrap({
    required this.prefs,
    required this.repository,
    required this.library,
    required this.player,
    required this.recent,
    required this.toasts,
    required this.mediaSession,
    required this.notificationGranted,
  });

  final AppPrefs prefs;
  final LibraryRepository repository;

  /// 曲库（播放列表、搜索、导入、落库）。
  final LibraryState library;

  /// 播放器（进度 notifier、模式、音量、持久化时机）。
  final PlayerState player;

  /// 最近播放（薄包装，条目本体在 [RecentState.store]）。
  final RecentState recent;

  final ToastState toasts;

  /// 把系统侧动作接回 [TransportController] 的协调器；已在 [buildBootstrap]
  /// 里 attach 过，界面层只持有引用，不需要再启动它。
  final MediaSessionCoordinator mediaSession;

  /// 通知权限是否可用。false 只影响通知栏 / 锁屏控件的可见性，不影响播放。
  final bool notificationGranted;

  /// 下面几个是状态层内部持有的原对象：界面层要用时不必知道它们被包在哪一层。
  Playlist get playlist => library.playlist;
  TransportController get transport => player.transport;
  ImportService get importer => library.importer;
  RecentStore get recentStore => recent.store;
}

/// 建对象、恢复存档、挂上媒体会话。测试可注入假 driver / 假 bridge。
Future<AppBootstrap> buildBootstrap({
  required AppPrefs prefs,
  required String dataDirectory,
  required AudioDriver driver,
  required MediaSessionBridge bridge,
  bool notificationGranted = true,
}) async {
  final toasts = ToastState();
  final recentStore = RecentStore(prefs);
  final playlist = Playlist(tracks: const []);
  final repository = LibraryRepository(directory: dataDirectory);
  final transport = TransportController(
    player: AudioPlayer(driver),
    recent: recentStore,
    toasts: toasts,
    playlist: playlist,
  );
  final importer = ImportService(
    playlist: playlist,
    toasts: toasts,
    covers: const CoverImageWriter(),
    coverDirectory: '$dataDirectory/covers',
  );
  final library = LibraryState(
    prefs: prefs,
    repo: repository,
    importer: importer,
    toasts: toasts,
    // 还原 / 导入 / 删除 / 换曲都不经过播放编排，补推视图这一步交给装配层
    onPlaylistChanged: transport.syncView,
  );
  final player = PlayerState(prefs: prefs, transport: transport);
  final recent = RecentState(recentStore);

  // 先把音量 / 静音 / 模式读回来，再还原曲库：存档里的模式是权威值，
  // 顺序反过来会被 prefs 里的旧值覆盖。
  await player.ready();
  await library.restore();

  // 最近播放后还原（只读 prefs，失败也只是一份空历史），再按列表校正失效标记。
  await recent.restore();
  await recent.refresh(library.tracks.map((track) => track.id).toSet());

  // 媒体会话最后挂：此时列表与当前曲目都已就位，首次快照就是真实状态。
  final coordinator = MediaSessionCoordinator(
    bridge: bridge,
    transport: transport,
  );
  await coordinator.attach();

  return AppBootstrap(
    prefs: prefs,
    repository: repository,
    library: library,
    player: player,
    recent: recent,
    toasts: toasts,
    mediaSession: coordinator,
    notificationGranted: notificationGranted,
  );
}

/// 应用根：注册状态层给 provider，再挂主题与占位 home。
///
/// provider 放在 `MaterialApp` 外面（与原版 Context 的位置一致）：T24 起的
/// `HomePage` 与任何路由都能 `context.watch<LibraryState>()` 拿到同一份实例。
/// `.value` 不接管 dispose —— 这些状态在应用生命周期内常驻。
/// M1 期间 home 只是占位，真正的双栏骨架由 T24 的 `HomePage`/`HomeLayout`
/// 接管，这里不参与布局，免得两处结构互相打架。
class LightMusicApp extends StatelessWidget {
  const LightMusicApp({required this.bootstrap, super.key});

  final AppBootstrap bootstrap;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryState>.value(value: bootstrap.library),
        ChangeNotifierProvider<PlayerState>.value(value: bootstrap.player),
        ChangeNotifierProvider<RecentState>.value(value: bootstrap.recent),
        ChangeNotifierProvider<ToastState>.value(value: bootstrap.toasts),
        Provider<AppPrefs>.value(value: bootstrap.prefs),
      ],
      child: MaterialApp(
        title: '流光音乐',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tokens: AppTokens.dark),
        home: const Scaffold(
          body: Center(child: Text('流光音乐 · M1 骨架')),
        ),
      ),
    );
  }
}
