// test/ui/tool_buttons_test.dart
//
// 三颗工具按钮（「T」歌词高亮色 / 水滴 卡面毛玻璃 / 闹钟 睡眠定时器）的**位置**：
//
//   * 沉浸模式（完整歌词页）：整组在歌词页页头 —— 歌名右边、波形样式下拉左边；
//     面板随之改**向下**弹（上面是屏幕顶，向上弹会出界）。
//   * 简约模式（封面页）：整组留在控制条左端，面板**向上**弹。
//
// 与 React 版的对应改动：`src/App.tsx` 的 `ToolButtons`（:997-1005）与
// `src/styles/app.css` 的 `.lyric-tools--head`（:2353-2374）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/audio_driver.dart' show FakeAudioDriver;
import 'package:light_music/playback/audio_player.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/playback/transport_controller.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_page_controller.dart';
import 'package:light_music/state/lyrics_state.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/sleep_timer_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/glass_control.dart';
import 'package:light_music/ui/lyrics_page.dart';
import 'package:light_music/ui/sleep_timer_button.dart';
import 'package:light_music/ui/tool_panel.dart';
import 'package:light_music/ui/transport.dart';
import 'package:light_music/ui/wave_strip.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

/// 三颗按钮的读屏名（生产代码里的 Semantics label）。
///
/// 「T」那颗用**正则**：Flutter 会把外层 `Semantics(label:)` 与子 `Text('T')`
/// 合成一个节点，标签变成 "歌词高亮颜色\nT"，字符串精确匹配就找不到了
/// （框架文档在 `bySemanticsLabel` 上专门提醒过这件事）。
final RegExp kTLabel = RegExp('歌词高亮颜色');
const String kGlassLabel = '卡面透明度与毛玻璃';
const String kSleepLabel = '睡眠定时器';

class _Matcher implements LyricsMatcher {
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async =>
      const LyricsMatch(status: 'ok', synced: '[00:01]Hello', plain: '');
}

class _Fetcher implements TranslationFetcher {
  @override
  Future<TranslationResult> fetch({
    required String title, required String artist, required double duration,
    CancelToken? cancel, bool useCache = true,
  }) async => const TranslationResult(status: 'ok');
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

/// 歌词页的装配：状态层 + 内存 prefs + 假播放内核。
class _Harness {
  _Harness() {
    prefs = AppPrefs.inMemory();
    final transport = TransportController(
      player: AudioPlayer(FakeAudioDriver()),
      recent: const _NoRecent(),
      toasts: const _NoToasts(),
      playlist: Playlist.fromTracks(const <Track>[]),
    );
    player = PlayerState(prefs: prefs, transport: transport);
    // LyricsState 的延时钩子给一个**永不到点**的 Future：widget 测试的
    // fake-async 里 pending Timer 会让用例报错，而这里不关心歌词内容。
    lyrics = LyricsState(source: _Matcher(), delay: (_) => Completer<void>().future);
    bilingual = BilingualState(lyrics: lyrics, source: _Fetcher());
    sleepTimer = SleepTimerState(
      prefs: prefs,
      player: player,
      toasts: ToastState(),
    );
  }

  late final AppPrefs prefs;
  late final PlayerState player;
  late final LyricsState lyrics;
  late final BilingualState bilingual;
  late final SleepTimerState sleepTimer;

  void dispose() {
    sleepTimer.dispose();
    bilingual.dispose();
    lyrics.dispose();
    player.dispose();
  }
}

/// 摆出歌词页（桌面视口 1280×900）。
///
/// provider 放在 MaterialApp **外面** —— 面板插进 Overlay，而 Overlay 在
/// Navigator 里、比 Scaffold 高。
Future<void> pumpLyricsPage(WidgetTester tester, _Harness harness) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);

  harness.lyrics.attach(Track(
    id: 't', src: '/m/t.flac', title: 'Yesterday', artist: 'The Beatles',
    album: 'Help!', duration: 125, isLocal: true,
  ));
  await harness.bilingual.settle();

  final theme = await ThemeState.load(harness.prefs);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LyricsState>.value(value: harness.lyrics),
        ChangeNotifierProvider<BilingualState>.value(value: harness.bilingual),
        ChangeNotifierProvider<PlayerState>.value(value: harness.player),
        ChangeNotifierProvider<SleepTimerState>.value(value: harness.sleepTimer),
        ChangeNotifierProvider<ThemeState>.value(value: theme),
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
}

/// 控制条贴底摆好，视口按逻辑像素。
Future<void> pumpTransport(
  WidgetTester tester,
  Widget child, {
  required List<SingleChildWidget> providers,
  double width = 1200,
  double height = 320,
}) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  final Widget app = MaterialApp(
    theme: buildTheme().copyWith(
      extensions: const [AppTokensData(tokens: AppTokens.dark)],
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
  await tester.pumpWidget(
    providers.isEmpty ? app : MultiProvider(providers: providers, child: app),
  );
  await tester.pump();
}

void main() {
  group('沉浸模式（歌词页）', () {
    testWidgets('三颗按钮在页头：歌名右侧、波形下拉左侧', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      // 语义句柄必须在用例体**内**销毁（框架在用例结束时会检查）。
      final semantics = tester.ensureSemantics();
      try {
        await pumpLyricsPage(tester, harness);

        expect(find.bySemanticsLabel(kTLabel), findsOneWidget);
        expect(find.bySemanticsLabel(kGlassLabel), findsOneWidget);
        expect(find.bySemanticsLabel(kSleepLabel), findsOneWidget);

        final title = tester.getRect(find.text('Yesterday'));
        final t = tester.getRect(find.bySemanticsLabel(kTLabel));
        final glass = tester.getRect(find.bySemanticsLabel(kGlassLabel));
        final sleep = tester.getRect(find.bySemanticsLabel(kSleepLabel));
        final picker = tester.getRect(find.byKey(const Key('wave-style-trigger')));

        // 顺序：歌名 → T → 水滴 → 闹钟 → 波形下拉
        expect(t.left, greaterThan(title.right), reason: '「T」在歌名右边');
        expect(glass.left, greaterThan(t.right), reason: '水滴在「T」右边');
        expect(sleep.left, greaterThan(glass.right), reason: '闹钟在水滴右边');
        expect(sleep.right, lessThan(picker.left), reason: '闹钟在下拉左边');
        // 三颗都在页头那条上（离顶部很近）
        expect(t.top, lessThan(80));
        expect(t.width, 26);
        expect(t.height, 26);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('三颗按钮是同一套壳：26×26、圆角 8、同色描边、图标居中', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final semantics = tester.ensureSemantics();
      try {
        await pumpLyricsPage(tester, harness);

        final t = tester.getRect(find.bySemanticsLabel(kTLabel));
        final glass = tester.getRect(find.bySemanticsLabel(kGlassLabel));
        final sleep = tester.getRect(find.bySemanticsLabel(kSleepLabel));

        // 三颗同尺寸、同一水平线（CSS 三处选择器逐字都是 26×26）。
        for (final r in [t, glass, sleep]) {
          expect(r.width, closeTo(26, 0.01), reason: '三颗都是 26 宽');
          expect(r.height, closeTo(26, 0.01), reason: '三颗都是 26 高');
          expect(r.top, closeTo(t.top, 0.01), reason: '三颗在页头同一条线上');
        }

        // 图标在这 26×26 的正中间 —— 闹钟那颗之前被 `Row(mainAxisSize: min)`
        // 在紧约束里靠 start 排，图标直接贴在左边框上（用户截图圈的就是这里）。
        void expectIconCentered(Rect trigger, Icon icon, String name) {
          final rect = tester.getRect(find.byWidget(icon));
          expect(rect.center.dx, closeTo(trigger.center.dx, 0.6), reason: '$name 水平居中');
          expect(rect.center.dy, closeTo(trigger.center.dy, 0.6), reason: '$name 垂直居中');
          expect(icon.size, 14, reason: '$name 图标 14×14（CSS `.glass-control__icon`）');
        }

        final glassIcon = tester.widget<Icon>(find.descendant(
          of: find.byType(GlassControl),
          matching: find.byType(Icon),
        ));
        expectIconCentered(glass, glassIcon, '水滴');
        final sleepIcon = tester.widget<Icon>(find.descendant(
          of: find.byType(SleepTimerButton),
          matching: find.byType(Icon),
        ));
        expectIconCentered(sleep, sleepIcon, '闹钟');

        // 三颗都用同一个外壳组件，未展开时的描边 / 底色 / 圆角必须一模一样。
        final chromes = find.byType(ToolTriggerChrome);
        expect(chromes, findsNWidgets(3));
        final boxes = tester.widgetList<Container>(
          find.descendant(of: chromes, matching: find.byType(Container)),
        ).toList();
        expect(boxes, hasLength(3));
        final tokens = AppTokens.dark;
        for (final box in boxes) {
          final decoration = box.decoration! as BoxDecoration;
          expect(decoration.color, tokens.surface, reason: '未展开时底色 --surface');
          expect(decoration.borderRadius, BorderRadius.circular(8));
          final border = decoration.border! as Border;
          expect(border.top.color, tokens.borderStrong, reason: '1px --border-strong');
          expect(border.top.width, closeTo(1, 0.001));
          expect(box.constraints!.maxWidth, 26);
          expect(box.constraints!.maxHeight, 26);
        }

        // 「T」这个字母是 13px/700、颜色 = 当前歌词高亮色（默认跟随 accent-light）。
        final letter = tester.widget<Text>(find.text('T'));
        expect(letter.style!.fontSize, 13);
        expect(letter.style!.fontWeight, FontWeight.w700);
        expect(letter.style!.color, tokens.accentLight);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('色板在按钮**下方**展开（页头位置向上弹会出界）', (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final semantics = tester.ensureSemantics();
      try {
        await pumpLyricsPage(tester, harness);

        final trigger = tester.getRect(find.bySemanticsLabel(kTLabel));
        await tester.tap(find.bySemanticsLabel(kTLabel));
        await tester.pump();

        // 色板的第一颗（薄荷）就是面板的左上角附近
        final swatch = tester.getRect(find.bySemanticsLabel('薄荷（默认）').first);
        expect(swatch.top, greaterThan(trigger.bottom), reason: '面板在按钮下方');
        expect(swatch.left, greaterThanOrEqualTo(8));
        expect(swatch.right, lessThanOrEqualTo(1280 - 8));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  });

  group('简约模式（控制条）', () {
    testWidgets('三颗按钮留在控制条左端', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final player = PlayerState.fake(Playlist());
        addTearDown(player.dispose);

        await pumpTransport(
          tester,
          const TransportBar(),
          providers: [ChangeNotifierProvider<PlayerState>.value(value: player)],
        );

        expect(find.bySemanticsLabel(kTLabel), findsOneWidget);
        expect(find.bySemanticsLabel(kGlassLabel), findsOneWidget);
        // 控制条上那行：按钮在左端
        final t = tester.getRect(find.bySemanticsLabel(kTLabel));
        final glass = tester.getRect(find.bySemanticsLabel(kGlassLabel));
        expect(glass.left, greaterThan(t.right));
        expect(t.left, lessThan(120), reason: '贴着控制条左端');
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('歌词页开着（沉浸模式）：控制条那行只剩频谱', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final player = PlayerState.fake(Playlist());
        addTearDown(player.dispose);
        final page = LyricsPageController()..open();
        // 频谱条要读 ThemeState（强调色 / 歌词色）。
        final theme = await ThemeState.load(AppPrefs.inMemory());

        await pumpTransport(
          tester,
          const TransportBar(),
          providers: [
            ChangeNotifierProvider<PlayerState>.value(value: player),
            ChangeNotifierProvider<LyricsPageController>.value(value: page),
            ChangeNotifierProvider<ThemeState>.value(value: theme),
          ],
        );

        // 三颗按钮已经搬到歌词页页头了
        expect(find.bySemanticsLabel(kTLabel), findsNothing);
        expect(find.bySemanticsLabel(kGlassLabel), findsNothing);
        expect(find.byType(WaveStrip), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  });
}
