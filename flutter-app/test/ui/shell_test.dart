// test/ui/shell_test.dart
//
// 双栏骨架（T24）：900 断点两档、控制条与左栏同底、窄屏贴底、整页不横向溢出、
// 超宽时内容按大屏档封顶（1360 / 1680）并居中。桌面档两列**融合成一张卡**：
// 外层一张整卡（[FusedCard]，边框/圆角/玻璃底/磨砂），里面是「面板 + 竖线 + 播放卡」。
// 沉浸模式的左列面板与大屏歌词页骨架见 `shell_overlay_test.dart`。
//
// 只量几何，不碰业务状态：四个区域各挂一个带 key 的 Text，`getRect` 量到的
// 就是骨架分配给它的那一格（桌面档里 stage / panel 都被 Expanded 拉满高度，
// 所以 Text 的矩形等于整格）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/ui/fused_card.dart';
import 'package:light_music/ui/glass_frost.dart';
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
  testWidgets('桌面 1200 宽：panel 在左、stage 在右且同顶', (tester) async {
    await pumpAt(tester, 1200, 800);

    final header = tester.getRect(find.byKey(const Key('header')));
    final stage = tester.getRect(find.byKey(const Key('stage')));
    final panel = tester.getRect(find.byKey(const Key('panel')));
    final transport = tester.getRect(find.byKey(const Key('transport')));
    final divider = tester.getRect(find.byKey(const Key('fused-divider-line')));

    expect(panel.left, lessThan(stage.left));
    expect(stage.top, panel.top);
    // 列表固定 400px，播放卡吃余量；中间那条竖线占 1px，紧贴面板右缘
    expect(panel.width, closeTo(400, 0.5));
    expect(stage.width, greaterThan(panel.width));
    expect(divider.width, closeTo(1, 0.5));
    expect(divider.left, closeTo(panel.right, 0.5));
    expect(stage.left, closeTo(divider.right, 0.5));
    // 竖线不顶满整卡：上下各让 18px
    expect(divider.top, closeTo(panel.top + 18, 0.5));
    expect(divider.bottom, closeTo(panel.bottom - 18, 0.5));
    // 控制条贴着 stage 那一列的底边，且与左栏面板同底 —— 视觉验收项，不能放宽
    expect(transport.left, stage.left);
    expect(transport.bottom, closeTo(panel.bottom, 1));
    // 桌面外层 padding 底部 28
    expect(panel.bottom, closeTo(800 - 28, 0.5));
    // 1200 还没到 1180 + 56 的封顶线：内容按窗口铺满，24/28/28 的边距不被上限吃掉
    expect(header.top, closeTo(24, 0.5));
    expect(panel.left, closeTo(28, 0.5));
    expect(stage.right, closeTo(1200 - 28, 0.5));
  });

  testWidgets('桌面双栏融合：只有一张整卡、一层磨砂，子卡不再自带卡面', (tester) async {
    await pumpAt(tester, 1200, 800);

    // 整卡只有一个：播放卡与面板各自那份卡面都剥掉了
    expect(find.byType(FusedCard), findsOneWidget);
    // 磨砂层也只剩外层这一层（frostLevel=0 时它仍在树上，只是原样返回 child）
    expect(find.byType(GlassFrostLayer), findsOneWidget);
    expect(find.byKey(const Key('fused-divider')), findsOneWidget);

    // 窄屏单栏没有融合卡
    await pumpAt(tester, 420, 800);
    expect(find.byType(FusedCard), findsNothing);
    expect(find.byKey(const Key('fused-divider')), findsNothing);
  });

  testWidgets('超宽 1920：内容封顶 1680 且水平居中', (tester) async {
    await pumpAt(tester, 1920, 1080);

    final stage = tester.getRect(find.byKey(const Key('stage')));
    final panel = tester.getRect(find.byKey(const Key('panel')));

    // 原版 `.app { max-width: 1180px }` 在大屏抬到 1680
    // （`@media (min-width: 1680px)`，app.css:5059-5064）：
    // 1920 窗口两侧各留 120，而不是原先的 370。
    expect(stage.right - panel.left, closeTo(1680, 0.5));
    // 左右余量相等 ⇒ 居中（而不是贴着左边）
    expect(panel.left, closeTo(1920 - stage.right, 0.5));
  });

  testWidgets('窄屏 420 宽：只有一张播放卡（stage + transport），列表收进弹层', (tester) async {
    await pumpAt(tester, 420, 800);

    final stage = tester.getRect(find.byKey(const Key('stage')));
    final transport = tester.getRect(find.byKey(const Key('transport')));

    // React `App.tsx:1714` 的 `{!compact && <Panel />}`：窄屏不渲染常驻面板。
    expect(find.byKey(const Key('panel')), findsNothing);
    // stage 在上、控制条在卡内底部，两者不重叠。
    expect(stage.bottom, lessThanOrEqualTo(transport.top));
    // 卡底边离窗口底边留 `.app { padding: … 14px }` 的 14px（app.css:419-420：
    // 「底部留白：整张播放卡浮在页面里，底边圆角与边距都要露出来」）。
    expect(transport.bottom, closeTo(800 - 14, 1));
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
