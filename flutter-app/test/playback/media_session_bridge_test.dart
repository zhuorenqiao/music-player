// test/playback/media_session_bridge_test.dart
//
// 系统媒体会话的边界（spec §7.1）。核心约束：外部动作一律走
// `TransportController` 的既有方法，bridge 只做「界面 → 系统」的推送与
// 「系统 → 界面」的转发，绝不出现第二条播放控制路径。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/play_mode.dart';
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

/// 广播流是异步投递：等两轮事件循环，让
/// 「驱动事件 → AudioPlayer → 控制器 → 协调器」这条链跑完
/// （与 transport_controller_test 的 settle 同一约定）。
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

void main() {
  test('attach 后推送当前曲目的元数据与播放态', () async {
    final bridge = FakeMediaSessionBridge();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1')]),
    );
    await MediaSessionCoordinator(
      bridge: bridge,
      transport: transport,
    ).attach();
    await transport.playTrack('1');
    await settle();
    expect(bridge.published.last.title, '歌1');
    expect(bridge.published.last.artist, '某人');
    expect(bridge.published.last.artUri, '/cache/1.jpg');
    expect(bridge.published.last.playing, isTrue);
  });

  test('系统侧四个动作全部转发到 transport 的同一入口', () async {
    final bridge = FakeMediaSessionBridge();
    final driver = FakeAudioDriver();
    final transport = TransportController(
      player: AudioPlayer(driver, scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1'), t('2')]),
    );
    await MediaSessionCoordinator(
      bridge: bridge,
      transport: transport,
    ).attach();
    await transport.playTrack('1');
    driver.calls.clear();

    bridge.emit(NextCommand());
    await Future<void>.delayed(Duration.zero);
    expect(transport.current!.id, '2');

    bridge.emit(PauseCommand());
    await Future<void>.delayed(Duration.zero);
    expect(driver.calls, contains('pause'));

    bridge.emit(PreviousCommand());
    await Future<void>.delayed(Duration.zero);
    expect(transport.current!.id, '1');

    bridge.emit(SeekCommand(50));
    await Future<void>.delayed(Duration.zero);
    expect(driver.calls, contains('seek:50.0'));
  });

  test('随机模式把 shuffle 与单曲循环同步给系统', () async {
    final bridge = FakeMediaSessionBridge();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1'), t('2')], mode: PlayMode.shuffle),
    );
    await MediaSessionCoordinator(
      bridge: bridge,
      transport: transport,
    ).attach();
    await transport.playTrack('1');
    expect(bridge.published.last.shuffleEnabled, isTrue);
    expect(bridge.published.last.repeatMode, MediaRepeatMode.all);
    transport.cycleMode(); // shuffle -> list
    await Future<void>.delayed(Duration.zero);
    expect(bridge.published.last.shuffleEnabled, isFalse);
  });

  test('position 推送节流到每秒一次，播放态变化不受限', () async {
    var fakeNow = 0;
    final bridge = FakeMediaSessionBridge();
    final driver = FakeAudioDriver();
    final transport = TransportController(
      player: AudioPlayer(driver, scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1')]),
    );
    final coordinator = MediaSessionCoordinator(
      bridge: bridge,
      transport: transport,
      nowMs: () => fakeNow,
    );
    await coordinator.attach();
    await transport.playTrack('1');
    final baseline = coordinator.publishCount;
    for (var i = 1; i <= 10; i++) {
      fakeNow = i * 200; // 200ms 一次
      driver.emitPosition(i.toDouble());
    }
    expect(coordinator.publishCount - baseline, lessThanOrEqualTo(3));
    fakeNow = 5000;
    driver.emitPlaying(false);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.published.last.playing, isFalse);
  });

  test('没有当前曲目时推空元数据并停掉会话，不抛', () async {
    final bridge = FakeMediaSessionBridge();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist(tracks: const []),
    );
    await MediaSessionCoordinator(
      bridge: bridge,
      transport: transport,
    ).attach();
    expect(bridge.published.last.title, isEmpty);
    expect(bridge.stopCount, greaterThanOrEqualTo(1));
  });
}
