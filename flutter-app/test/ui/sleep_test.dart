// test/ui/sleep_test.dart
//
// 休眠模块（T32）：顶栏入口（在「电台」左侧）、状态层（让位 / 自动退让 /
// 续播不重开文件 / 停止清空）、休眠页（三页签、点行起播）、迷你条。
//
// 全部走 FakeSleepEngine + FakeRadioEngine + FakeAudioDriver：不开原生库、
// 不写临时 WAV、不打网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/radio/radio_engine.dart';
import 'package:light_music/radio/radio_state.dart';
import 'package:light_music/radio/radio_station.dart';
import 'package:light_music/sleep/sleep_audio.dart';
import 'package:light_music/sleep/sleep_state.dart';
import 'package:light_music/sleep/sleep_track.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/header.dart';
import 'package:light_music/ui/page_link_chip.dart';
import 'package:light_music/ui/sleep_bar.dart';
import 'package:light_music/ui/sleep_page.dart';
import 'package:provider/provider.dart';

class _NoRecent implements RecentRecorder {
  @override
  void record(Track track, {DateTime? at}) {}
}

Track _track() => Track(id: 't1', src: '/t1.flac', title: '歌', duration: 100);

/// 不落盘的缓存替身：只返回一个稳定的假路径。
class _FakeCache extends SleepAudioCache {
  @override
  Future<String> fileFor(SleepTrack track) async => '/fake/${track.id}.wav';
}

/// 一套可观测的装配：音乐、电台、休眠三条链路 + 各自的假内核。
class _Harness {
  _Harness() {
    driver = FakeAudioDriver();
    transport = TransportController(
      player: AudioPlayer(driver, scheduler: (_, _) {}),
      recent: _NoRecent(),
      toasts: ToastState(),
      playlist: Playlist.fromTracks([_track()]),
    );
    player = PlayerState(prefs: AppPrefs.inMemory(), transport: transport);
    radio = RadioState(engine: FakeRadioEngine());
    engine = FakeSleepEngine();
    sleep = SleepState(
      player: player,
      radio: radio,
      engine: engine,
      cache: _FakeCache(),
    );
  }

  late final FakeAudioDriver driver;
  late final TransportController transport;
  late final PlayerState player;
  late final RadioState radio;
  late final FakeSleepEngine engine;
  late final SleepState sleep;

  SleepTrack track(String id) => sleepTrackById(id)!;

  Future<void> dispose() async {
    sleep.dispose();
    radio.dispose();
    player.dispose();
  }
}

void _setViewport(WidgetTester tester, Size size) {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

Widget _themed(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: child,
);

Widget _sleepHosted(_Harness h, Widget child) => _themed(
  ChangeNotifierProvider<SleepState>.value(value: h.sleep, child: child),
);

void main() {
  group('SleepState', () {
    testWidgets('起播：先停音乐与电台，再开声；淡入到 0.72', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);

      // 先让电台在响，验证「双让位」不是只停音乐。
      await h.radio.tune(radioStationById('fm-beijing-music')!);
      await tester.pump();
      expect(h.radio.playing, isTrue);

      final rain = h.track('sleep-rain');
      await h.sleep.tune(rain);
      await tester.pump();

      expect(h.driver.calls, contains('pause'), reason: '音乐要先停');
      expect(h.radio.playing, isFalse, reason: '电台也要停');
      expect(h.sleep.current?.id, 'sleep-rain');
      expect(h.sleep.playing, isTrue);
      expect(h.engine.calls, contains('open:/fake/sleep-rain.wav'));
      expect(h.engine.calls, contains('volume:0.00'));

      // 淡入按 Timer.tick 走：拨 1.5s 到顶。
      await tester.pump(const Duration(milliseconds: 1500));
      expect(h.engine.calls.last, 'volume:0.72');
      await h.sleep.pause();
      await tester.pump();
    });

    testWidgets('续播不重开文件；停止清空当前曲目', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);

      await h.sleep.tune(h.track('sleep-ocean'));
      await tester.pump(const Duration(milliseconds: 1500));
      final opens = h.engine.calls
          .where((call) => call.startsWith('open:'))
          .length;

      await h.sleep.pause();
      await tester.pump();
      await h.sleep.resume();
      await tester.pump(const Duration(milliseconds: 1500));

      expect(
        h.engine.calls.where((call) => call.startsWith('open:')).length,
        opens,
        reason: '媒体还挂在 Player 上，续播只 play 不重开',
      );
      expect(h.engine.calls.last, 'volume:0.72');

      await h.sleep.stop();
      expect(h.sleep.current, isNull);
      expect(h.sleep.playing, isFalse);
      expect(h.engine.calls, contains('stop'));
    });

    testWidgets('音乐一开声，休眠自动让位且保留曲目', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);

      await h.sleep.tune(h.track('sleep-wind'));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(h.sleep.playing, isTrue);

      await h.transport.playTrack('t1');
      await tester.pump();

      expect(h.sleep.playing, isFalse);
      expect(h.sleep.current?.id, 'sleep-wind', reason: '迷你条还要交代是哪一段');
      expect(h.engine.calls.last, 'pause');
      await h.player.flushPersist();
    });

    testWidgets('开流失败：稳定态 + 一句人话', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.engine.failNextOpen = true;

      await h.sleep.tune(h.track('sleep-noise'));
      await tester.pump();

      expect(h.sleep.playing, isFalse);
      expect(h.sleep.loading, isFalse);
      expect(h.sleep.error, contains('再点一次'));
      expect(h.sleep.current?.id, 'sleep-noise', reason: '失败也保留选择');
      await h.player.flushPersist();
    });
  });

  group('顶栏入口', () {
    testWidgets('桌面：休眠在电台左侧，点它进休眠', (tester) async {
      _setViewport(tester, const Size(1200, 800));
      var opened = 0;
      await tester.pumpWidget(
        _themed(
          Scaffold(
            body: AppHeader(
              onAddFiles: () async {},
              onAddFolder: () async {},
              onClearPlaylist: () async {},
              onOpenSleep: () => opened++,
              onOpenRadio: () {},
            ),
          ),
        ),
      );

      expect(find.text('助眠'), findsOneWidget);
      expect(find.text('电台'), findsOneWidget);
      final sleepX = tester.getCenter(find.text('助眠')).dx;
      final radioX = tester.getCenter(find.text('电台')).dx;
      final moreX = tester.getCenter(find.text('更多')).dx;
      expect(sleepX, lessThan(radioX));
      expect(radioX, lessThan(moreX));

      await tester.tap(find.text('助眠'));
      expect(opened, 1);
    });

    testWidgets('窄屏：只留 32×32 月亮图标', (tester) async {
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        _themed(
          Scaffold(
            body: AppHeader(
              onAddFiles: () async {},
              onAddFolder: () async {},
              onClearPlaylist: () async {},
              onOpenSleep: () {},
              onOpenRadio: () {},
            ),
          ),
        ),
      );

      expect(find.text('助眠'), findsNothing);
      final button = find.byKey(const Key('sleep-button'));
      expect(button, findsOneWidget);
      expect(tester.getSize(button), const Size(32, 32));
    });
  });

  group('休眠页', () {
    testWidgets('三个页签、首曲夜色卡、点行起播', (tester) async {
      _setViewport(tester, const Size(1280, 900));
      final h = _Harness();
      addTearDown(h.dispose);

      await tester.pumpWidget(_sleepHosted(h, SleepPage(onBack: () {})));
      await tester.pump();

      for (final tab in kSleepTabs) {
        expect(
          find.byKey(Key('sleep-tab-${tab.id.name}'), skipOffstage: false),
          findsOneWidget,
        );
      }
      expect(find.text('夜雨 · 屋檐'), findsNWidgets(2)); // 卡面 + 行表
      expect(
        tester.getSize(find.byKey(const Key('sleep-art-card'))).width,
        760,
        reason: '桌面版心 760，与 React `.sleep-page` max-width 一致',
      );
      final cardTopLeft = tester.getTopLeft(
        find.byKey(const Key('sleep-art-card')),
      );
      expect(cardTopLeft.dx, 260, reason: '760 版心居中后左边距');
      expect(cardTopLeft.dy, closeTo(182, 2), reason: '页头 + 问候 + 24 间距');
      expect(find.byKey(const Key('sleep-row-sleep-ocean')), findsOneWidget);
      expect(find.text('晚安，好梦。'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sleep-row-sleep-ocean')));
      await tester.pump();
      expect(h.sleep.current?.id, 'sleep-ocean');
      expect(h.sleep.playing, isTrue);

      // 让淡入定时器走完，再把树拆掉，避免 pending Timer / Ticker。
      await tester.pump(const Duration(milliseconds: 1500));
      await h.sleep.pause();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('窄屏 390×844：卡片 226 高，页签与行表不溢出', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final h = _Harness();
      addTearDown(h.dispose);

      await tester.pumpWidget(_sleepHosted(h, SleepPage(onBack: () {})));
      await tester.pump();

      expect(find.text('把今天，轻轻放下'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('sleep-art-card'))),
        const Size(358, 226),
      );
      expect(find.text('晚安，好梦。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('切换页签：摇篮三张行、白噪两张，声景七张', (tester) async {
      _setViewport(tester, const Size(1280, 900));
      final h = _Harness();
      addTearDown(h.dispose);

      await tester.pumpWidget(_sleepHosted(h, SleepPage(onBack: () {})));
      await tester.pump();

      // 声景页：老的雨 / 潮 / 风 + 新加的溪涧 / 鸟鸣 / 篝火 / 虫鸣
      for (final id in [
        'sleep-rain',
        'sleep-stream',
        'sleep-birds',
        'sleep-campfire',
        'sleep-crickets',
      ]) {
        expect(
          find.byKey(Key('sleep-row-$id'), skipOffstage: false),
          findsOneWidget,
          reason: id,
        );
      }

      await tester.tap(find.byKey(const Key('sleep-tab-lullaby')));
      await tester.pump();
      expect(find.byKey(const Key('sleep-row-sleep-lullaby')), findsOneWidget);
      expect(find.byKey(const Key('sleep-row-sleep-musicbox')), findsOneWidget);
      expect(find.byKey(const Key('sleep-row-sleep-nocturne')), findsOneWidget);
      expect(find.byKey(const Key('sleep-row-sleep-rain')), findsNothing);

      await tester.tap(find.byKey(const Key('sleep-tab-noise')));
      await tester.pump();
      expect(find.byKey(const Key('sleep-row-sleep-noise')), findsOneWidget);
      expect(
        find.byKey(const Key('sleep-row-sleep-waterfall')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sleep-row-sleep-lullaby')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('右上角「电台」互跳：挨着「音乐」，点它去电台页', (tester) async {
      _setViewport(tester, const Size(1280, 900));
      final h = _Harness();
      addTearDown(h.dispose);
      var opened = 0;

      await tester.pumpWidget(
        _sleepHosted(h, SleepPage(onBack: () {}, onOpenRadio: () => opened++)),
      );
      await tester.pump();

      final radioChip = find.byKey(const Key('sleep-radio-button'));
      expect(radioChip, findsOneWidget);
      expect(find.text('电台'), findsOneWidget);
      // 桌面：与「音乐」回退同一档 36px 胶囊，排它在左边
      expect(tester.getSize(radioChip).height, 36);
      final tokens = tester.element(radioChip).tokens;
      expect(tester.widget<Text>(find.text('电台')).style?.color, tokens.text);
      expect(tester.widget<Text>(find.text('音乐')).style?.color, tokens.text);
      final radioPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('sleep-radio-button')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((radioPaint.painter! as BroadcastPainter).color, tokens.text);
      final note = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('sleep-back-button')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((note.painter! as MusicNotePainter).color, tokens.text);
      expect(
        tester.getCenter(radioChip).dx,
        lessThan(
          tester.getCenter(find.byKey(const Key('sleep-back-button'))).dx,
        ),
      );

      await tester.tap(radioChip);
      expect(opened, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('窄屏：电台 / 音乐 / 更多三颗各 32×32，按 8px 自右向左排', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final h = _Harness();
      addTearDown(h.dispose);

      await tester.pumpWidget(
        _sleepHosted(h, SleepPage(onBack: () {}, onOpenRadio: () {})),
      );
      await tester.pump();

      // 四颗（定时器 26 + 三颗 32）与品牌块同处一行也不挤爆
      expect(tester.takeException(), isNull);
      // 落位与 Web 的 right: 90 / 50 / 10 同构（390 - 16 内缩 + 6 只挪绘制）
      // 纵向 = 三页统一口径：按钮上缘 12（图标中心 28）
      expect(
        tester.getRect(find.byKey(const Key('sleep-radio-button'))),
        const Rect.fromLTWH(268, 12, 32, 32),
      );
      expect(
        tester.getRect(find.byKey(const Key('sleep-back-button'))),
        const Rect.fromLTWH(308, 12, 32, 32),
      );
      expect(
        tester.getRect(find.byKey(const Key('menu-button'))),
        const Rect.fromLTWH(348, 12, 32, 32),
      );
      final tokens = tester.element(find.byType(SleepPage)).tokens;
      final radioPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('sleep-radio-button')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((radioPaint.painter! as BroadcastPainter).color, tokens.textDim);
      final notePaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('sleep-back-button')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((notePaint.painter! as MusicNotePainter).color, tokens.textDim);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('迷你休眠条', () {
    testWidgets('在放时交代曲目与质地，三个动作各自生效', (tester) async {
      _setViewport(tester, const Size(1200, 900));
      final h = _Harness();
      addTearDown(h.dispose);
      await h.sleep.tune(h.track('sleep-rain'));
      await tester.pump(const Duration(milliseconds: 1500));

      var opened = 0;
      await tester.pumpWidget(
        _sleepHosted(h, Scaffold(body: SleepBar(onOpen: () => opened++))),
      );

      expect(find.text('夜雨 · 屋檐'), findsOneWidget);
      expect(find.text('雨声 · 窗外 · 32 秒循环'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sleep-bar-open')));
      expect(opened, 1);

      await tester.tap(find.byKey(const Key('sleep-bar-toggle')));
      await tester.pump();
      expect(h.sleep.playing, isFalse);
      expect(h.sleep.current?.id, 'sleep-rain');

      await tester.tap(find.byKey(const Key('sleep-bar-stop')));
      await tester.pump();
      expect(h.sleep.current, isNull);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
