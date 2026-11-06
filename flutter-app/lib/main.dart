// lib/main.dart
//
// 组合根：所有平台对象在这里连线并预热，然后才 runApp。
//
// 两件事必须发生在首帧之前（spec §9 首帧不闪、§7.2 媒体会话）：
//   1. `AppPrefs.ready()`：shared_preferences 的读取是同步的，句柄没预热时
//      读到的是「没有存档」，界面会先画一帧默认态再跳变；
//   2. `ensureNotificationPermission()`：Android 13+ 的弹窗要绑在启动时，
//      被拒也不阻断播放，只是通知栏控件拿不到（界面另给 info 级提示）。
//
// 界面层不 new 任何业务对象：`LightMusicApp(bootstrap: ...)` 拿到的是建好的
// 播放列表、播放器、存档仓与媒体会话协调器。T24 会把 `LightMusicApp` /
// `AppBootstrap` 搬到 `lib/app.dart`，并用 `HomePage`/`HomeLayout` 的双栏骨架
// 替换下面这个占位 home；T23 落地后 LibraryState / PlayerState / RecentState
// 直接接在 [buildBootstrap] 里已有的 repository / importer / recent 上。
import 'package:flutter/material.dart';
// 只取 MediaKit.ensureInitialized：包里的 Playlist 与我们的歌单模型重名。
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:path_provider/path_provider.dart';

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
    required this.playlist,
    required this.transport,
    required this.importer,
    required this.recent,
    required this.toasts,
    required this.mediaSession,
    required this.notificationGranted,
  });

  final AppPrefs prefs;
  final LibraryRepository repository;
  final Playlist playlist;
  final TransportController transport;
  final ImportService importer;
  final RecentStore recent;
  final ToastState toasts;

  /// 把系统侧动作接回 [TransportController] 的协调器；已在 [buildBootstrap]
  /// 里 attach 过，界面层只持有引用，不需要再启动它。
  final MediaSessionCoordinator mediaSession;

  /// 通知权限是否可用。false 只影响通知栏 / 锁屏控件的可见性，不影响播放。
  final bool notificationGranted;
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
  final recent = RecentStore(prefs);
  final playlist = Playlist(tracks: const []);
  final repository = LibraryRepository(directory: dataDirectory);
  final transport = TransportController(
    player: AudioPlayer(driver),
    recent: recent,
    toasts: toasts,
    playlist: playlist,
  );
  final importer = ImportService(
    playlist: playlist,
    toasts: toasts,
    covers: const CoverImageWriter(),
    coverDirectory: '$dataDirectory/covers',
  );

  // 最近播放先还原：它只读 prefs，不碰播放列表，失败也只是一份空历史。
  await recent.restore();

  // 媒体会话最后挂：协调器 attach 时会立刻推一次快照（此时列表还没还原，
  // 推的是空态），之后所有变化都自动跟着 transport 走。
  final coordinator = MediaSessionCoordinator(
    bridge: bridge,
    transport: transport,
  );
  await coordinator.attach();

  return AppBootstrap(
    prefs: prefs,
    repository: repository,
    playlist: playlist,
    transport: transport,
    importer: importer,
    recent: recent,
    toasts: toasts,
    mediaSession: coordinator,
    notificationGranted: notificationGranted,
  );
}

/// 应用根。M1 期间只挂主题与占位 home —— 真正的双栏骨架由 T24 的
/// `HomePage`/`HomeLayout` 接管，这里不参与布局，免得两处结构互相打架。
class LightMusicApp extends StatelessWidget {
  const LightMusicApp({required this.bootstrap, super.key});

  final AppBootstrap bootstrap;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '流光音乐',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tokens: AppTokens.dark),
      home: const Scaffold(
        body: Center(child: Text('流光音乐 · M1 骨架')),
      ),
    );
  }
}
