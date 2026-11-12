// test/ui/panel_flush_test.dart
//
// 弹层里的面板要脱掉自己的卡片外观（对译 `.panel--sheet`，app.css:1673-1685）：
//   border: none; border-radius: 0; background: transparent; box-shadow: none;
// 因为底部弹层自己已经画了一层 sheet 卡面（`_SheetCard` 的 24 顶部圆角 +
// sheet-a→sheet-b 渐变 + 三边描边）。面板不脱就会叠成「卡里套卡」两道边。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';

import 'panel_harness.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: child),
);

/// 面板自己那层「卡面」的判定：一个带圆角 + 渐变 + 边框的 Container。
/// 侧栏版必须有且只有一层；弹层版（flush）一个都不该有。
int _cardShellCount(WidgetTester tester) {
  var count = 0;
  for (final element in find.byType(Container).evaluate()) {
    final widget = element.widget as Container;
    final decoration = widget.decoration;
    if (decoration is! BoxDecoration) continue;
    final hasBorder = decoration.border != null;
    final hasGradient = decoration.gradient != null;
    if (hasBorder && hasGradient) count++;
  }
  return count;
}

void main() {
  testWidgets('侧栏版面板保留自己的卡面（一行边框 + 渐变）', (tester) async {
    final harness = PanelHarness(tall: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(wrap(harness.build()));
    await tester.pump();

    expect(_cardShellCount(tester), 1, reason: '侧栏版应画一层 panel 卡面');
    expect(tester.takeException(), isNull);
  });

  testWidgets('弹层版面板剥掉卡面（flush），只剩内容', (tester) async {
    final harness = PanelHarness(tall: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(wrap(harness.build(flush: true)));
    await tester.pump();

    expect(
      _cardShellCount(tester),
      0,
      reason: 'flush 时不该再画 panel 卡面（弹层已经画了一层）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('flush 不影响内容：表头 / 搜索 / 列表都还在', (tester) async {
    final harness = PanelHarness(tall: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(wrap(harness.build(flush: true)));
    await tester.pump();

    expect(find.byKey(const Key('panel-header')), findsOneWidget);
    expect(find.byKey(const Key('panel-search')), findsOneWidget);
    expect(find.byKey(const Key('panel-tab-playlist')), findsOneWidget);
    expect(find.byKey(const Key('panel-tab-recent')), findsOneWidget);
  });

  testWidgets('flush 弹层版仍能切 tab（结构没改变行为）', (tester) async {
    final harness = PanelHarness(tall: true);
    addTearDown(harness.dispose);
    await tester.pumpWidget(wrap(harness.build(flush: true)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('panel-tab-recent')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('列表滚动条与 ListView 共用一个 controller（悬停不抛）', (tester) async {
    // 回归：RawScrollbar 曾拿 PrimaryScrollController.maybeOf(context)，
    // 而 Panel 里的 ListView 在桌面上并不接纳它 —— 两者不是同一个
    // controller，鼠标悬停滚动条就抛
    // 「The Scrollbar's ScrollController has no ScrollPosition attached」。
    final harness = PanelHarness(tall: true, titles: const ['十年', '孤勇者']);
    addTearDown(harness.dispose);
    await tester.pumpWidget(wrap(harness.build()));
    await tester.pump();

    final listView = tester.widget<ListView>(
      find.byKey(const Key('playlist-list')),
    );
    final scrollbar = tester.widget<RawScrollbar>(find.byType(RawScrollbar));

    expect(listView.controller, isNotNull);
    // 同一个实例：RawScrollbar 才拿得到 ScrollPosition。
    expect(identical(scrollbar.controller, listView.controller), isTrue);
    expect(tester.takeException(), isNull);
  });
}
