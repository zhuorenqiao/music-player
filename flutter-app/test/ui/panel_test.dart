// test/ui/panel_test.dart
//
// 播放列表面板（T28）：两个 tab、200ms 防抖搜索、统计行、空态、常驻提示。
// 装配壳见 `panel_harness.dart`：真状态层 + 内存 prefs + 临时目录仓储，
// 播放列表与最近条目都是构造出来的假数据（不碰文件与音频 IO）。
//
// 两条测试规则：
//   - 语义 handle 必须在用例体内 dispose：`addTearDown` 跑在框架收尾校验之后，
//     会被判成泄漏（同 header_test）；
//   - 音柱 ticker 在「当前行 + 播放中」时按 60fps 跑，这类用例一律
//     `pump(Duration)`，绝不 `pumpAndSettle`（永远 settle 不了）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';

import 'panel_harness.dart';

/// 搜索框 finder。Flutter 3.47 的 `CommonFinders` 没有 `find.byPlaceholder`
/// （brief 里的写法抄自 React 版测试），这里按 key 取同一个 TextField；
/// 「placeholder 文案逐字」由 `find.text('搜索歌名')` 断言（面板用自绘 hint，
/// 视觉上仍是 `搜索歌名`）。
Finder searchField() => find.byKey(const Key('panel-search'));

void main() {
  Future<void> pump(WidgetTester tester, PanelHarness harness) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildTheme().copyWith(
            extensions: const [AppTokensData(tokens: AppTokens.dark)],
          ),
          home: Scaffold(
            body: SizedBox(width: 420, height: 700, child: harness.build()),
          ),
        ),
      );

  testWidgets('默认在播放列表 tab，显示统计行', (tester) async {
    final harness = PanelHarness(titles: ['十年', '白玫瑰']);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('2 首 · 总时长 07:32'), findsOneWidget);
    expect(find.text('十年'), findsOneWidget);
  });

  testWidgets('搜索框 placeholder 与 aria 文案逐字', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = PanelHarness(titles: ['十年']);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    expect(find.text('搜索歌名'), findsOneWidget); // 占位文案逐字
    expect(searchField(), findsOneWidget);
    expect(find.bySemanticsLabel('搜索歌名'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('输入后 200ms 才生效，期间列表不跳', (tester) async {
    final harness = PanelHarness(titles: ['十年', '白玫瑰']);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    await tester.enterText(searchField(), '十年');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('白玫瑰'), findsOneWidget); // 未生效
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('白玫瑰'), findsNothing); // 已生效
    expect(find.text('找到 1 首 · 共 2 首'), findsOneWidget);
  });

  testWidgets('清空关键词后恢复完整列表且不闪', (tester) async {
    final harness = PanelHarness(titles: ['十年', '白玫瑰']);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    await tester.enterText(searchField(), 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('没有找到《zzz》'), findsOneWidget);
    await tester.enterText(searchField(), '');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('十年'), findsOneWidget);
  });

  testWidgets('空列表空态居中且无装饰框', (tester) async {
    final harness = PanelHarness();
    addTearDown(harness.dispose);
    await pump(tester, harness);
    expect(find.text('播放列表是空的'), findsOneWidget);
    expect(find.text('点击「添加音乐」，或把音频文件拖到页面上'), findsOneWidget);
    expect(find.byKey(const Key('empty-dashed-border')), findsNothing);
    final rect = tester.getRect(find.text('播放列表是空的'));
    expect(rect.center.dy, greaterThan(200)); // 在内容区中部，不贴顶
  });

  testWidgets('最近 tab 顶部说明与清空按钮', (tester) async {
    final harness = PanelHarness(recentCount: 2);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    await tester.tap(find.text('最近'));
    await tester.pumpAndSettle();
    expect(find.text('按播放时间排序，最多保留 50 首'), findsOneWidget);
    expect(find.text('清空历史'), findsOneWidget);
  });

  testWidgets('最近为空时清空按钮禁用', (tester) async {
    final harness = PanelHarness();
    addTearDown(harness.dispose);
    await pump(tester, harness);
    await tester.tap(find.text('最近'));
    await tester.pumpAndSettle();
    expect(find.text('还没有播放记录'), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '清空历史'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('常驻错误横幅优先于列表内容', (tester) async {
    final harness = PanelHarness(
      titles: ['十年'],
      notice: '音频解码失败，文件可能已损坏',
    );
    addTearDown(harness.dispose);
    await pump(tester, harness);
    expect(find.text('音频解码失败，文件可能已损坏'), findsOneWidget);
    expect(find.text('继续播放'), findsOneWidget);
    // 提示条在列表之上：两行垂直位置上下有序
    final notice = tester.getRect(find.text('音频解码失败，文件可能已损坏'));
    final row = tester.getRect(find.text('十年'));
    expect(notice.bottom, lessThanOrEqualTo(row.top));
  });

  testWidgets('熔断提示单独一条文案，带说明', (tester) async {
    final harness = PanelHarness(titles: ['十年'], circuitOpen: true);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    expect(find.textContaining('已停止自动切歌'), findsOneWidget);
    // 熔断时不提供「继续播放」：自动跳已经停手，点了也没有可重试的目标
    expect(find.text('继续播放'), findsNothing);
  });

  testWidgets('过滤时列表高度不塌（固定行不参与收缩）', (tester) async {
    final harness = PanelHarness(titles: ['十年', '白玫瑰'], tall: true);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    final headerBefore = tester.getRect(
      find.byKey(const Key('panel-header')),
    );
    await tester.enterText(searchField(), '十年');
    await tester.pump(const Duration(milliseconds: 300));
    final headerAfter = tester.getRect(find.byKey(const Key('panel-header')));
    expect(headerAfter.top, headerBefore.top);
    expect(headerAfter.height, headerBefore.height);
  });

  testWidgets('点击已失效的最近记录只提示，不播放', (tester) async {
    final harness = PanelHarness(titles: ['十年'], recentCount: 1);
    addTearDown(harness.dispose);
    await pump(tester, harness);
    await tester.tap(find.text('最近'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧歌0'));
    await tester.pump();
    expect(
      harness.toasts.items.single.message,
      '这首歌已经不在播放列表里了',
    );
    expect(harness.player.playing, isFalse);
    // 定时器不能留到用例结束（框架会判 pending timer）
    harness.toasts.drainForTest();
  });
}
