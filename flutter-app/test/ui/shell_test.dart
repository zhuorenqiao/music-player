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
import 'package:light_music/ui/player_card.dart';
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
    // 页面铺满（`.app { padding: 0 }`，app.css 的 `@media (max-width: 899px)`）：
    // 卡底边直接落在窗口底边，不再有原来的 14px 外层留白。
    expect(transport.bottom, closeTo(800, 1));
    expect(stage.top, closeTo(0, 0.5));
  });

  testWidgets('窄屏简约模式：顶栏浮在卡片右上角内侧 16px / 10px', (tester) async {
    await pumpAt(tester, 420, 800);

    final header = tester.getRect(find.byKey(const Key('header')));
    final stage = tester.getRect(find.byKey(const Key('stage')));

    // `body:not(.is-lyrics-page) .app__header,
    //  body.is-lyrics-page .app__header { position: absolute;
    //  top: 28px; right: 0; padding: 0 10px }`：
    // 测试视口没有安全区，顶栏 top = 安全区 + 16 = 16（与电台页右上角两颗
    // 同一条水平线，那边也是 16）；右侧 10px 由顶栏自己的左右内边距给出 ——
    // 不占流、叠在卡片右上角。
    expect(header.top, closeTo(16, 0.5));
    expect(header.right, closeTo(420 - 10, 0.5));
    // 卡片已经跟着铺满，从视口左上角开始
    expect(stage.top, closeTo(0, 0.5));
  });

  testWidgets('窄屏歌词页：顶栏与简约模式同一处（也浮在卡片右上角）', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: HomeLayout(
            header: const Text('HEADER', key: Key('header')),
            stage: const Text('STAGE', key: Key('stage')),
            panel: const Text('PANEL', key: Key('panel')),
            transport: const Text('TRANSPORT', key: Key('transport')),
            overlay: const Text('LYRICS', key: Key('overlay')),
          ),
        ),
      ),
    );

    final header = tester.getRect(find.byKey(const Key('header')));
    final overlay = tester.getRect(find.byKey(const Key('overlay')));

    // 两种模式共用同一条 `Positioned(top: 安全区 + 16, right: 10)`：切模式时
    // 「电台 / 更多」不再上下跳（从前歌词页顶栏在流内，位置是 10 + 32 + 14 间距）。
    expect(header.top, closeTo(16, 0.5));
    expect(header.right, closeTo(420 - 10, 0.5));
    // 顶栏不再占流：歌词卡直接铺到屏幕顶边
    expect(overlay.top, closeTo(0, 0.5));
  });

  testWidgets('窄屏铺满：卡面铺到屏幕四边，内容按系统栏 insets 内缩', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    // 刘海机：状态栏 32、手势条 20（edge-to-edge 之后 Flutter 视图铺到这两条底下）
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 20);
    await tester.pumpWidget(wrap());

    final card = tester.getRect(find.byType(PlayerCard));
    final stage = tester.getRect(find.byKey(const Key('stage')));
    final transport = tester.getRect(find.byKey(const Key('transport')));
    final header = tester.getRect(find.byKey(const Key('header')));

    // 卡面自己铺满整屏（含状态栏 / 手势条底下）—— 这条黑边就是这么没的
    expect(card.top, closeTo(0, 0.5));
    expect(card.bottom, closeTo(800, 0.5));
    expect(card.height, closeTo(800, 0.5));
    // 内容按 insets 内缩，不钻到系统栏下面
    expect(stage.top, closeTo(32, 0.5));
    expect(transport.bottom, closeTo(800 - 20, 0.5));
    // 顶栏 = 安全区 + 16（与电台页右上角两颗同一条水平线）
    expect(header.top, closeTo(48, 0.5));
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
