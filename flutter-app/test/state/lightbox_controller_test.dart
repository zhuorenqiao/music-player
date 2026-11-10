// test/state/lightbox_controller_test.dart
//
// M2b T9 闸口：灯箱控制器的幂等语义 + `closeOverlay` 分支的层叠优先级。
//
// 分支矩阵走**真装配**：Esc 的顶层判定在 `app.dart` 的 playerCallback 闭包里，
// 只有把 [LightMusicApp] 真跑起来、发真 Esc 键才能验「灯箱开着时歌词页不被
// 关」。装配用的替身与 lyrics_wiring_test 同一套：假 matcher / fetcher、
// FakeAudioDriver / FakeMediaSessionBridge，绝不打网络。
//
// 收尾纪律（照抄 m1_smoke_test）：player / library / recent / toasts 各自
// dispose；`AppBootstrap.dispose`（时长探测内核的释放链）由界面层的
// `State.dispose` unawaited 排进真异步区 —— 测试不等它，FakeAsync 的收尾
// 一旦 await 那条真异步链就会永远挂住。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/app.dart' show AppBootstrap, LightMusicApp;
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/library/library_repository.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/main.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/media_session_bridge.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/lightbox_controller.dart';

class _Matcher implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async =>
      const LyricsMatch(status: 'not-found');
}

class _Fetcher implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async =>
      const TranslationResult(status: 'not-found', reason: 'song-not-matched');
}

/// 永不完成的延时接缝：与 lyrics_wiring_test 同一条防 pending-Timer 手法。
Future<void> Function(Duration) get _neverFire {
  final completer = Completer<void>();
  return (_) => completer.future;
}

void main() {
  group('LightboxController', () {
    test('初始关闭；open/close/toggle 幂等，同值不通知', () {
      final controller = LightboxController();
      var notified = 0;
      controller.addListener(() => notified++);

      expect(controller.isOpen, isFalse);

      controller.open();
      expect(controller.isOpen, isTrue);
      controller.open();
      expect(notified, 1, reason: '重复 open 幂等：不第二次通知');

      controller.close();
      expect(controller.isOpen, isFalse);
      controller.close();
      expect(notified, 2, reason: '重复 close 幂等：不第二次通知');

      controller.toggle();
      expect(controller.isOpen, isTrue);
      controller.toggle();
      expect(controller.isOpen, isFalse);
      expect(notified, 4);
    });

    test('toggle 走完整序列：关 → 开 → 关，每次各通知一次', () {
      final controller = LightboxController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.toggle();
      expect(controller.isOpen, isTrue);
      controller.toggle();
      expect(controller.isOpen, isFalse);
      expect(notified, 2);
    });
  });

  group('closeOverlay 层叠优先级（真装配：真 App + 真 Esc 键）', () {
    testWidgets('灯箱开着 + 歌词页开着：Esc 只关灯箱，歌词页保持其下', (tester) async {
      final h = await _pumpApp(tester);
      h.bootstrap.lyricsPage.open();
      h.bootstrap.lightbox.open();
      await tester.pump();

      await _pressEsc(tester);

      expect(h.bootstrap.lightbox.isOpen, isFalse, reason: '灯箱在最上面，先关');
      expect(h.bootstrap.lyricsPage.isOpen, isTrue, reason: '歌词页叠在下面，不受影响');
    });

    testWidgets('只开灯箱：Esc 关灯箱，歌词页保持关', (tester) async {
      final h = await _pumpApp(tester);
      h.bootstrap.lightbox.open();
      await tester.pump();

      await _pressEsc(tester);

      expect(h.bootstrap.lightbox.isOpen, isFalse);
      expect(h.bootstrap.lyricsPage.isOpen, isFalse);
    });

    testWidgets('只开歌词页：Esc 关歌词页', (tester) async {
      final h = await _pumpApp(tester);
      h.bootstrap.lyricsPage.open();
      await tester.pump();

      await _pressEsc(tester);

      expect(h.bootstrap.lightbox.isOpen, isFalse);
      expect(h.bootstrap.lyricsPage.isOpen, isFalse);
    });

    testWidgets('都关：Esc 无动作、无异常', (tester) async {
      final h = await _pumpApp(tester);

      await _pressEsc(tester);

      expect(h.bootstrap.lightbox.isOpen, isFalse);
      expect(h.bootstrap.lyricsPage.isOpen, isFalse);
    });
  });
}

/// 组合根 + 真 [LightMusicApp] 的装配：组合根要读真实文件 / 跑真异步，
/// 借 `runAsync` 跑（testWidgets 的 FakeAsync 里 await 真异步等不到头 ——
/// 与 lyrics_wiring_test / m1_smoke_test 同一条手法）。收尾全走 `addTearDown`
/// 的同步 dispose，不 await 任何真异步链（见文件头「收尾纪律」）。
Future<AppBootstrapHarness> _pumpApp(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('lightbox-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final prefs = AppPrefs.inMemory();
  final bootstrap = await tester.runAsync(() async {
    await LibraryRepository(directory: dir.path).save(
      LibrarySnapshot(
        tracks: [
          Track(id: 'a', src: '/m/a.flac', title: 'A', duration: 60),
        ],
        order: ['a'],
        currentId: 'a',
      ),
    );
    return buildBootstrap(
      prefs: prefs,
      dataDirectory: dir.path,
      driver: FakeAudioDriver(),
      bridge: FakeMediaSessionBridge(),
      lyricsMatcher: _Matcher(),
      translationFetcher: _Fetcher(),
      lyricsDelay: _neverFire,
    );
  });

  addTearDown(bootstrap!.player.dispose);
  addTearDown(bootstrap.library.dispose);
  addTearDown(bootstrap.recent.dispose);
  addTearDown(bootstrap.toasts.dispose);
  // `AppBootstrap.dispose` 不在这里 await：时长探测内核的关闭排在真异步区，
  // 界面层卸载（pumpWidget 的树被拆）时已经由 `State.dispose` unawaited 发起。

  await tester.pumpWidget(LightMusicApp(bootstrap: bootstrap));
  // 快捷键宿主（AppShortcuts 里的 autofocus Focus）首帧才拿到焦点，
  // 不补这一帧的话 Esc 会落空。
  await tester.pump();
  return AppBootstrapHarness(dir, bootstrap);
}

/// 发一个真 Esc 键并推一帧。
///
/// `closeOverlay` 分支是**同步**的（switch 里直接调 controller），不需要排
/// 事件队列 —— 那条 `runAsync(pumpEventQueue)` 只对「内核异步回包改状态」的
/// 用例必要，这里加了反而多等一轮真异步排水。
Future<void> _pressEsc(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump();
}

class AppBootstrapHarness {
  AppBootstrapHarness(this.dir, this.bootstrap);

  final Directory dir;
  final AppBootstrap bootstrap;
}
