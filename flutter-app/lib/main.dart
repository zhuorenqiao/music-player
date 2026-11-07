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
// 界面层不 new 任何业务对象：`LightMusicApp(bootstrap: ...)` 只拿建好的三个
// 状态层与提示条（注册给 provider 的事在 `app.dart`）。状态层本身不认识播放
// 编排，列表改动后的收尾由这里的 [_playlistChangeHandler] 接到
// [TransportController] 上。
import 'dart:async';

import 'package:flutter/material.dart';
// 只取 MediaKit.ensureInitialized：包里的 Playlist 与我们的歌单模型重名。
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/app_prefs.dart';
import 'core/platform_services.dart';
import 'library/duration_probe.dart';
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

/// 建对象、恢复存档、挂上媒体会话。测试可注入假 driver / 假 bridge。
///
/// [notificationGranted] 为 null 时按 [queryNotificationPermission]（默认
/// [notificationPermissionGranted]）查询当前状态；直接传 bool 可跳过查询。
/// [mediaSessionAttachTimeout] 只在测试里缩短。
/// [durationOpener] 只在测试里注入：生产上是 media_kit 的独立内核 opener
/// （I1 —— `ImportService.durationProbe` 从前没有任何赋值点，无标签曲目的
/// 时长就永远缺失），排队与 3000ms 预算由 [DurationProbe] 统一管。
/// [durationOpenerClose] 与它配对：注入假 opener 时一并注入它的释放接缝，
/// 好让测试断言 [AppBootstrap.dispose] 真的把探测内核关掉了（终审 A2）；
/// 生产上不传，用的是 [MediaKitDurationOpener.dispose]。
Future<AppBootstrap> buildBootstrap({
  required AppPrefs prefs,
  required String dataDirectory,
  required AudioDriver driver,
  required MediaSessionBridge bridge,
  bool? notificationGranted,
  Future<bool> Function()? queryNotificationPermission,
  Duration mediaSessionAttachTimeout = kMediaSessionAttachTimeout,
  Future<double> Function(String source)? durationOpener,
  Future<void> Function()? durationOpenerClose,
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
  // 探时长用的是**另一台**内核（不是 [driver]）：回填不许打断正在播的曲目。
  // `MediaKitDurationOpener` 里那台 Player 是懒建 + 复用的，从头到尾只有一台，
  // 但「只有一台」不等于「有人关」——释放接缝在这里交进探针，退出时由
  // `AppBootstrap.dispose()` 调用（终审 A2）。
  final probeOpener = durationOpener == null
      ? MediaKitDurationOpener(timeoutMs: kDurationProbeTimeoutMs)
      : null;
  final probe = DurationProbe(
    durationOpener ?? probeOpener!.call,
    timeoutMs: kDurationProbeTimeoutMs,
    closeOpener: durationOpenerClose ?? probeOpener?.dispose,
  );
  final importer = ImportService(
    playlist: playlist,
    toasts: toasts,
    covers: const CoverImageWriter(),
    coverDirectory: '$dataDirectory/covers',
    // 交出去的是**带来路**的那条（`probeOutcome`）而不是裸秒数：回填批次
    // 要不要给这条曲目记「已探测」标记，取决于探不出是**超时**还是
    // **这文件真没有时长**（第 3 轮 C1）。两条从前都是 NaN，接错编译不过。
    durationProbe: probe.probeOutcome,
  );
  final recent = RecentState(recentStore);
  final library = LibraryState(
    prefs: prefs,
    repo: repository,
    importer: importer,
    toasts: toasts,
    // 还原 / 导入 / 删除 / 清空 / 换曲都不经过播放编排，收尾交给装配层
    onPlaylistChanged: _playlistChangeHandler(transport, recent),
  );
  final player = PlayerState(prefs: prefs, transport: transport);
  // 停止播放也要落一次盘，而且**当场落完**（终审 R2 + 它的残留）：
  // `stopPlayback` 清掉的是播放指针，而指针就是 prefs 那份 `currentId` 现场的
  // 真相。从暂停态按停止时内核状态本来就没变，一个驱动事件都不会发，
  // `PlayerState._onEvent` 一次盘也排不上，留下的就是停止前那个 currentId ——
  // 重启复活一首用户明明停掉的歌。
  //
  // 这里接的是 `flushPersist` 而不是 `schedulePersist`：后者排在 400ms 防抖之后，
  // 「停止 → 马上杀进程」就等于没停过（防抖对播放推进是省写盘，对停止是丢数据）。
  // transport 建在 player 之前，所以这条线只能建好之后接。
  transport.onStopped = player.flushPersist;

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
    durationProbe: probe,
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

/// 列表改动后的收尾：校正「最近播放」的失效标记，补推视图，并把两种
/// 「内核里还挂着已删曲目」的情况翻译成播放层动作。
///
/// [LibraryState] 只负责在改动后喊一声（[removedId] 是刚被删掉的 id）；做
/// 什么是装配层的事 —— 状态层不认识 [TransportController]。列表本身由两边
/// 共享（同一个 [Playlist] 实例），所以这里读 `transport.playlist` 就是最新
/// 列表。三档对应原版 `player.tsx` 的 `removeTrack` / `clearList`：
///   - 每次改动都按当前 id 集合校正「已失效」标记：只在启动跑一次的话，
///     删掉一首听过的歌之后面板仍显示它「在列表里」，点下去才提示（C2）；
///   - 删掉的正是内核里加载的那首：接续曲目接手播放（原版 `goTo` + autoplay）；
///   - 列表空了（清空或删空）：停播并卸载，否则通知栏会留一条指向不存在
///     文件的幽灵条目（原版 `player.stop()`）。
void Function({String? removedId}) _playlistChangeHandler(
  TransportController transport,
  RecentState recent,
) {
  return ({String? removedId}) {
    final playlist = transport.playlist;
    // 校正失效标记：store 的变化回调会把重绘喊到界面那边，这里不用等它。
    unawaited(
      recent.refresh(playlist.tracks.map((track) => track.id).toSet()),
    );
    if (removedId != null &&
        removedId == transport.player.track?.id &&
        playlist.tracks.isNotEmpty) {
      final nextId = playlist.current?.id;
      if (nextId != null) {
        unawaited(transport.playTrack(nextId));
        return;
      }
    }
    // 什么都没加载（例如冷启动就是空列表）时不必去碰驱动
    if (playlist.tracks.isEmpty && transport.player.track != null) {
      unawaited(transport.stopPlayback());
      return;
    }
    transport.syncView();
  };
}
