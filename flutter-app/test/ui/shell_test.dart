// test/ui/shell_test.dart
//
// 双栏骨架（T24）：900 断点两档、控制条与右栏同底、窄屏贴底、整页不横向溢出、
// 超宽时内容封顶 1180 并居中。
//
// 只量几何，不碰业务状态：四个区域各挂一个带 key 的 Text，`getRect` 量到的
// 就是骨架分配给它的那一格（桌面档里 stage / panel 都被 Expanded 拉满高度，
// 所以 Text 的矩形等于整格）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/ui/shell.dart';

HomeLayout buildLayout() => const HomeLayout(
  header: Text('HEADER', key: Key('header')),
  stage: Text('STAGE', key: Key('stage')),
  panel: Text('PANEL', key: Key('panel')),
  transport: Text('TRANSPORT', key: Key('transport')),
);

Widget wrap() => MaterialApp(
  theme: buildTheme(),
  home: Scaffold(body: buildLayout()),
);

/// 按逻辑像素设视口再 pump：`SizedBox` 套在 home 里没用 —— Scaffold 的父级
/// 约束是紧的，SizedBox 会被压回默认的 800×600。
Future<void> pumpAt(
  WidgetTester tester,
  double width,
  double height,
) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  await tester.pumpWidget(wrap());
}

void main() {
  testWidgets('桌面 1200 宽：stage 在左、panel 在右且同顶', (tester) async {
    await pumpAt(tester, 1200, 800);

    final header = tester.getRect(find.byKey(const Key('header')));
    final stage = tester.getRect(find.byKey(const Key('stage')));
    final panel = tester.getRect(find.byKey(const Key('panel')));
    final transport = tester.getRect(find.byKey(const Key('transport')));

    expect(stage.left, lessThan(panel.left));
    expect(stage.top, panel.top);
    // 控制条贴着 stage 那一列的底边，且与右栏面板同底 —— 视觉验收项，不能放宽
    expect(transport.left, stage.left);
    expect(transport.bottom, closeTo(panel.bottom, 1));
    // 桌面外层 padding 底部 28
    expect(panel.bottom, closeTo(800 - 28, 0.5));
    // 1200 还没到 1180 + 56 的封顶线：内容按窗口铺满，24/28/28 的边距不被上限吃掉
    expect(header.top, closeTo(24, 0.5));
    expect(stage.left, closeTo(28, 0.5));
    expect(panel.right, closeTo(1200 - 28, 0.5));
  });

  testWidgets('超宽 1920：内容封顶 1180 且水平居中', (tester) async {
    await pumpAt(tester, 1920, 1080);

    final stage = tester.getRect(find.byKey(const Key('stage')));
    final panel = tester.getRect(find.byKey(const Key('panel')));

    // 原版 `.app { max-width: 1180px; margin: 0 auto }`
    expect(panel.right - stage.left, closeTo(1180, 0.5));
    // 左右余量相等 ⇒ 居中（而不是贴着左边）
    expect(stage.left, closeTo(1920 - panel.right, 0.5));
  });

  testWidgets('窄屏 420 宽：单列堆叠且控制条在最底', (tester) async {
    await pumpAt(tester, 420, 800);

    final stage = tester.getRect(find.byKey(const Key('stage')));
    final panel = tester.getRect(find.byKey(const Key('panel')));
    final transport = tester.getRect(find.byKey(const Key('transport')));

    expect(stage.bottom, lessThanOrEqualTo(panel.top));
    expect(panel.bottom, lessThanOrEqualTo(transport.top));
    expect(transport.bottom, closeTo(800, 1));
  });

  testWidgets('900 断点两侧列数不同', (tester) async {
    await pumpAt(tester, 900, 700);
    expect(find.byKey(const Key('desktop-grid')), findsOneWidget);

    await pumpAt(tester, 899, 700);
    expect(find.byKey(const Key('desktop-grid')), findsNothing);
  });

  testWidgets('整页不出现横向滚动', (tester) async {
    await pumpAt(tester, 320, 640);

    expect(tester.takeException(), isNull);
  });
}
