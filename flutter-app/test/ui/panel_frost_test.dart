// test/ui/panel_frost_test.dart
//
// M3 D.6：面板与播放卡共用同一套磨砂膜（`.player::before, .panel::before`，
// app.css:461-477）。frost==0 时零开销、frost>0 时挂 BackdropFilter；
// 弹层版（flush）用自己的 sheet 卡面，不该再挂一层磨砂。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/glass_frost.dart';

import 'panel_harness.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('frost=0：不挂 GlassFrostLayer / BackdropFilter（零开销）', (tester) async {
    final harness = PanelHarness(tall: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(wrap(harness.build()));
    await tester.pump();

    // harness 默认构造的 Panel 没传 frostLevel → 0。
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('frost>0：面板包上 GlassFrostLayer，BackdropFilter 真的挂上', (tester) async {
    final harness = PanelHarness(tall: true);
    addTearDown(harness.dispose);
    // 直接构造带磨砂的 Panel，复用 harness 的全部 provider。
    await tester.pumpWidget(wrap(harness.build(frostLevel: 0.33)));
    await tester.pump();

    expect(find.byType(GlassFrostLayer), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('弹层版（flush）不挂磨砂层', (tester) async {
    final harness = PanelHarness(tall: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(wrap(harness.build(flush: true, frostLevel: 0.5)));
    await tester.pump();

    expect(find.byType(GlassFrostLayer), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
