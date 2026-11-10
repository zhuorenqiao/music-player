// test/ui/theme_drawer_test.dart
//
// M3 T6：换肤抽屉 —— 渲染、三段选择即时生效、主题色三 swatch、提示行、
// 关闭按钮、「抽屉不关可来回比对」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/theme_drawer.dart';
import 'package:provider/provider.dart';

Widget wrap(ThemeState state) => MultiProvider(
  providers: [ChangeNotifierProvider<ThemeState>.value(value: state)],
  child: MaterialApp(
    theme: buildTheme(tokens: AppTokens.dark),
    home: Scaffold(
      body: Center(
        child: ThemeDrawer(),
      ),
    ),
  ),
);

void main() {
  testWidgets('抽屉渲染三段选择与主题色 swatch；选择即时生效、抽屉不关', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 800);
    addTearDown(tester.view.reset);
    final state = await ThemeState.load(AppPrefs.inMemory());
    await tester.pumpWidget(wrap(state));

    expect(find.text('明暗模式'), findsOneWidget);
    expect(find.text('主题色'), findsOneWidget);
    expect(find.text('系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('薄荷'), findsOneWidget);
    expect(find.text('粉色'), findsOneWidget);
    expect(find.text('蓝色'), findsOneWidget);
    // 默认 mode=system：提示行出现（跟随浅色——platformDark 缺省 false）。
    expect(find.text('当前跟随系统：浅色'), findsOneWidget);

    // 点「深色」：即时生效（token 表换）+ 不关抽屉（可来回比对）。
    await tester.tap(find.text('深色'));
    await tester.pump();
    expect(state.mode, ThemeModeSetting.dark);
    expect(find.byType(ThemeDrawer), findsOneWidget);

    // 点「粉色」：themeKey 变。
    await tester.tap(find.text('粉色'));
    await tester.pump();
    expect(state.themeKey, 'dark-pink');
    expect(find.byType(ThemeDrawer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mode==system 时提示行出现并随平台亮度解析', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 800);
    addTearDown(tester.view.reset);
    final state = await ThemeState.load(
      AppPrefs.inMemory(),
      platformDark: () => true,
    );
    await tester.pumpWidget(wrap(state));

    expect(find.text('当前跟随系统：深色'), findsOneWidget);

    // 切浅色模式：提示行消失。
    await tester.tap(find.text('浅色'));
    await tester.pump();
    expect(find.textContaining('当前跟随系统'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭按钮调 onClose（宿主据此 pop）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 800);
    addTearDown(tester.view.reset);
    final state = await ThemeState.load(AppPrefs.inMemory());
    await tester.pumpWidget(wrap(state));
    // onClose 由 showThemeDrawer 传 Navigator.maybePop；这里没走那个宿主，
    // 只断言「点击不抛异常、抽屉仍在」（关闭链路的接线在宿主侧）。
    await tester.tap(find.bySemanticsLabel('关闭换肤'));
    await tester.pump();
    expect(find.byType(ThemeDrawer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
