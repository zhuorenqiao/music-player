// test/playback/flutter_media_session_bridge_test.dart
//
// 系统媒体会话的 Android / Windows 实现（spec §7.2）。分两层：
//   - 纯映射：快照 → 平台元数据 / 播放态 / 动作名，动作名 → 命令。
//     这一层把包的真实签名钉死（PlaybackStatus 枚举、skipToNext 这类名字），
//     改了包版本而没改映射时，这里先红；
//   - 控制器语义：锁屏的 Play / Stop 必须与界面同一入口 —— 播放不重载、
//     停止清当前曲目。两个新方法直接在这里断言，不依赖设备。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_media_session/flutter_media_session.dart' as fms;
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/flutter_media_session_bridge.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';

class _NoRecent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}

class _NoToast implements ToastSink {
  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}
  @override
  void info(String message) {}
  @override
  void error(String message, {int durationMs = 3200}) {}
}

/// 只管「会话生命周期 + 保活开关」的平台替身。
///
/// 真平台在测试里没有通道可走，而「息屏续播」这条链的证据只能是
/// `setBackgroundKeepAlive` 有没有被调到 —— 包的默认值是关，漏调就等于没保活。
class _FakePlatform extends fms.FlutterMediaSessionPlatform {
  final List<String> calls = [];

  /// 每次 [setBackgroundKeepAlive] 的值，按调用顺序（先记再抛）。
  final List<bool> keepAlive = [];

  /// 模拟系统不给唤醒锁。
  bool failKeepAlive = false;

  @override
  Future<void> activate() async => calls.add('activate');

  @override
  Future<void> deactivate() async => calls.add('deactivate');

  @override
  Future<bool> requestNotificationPermission() async {
    calls.add('requestNotificationPermission');
    return true;
  }

  @override
  Future<void> setBackgroundKeepAlive(bool enabled) async {
    keepAlive.add(enabled);
    if (failKeepAlive) {
      throw PlatformException(code: 'WAKE_LOCK_DENIED');
    }
  }

  @override
  Future<void> updateMetadata(fms.MediaMetadata metadata) async {}

  @override
  Future<void> updatePlaybackState(fms.PlaybackState state) async {}

  @override
  Future<void> updateAvailableActions(Set<fms.MediaAction>? actions) async {}

  @override
  Stream<fms.MediaAction> get onMediaAction =>
      const Stream<fms.MediaAction>.empty();
}

/// 广播流是异步投递：等两轮事件循环，让
/// 「驱动事件 → AudioPlayer → 控制器 → 协调器」这条链跑完。
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Track t(String id) => Track(
  id: id,
  src: '/$id.flac',
  title: '歌$id',
  artist: '某人',
  album: '某碟',
  cover: '/cache/$id.jpg',
  duration: 100,
);

TransportController buildTransport(FakeAudioDriver driver) => TransportController(
  player: AudioPlayer(driver),
  recent: _NoRecent(),
  toasts: _NoToast(),
  playlist: Playlist.fromTracks([t('1'), t('2')]),
);

Iterable<String> opensIn(List<String> calls) =>
    calls.where((call) => call.startsWith('open:'));

void main() {
  group('纯映射', () {
    test('播放态名称映射逐一对应', () {
      expect(mapStateName(const PublishedSnapshot(playing: true)), 'playing');
      expect(
        mapStateName(const PublishedSnapshot(playing: false, title: 'A')),
        'paused',
      );
      expect(mapStateName(const PublishedSnapshot(title: '')), 'stopped');
    });

    test('播放态落到包内的 PlaybackStatus（没有 stopped 档，空态是 idle）', () {
      expect(
        statusFor(const PublishedSnapshot(title: 'A', playing: true)),
        fms.PlaybackStatus.playing,
      );
      expect(
        statusFor(const PublishedSnapshot(title: 'A')),
        fms.PlaybackStatus.paused,
      );
      expect(statusFor(const PublishedSnapshot()), fms.PlaybackStatus.idle);
    });

    test('动作集合：有当前曲目才允许上下曲，未知时长不给 seek', () {
      const withTrack = PublishedSnapshot(
        title: 'A',
        playing: true,
        duration: null,
      );
      expect(
        actionsFor(withTrack),
        containsAllInOrder(['play', 'pause', 'next', 'previous', 'stop']),
      );
      expect(actionsFor(withTrack), isNot(contains('seek')));
      const known = PublishedSnapshot(
        title: 'A',
        playing: true,
        duration: Duration(seconds: 100),
      );
      expect(actionsFor(known), contains('seek'));
      expect(actionsFor(const PublishedSnapshot()), isEmpty);
    });

    test('动作集合翻成包认的动作名：上下曲是 skipToNext / skipToPrevious', () {
      const known = PublishedSnapshot(
        title: 'A',
        playing: true,
        duration: Duration(seconds: 100),
      );
      expect(
        mediaActionsFor(known),
        containsAllInOrder([
          fms.MediaAction.play,
          fms.MediaAction.pause,
          fms.MediaAction.skipToNext,
          fms.MediaAction.skipToPrevious,
          fms.MediaAction.stop,
          fms.MediaAction.seekTo,
        ]),
      );
      // 时长未知：seek 不给。
      expect(
        mediaActionsFor(const PublishedSnapshot(title: 'A')),
        isNot(contains(fms.MediaAction.seekTo)),
      );
      // 空态一个都不给（通知栏 / SMTC 应该干净）。
      expect(mediaActionsFor(const PublishedSnapshot()), isEmpty);
    });

    test('artUri 为本地缓存路径时转 file URI，空值返回 null', () {
      expect(toArtUri(''), isNull);
      expect(toArtUri(null), isNull);
      expect(toArtUri('https://x/y.jpg'), 'https://x/y.jpg');

      final dir = Directory.systemTemp.createTempSync('art_uri_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cover = File('${dir.path}${Platform.pathSeparator}cover.jpg')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final uri = toArtUri(cover.path);
      expect(uri, cover.uri.toString());
      expect(uri, startsWith('file://'));

      // 文件不存在：宁可不画，也不给系统一个打不开的缩略图。
      expect(toArtUri('${dir.path}${Platform.pathSeparator}missing.jpg'), isNull);
    });

    test('系统动作字符串归一到命令', () {
      expect(commandFromName('play'), isA<PlayCommand>());
      expect(commandFromName('pause'), isA<PauseCommand>());
      expect(commandFromName('next'), isA<NextCommand>());
      expect(commandFromName('nexttrack'), isA<NextCommand>());
      expect(commandFromName('previous'), isA<PreviousCommand>());
      expect(commandFromName('previoustrack'), isA<PreviousCommand>());
      expect(commandFromName('stop'), isA<StopCommand>());
      expect(commandFromName('unknown-action'), isNull);
      // 包真的发出来的是这组名字（大小写不敏感）。
      expect(commandFromName('skipToNext'), isA<NextCommand>());
      expect(commandFromName('skipToPrevious'), isA<PreviousCommand>());
      expect(commandFromName('fastForward'), isA<NextCommand>());
      expect(commandFromName('rewind'), isA<PreviousCommand>());
      // seekTo 需要位置，不能只凭名字造。
      expect(commandFromName('seekTo'), isNull);
    });

    test('平台动作对象：seekTo 带位置才成命令，其余按名字走', () {
      final seek = commandFromAction(
        const fms.MediaAction('seekTo', seekPosition: Duration(seconds: 42)),
      );
      expect(seek, isA<SeekCommand>());
      expect((seek as SeekCommand).seconds, 42);

      expect(
        commandFromAction(fms.MediaAction.skipToNext),
        isA<NextCommand>(),
      );
      expect(commandFromAction(fms.MediaAction.play), isA<PlayCommand>());
      // 没有位置的 seekTo 直接丢弃，不猜 0 秒。
      expect(commandFromAction(fms.MediaAction.seekTo), isNull);
      // M1 不做随机 / 循环切换：这两个动作不认识。
      expect(commandFromAction(fms.MediaAction.shuffle), isNull);
      expect(commandFromAction(fms.MediaAction.repeat), isNull);
    });
  });

  group('控制器语义', () {
    test('resume 从暂停处继续，不重载媒体（没有第二次 open）', () async {
      final driver = FakeAudioDriver();
      final transport = buildTransport(driver);

      await transport.playTrack('1');
      await settle();
      await transport.togglePlay(); // 暂停
      await settle();
      expect(transport.view.value.playing, isFalse);
      expect(opensIn(driver.calls).length, 1);

      driver.emitPosition(37);
      await settle();
      driver.calls.clear();

      await transport.resume();
      await settle();

      expect(opensIn(driver.calls), isEmpty);
      expect(driver.calls, contains('play'));
      expect(transport.view.value.playing, isTrue);
      expect(transport.current!.id, '1');
    });

    test('stopPlayback 暂停、清当前曲目，列表保留，系统侧回到空态', () async {
      final bridge = FakeMediaSessionBridge();
      final driver = FakeAudioDriver();
      final playlist = Playlist.fromTracks([t('1'), t('2')]);
      final transport = TransportController(
        player: AudioPlayer(driver),
        recent: _NoRecent(),
        toasts: _NoToast(),
        playlist: playlist,
      );
      await MediaSessionCoordinator(
        bridge: bridge,
        transport: transport,
      ).attach();

      await transport.playTrack('1');
      await settle();
      expect(bridge.published.last.title, '歌1');
      final stopsBefore = bridge.stopCount;

      driver.calls.clear();
      await transport.stopPlayback();
      await settle();

      expect(driver.calls, contains('pause'));
      expect(transport.current, isNull);
      expect(transport.view.value.current, isNull);
      // 列表一首不少：停止只清「当前」，不是清空歌单。
      expect(playlist.size, 2);
      expect(transport.position.value, 0);
      // 空态快照推给系统，并停掉会话（通知栏撤控件）。
      expect(bridge.published.last.title, isEmpty);
      expect(bridge.published.last.artUri, isNull);
      expect(bridge.stopCount, stopsBefore + 1);
    });

    test('stopPlayback 之后 resume 退回「加载当前曲目并播放」', () async {
      final driver = FakeAudioDriver();
      final transport = buildTransport(driver);

      await transport.playTrack('1');
      await settle();
      await transport.stopPlayback();
      await settle();
      driver.calls.clear();

      await transport.resume();
      await settle();

      expect(opensIn(driver.calls).length, 1);
      expect(driver.calls, contains('play'));
      expect(transport.current!.id, '1');
      expect(transport.view.value.playing, isTrue);
    });

    test('系统侧 Play 走 resume、Stop 走 stopPlayback', () async {
      final bridge = FakeMediaSessionBridge();
      final driver = FakeAudioDriver();
      final transport = buildTransport(driver);
      await MediaSessionCoordinator(
        bridge: bridge,
        transport: transport,
      ).attach();

      await transport.playTrack('1');
      await settle();
      await transport.togglePlay(); // 暂停
      await settle();
      driver.calls.clear();

      bridge.emit(const PlayCommand());
      await settle();
      expect(opensIn(driver.calls), isEmpty);
      expect(driver.calls, contains('play'));
      expect(transport.view.value.playing, isTrue);

      driver.calls.clear();
      bridge.emit(const StopCommand());
      await settle();
      expect(driver.calls, contains('pause'));
      expect(transport.current, isNull);
      expect(bridge.published.last.title, isEmpty);
    });
  });

  group('后台保活（息屏续播）', () {
    late fms.FlutterMediaSessionPlatform original;

    setUp(() => original = fms.FlutterMediaSessionPlatform.instance);
    tearDown(() => fms.FlutterMediaSessionPlatform.instance = original);

    test('start() 主动打开保活（包默认是关的），dispose() 释放', () async {
      final platform = _FakePlatform();
      fms.FlutterMediaSessionPlatform.instance = platform;
      final bridge = FlutterMediaSessionBridge();

      await bridge.start();
      expect(platform.calls, contains('activate'));
      // 关键：不打开就永远没有唤醒锁，「息屏续播」只是运气。
      expect(platform.keepAlive, [true]);

      await bridge.dispose();
      // 3.0.9 没有单独的 release：传 false 就是释放。
      expect(platform.keepAlive, [true, false]);
      expect(platform.calls, contains('deactivate'));
    });

    test('stop() 释放保活，重新播放再拿回来（不必重启会话）', () async {
      final platform = _FakePlatform();
      fms.FlutterMediaSessionPlatform.instance = platform;
      final bridge = FlutterMediaSessionBridge();

      await bridge.start();
      await bridge.publish(const PublishedSnapshot(title: 'A', playing: true));
      // 已经在放：不该每秒重复打同一个开关。
      expect(platform.keepAlive, [true]);

      await bridge.stop();
      expect(platform.keepAlive, [true, false]);

      await bridge.publish(const PublishedSnapshot(title: 'A', playing: true));
      expect(platform.keepAlive, [true, false, true]);
    });

    test('暂停松手、继续播放再拿回来（桌面上不该一直不让系统睡）', () async {
      final platform = _FakePlatform();
      fms.FlutterMediaSessionPlatform.instance = platform;
      final bridge = FlutterMediaSessionBridge();

      await bridge.start();
      await bridge.publish(const PublishedSnapshot(title: 'A'));
      expect(platform.keepAlive, [true, false]);

      await bridge.publish(const PublishedSnapshot(title: 'A', playing: true));
      expect(platform.keepAlive, [true, false, true]);
    });

    test('保活失败不抛：start / publish / dispose 都走完', () async {
      final platform = _FakePlatform()..failKeepAlive = true;
      fms.FlutterMediaSessionPlatform.instance = platform;
      final bridge = FlutterMediaSessionBridge();

      await expectLater(bridge.start(), completes);
      await expectLater(
        bridge.publish(const PublishedSnapshot(title: 'A', playing: true)),
        completes,
      );
      await expectLater(bridge.dispose(), completes);
      // 拿不到锁也要真的试过，并且 dispose 仍然会去释放。
      expect(platform.keepAlive, [true, false]);
      expect(platform.calls, contains('deactivate'));
    });
  });
}
