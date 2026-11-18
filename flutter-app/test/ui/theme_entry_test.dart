// test/ui/theme_entry_test.dart
//
// M3 T6 回归：一级菜单的「换肤」入口必须真的把二级抽屉弹出来。
//
// 这里刻意**逐帧**推进（16ms 一步）而不是 `pumpAndSettle()`：`pumpAndSettle`
// 会把一次 pump 里的时间大步跨过去，计时器与路由拆树的先后顺序和真机不一致，
// 于是「二级抽屉挂在已被 pop 的一级抽屉 context 上」这种竞态在它眼里是过的。
// 真机（尤其 release）是 240ms 收起动画先结束、260ms 计时器后到 —— 逐帧推进
// 复现的正是这个顺序。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/drawer_menu.dart';
import 'package:light_music/ui/header.dart';
import 'package:light_music/ui/theme_drawer.dart';
import 'package:provider/provider.dart';

Future<void> pumpHeader(WidgetTester tester, ThemeState state) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 800);
  await tester.pumpWidget(
    MultiProvider(
      providers: [ChangeNotifierProvider<ThemeState>.value(value: state)],
      child: MaterialApp(
        theme: buildTheme(tokens: AppTokens.dark),
        home: Scaffold(
          body: AppHeader(
            onAddFiles: () async {},
            onAddFolder: () async {},
            onClearPlaylist: () async {},
          ),
        ),
      ),
    ),
  );
}

/// 按 60fps 逐帧推进 [milliseconds] 毫秒。
Future<void> pumpFrames(
  WidgetTester tester,
  int milliseconds, {
  Duration step = const Duration(milliseconds: 16),
}) async {
  var elapsed = 0;
  while (elapsed < milliseconds) {
    await tester.pump(step);
    elapsed += step.inMilliseconds;
  }
}

void main() {
  testWidgets('点一级菜单「换肤」会弹出换肤抽屉（真机帧序）', (tester) async {
    final state = await ThemeState.load(AppPrefs.inMemory());
    await pumpHeader(tester, state);

    await tester.tap(find.byKey(const Key('menu-button')));
    await pumpFrames(tester, 400);
    expect(find.byType(DrawerMenu), findsOneWidget);
    expect(find.text('换肤'), findsOneWidget);

    await tester.tap(find.text('换肤'));
    // 收起动画 240ms + 二级抽屉的 260ms 计时：逐帧走完，一级抽屉先拆掉。
    await pumpFrames(tester, 800);

    expect(find.byType(DrawerMenu), findsNothing);
    expect(find.byType(ThemeDrawer), findsOneWidget);
    expect(find.text('明暗模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
