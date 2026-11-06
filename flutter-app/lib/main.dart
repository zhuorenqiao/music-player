// lib/main.dart
//
// 组合根：所有平台对象在这里连线并预热，然后才 runApp。
//
// 三件事必须发生在首帧之前（spec §9 首帧不闪、§7.2 媒体会话）：
//   1. `AppPrefs.ready()`：shared_preferences 的读取是同步的，句柄没预热时
//      读到的是「没有存档」，界面会先画一帧默认态再跳变；
//   2. 曲库还原（`library.restore()`）：列表没就位就 attach 媒体会话，推给
//      系统的是空快照，通知栏会先闪一下「没有在播」；
//   3. 媒体会话附着（`coordinator.attach()`）：但它**必须有上限** —— 见
//      [kMediaSessionAttachTimeout]，会话起不来只是少一组系统控件，界面照常起。
//
// 通知权限不在启动时申请（T22 修正）：Android 13+ 的弹窗由
// `FlutterMediaSession.activate()` 在 attach 里自己弹，这里只查询结果
// （[notificationPermissionGranted]，绝不 prompt），供界面提示条用真实状态。
// 被拒也不阻断播放，只是通知栏控件拿不到（界面另给 info 级提示）。
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

/// 媒体会话附着的上限。`activate()` 会抛（Android 没有 Activity 时 `NO_ACTIVITY`）
/// 也可能长时间不返回（13+ 要等用户点系统权限对话框），而它一旦把启动扣住，
/// `runApp` 就永远不会跑 —— 用户看到的是一片空白窗口，连错误都没有。
///
/// 3 秒足够让正常设备连上（Android 起前台服务 / Windows 初始化 SMTC 都是毫秒级）；
/// 超时就当会话不可用：没有通知栏 / 锁屏控件，播放与界面照常。
const Duration kMediaSessionAttachTimeout = Duration(seconds: 3);

/// 通知权限查询的上限：同样是一次平台往返，不值得让首帧等它。
const Duration kNotificationQueryTimeout = Duration(seconds: 3);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 的原生库要在创建 Player 之前初始化。
  MediaKit.ensureInitialized();
  final prefs = await AppPrefs.ready();
  final support = await getApplicationSupportDirectory();
  final bootstrap = await buildBootstrap(
    prefs: prefs,
    dataDirectory: support.path,
    driver: MediaKitDriver(),
    bridge: FlutterMediaSessionBridge(),
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
    required this.notificationPermission,
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
  ///
  /// 这是**首帧时**的快照：Android 上 `activate()` 的弹窗在 attach 里已经弹完，
  /// 所以通常就是用户的真实选择。它有两个不新鲜的时刻 —— 权限框的答复晚于
  /// attach 的 3 秒上限、以及用户后来在系统设置里改权限 —— 需要实时值时用
  /// [notificationPermission]（只查询、绝不弹窗）。
  final bool notificationGranted;

  /// 实时查询通知权限，不弹窗（申请归 `activate()`）。提示条（T24）用它。
  final Future<bool> Function() notificationPermission;

  /// 下面几个是状态层内部持有的原对象：界面层要用时不必知道它们被包在哪一层。
  Playlist get playlist => library.playlist;
  TransportController get transport => player.transport;
  ImportService get importer => library.importer;
  RecentStore get recentStore => recent.store;
}

/// 建对象、恢复存档、挂上媒体会话。测试可注入假 driver / 假 bridge。
///
/// [notificationGranted] 为 null 时按 [queryNotificationPermission]（默认
/// [notificationPermissionGranted]）查询当前状态；直接传 bool 可跳过查询。
/// [mediaSessionAttachTimeout] 只在测试里缩短。
Future<AppBootstrap> buildBootstrap({
  required AppPrefs prefs,
  required String dataDirectory,
  required AudioDriver driver,
  required MediaSessionBridge bridge,
  bool? notificationGranted,
  Future<bool> Function()? queryNotificationPermission,
  Duration mediaSessionAttachTimeout = kMediaSessionAttachTimeout,
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
  //
  // 但会话挂不上不许拖住启动：`activate()` 会抛（Android 没有 Activity 时
  // `NO_ACTIVITY`）、也可能卡在系统权限对话框上不返回，无限等下去 `runApp`
  // 就永远不跑。超时 / 异常一律当成「媒体会话不可用」—— 少一组系统控件，
  // 播放与界面照常；只记一次日志，不弹错误（用户没有可操作的东西）。
  final coordinator = MediaSessionCoordinator(
    bridge: bridge,
    transport: transport,
  );
  try {
    await coordinator.attach().timeout(mediaSessionAttachTimeout);
  } catch (error) {
    debugPrint('media session unavailable: $error');
  }

  // 通知权限只查询、不申请（申请归 `activate()` 管，见文件头）：弹窗在 attach
  // 里发生，所以这里读到的是用户刚做出的选择。查询同样设上限、绝不抛。
  final granted =
      notificationGranted ??
      await _queryNotificationPermission(queryNotificationPermission);

  return AppBootstrap(
    prefs: prefs,
    repository: repository,
    library: library,
    player: player,
    recent: recent,
    toasts: toasts,
    mediaSession: coordinator,
    notificationGranted: granted,
    notificationPermission: () =>
        _queryNotificationPermission(queryNotificationPermission),
  );
}

/// 查询通知权限，失败 / 超时按 false（没有通知栏控制）处理，绝不抛出。
Future<bool> _queryNotificationPermission(
  Future<bool> Function()? query,
) async {
  try {
    return await (query ?? notificationPermissionGranted)()
        .timeout(kNotificationQueryTimeout);
  } catch (error) {
    debugPrint('notification permission query failed: $error');
    return false;
  }
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
