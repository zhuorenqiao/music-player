import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/audio_driver.dart' show FakeAudioDriver;
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/lyrics_page.dart';
import 'package:provider/provider.dart';

class _Matcher implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async =>
      const LyricsMatch(status: 'ok', synced: '[00:01]Hello\n[00:05]Darkness', plain: '');
}

class _Fetcher implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title, required String artist, required double duration,
    CancelToken? cancel, bool useCache = true,
  }) async => const TranslationResult(
    status: 'ok',
    translatedLyrics: '[00:01]你好\n[00:05]黑暗',
    originalLyrics: '[00:01]Hello\n[00:05]Darkness',
  );
}

class _NotFoundMatcher implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async =>
      const LyricsMatch(status: 'not-found');
}

class _NoRecent implements RecentRecorder {
  const _NoRecent();
  @override
  void record(Track track, {DateTime? at}) {}
}

class _NoToasts implements ToastSink {
  const _NoToasts();
  @override
  void show(String message, {String key = '', int durationMs = 3200}) {}
  @override
  void info(String message) {}
  @override
  void error(String message, {int durationMs = 3200}) {}
}

/// `LyricsPage` 真正消费 `LyricsView(full)`，而它订阅 `PlayerState`（进度）。
/// 所以 harness 必须同时提供三个 provider —— brief 的骨架只给了两个，
/// 少了 `PlayerState` 会在 pump 时直接 Provider 抛错。
Widget harness({
  required LyricsState lyrics,
  required BilingualState bilingual,
  required PlayerState player,
  required Widget child,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<LyricsState>.value(value: lyrics),
    ChangeNotifierProvider<BilingualState>.value(value: bilingual),
    ChangeNotifierProvider<PlayerState>.value(value: player),
  ],
  child: MaterialApp(
    theme: buildTheme().copyWith(extensions: const [AppTokensData(tokens: AppTokens.dark)]),
    home: Scaffold(body: child),
  ),
);

PlayerState makePlayer() {
  final transport = TransportController(
    player: AudioPlayer(FakeAudioDriver()),
    recent: const _NoRecent(),
    toasts: const _NoToasts(),
    playlist: Playlist.fromTracks(const <Track>[]),
  );
  return PlayerState(prefs: AppPrefs.inMemory(), transport: transport);
}

/// 桌面视口（1280×900）：brief 骨架的两条用例（「头部」「空态」）都断言了
/// `lyrics-page-cover` 存在，说明它们的前提是桌面档 —— 而 flutter_test 默认视口是
/// 800×600，`isDesktop(800)` 为 false，会走窄屏分支（封面按规格藏掉）。
/// 所以这里按用例自己的意图显式设桌面视口。
void useDesktopViewport(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
}

void main() {
  late LyricsState lyrics;
  late BilingualState bilingual;
  late PlayerState player;

  /// 状态机注入一个**永不到点**的延时：T13 的慢提示 / 自动重试都是
  /// `Future.delayed`，在 widget 测试的 fake-async 里会留下一个 pending Timer，
  /// 用例结束时报「A Timer is still pending」。这里让它们永远挂着（也不真等），
  /// 本文件也不关心那两档文案 —— 真要验它们的是 T13 自己的用例。
  Future<void> neverFire(Duration _) => Completer<void>().future;

  void useLyrics(LyricsMatcher source) {
    lyrics = LyricsState(source: source, delay: neverFire);
    bilingual = BilingualState(lyrics: lyrics, source: _Fetcher());
  }

  setUp(() {
    useLyrics(_Matcher());
    player = makePlayer();
  });

  tearDown(() {
    player.dispose();
    bilingual.dispose();
    lyrics.dispose();
  });

  testWidgets('头部：返回、歌名、双语开关；正文有歌词行', (tester) async {
    useDesktopViewport(tester);
    lyrics.attach(Track(
      id: 't', src: '/m/t.flac', title: 'Yesterday', artist: 'The Beatles', album: 'Help!',
      duration: 125, isLocal: true,
    ));
    await bilingual.settle();

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('返回'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('The Beatles · Help!'), findsOneWidget);
    expect(find.byKey(const Key('bilingual-toggle')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(find.byKey(const Key('lyrics-page-cover')), findsOneWidget);
  });

  testWidgets('窄屏隐藏封面', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 900);
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lyrics-page-cover')), findsNothing);
  });

  testWidgets('没有歌词时显示状态块与重试', (tester) async {
    useDesktopViewport(tester);
    lyrics.dispose();
    bilingual.dispose();
    useLyrics(_NotFoundMatcher());
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('未找到「A」的歌词'), findsOneWidget);
    expect(find.byKey(const Key('lyrics-retry')), findsOneWidget);
  });
}
