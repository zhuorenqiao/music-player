// test/ui/parity_regression_test.dart
//
// 与 React 版并排比对后的差异回归：这几处曾经与原版对不上，现钉住.
//
//   1. 头部右上角是「更多」（三点竖排图标 + 文字），不是「菜单」+ 汉堡线；
//   2. 歌词页右栏封面是**圆角方形**（24px 圆角 + 1px 描边），不是黑胶圆碟；
//   3. 桌面控制条在歌词页时补一颗「播放列表」入口（React
//      `body.is-lyrics-page .controls__queue`）；
//   4. 抽屉/弹层遮罩取 `--scrim`（压暗），不是「页面底色 + 66% 透明度」
//      —— 后者在浅色主题里是一层白纱，把背景漂白（React `.drawer__scrim`
//      用的是 `var(--scrim)`，app.css:3207）。
//
// 频谱柱体清晰度的回归在 test/wave/wave_styles_test.dart 里（像素级断言）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/audio_driver.dart';
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_page_controller.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/drawer_menu.dart';
import 'package:light_music/ui/header.dart';
import 'package:light_music/ui/lyrics_page.dart';
import 'package:light_music/ui/transport.dart';
import 'package:light_music/ui/vinyl_deck.dart';
import 'package:provider/provider.dart';

class _NullRecent implements RecentRecorder {
  const _NullRecent();
  @override
  void record(Track track, {DateTime? at}) {}
}

class _SilentToasts implements ToastSink {
  const _SilentToasts();
  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}
  @override
  void info(String message) {}
  @override
  void error(String message, {int durationMs = 3200}) {}
}

class _NoMatch implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async =>
      const LyricsMatch(status: 'not-found');
}

class _NoTranslation implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async =>
      const TranslationResult(status: 'not-found');
}

void main() {
  group('头部：右上角是「更多」', () {
    testWidgets('视觉文案与读屏名都是「更多」', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 400);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme().copyWith(
            extensions: const [AppTokensData(tokens: AppTokens.dark)],
          ),
          home: Scaffold(
            body: AppHeader(
              onAddFiles: () async {},
              onAddFolder: () async {},
              onClearPlaylist: () async {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('更多'), findsOneWidget);
      expect(find.text('菜单'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('歌词页右栏封面：圆角方形而非黑胶圆碟', () {
    testWidgets('封面是方图（无 ClipOval 圆碟）', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final track = Track(
        id: 't1',
        src: '/music/t1.flac',
        title: '谁稀罕',
        artist: '周杰伦',
      );
      final player = PlayerState(
        prefs: AppPrefs.inMemory(),
        transport: TransportController(
          player: AudioPlayer(FakeAudioDriver()),
          recent: const _NullRecent(),
          toasts: const _SilentToasts(),
          playlist: Playlist.fromTracks([track]),
        ),
      );
      final page = LyricsPageController();
      final theme = ThemeState.unloaded();
      // delay 注入一个永不完成的 Future：attach 会排 4s 慢提示 Timer，
      // 而 testWidgets 收尾要求「没有 pending Timer」（既有 lyrics_page 用例
      // 的同一套手法）。
      Future<void> neverFire(Duration _) => Completer<void>().future;
      final lyrics = LyricsState(source: _NoMatch(), delay: neverFire);
      final bilingual = BilingualState(lyrics: lyrics, source: _NoTranslation());
      lyrics.attach(track);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerState>.value(value: player),
            ChangeNotifierProvider<LyricsPageController>.value(value: page),
            ChangeNotifierProvider<ThemeState>.value(value: theme),
            ChangeNotifierProvider<LyricsState>.value(value: lyrics),
            ChangeNotifierProvider<BilingualState>.value(value: bilingual),
          ],
          child: MaterialApp(
            theme: buildTheme().copyWith(
              extensions: const [AppTokensData(tokens: AppTokens.dark)],
            ),
            home: const Scaffold(body: LyricsPage()),
          ),
        ),
      );
      await tester.pump();

      // 封面节点存在。
      expect(find.byKey(const Key('lyrics-page-cover')), findsOneWidget);
      // **不再是黑胶碟面**：CoverDisc 会带一整套 vinyl 部件（碟面 / 标签 /
      // 反光），歌词页不该有它们。
      expect(find.byKey(const Key('vinyl-label')), findsNothing);
      expect(find.byType(CoverDisc), findsNothing);
      expect(tester.takeException(), isNull);

      addTearDown(player.dispose);
      addTearDown(page.dispose);
      addTearDown(theme.dispose);
      addTearDown(lyrics.dispose);
      addTearDown(bilingual.dispose);
    });
  });

  group('桌面控制条：歌词页时补列表入口', () {
    testWidgets('歌词页开着 → 有「播放列表」按钮；关掉 → 没有', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 400);
      addTearDown(tester.view.reset);

      final player = PlayerState(
        prefs: AppPrefs.inMemory(),
        transport: TransportController(
          player: AudioPlayer(FakeAudioDriver()),
          recent: const _NullRecent(),
          toasts: const _SilentToasts(),
          playlist: Playlist(),
        ),
      );
      final page = LyricsPageController();
      final theme = ThemeState.unloaded();

      Widget app() => MultiProvider(
            providers: [
              ChangeNotifierProvider<PlayerState>.value(value: player),
              ChangeNotifierProvider<LyricsPageController>.value(value: page),
              ChangeNotifierProvider<ThemeState>.value(value: theme),
            ],
            child: MaterialApp(
              theme: buildTheme().copyWith(
                extensions: const [AppTokensData(tokens: AppTokens.dark)],
              ),
              home: const Scaffold(body: TransportBar()),
            ),
          );

      await tester.pumpWidget(app());
      await tester.pump();
      expect(
        find.byKey(const Key('btn-queue')),
        findsNothing,
        reason: '桌面平时左栏常驻列表，不重复给入口',
      );

      page.open();
      await tester.pumpWidget(app());
      await tester.pump();
      expect(
        find.byKey(const Key('btn-queue')),
        findsOneWidget,
        reason: '歌词页占掉右栏，要补列表入口（React 同款规则）',
      );
      expect(tester.takeException(), isNull);

      // ≥1280：歌词页左列常驻列表，这颗入口就多余了
      // （`body.is-lyrics-page .controls__queue { display: none }`，app.css:5035-5037）
      tester.view.physicalSize = const Size(1400, 400);
      await tester.pumpWidget(app());
      await tester.pump();
      expect(find.byKey(const Key('btn-queue')), findsNothing);

      addTearDown(player.dispose);
      addTearDown(page.dispose);
      addTearDown(theme.dispose);
    });
  });

  group('抽屉遮罩：取 --scrim，不用底色派生', () {
    test('六套主题的遮罩都等于 token.scrim，浅色是压暗而非白纱', () {
      const all = [
        AppTokens.dark,
        AppTokens.darkPink,
        AppTokens.darkBlue,
        AppTokens.lightMint,
        AppTokens.lightPink,
        AppTokens.lightBlue,
      ];
      for (final tokens in all) {
        expect(
          scrimColor(tokens),
          tokens.scrim,
          reason: '${tokens.name}：遮罩应逐字取 --scrim（app.css:82/:190/:294/:336）',
        );
      }

      // 浅色主题的 `--bg` 近白：用底色派生出来是一层亮纱（RX 实测约 0.9），
      // 而 --scrim 是 rgba(28, 42, 56, 0.3) 的压暗色。亮度差就是「背景被漂白」
      // 与「背景被推远」的差。
      for (final tokens in [AppTokens.lightMint, AppTokens.lightPink, AppTokens.lightBlue]) {
        expect(
          scrimColor(tokens).computeLuminance(),
          lessThan(0.2),
          reason: '${tokens.name}：遮罩必须是暗色，不能是 bg 派生的白纱',
        );
      }
    });

    testWidgets('浅色主题下抽屉真的压了一层暗色遮罩', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme().copyWith(
            extensions: const [AppTokensData(tokens: AppTokens.lightPink)],
          ),
          home: Scaffold(
            body: AppHeader(
              onAddFiles: () async {},
              onAddFolder: () async {},
              onClearPlaylist: () async {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('menu-button')));
      await tester.pumpAndSettle();

      final barriers = tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .where((barrier) => barrier.color != null)
          .toList();
      expect(barriers, isNotEmpty, reason: '抽屉路由必须带遮罩');
      for (final barrier in barriers) {
        expect(
          barrier.color,
          AppTokens.lightPink.scrim,
          reason: '遮罩色应为 --scrim，而不是亮色白纱',
        );
      }
    });
  });
}
