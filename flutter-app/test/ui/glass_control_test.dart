// test/ui/glass_control_test.dart
//
// M3 T7：玻璃双滑块 —— 面板渲染、滑杆写 ThemeState 并持久化、glassLevel 换算。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/glass_control.dart';
import 'package:light_music/ui/lyric_color_button.dart';
import 'package:provider/provider.dart';

Widget wrap(ThemeState state) => MultiProvider(
  providers: [ChangeNotifierProvider<ThemeState>.value(value: state)],
  child: MaterialApp(
    theme: buildTheme(tokens: AppTokens.dark),
    home: Scaffold(
      body: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [const LyricColorButton(), const SizedBox(width: 8), const GlassControl()],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('水滴按钮打开面板：透明/磨砂两行滑杆与 % 文案', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 600);
    addTearDown(tester.view.reset);
    final state = await ThemeState.load(AppPrefs.inMemory());
    await tester.pumpWidget(wrap(state));

    expect(find.bySemanticsLabel('卡面透明度与毛玻璃'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('卡面透明度与毛玻璃'));
    await tester.pump();

    expect(find.text('透明'), findsOneWidget);
    expect(find.text('磨砂'), findsOneWidget);
    expect(find.text('0%'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖滑杆写 ThemeState 并持久化（50%）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 600);
    addTearDown(tester.view.reset);
    final prefs = AppPrefs.inMemory();
    final state = await ThemeState.load(prefs);
    await tester.pumpWidget(wrap(state));

    await tester.tap(find.bySemanticsLabel('卡面透明度与毛玻璃'));
    await tester.pump();

    // 滑杆是 Material Slider：直接向滑轨中点拖（分度 100，中点 = 50）。
    final track = find.byType(Slider).first;
    final rect = tester.getRect(track);
    await tester.dragFrom(
      rect.centerLeft,
      Offset(rect.width / 2, 0),
    );
    await tester.pumpAndSettle();

    expect(state.transparency, 50, reason: '滑轨中点 ≈ 50（divisions=100）');
    expect(state.glassLevel, closeTo(0.5, 0.001));
    expect(await prefs.readString(StorageKeys.cardTransparency), '50');
    expect(tester.takeException(), isNull);
  });

  test('glassLevel 换算：0→1、100→0、50→0.5', () async {
    final state = await ThemeState.load(AppPrefs.inMemory());
    state.setTransparency(0);
    expect(state.glassLevel, 1.0);
    state.setTransparency(100);
    expect(state.glassLevel, 0.0);
    state.setTransparency(50);
    expect(state.glassLevel, closeTo(0.5, 0.001));
  });
}
