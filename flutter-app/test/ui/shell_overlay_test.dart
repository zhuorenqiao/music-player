import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
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
  testWidgets('桌面：overlay 替换两列，transport 仍在', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.text('歌词页'), findsOneWidget);
    expect(find.byKey(const Key('s')), findsNothing);
    expect(find.byKey(const Key('p')), findsNothing);
    expect(find.byKey(const Key('h')), findsOneWidget);
    expect(find.byKey(const Key('t')), findsOneWidget);
  });

  testWidgets('窄屏：overlay 替换 stage + panel，transport 仍在', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpWidget(harness(overlay: const Text('歌词页')));
    await tester.pump();
    expect(find.byKey(const Key('s')), findsNothing);
    expect(find.byKey(const Key('p')), findsNothing);
    expect(find.byKey(const Key('t')), findsOneWidget);
  });

  testWidgets('没有 overlay 时结构不变', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(find.byKey(const Key('s')), findsOneWidget);
    expect(find.byKey(const Key('p')), findsOneWidget);
  });
}
