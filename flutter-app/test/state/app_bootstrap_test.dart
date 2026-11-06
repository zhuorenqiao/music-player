// test/state/app_bootstrap_test.dart
//
// 组合根（T23 的装配）：存档还原顺序、媒体会话附着时机，以及
// 「应用根把四个状态注册给 provider」这条界面契约。
//
// 另有两条启动健壮性（T22 修正）：媒体会话起不来 / 永不返回都不许挡住
// `runApp`，通知权限只查询不申请。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/main.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/play_mode.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/library_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/recent_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:provider/provider.dart';

Track track(String id, String title) =>
    Track(id: id, src: '/m/$id.flac', title: title, duration: 61);

/// `start()` 直接抛：Android 没有 Activity 时 `activate()` 报 `NO_ACTIVITY`。
class _ThrowingBridge implements MediaSessionBridge {
  @override
  Stream<MediaSessionCommand> get commands =>
      const Stream<MediaSessionCommand>.empty();

  @override
  Future<void> start() async => throw StateError('NO_ACTIVITY');

  @override
  Future<void> stop() async {}

  @override
  Future<void> publish(PublishedSnapshot snapshot) async {}

  @override
  Future<void> dispose() async {}
}

/// `start()` 永不返回：卡在系统权限对话框上，或平台通道永久沉默。
class _HangingBridge implements MediaSessionBridge {
  @override
  Stream<MediaSessionCommand> get commands =>
      const Stream<MediaSessionCommand>.empty();

  @override
  Future<void> start() => Completer<void>().future;

  @override
  Future<void> stop() async {}

  @override
  Future<void> publish(PublishedSnapshot snapshot) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory dir;
  late AppPrefs prefs;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('light-boot');
    prefs = AppPrefs.inMemory();
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(
        tracks: [track('a', '十年'), track('b', '孤勇者')],
        order: ['b', 'a'],
        currentId: 'a',
        mode: PlayMode.one,
      ),
    );
    await prefs.writeNumber(StorageKeys.volume, 0.25);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('启动装配：按存档顺序还原、读回音量与模式、附着媒体会话', () async {
    final bridge = FakeMediaSessionBridge();

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: bridge,
    );

    expect(bootstrap.library.tracks.map((t) => t.id), ['b', 'a']);
    expect(bootstrap.library.currentId, 'a');
    expect(bootstrap.player.transport.playlist.mode, PlayMode.one);
    expect(bootstrap.player.volume, 0.25);
    // 媒体会话 attach 时列表已就位，首推就是还原出来的当前曲目
    expect(bridge.startCount, 1);
    expect(bridge.published.last.title, '十年');
  });

  test('通知权限只查询不申请：结果进 AppBootstrap，且能再查一次', () async {
    var queries = 0;
    var granted = false;

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      queryNotificationPermission: () async {
        queries += 1;
        return granted;
      },
    );

    // 启动只查一次，结果如实落到界面要用的字段上（T24 的提示条）。
    expect(queries, 1);
    expect(bootstrap.notificationGranted, isFalse);

    // 用户在系统对话框里点了「允许」：提示条能拿到新的真实状态，不停在首帧。
    granted = true;
    expect(await bootstrap.notificationPermission(), isTrue);
    expect(queries, 2);
  });

  test('通知权限查询抛异常：按「没有」处理，装配照旧完成', () async {
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      queryNotificationPermission: () async => throw StateError('no channel'),
    );

    expect(bootstrap.notificationGranted, isFalse);
    expect(bootstrap.library.tracks.map((t) => t.id), ['b', 'a']);
  });

  test('媒体会话 activate 抛异常：启动照旧（只是没有系统控件）', () async {
    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: _ThrowingBridge(),
      queryNotificationPermission: () async => true,
    );

    // 存档还原、播放器、曲库一样不少 —— runApp 前不会炸。
    expect(bootstrap.library.tracks.map((t) => t.id), ['b', 'a']);
    expect(bootstrap.player.transport.playlist.size, 2);
    expect(bootstrap.notificationGranted, isTrue);
  });

  test('媒体会话永不返回：attach 超时后 buildBootstrap 照样返回', () async {
    final watch = Stopwatch()..start();

    final bootstrap = await buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: _HangingBridge(),
      mediaSessionAttachTimeout: const Duration(milliseconds: 50),
      queryNotificationPermission: () async => true,
    );
    watch.stop();

    expect(bootstrap.library.tracks, hasLength(2));
    // 默认 3 秒上限：绝不允许无限等下去（否则界面永远不出现）。
    expect(watch.elapsed, lessThan(kMediaSessionAttachTimeout));
  });

  testWidgets('应用根把四个状态注册给 provider', (tester) async {
    // 组合根要读真实文件；testWidgets 的假时钟里必须借 runAsync 跑真异步
    final bootstrap = (await tester.runAsync(
      () => buildBootstrap(
        prefs: prefs,
        dataDirectory: dir.path,
        driver: FakeAudioDriver(),
        bridge: FakeMediaSessionBridge(),
      ),
    ))!;

    await tester.pumpWidget(LightMusicApp(bootstrap: bootstrap));

    final context = tester.element(find.text('流光音乐 · M1 骨架'));
    expect(context.read<LibraryState>(), same(bootstrap.library));
    expect(context.read<PlayerState>(), same(bootstrap.player));
    expect(context.read<RecentState>(), same(bootstrap.recent));
    expect(context.read<ToastState>(), same(bootstrap.toasts));
  });
}
