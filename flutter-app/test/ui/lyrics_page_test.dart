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
import 'package:light_music/state/lyrics_page_controller.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/lyrics_page.dart';
import 'package:light_music/ui/tool_buttons.dart';
import 'package:light_music/ui/wave_style_picker.dart';
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
  LyricsPageController? page,
  required Widget child,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<LyricsState>.value(value: lyrics),
    ChangeNotifierProvider<BilingualState>.value(value: bilingual),
    ChangeNotifierProvider<PlayerState>.value(value: player),
    // 歌词页开合：不传就是纯展示（旧用例一律不传，行为不变）。
    if (page != null)
      ChangeNotifierProvider<LyricsPageController>.value(value: page),
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

  testWidgets('头部：歌名、双语开关、三颗工具按钮；正文有歌词行', (tester) async {
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

    // 原版头部只有「歌名块 + 三颗工具按钮 + 波形下拉」，没有「返回」胶囊
    // （退出走 Esc / L，见 lib/ui/lyrics_page.dart 文件头）。这条断言把
    // 「别再把返回按钮加回来」钉住。
    expect(find.text('返回'), findsNothing);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('The Beatles · Help!'), findsOneWidget);
    expect(find.byKey(const Key('bilingual-toggle')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(find.byKey(const Key('lyrics-page-cover')), findsOneWidget);
  });

  testWidgets('大屏（≥1280）歌词页两列放宽：封面 clamp(280, 24vw, 400)', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();
    final cover = tester.getRect(find.byKey(const Key('lyrics-page-cover')));
    // app.css:5045-5048：≥1280 换 `clamp(280px, 24vw, 400px)`，1400×0.24 = 336
    expect(cover.width, closeTo(336, 0.6));

    // ≥1680 再抬一档：`clamp(360px, 25vw, 480px)`，1700×0.25 = 425
    tester.view.physicalSize = const Size(1700, 900);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const Key('lyrics-page-cover'))).width,
      closeTo(425, 0.6),
    );
  });

  testWidgets('窄屏隐藏封面', (tester) async {    addTearDown(tester.view.reset);
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

  testWidgets('页面内边距分档：桌面 18/20/6，窄屏 16/16/6', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();

    // 桌面：`.lyrics-page { padding: 18px 20px 6px }`（≥900，app.css:4944-4949）
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpAndSettle();
    // `Padding` 自身的 rect 就是外框，量不到留白；量它里面那层内容列。
    final desktop = tester.getRect(
      find
          .descendant(
            of: find.byKey(const Key('lyrics-page-body')),
            matching: find.byType(Column),
          )
          .first,
    );
    final card = tester.getRect(find.byType(LyricsPage));
    expect(desktop.left - card.left, closeTo(20, 0.6)); // padding 左右 20
    expect(desktop.top - card.top, closeTo(18, 0.6)); // padding 上 18

    // 窄屏：`padding: 16px 16px 6px`
    tester.view.physicalSize = const Size(700, 900);
    await tester.pumpAndSettle();
    final narrow = tester.getRect(
      find
          .descendant(
            of: find.byKey(const Key('lyrics-page-body')),
            matching: find.byType(Column),
          )
          .first,
    );
    final narrowCard = tester.getRect(find.byType(LyricsPage));
    expect(narrow.left - narrowCard.left, closeTo(16, 0.6));
    expect(narrow.top - narrowCard.top, closeTo(16, 0.6));
  });

  testWidgets('小屏：点正文空白切回简约模式；点歌词行仍定位、不退出', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    // 手机档（<900）：热区只在这一档存在
    tester.view.physicalSize = const Size(430, 900);
    lyrics.attach(Track(
      id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true,
    ));
    await bilingual.settle();
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, page: page,
      child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lyrics-tap-to-simple')), findsOneWidget);

    // 点歌词行：里层那颗「定位播放」的识别器先入先赢，页面不退出
    await tester.tap(find.text('Hello'));
    await tester.pumpAndSettle();
    expect(page.isOpen, isTrue, reason: '点歌词文字仍是定位，不该切回简约模式');

    // 点正文底部留白（最后一行歌词之下）：切回简约模式
    final zone = tester.getRect(find.byKey(const Key('lyrics-tap-to-simple')));
    await tester.tapAt(Offset(zone.left + 4, zone.bottom - 4));
    await tester.pumpAndSettle();
    expect(page.isOpen, isFalse, reason: '点空白应切回简约模式');
  });

  testWidgets('小屏：点歌名那条带（页头）也能切回简约模式', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    lyrics.attach(Track(
      id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true,
    ));
    await bilingual.settle();
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, page: page,
      child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();

    // 热区包住整页（含页头）：从前只包正文，点歌名那一带没反应
    await tester.tap(find.text('A').first);
    await tester.pumpAndSettle();
    expect(page.isOpen, isFalse, reason: '点歌名那一带也应切回简约模式');
  });

  testWidgets('桌面（≥900）不做这个热区（有 Esc / L，避免鼠标误点留白退出）', (tester) async {
    useDesktopViewport(tester);
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, page: page,
      child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lyrics-tap-to-simple')), findsNothing);
  });

  testWidgets('窄屏页头不再挂「T/水滴/闹钟」与波形下拉（它们下移到控制条）', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, page: page,
      child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();

    // 页头只剩歌名 + 艺人（见 transport.dart 的 `_WaveRow`：窄屏那组搬到频谱上方）
    expect(find.byType(ToolButtons), findsNothing);
    expect(find.byType(WaveStylePicker), findsNothing);
  });

  testWidgets('桌面（≥900）页头仍带那三颗按钮与波形下拉', (tester) async {
    useDesktopViewport(tester);
    lyrics.attach(Track(id: 't', src: '/m/t.flac', title: 'A', artist: 'B', duration: 60, isLocal: true));
    await bilingual.settle();
    final page = LyricsPageController()..open();
    addTearDown(page.dispose);

    await tester.pumpWidget(harness(
      lyrics: lyrics, bilingual: bilingual, player: player, page: page,
      child: const LyricsPage(),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ToolButtons), findsOneWidget);
    expect(find.byType(WaveStylePicker), findsOneWidget);
  });
}
