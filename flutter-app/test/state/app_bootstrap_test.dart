// test/state/app_bootstrap_test.dart
//
// 组合根（T23 的装配）：存档还原顺序、媒体会话附着时机，以及
// 「应用根把四个状态注册给 provider」这条界面契约。
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