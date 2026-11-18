// test/ui/sleep_timer_button_test.dart
//
// 睡眠定时器：状态语义（deadline / 剩余时间 / 到点暂停 / 重启恢复）+ 按钮与面板。
// 面板同步 React 新版（`SleepTimerButton.tsx` 工作区那版）：滑杆 1~999 分钟
// （指数映射）+ 自定义输入 + 开始 / 重新计时，运行中多一行「剩余 + 取消定时」。
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

/// 面板里那行读数当前显示什么。
String _readout(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('sleep-timer-readout')))
    .data!;

void main() {
  group('滑杆映射与读数', () {
    test('位置 ↔ 分钟数是一对反函数（指数映射，两端对齐）', () {
      expect(minutesForPosition(0), kSleepTimerMinMinutes);
      expect(minutesForPosition(100), kSleepTimerMaxMinutes);
      // 中点：1 * 999^0.5 ≈ 31.6 → 32（低端行程更宽的那份手感）
      expect(minutesForPosition(50), 32);
      expect(positionForMinutes(kSleepTimerMinMinutes), 0);
      expect(positionForMinutes(kSleepTimerMaxMinutes), 100);
      // 来回一趟不掉档（滑杆位置是 double，读数要能回到同一个分钟数）
      for (final minutes in <int>[2, 10, 45, 120, 300, 720]) {
        expect(minutesForPosition(positionForMinutes(minutes)), minutes);
      }
    });

    test('读数：不足 1 小时报分钟，否则报「X 小时 Y 分钟」', () {
      expect(sleepTimerReadout(10), '10 分钟');
      expect(sleepTimerReadout(59), '59 分钟');
      expect(sleepTimerReadout(60), '1 小时');
      expect(sleepTimerReadout(75), '1 小时 15 分钟');
      expect(sleepTimerReadout(kSleepTimerMaxMinutes), '16 小时 39 分钟');
      expect(kSleepTimerMaxReadout, '16 小时 39 分钟');
    });

    test('缺省仍是 10 分钟（面板打开时滑杆停在这一档）', () {
      expect(kSleepTimerDefaultMinutes, 10);
    });
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
    testWidgets('点开面板：滑杆 + 自定义输入 + 开始（默认 10 分钟）', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();

      expect(find.byKey(const Key('sleep-timer-slider')), findsNothing);
      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      expect(find.byKey(const Key('sleep-timer-slider')), findsOneWidget);
      expect(find.byKey(const Key('sleep-timer-custom')), findsOneWidget);
      expect(_readout(tester), '10 分钟');
      // 滑杆右端的上限读数
      expect(find.text('1 分钟 – 16 小时 39 分钟'), findsOneWidget);
      expect(find.text('开始'), findsOneWidget);
      // 未运行：没有「取消定时」那一行
      expect(find.text('取消定时'), findsNothing);
      await harness.cleanup();
    });

    testWidgets('自定义 15 分钟再点开始：定时器跑起来，按钮显示剩余时间', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('sleep-timer-custom')),
        '15',
      );
      await tester.pump();
      expect(_readout(tester), '15 分钟');

      await tester.tap(find.text('开始'));
      await tester.pump();

      expect(harness.timer.running, isTrue);
      expect(harness.timer.remaining, const Duration(minutes: 15));
      // 按钮上直接显示剩余 mm:ss
      expect(find.text('15:00'), findsOneWidget);
      await harness.cleanup();
    });

    testWidgets('拖滑杆到右端：读数变成小时级，自定义框跟着同步', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      // 一路拖过右端：值被夹在 999 分钟（16 小时 39 分钟）上。
      await tester.drag(
        find.byKey(const Key('sleep-timer-slider')),
        const Offset(400, 0),
      );
      await tester.pump();

      expect(_readout(tester), '16 小时 39 分钟');
      // 自定义输入框里的原始文本 = 同一个分钟数
      final field = tester.widget<TextField>(
        find.byKey(const Key('sleep-timer-custom')),
      );
      expect(field.controller!.text, '999');

      await tester.tap(find.text('开始'));
      await tester.pump();
      expect(harness.timer.remaining, const Duration(minutes: 999));
      await harness.cleanup();
    });

    testWidgets('运行中再点开：剩余 + 取消定时，按钮变「重新计时」', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();
      harness.timer.start(20);
      await tester.pump();

      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      expect(find.text('剩余 20:00'), findsOneWidget);
      expect(find.text('取消定时'), findsOneWidget);
      expect(find.text('重新计时'), findsOneWidget);
      expect(find.text('开始'), findsNothing);

      await tester.tap(find.text('取消定时'));
      await tester.pump();

      expect(harness.timer.running, isFalse);
      // 面板收起（取消后 Overlay 一并移除）
      expect(find.text('取消定时'), findsNothing);
      await harness.cleanup();
    });

    testWidgets('超出范围的输入不生效（夹在 1~999 分钟）', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(_wrap(harness, const SleepTimerButton()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sleep-timer-trigger')));
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('sleep-timer-custom')),
        '1200',
      );
      await tester.pump();
      // 越界不改已选的档，读数仍停在 10 分钟
      expect(_readout(tester), '10 分钟');

      await tester.tap(find.text('开始'));
      await tester.pump();
      expect(harness.timer.remaining, const Duration(minutes: 10));
      await harness.cleanup();
    });
  });
}
