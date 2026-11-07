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

  test('音量拖到 0 只写音量：重启读回 volume=0 且 muted=false', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.setVolume(0);
    // 原版 `volume` 与 `muted` 是两个独立键：拖到 0 只是「没有声音」，
    // 不是「按了静音」。写成 muted=true 会让重启后取消静音也解不掉（I3）。
    expect(await prefs.readNumber(StorageKeys.volume), 0);
    expect(await prefs.readBool(StorageKeys.muted), isFalse);

    // 「重开应用」：新的状态层实例读同一份存档
    final restart = buildState(prefs);
    addTearDown(restart.dispose);
    await restart.ready();

    expect(restart.volume, 0);
    expect(restart.muted, isFalse);
  });

  test('静音状态下拖音量会解掉静音，prefs 里的 muted 跟着改对', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.toggleMute();
    expect(state.muted, isTrue);
    expect(await prefs.readBool(StorageKeys.muted), isTrue);

    // 对齐 player.js:315-324：`setVolume(>0)` 顺带把 muted 清掉
    await state.setVolume(0.5);
    expect(state.muted, isFalse);
    expect(await prefs.readBool(StorageKeys.muted), isFalse);
    expect(state.volume, closeTo(0.5, 1e-9));

    // 取消静音恢复的是记忆音量，不是 0
    await state.toggleMute();
    await state.toggleMute();
    expect(state.volume, closeTo(0.5, 1e-9));
  });

  /// 终审 R5：原版 `setVolume` 的**两个分支都清静音**（`src/lib/player.js:315-324`），
  /// 只有 `v > 0` 那支额外记 `lastVolume`。移植时 else 分支被写成了「什么都不做」，
  /// 于是静音状态下拖到 0，存档里留的是 `muted=true`：重启读回来是「已静音」，
  /// 用户按静音按钮取消静音也解不掉（音量本来就是 0）。
  test('静音时拖到 0 后 muted 变 false 且音量存 0', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.toggleMute();
    expect(state.muted, isTrue);
    expect(await prefs.readBool(StorageKeys.muted), isTrue);

    await state.setVolume(0);
    expect(state.muted, isFalse, reason: 'player.js:322 的 else 分支同样写 muted = false');
    expect(await prefs.readBool(StorageKeys.muted), isFalse);
    expect(await prefs.readNumber(StorageKeys.volume), 0);

    // 「重开应用」：读回来的必须是「音量 0、没有静音」
    final restart = buildState(prefs);
    addTearDown(restart.dispose);
    await restart.ready();
    expect(restart.volume, 0);
    expect(restart.muted, isFalse);
  });

  /// 终审 A1 的验收口径：音量 / 静音的存档路径与 currentId / order 一致 ——
  /// **同一处写、同一处读**，写的是 `AppPrefs` 那两个键，重启读得到的就是
  /// 自己写过的值（不是文件仓里那份从没有读方的死字段，也不是默认 0.7）。
  test('设音量 0.33 之后用同一份存档重建，读回 0.33', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.setVolume(0.33);
    expect(await prefs.readNumber(StorageKeys.volume), 0.33);

    final restart = buildState(prefs);
    addTearDown(restart.dispose);
    await restart.ready();

    expect(restart.volume, closeTo(0.33, 1e-9), reason: '存档值必须原样读回');
    expect(restart.muted, isFalse);
  });

  test('静音存档重启后仍是静音，取消静音恢复的是记忆音量而不是默认 0.7', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.setVolume(0.33);
    await state.toggleMute();
    expect(state.muted, isTrue);
    // 静音只改 muted 键：音量键留着 0.33，重启才有「记忆音量」可恢复
    expect(await prefs.readNumber(StorageKeys.volume), 0.33);
    expect(await prefs.readBool(StorageKeys.muted), isTrue);

    final restart = buildState(prefs);
    addTearDown(restart.dispose);
    await restart.ready();

    expect(restart.muted, isTrue, reason: 'muted=true 必须如实还原');
    // 静音态下读数是 0（UI 靠它画静音图标），但底层记着的是 0.33
    await restart.toggleMute();
    expect(restart.muted, isFalse);
    expect(restart.volume, closeTo(0.33, 1e-9), reason: '取消静音恢复记忆音量，不许落到 0.7');
    expect(await prefs.readBool(StorageKeys.muted), isFalse);
  });

  /// 第 3 轮 M2：还原里「先 volume、后 muted」这个**顺序**是承重的，不是巧合。
  ///
  /// `AudioPlayer.setVolume` 两个分支都清静音（终审 R5），所以 muted 一旦摆在
  /// 前面，紧随其后的 `setVolume(0)` 就会把刚落地的静音当场擦掉 —— 用户
  /// 「静音 + 音量 0」这份现场重启后变成「没静音」，而音量本来就是 0，
  /// 按静音按钮也解不掉任何东西。把 `_loadPersistedPrefs` 的两段换过来，
  /// 这条就红（`lib/state/player_state.dart` 那段注释守的正是这里）。
  test('静音 + 音量为 0 的存档重启仍是静音：还原顺序承重', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs);
    addTearDown(state.dispose);

    await state.setVolume(0);
    // 上一条是 R5：拖到 0 只写音量，不写静音。
    expect(await prefs.readNumber(StorageKeys.volume), 0);
    expect(await prefs.readBool(StorageKeys.muted), isFalse);
    // 再按静音，就留下「volume=0 + muted=true」这份现场（toggleMute 不碰音量键）。
    await state.toggleMute();
    expect(await prefs.readNumber(StorageKeys.volume), 0);
    expect(await prefs.readBool(StorageKeys.muted), isTrue);

    final restart = buildState(prefs);
    addTearDown(restart.dispose);
    await restart.ready();

    expect(
      restart.muted,
      isTrue,
      reason: 'setVolume(0) 清掉的那一次必须被后面的 setMuted(true) 覆盖回来',
    );
    expect(
      await prefs.readBool(StorageKeys.muted),
      isTrue,
      reason: '还原只是读回现场，不许顺手把它改掉',
    );
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

  test('停止播放之后 flushPersist 清掉 currentId，重启不复活已停的曲目', () async {
    final prefs = AppPrefs.inMemory();
    final state = buildState(prefs, tracks: [t('1'), t('2')]);
    addTearDown(state.dispose);

    await state.playTrack('2');
    await state.flushPersist();
    expect(await prefs.readString(StorageKeys.currentId), '2');

    await state.transport.stopPlayback();
    await state.flushPersist();

    // 以前只写不清：停止播放之后重启，会复活一个「不该再播」的 currentId（I4）
    expect(await prefs.readString(StorageKeys.currentId), isNull);
    expect(await prefs.readJson(StorageKeys.order), ['1', '2']);
  });

  test('当前曲目后来变坏：旧的 currentId 要被清掉', () async {
    final prefs = AppPrefs.inMemory();
    final driver = FakeAudioDriver();
    final state = buildState(prefs, tracks: [t('1'), t('2')], driver: driver);
    addTearDown(state.dispose);

    await state.playTrack('1');
    await state.flushPersist();
    expect(await prefs.readString(StorageKeys.currentId), '1');

    // 播过之后文件坏了：这一首不该再是重启时的光标
    driver.alwaysFail = true;
    await state.playTrack('1');
    await settle();
    await state.flushPersist();

    expect(state.current?.broken, isTrue);
    expect(
      await prefs.readString(StorageKeys.currentId),
      isNull,
      reason: '写进去过又留着，就是「指向已损坏曲目的 currentId」',
    );
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
