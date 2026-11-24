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
import 'package:light_music/radio/radio_engine.dart';
import 'package:light_music/radio/radio_media_session.dart';
import 'package:light_music/radio/radio_state.dart';
import 'package:light_music/radio/radio_station.dart';

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

  test('电台在响时，系统侧的播放类按键不再拉起音乐（否则听起来像「自动放歌」）', () async {
    final bridge = FakeMediaSessionBridge();
    final driver = FakeAudioDriver();
    final transport = TransportController(
      player: AudioPlayer(driver, scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1'), t('2')]),
    );
    final coordinator = MediaSessionCoordinator(
      bridge: bridge,
      transport: transport,
    );
    var radioPlaying = true;
    coordinator.suppressTransportCommands = () => radioPlaying;
    await coordinator.attach();
    await transport.playTrack('1');
    // 电台接管声音：音乐被暂停（用户听到的是电台）
    await transport.pause();
    driver.calls.clear();

    bridge.emit(PlayCommand());
    await Future<void>.delayed(Duration.zero);
    expect(driver.calls, isNot(contains('play')), reason: '电台在响，Play 不能把音乐拉起来');

    bridge.emit(NextCommand());
    await Future<void>.delayed(Duration.zero);
    expect(transport.current!.id, '1', reason: '电台在响，Next 也不能换歌');

    // 电台停了（用户按了关闭 / 断流用尽），系统按键恢复原样
    radioPlaying = false;
    bridge.emit(PlayCommand());
    await Future<void>.delayed(Duration.zero);
    expect(driver.calls, contains('play'));
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

  test('artUriFor 接管封面解析：在线匹配 / 写真路径由回调进通知', () async {
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
      artUriFor: (track) => '/matched/${track.id}.jpg',
    ).attach();
    await transport.playTrack('1');
    await settle();
    // 回调结果覆盖曲目自带的内嵌封面路径。
    expect(bridge.published.last.artUri, '/matched/1.jpg');
  });

  test('artUriFor 返回空串时封面为 null（生成卡不进通知）', () async {
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
      artUriFor: (_) => '',
    ).attach();
    await transport.playTrack('1');
    await settle();
    expect(bridge.published.last.artUri, isNull);
  });

  test('封面异步到货后 refresh 补推新封面，通知栏不留占位图', () async {
    String? matchedUri;
    final bridge = FakeMediaSessionBridge();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver(), scheduler: (d, cb) => cb()),
      recent: _NoRecent(),
      toasts: _NoToast(),
      playlist: Playlist.fromTracks([t('1')]),
    );
    final coordinator = MediaSessionCoordinator(
      bridge: bridge,
      transport: transport,
      artUriFor: (_) => matchedUri ?? '',
    );
    await coordinator.attach();
    await transport.playTrack('1');
    await settle();
    expect(bridge.published.last.artUri, isNull);

    // 在线封面晚到：封面表通知 → 装配层调 refresh 补推一次。
    matchedUri = '/matched/1.jpg';
    coordinator.refresh();
    await settle();
    expect(bridge.published.last.artUri, '/matched/1.jpg');
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

  test('电台开始出声后卡片切到电台：台名 / 分类 / 直播，没有进度', () async {
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
    );
    await coordinator.attach();
    await transport.playTrack('1');
    expect(bridge.published.last.kind, MediaKind.music, reason: '先放音乐');

    final engine = FakeRadioEngine();
    final radio = RadioState(
      engine: engine,
      // 与 App 的互斥钩子一致：电台开播先让音乐暂停。
      onTuned: (_) async => transport.player.pause(),
    );
    final binding = RadioMediaSessionBinding(
      session: coordinator,
      radio: radio,
    )..attach();
    addTearDown(() {
      binding.dispose();
      radio.dispose();
    });

    final station = kRadioStations.firstWhere((s) => s.id == 'net-intl-news');
    await radio.tune(station);
    await settle();

    expect(coordinator.radioOwnsCard, isTrue);
    final snapshot = bridge.published.last;
    expect(snapshot.kind, MediaKind.radio);
    expect(snapshot.title, '国际新闻');
    expect(snapshot.artist, '资讯 · 网络台 · 直播');
    expect(snapshot.album, '流光音乐 · 电台');
    expect(snapshot.live, isTrue);
    expect(snapshot.duration, isNull, reason: '直播不画进度条');
    expect(snapshot.playing, isTrue);
    expect(snapshot.position, Duration.zero);
  });

  test('电台接管时系统按键走电台；关闭后卡片交还暂停的音乐', () async {
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
    );
    await coordinator.attach();
    await transport.playTrack('1');
    final engine = FakeRadioEngine();
    final radio = RadioState(
      engine: engine,
      onTuned: (_) async => transport.player.pause(),
    );
    final binding = RadioMediaSessionBinding(
      session: coordinator,
      radio: radio,
    )..attach();
    addTearDown(() {
      binding.dispose();
      radio.dispose();
    });
    await radio.tune(kRadioStations.firstWhere((s) => s.id == 'net-intl-news'));
    await settle();
    expect(coordinator.radioOwnsCard, isTrue);

    engine.calls.clear();
    bridge.emit(const PauseCommand());
    await settle();
    expect(engine.calls, contains('pause'));
    expect(bridge.published.last.kind, MediaKind.radio);
    expect(bridge.published.last.playing, isFalse);

    driver.calls.clear();
    bridge.emit(const PlayCommand());
    await settle();
    expect(engine.calls, contains('play'), reason: 'Play 续播的是电台');
    expect(driver.calls, isNot(contains('play')), reason: '不能把音乐拉起来');

    bridge.emit(const NextCommand());
    await settle();
    expect(transport.current!.id, '1', reason: '直播没有下一台，不该换歌');

    bridge.emit(const StopCommand());
    await settle();
    expect(radio.current, isNull);
    expect(bridge.published.last.kind, MediaKind.music);
    expect(bridge.published.last.title, '歌1');
    expect(bridge.published.last.playing, isFalse);
  });

  test('音乐开声抢回卡片；都没响时卡片留在电台（最后响过的是它）', () async {
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
    );
    await coordinator.attach();
    await transport.playTrack('1');
    await transport.pause();
    await settle();

    final engine = FakeRadioEngine();
    final radio = RadioState(
      engine: engine,
      onTuned: (_) async => transport.player.pause(),
    );
    final binding = RadioMediaSessionBinding(
      session: coordinator,
      radio: radio,
    )..attach();
    addTearDown(() {
      binding.dispose();
      radio.dispose();
    });
    await radio.tune(kRadioStations.firstWhere((s) => s.id == 'net-intl-news'));
    await settle();
    expect(bridge.published.last.kind, MediaKind.radio);

    // 用户暂停电台：卡片留在这一台上（不是切回同样暂停的音乐）。
    await radio.pause();
    await settle();
    expect(bridge.published.last.kind, MediaKind.radio);
    expect(bridge.published.last.playing, isFalse);

    // 音乐开声：卡片立刻切回音乐。
    await transport.resume();
    await settle();
    expect(bridge.published.last.kind, MediaKind.music);
    expect(bridge.published.last.title, '歌1');

    // 音乐再暂停：最后响过的是音乐，卡片留在音乐。
    await transport.pause();
    await settle();
    expect(bridge.published.last.kind, MediaKind.music);
  });
}
