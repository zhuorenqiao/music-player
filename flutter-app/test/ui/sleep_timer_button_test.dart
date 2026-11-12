// test/ui/sleep_timer_button_test.dart
//
// 睡眠定时器：状态语义（deadline / 剩余时间 / 到点暂停 / 重启恢复）+ 按钮与面板。
//
// 时钟是注入的（`now:` 接缝），倒计时的 tick 用真 Timer —— testWidgets 的
// FakeAsync 里 `tester.pump(Duration)` 会把定时器拨到点，与 lyrics_view 那套
// 用法一致。用例收尾必须把定时器停掉（cancel / dispose），否则 FakeAsync 会
// 报「还有 pending Timer」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/sleep_timer_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/sleep_timer_button.dart';
import 'package:provider/provider.dart';

class _NoRecent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}

Track _track() =>
    Track(id: 't1', src: '/t1.flac', title: '歌', duration: 100);

/// 一套可观测的装配：内核、播放器、提示、prefs 与定时器。
class _Harness {
  _Harness({
    AppPrefs? prefs,
  })  : prefs = prefs ?? AppPrefs.inMemory(),
        toasts = ToastState() {
    driver = FakeAudioDriver();
    transport = TransportController(
      player: AudioPlayer(driver, scheduler: (_, _) {}),
      recent: _NoRecent(),
      toasts: toasts,
      playlist: Playlist.fromTracks([_track()]),
    );
    player = PlayerState(prefs: this.prefs, transport: transport);
    timer = SleepTimerState(
      prefs: this.prefs,
      player: player,
      toasts: toasts,
      now: () => clock,
    );
  }

  final AppPrefs prefs;
  final ToastState toasts;
  late final FakeAudioDriver driver;
  late final TransportController transport;
  late final PlayerState player;
  late final SleepTimerState timer;

  /// 可拨动的假时钟。
  DateTime clock = DateTime(2026, 1, 1, 12, 0, 0);

  /// 收尾：把定时器、提示与落盘去抖的 Timer 都停掉。
  ///
  /// **必须在用例体里调**（不能只放进 addTearDown）：FakeAsync 的
  /// 「没有 pending Timer」断言跑在 tearDown **之前**，留到 tearDown 就晚了。
  Future<void> cleanup() async {
    timer.cancel();
    toasts.drainForTest();
    await player.flushPersist();
  }

  void dispose() {
    timer.dispose();
    player.dispose();
  }
}

/// 装配：provider 放在 MaterialApp **外面** —— 面板是插进 Overlay 的，
/// 而 Overlay 在 Navigator 里、比 Scaffold 高，provider 放在 Scaffold 的 body 里
/// 面板就找不到它了。生产里 provider 由 app.dart 的 MultiProvider 挂在
/// MaterialApp 外面，与这里一致。
Widget _wrap(_Harness harness, Widget child) =>
    ChangeNotifierProvider<SleepTimerState>.value(
      value: harness.timer,
      child: MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  test('预设档位：10/15/20/30/60 分钟，默认 10 分钟', () {
    expect(kSleepTimerPresets, <int>[10, 15, 20, 30, 60]);
    expect(kSleepTimerDefaultMinutes, 10);
  });

  testWidgets('设定 10 分钟：deadline 与剩余时间对得上', (tester) async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    harness.timer.start(10);
    await tester.pump();

    expect(harness.timer.running, isTrue);
    expect(
      harness.timer.deadline,
      harness.clock.add(const Duration(minutes: 10)),
    );
    expect(harness.timer.remaining, const Duration(minutes: 10));
    expect(harness.timer.remainingText, '10:00');
    expect(harness.timer.ending, isFalse);
    await harness.cleanup();
  });

  testWidgets('取消定时器：回到未启用', (tester) async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    harness.timer.start(15);
    await tester.pump();
    harness.timer.cancel();
    await tester.pump();

    expect(harness.timer.running, isFalse);
    expect(harness.timer.deadline, isNull);
    expect(harness.timer.remainingText, '00:00');
    await harness.cleanup();
  });

  testWidgets('到点：暂停播放 + 提示 + 定时器清空', (tester) async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    harness.timer.start(1);
    await tester.pump();

    // 时间到：把假时钟拨过截止时刻，再让 tick 跑一次。
    harness.clock = harness.clock.add(const Duration(minutes: 1, seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(harness.driver.calls, contains('pause'));
    expect(harness.timer.running, isFalse);
    expect(
      harness.toasts.items.map((item) => item.message),
      contains('定时结束，已暂停播放'),
    );
    await harness.cleanup();
  });

  testWidgets('重启后恢复：deadline 还在就接着走', (tester) async {
    final prefs = AppPrefs.inMemory();
    final harness = _Harness(prefs: prefs);
    addTearDown(harness.dispose);

    harness.timer.start(30);
    await tester.pump();
    final deadline = harness.timer.deadline!;

    // 换一个实例（模拟重启），从 prefs 里把 deadline 接回来。
    final restored = _Harness(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.timer.restore();
    await tester.pump();

    expect(restored.timer.running, isTrue);
    expect(restored.timer.deadline, deadline);
    await harness.cleanup();
    await restored.cleanup();
  });

  testWidgets('早就过期的 deadline 不恢复', (tester) async {
    final prefs = AppPrefs.inMemory();
    await prefs.writeNumber(
      StorageKeys.sleepTimer,
      DateTime(2020).millisecondsSinceEpoch,
    );

    final harness = _Harness(prefs: prefs);
    addTearDown(harness.dispose);
    await harness.timer.restore();
    await tester.pump();

    expect(harness.timer.running, isFalse);
    expect(await prefs.readNumber(StorageKeys.sleepTimer), isNull);
    await harness.cleanup();
  });

  group('按钮与面板', () {
    testWidgets('点开面板：5 档预设 + 自定义输入 + 开始', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();

      expect(find.text('10 分钟'), findsNothing);
      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      for (final preset in kSleepTimerPresets) {
        expect(find.text('$preset 分钟'), findsOneWidget);
      }
      expect(find.byKey(const Key('sleep-timer-custom')), findsOneWidget);
      expect(find.text('开始'), findsOneWidget);
      await harness.cleanup();
    });

    testWidgets('选一档再点开始：定时器跑起来，按钮显示剩余时间', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      await tester.tap(find.text('15 分钟'));
      await tester.pump();
      await tester.tap(find.text('开始'));
      await tester.pump();

      expect(harness.timer.running, isTrue);
      expect(harness.timer.remaining, const Duration(minutes: 15));
      // 按钮上直接显示剩余 mm:ss
      expect(find.text('15:00'), findsOneWidget);
      await harness.cleanup();
    });

    testWidgets('自定义分钟数：输入什么就是几（合法区间内）', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('sleep-timer-custom')),
        '45',
      );
      await tester.pump();
      await tester.tap(find.text('开始'));
      await tester.pump();

      expect(harness.timer.remaining, const Duration(minutes: 45));
      expect(find.text('45:00'), findsOneWidget);
      await harness.cleanup();
    });
  });
}
