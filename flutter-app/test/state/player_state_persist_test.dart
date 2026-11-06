// test/state/player_state_persist_test.dart
//
// 播放器状态层：持久化时机（音量 / 静音 / 模式 / 当前曲目 / 顺序）与
// 「进度只发给 ValueNotifier 订阅者，不驱动整树重绘」这条硬约束。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/toast_state.dart';

Track t(String id) =>
    Track(id: id, src: '/$id.flac', title: '歌$id', duration: 100);

/// 广播流是异步投递：等两轮事件循环，让「驱动事件 → 播放器 → 控制器」跑完。
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _NoRecent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}

PlayerState buildState(
  AppPrefs prefs, {
  AudioDriver? driver,
  List<Track>? tracks,
}) => PlayerState(
  prefs: prefs,
  transport: TransportController(
    player: AudioPlayer(driver ?? FakeAudioDriver(), scheduler: (d, cb) => cb()),
    recent: _NoRecent(),
    toasts: ToastState(),
    playlist: Playlist.fromTracks(tracks ?? [t('1')]),
  ),
);

void main() {
  test('音量、静音、模式写进 prefs 并可读回', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.setVolume(0.42);
    await state.toggleMute();
    state.cycleMode();
    await state.flushPersist();

    expect(await prefs.readNumber(StorageKeys.volume), 0.42);
    expect(await prefs.readBool(StorageKeys.muted), isTrue);
    expect(await prefs.readString(StorageKeys.mode), 'one');
  });

  test('冷启动读回音量与模式', () async {
    final prefs = AppPrefs.inMemory();
    await prefs.writeNumber(StorageKeys.volume, 0.3);
    await prefs.writeString(StorageKeys.mode, 'shuffle');
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.ready();

    expect(state.volume, 0.3);
    expect(state.transport.playlist.mode.name, 'shuffle');
  });

  test('当前曲目与顺序落 prefs', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs, tracks: [t('1'), t('2')]);
    addTearDown(state.dispose);

    await state.playTrack('2');
    await state.flushPersist();

    expect(await prefs.readString(StorageKeys.currentId), '2');
    expect(await prefs.readJson(StorageKeys.order), ['1', '2']);
  });

  test('进度通知只发给订阅者，不触发全局 notify', () async {
    final prefs = AppPrefs.inMemory();
    final driver = FakeAudioDriver();
    final state = buildState(prefs, driver: driver);
    addTearDown(state.dispose);

    var positionCalls = 0;
    var stateCalls = 0;
    state.position.addListener(() => positionCalls++);
    state.addListener(() => stateCalls++);
    final baseline = stateCalls;

    await state.playTrack('1');
    await settle();
    // 切歌本身可以有少量语义通知（加载 / 播放态），但绝不是每帧一次
    expect(stateCalls - baseline, isNot(greaterThan(3)));

    final beforePositions = stateCalls;
    driver.emitPosition(1);
    driver.emitPosition(2);
    await settle();

    expect(positionCalls, 2);
    expect(stateCalls, beforePositions); // 进度一个字节都不该驱动整树

    // 再连推几帧仍是同样结论：全局通知计数保持不动
    for (var i = 3; i <= 6; i++) {
      driver.emitPosition(i.toDouble());
    }
    await settle();
    expect(positionCalls, 6);
    expect(stateCalls, beforePositions);
  });

  test('损坏曲目不写进 currentId', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(
      prefs,
      driver: FakeAudioDriver()..alwaysFail = true,
    );
    addTearDown(state.dispose);

    await state.playTrack('1');
    // 加载失败是经广播流异步投递回来的（真实场景里由 400ms 防抖兜住），
    // 等它落到 track.broken 上再落盘
    await settle();
    await state.flushPersist();

    expect(state.current?.broken, isTrue);
    expect(await prefs.readString(StorageKeys.currentId), isNot('1'));
  });
}
