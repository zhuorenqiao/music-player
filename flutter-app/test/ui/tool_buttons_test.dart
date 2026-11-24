// test/ui/tool_buttons_test.dart
//
// 三颗工具按钮（「T」歌词高亮色 / 水滴 卡面毛玻璃 / 闹钟 睡眠定时器）的位置：
// 简约与沉浸模式都排在控制条里、音谱条上方，面板统一向上弹。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/playback/playlist.dart';
import 'package:light_music/state/lyrics_page_controller.dart';
import 'package:light_music/state/player_state.dart';
import 'package:light_music/state/sleep_timer_state.dart';
import 'package:light_music/state/toast_state.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/glass_control.dart';
import 'package:light_music/ui/sleep_timer_button.dart';
import 'package:light_music/ui/tool_panel.dart';
import 'package:light_music/ui/transport.dart';
import 'package:light_music/ui/wave_strip.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

/// 三颗按钮的读屏名（生产代码里的 Semantics label）。
///
/// 「T」那颗用**正则**：Flutter 会把外层 `Semantics(label:)` 与子 `Text('T')`
/// 合成一个节点，标签变成 "歌词高亮颜色\nT"，字符串精确匹配就找不到了。
final RegExp kTLabel = RegExp('歌词高亮颜色');
const String kGlassLabel = '卡面透明度与毛玻璃';
const String kSleepLabel = '睡眠定时器';

/// 控制条贴底摆好，视口按逻辑像素。
Future<void> pumpTransport(
  WidgetTester tester,
  Widget child, {
  required List<SingleChildWidget> providers,
  double width = 1200,
  double height = 900,
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
    MultiProvider(providers: providers, child: app),
  );
  await tester.pump();
}

void main() {
  Future<({PlayerState player, SleepTimerState sleep, ThemeState theme, LyricsPageController page})>
  setup({bool immersive = true}) async {
    final player = PlayerState.fake(Playlist());
    addTearDown(player.dispose);
    final toasts = ToastState();
    addTearDown(toasts.dispose);
    final sleep = SleepTimerState(
      prefs: AppPrefs.inMemory(),
      player: player,
      toasts: toasts,
    );
    addTearDown(sleep.dispose);
    final theme = await ThemeState.load(AppPrefs.inMemory());
    addTearDown(theme.dispose);
    final page = LyricsPageController();
    if (immersive) page.open();
    addTearDown(page.dispose);
    return (player: player, sleep: sleep, theme: theme, page: page);
  }

  List<SingleChildWidget> providersFor(
    ({PlayerState player, SleepTimerState sleep, ThemeState theme, LyricsPageController page}) state,
  ) => <SingleChildWidget>[
    ChangeNotifierProvider<PlayerState>.value(value: state.player),
    ChangeNotifierProvider<SleepTimerState>.value(value: state.sleep),
    ChangeNotifierProvider<ThemeState>.value(value: state.theme),
    ChangeNotifierProvider<LyricsPageController>.value(value: state.page),
  ];

  group('沉浸模式（控制条）', () {
    testWidgets('三颗按钮在音谱条上方，尺寸 26×26', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final state = await setup();
        await pumpTransport(
          tester,
          const TransportBar(),
          providers: providersFor(state),
        );

        expect(find.bySemanticsLabel(kTLabel), findsOneWidget);
        expect(find.bySemanticsLabel(kGlassLabel), findsOneWidget);
        expect(find.bySemanticsLabel(kSleepLabel), findsOneWidget);

        final t = tester.getRect(find.bySemanticsLabel(kTLabel));
        final glass = tester.getRect(find.bySemanticsLabel(kGlassLabel));
        final sleep = tester.getRect(find.bySemanticsLabel(kSleepLabel));
        final wave = tester.getRect(find.byType(WaveStrip));

        expect(glass.left, greaterThan(t.right));
        expect(sleep.left, greaterThan(glass.right));
        expect(sleep.bottom, lessThan(wave.top), reason: '整组在音谱条上方');
        for (final rect in [t, glass, sleep]) {
          expect(rect.width, closeTo(26, 0.01));
          expect(rect.height, closeTo(26, 0.01));
          expect(rect.top, closeTo(t.top, 0.01));
        }
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('只留图标：无描边 / 无底色 / 无圆角，图标居中', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final state = await setup();
        await pumpTransport(
          tester,
          const TransportBar(),
          providers: providersFor(state),
        );

        final glass = tester.getRect(find.bySemanticsLabel(kGlassLabel));
        final sleep = tester.getRect(find.bySemanticsLabel(kSleepLabel));

        void expectIconCentered(Rect trigger, Icon icon, String name) {
          final rect = tester.getRect(find.byWidget(icon));
          expect(rect.center.dx, closeTo(trigger.center.dx, 0.6), reason: '$name 水平居中');
          expect(rect.center.dy, closeTo(trigger.center.dy, 0.6), reason: '$name 垂直居中');
          expect(icon.size, 17, reason: '$name 图标 17×17');
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

        final chromes = find.byType(ToolTriggerChrome);
        expect(chromes, findsNWidgets(3));
        final boxes = tester.widgetList<Container>(
          find.descendant(of: chromes, matching: find.byType(Container)),
        ).toList();
        expect(boxes, hasLength(3));
        for (final box in boxes) {
          expect(box.decoration, isNull, reason: '只留图标：没有描边 / 底色 / 圆角');
          expect(box.constraints!.maxWidth, 26);
          expect(box.constraints!.maxHeight, 26);
        }

        final letter = tester.widget<Text>(find.text('T'));
        expect(letter.style!.fontSize, 15);
        expect(letter.style!.fontWeight, FontWeight.w700);
        expect(letter.style!.color, AppTokens.dark.accentLight);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('色板向按钮上方展开', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final state = await setup();
        await pumpTransport(
          tester,
          const TransportBar(),
          providers: providersFor(state),
        );

        final trigger = tester.getRect(find.bySemanticsLabel(kTLabel));
        await tester.tap(find.bySemanticsLabel(kTLabel));
        await tester.pump();

        final swatch = tester.getRect(find.bySemanticsLabel('薄荷（默认）').first);
        expect(swatch.bottom, lessThan(trigger.top), reason: '面板在按钮上方');
        expect(swatch.left, greaterThanOrEqualTo(8));
        expect(swatch.right, lessThanOrEqualTo(1192));
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
        final state = await setup(immersive: false);
        await pumpTransport(
          tester,
          const TransportBar(),
          providers: providersFor(state),
        );

        expect(find.bySemanticsLabel(kTLabel), findsOneWidget);
        expect(find.bySemanticsLabel(kGlassLabel), findsOneWidget);
        final t = tester.getRect(find.bySemanticsLabel(kTLabel));
        final glass = tester.getRect(find.bySemanticsLabel(kGlassLabel));
        expect(glass.left, greaterThan(t.right));
        expect(t.left, lessThan(120), reason: '贴着控制条左端');
        expect(find.byType(WaveStrip), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('歌词页开着时三颗按钮仍在，并与频谱同框', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final state = await setup();
        await pumpTransport(
          tester,
          const TransportBar(),
          providers: providersFor(state),
        );

        expect(find.bySemanticsLabel(kTLabel), findsOneWidget);
        expect(find.bySemanticsLabel(kGlassLabel), findsOneWidget);
        expect(find.byType(WaveStrip), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  });
}