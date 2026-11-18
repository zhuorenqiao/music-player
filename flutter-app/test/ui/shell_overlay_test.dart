// test/ui/shell_overlay_test.dart
//
// 沉浸模式（完整歌词页盖住内容区）的骨架。除了「谁替换谁」，这里还钉住两件事：
//
//   1. **歌词页与控制条必须同在一张卡里**。对译 React `App.tsx:1832-1848` ——
//      `.app__main` 那张卡里是 `{lyricsPage ? <LyricsPage/> : <Stage/>}` 与
//      `<Transport/>`，而 `.player > .lyrics-page / .player > .transport` 一律剥掉
//      自己的卡面（app.css:510-518），所以沉浸模式只有一张卡，卡内没有第二道缝。
//   2. **大屏（≥1280）左列把播放列表放回来**，与右列那张播放卡同住一张融合卡
//      （`body.is-lyrics-page .panel:not(.panel--sheet) { display: flex; grid-area: panel }`，
//      app.css:5003-5018）；1280 以下歌词页独占整宽（app.css:4944-4948）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/fused_card.dart';
import 'package:light_music/ui/player_card.dart';
import 'package:light_music/ui/shell.dart';

Widget harness({Widget? overlay}) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(
    body: HomeLayout(
      header: const SizedBox(key: Key('h'), height: 40),
      stage: const SizedBox(key: Key('s')),
      panel: const SizedBox(key: Key('p')),
      transport: const SizedBox(key: Key('t'), height: 60),
      overlay: overlay,
    ),
  ),
);

void main() {
  testWidgets('大屏（≥1280）：overlay 时左列是播放列表，与播放卡同住一张卡', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.text('歌词页'), findsOneWidget);
    // 曲目区让位，但**列表面板回来了**
    expect(find.byKey(const Key('s')), findsNothing);
    expect(find.byKey(const Key('p')), findsOneWidget);
    expect(find.byKey(const Key('h')), findsOneWidget);
    expect(find.byKey(const Key('t')), findsOneWidget);

    // 只有一张卡（融合卡），列表、歌词页、控制条都在这一张卡里
    expect(find.byType(FusedCard), findsOneWidget);
    expect(find.byType(PlayerCard), findsOneWidget);
    for (final key in const [Key('p'), Key('t')]) {
      expect(
        find.descendant(of: find.byType(FusedCard), matching: find.byKey(key)),
        findsOneWidget,
        reason: '$key 在融合卡内',
      );
    }
    expect(
      find.descendant(of: find.byType(PlayerCard), matching: find.text('歌词页')),
      findsOneWidget,
    );

    // 列表与播放卡之间是一条 1px 竖线（不是两张卡的缝）
    final panel = tester.getRect(find.byKey(const Key('p')));
    final divider = tester.getRect(find.byKey(const Key('fused-divider-line')));
    final overlay = tester.getRect(find.text('歌词页'));
    expect(divider.width, closeTo(1, 0.5));
    expect(divider.left, closeTo(panel.right, 0.5));
    expect(overlay.left, greaterThanOrEqualTo(divider.right));
    // 列宽 `clamp(300px, 26vw, 400px)`：1440 × 0.26 = 374.4
    expect(panel.width, closeTo(374.4, 0.6));
    // 面板顶到底与播放卡同高（`align-self: stretch`）
    expect(panel.height, greaterThan(0));
  });

  testWidgets('1280 以下（中等屏）：overlay 独占整宽，列表不出现', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.text('歌词页'), findsOneWidget);
    expect(find.byKey(const Key('s')), findsNothing);
    // app.css:4944-4948：歌词页把非弹层的面板让位（1280 起才放回来）
    expect(find.byKey(const Key('p')), findsNothing);
    expect(find.byKey(const Key('fused-divider')), findsNothing);
    expect(find.byType(FusedCard), findsOneWidget);
  });

  testWidgets('桌面：overlay 替换两列，transport 仍在同一张卡里', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.text('歌词页'), findsOneWidget);
    expect(find.byKey(const Key('s')), findsNothing);
    expect(find.byKey(const Key('p')), findsNothing);
    expect(find.byKey(const Key('h')), findsOneWidget);
    expect(find.byKey(const Key('t')), findsOneWidget);

    // 只有一张卡（融合卡），歌词页与控制条都在这张卡里
    expect(find.byType(FusedCard), findsOneWidget);
    expect(find.byType(PlayerCard), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PlayerCard),
        matching: find.text('歌词页'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(PlayerCard),
        matching: find.byKey(const Key('t')),
      ),
      findsOneWidget,
    );

    // 卡内上下相接：中间没有缝（旧的「两张卡 + 18px gap」在这里会露馅）
    final overlayRect = tester.getRect(find.text('歌词页'));
    final transportRect = tester.getRect(find.byKey(const Key('t')));
    expect(transportRect.top, moreOrLessEquals(overlayRect.bottom, epsilon: 0.5));
  });

  testWidgets('窄屏：overlay 替换 stage + panel，transport 仍在同一张卡里', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.byKey(const Key('s')), findsNothing);
    expect(find.byKey(const Key('p')), findsNothing);
    expect(find.byKey(const Key('t')), findsOneWidget);

    // 窄屏没有融合卡，那张 `.player` 卡就是唯一的卡
    expect(find.byType(FusedCard), findsNothing);
    expect(find.byType(PlayerCard), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PlayerCard),
        matching: find.byKey(const Key('t')),
      ),
      findsOneWidget,
    );
    final overlayRect = tester.getRect(find.text('歌词页'));
    final transportRect = tester.getRect(find.byKey(const Key('t')));
    expect(transportRect.top, moreOrLessEquals(overlayRect.bottom, epsilon: 0.5));
  });

  testWidgets('没有 overlay 时结构不变', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(find.byKey(const Key('s')), findsOneWidget);
    expect(find.byKey(const Key('p')), findsOneWidget);
    expect(find.byType(FusedCard), findsOneWidget);
  });
}
