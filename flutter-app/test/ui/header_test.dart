// test/ui/header_test.dart
//
// 顶栏与一级抽屉（T25）：品牌区、右侧唯一的「更多」按钮（视觉文案与读屏名
// 都是「更多」，对译 React `LibraryMenu.tsx` 的 `btn__text`）、抽屉里的三条
// 一级入口、清空前的二次确认、抽屉宽度。
//
// 三个回调全部由测试注入 —— 测试绝不碰 file_picker（真实选择器在
// `core/file_picking.dart` 里，由 `HomePage` 接线）。
//
// 宽度相关用例必须改视口：`AppHeader` 读 `MediaQuery` 的窗口宽度，
// 在 Scaffold body 里套 SizedBox 是改不动的（父级约束是紧的）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/drawer_menu.dart';
import 'package:light_music/ui/header.dart';

/// 三个入口各自被调用的次数。
class Calls {
  int addFiles = 0;
  int addFolder = 0;
  int cleared = 0;
}

/// 按逻辑像素设视口，pump 一个只挂顶栏的页面。
///
/// [onSwitchView] / [immersive] 用来展开「模式切换」按钮：窄屏只有歌词页
/// （immersive == true）才渲染它，桌面两种状态都有。
Future<Calls> pumpHeader(
  WidgetTester tester,
  double width, {
  VoidCallback? onSwitchView,
  bool immersive = false,
}) async {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);

  final calls = Calls();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme().copyWith(
        extensions: const [AppTokensData(tokens: AppTokens.dark)],
      ),
      home: Scaffold(
        body: AppHeader(
          onAddFiles: () async => calls.addFiles++,
          onAddFolder: () async => calls.addFolder++,
          onClearPlaylist: () async => calls.cleared++,
          onSwitchView: onSwitchView,
          immersive: immersive,
        ),
      ),
    ),
  );
  return calls;
}

/// `find.bySemanticsLabel` 要求语义树已开启，而 handle 必须在用例体**内**销毁：
/// `addTearDown` 跑在框架的收尾校验之后，会被判成泄漏。
void headerTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      semantics.dispose();
    }
  });
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('更多'));
  await tester.pumpAndSettle();
}

void main() {
  headerTest('桌面显示品牌标题与副标题，只一个菜单按钮', (tester) async {
    await pumpHeader(tester, 1200);

    expect(find.text('流光音乐'), findsOneWidget);
    expect(find.text('LIGHT MUSIC PLAYER'), findsOneWidget);
    expect(find.bySemanticsLabel('更多'), findsOneWidget);
    // 视觉文字与读屏名都是「更多」（React `LibraryMenu.tsx:65` 的
    // `<span className="btn__text">更多</span>`）：语义里只能有一套名字，
    // 否则「更多」会作为第二个按钮名冒出来。
    expect(find.text('更多'), findsOneWidget);
    expect(find.bySemanticsLabel('菜单'), findsNothing);
  });

  headerTest('窄屏（<900）不显示品牌，只剩一颗透明的 ⋯', (tester) async {
    await pumpHeader(tester, 420);

    // 小屏铺满后品牌整块让位给卡片（`@media (max-width: 899px)` 的 `.brand`）
    expect(find.text('流光音乐'), findsNothing);
    expect(find.text('LIGHT MUSIC PLAYER'), findsNothing);
    // `.btn__text { display: none }`：只留图标
    expect(find.text('更多'), findsNothing);
    expect(tester.getSize(find.bySemanticsLabel('更多')), const Size(32, 32));
    // 按钮的「地」也去掉（`border: 0; background: none`）：壳里不再有带装饰的
    // Container，只剩那颗 19px 的 ⋯ 自己
    expect(
      find.descendant(
        of: find.byKey(const Key('menu-button')),
        matching: find.byType(Container),
      ),
      findsNothing,
      reason: '窄屏是透明点击区，不再套胶囊外壳',
    );
  });

  headerTest('窄屏不渲染「模式切换」：简约模式与歌词页都没有', (tester) async {
    // 简约模式：点曲目区就能进歌词页，这颗按钮是重复的
    await pumpHeader(tester, 420, onSwitchView: () {});
    expect(find.byKey(const Key('view-mode-button')), findsNothing);

    // 歌词页：点空白处就能退回来（`LyricsPageController.close`），同样不渲染
    await pumpHeader(tester, 420, onSwitchView: () {}, immersive: true);
    expect(find.byKey(const Key('view-mode-button')), findsNothing);
    // 顶栏只剩「更多」，仍是 32×32
    expect(find.bySemanticsLabel('更多'), findsOneWidget);
    expect(tester.getSize(find.bySemanticsLabel('更多')), const Size(32, 32));
  });

  headerTest('桌面仍是「模式切换 + 更多」两颗文字胶囊', (tester) async {
    await pumpHeader(tester, 1200, onSwitchView: () {});

    expect(find.text('沉浸模式'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    // 桌面不收敛：36px 高、带文字的胶囊（宽度撑开而不是 32 方块）
    final menuSize = tester.getSize(find.bySemanticsLabel('更多'));
    expect(menuSize.height, 36);
    expect(menuSize.width, greaterThan(32));
  });

  headerTest('「更多」是白底（--surface），不是透明底', (tester) async {
    await pumpHeader(tester, 1200);

    final finder = find.descendant(
      of: find.byKey(const Key('menu-button')),
      matching: find.byType(Container),
    );
    expect(finder, findsOneWidget, reason: '胶囊外壳就一个 Container');
    final decoration =
        tester.widget<Container>(finder).decoration! as BoxDecoration;
    expect(
      decoration.color,
      AppTokens.dark.surface,
      reason: '白底与旁边排序圆钮、卡片里 T/水滴/闹钟同一档',
    );
    final border = decoration.border! as Border;
    expect(border.top.color, AppTokens.dark.border, reason: '1px --border 不清掉');
  });

  headerTest('菜单里只有一级入口，且不出现说明文字', (tester) async {
    await pumpHeader(tester, 1200);
    await openMenu(tester);

    expect(find.text('添加音乐'), findsOneWidget);
    expect(find.text('添加整个文件夹'), findsOneWidget);
    expect(find.text('清空播放列表'), findsOneWidget);
    // parity 校正（M3 T6）：换肤二级抽屉落地，一级菜单现在有第四个入口
    //（LibraryMenu.tsx:104 的「换肤」对译）。
    expect(find.text('换肤'), findsOneWidget);
    expect(find.textContaining('把音频文件'), findsNothing); // 一级行不带说明
  });

  headerTest('清空是二次确认，不在菜单里直接执行', (tester) async {
    final calls = await pumpHeader(tester, 1200);
    await openMenu(tester);

    await tester.tap(find.text('清空播放列表'));
    await tester.pumpAndSettle();

    expect(find.text('确定清空播放列表吗？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(calls.cleared, 0);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('确定清空播放列表吗？'), findsNothing);
    expect(calls.cleared, 0);
  });

  headerTest('点「清空」才真的清空，抽屉随手收掉', (tester) async {
    final calls = await pumpHeader(tester, 1200);
    await openMenu(tester);

    await tester.tap(find.text('清空播放列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(calls.cleared, 1);
    expect(find.byType(DrawerMenu), findsNothing);
  });

  headerTest('添加类入口先收抽屉再回调', (tester) async {
    final calls = await pumpHeader(tester, 1200);

    await openMenu(tester);
    await tester.tap(find.text('添加音乐'));
    await tester.pumpAndSettle();
    expect(calls.addFiles, 1);
    expect(find.byType(DrawerMenu), findsNothing);

    await openMenu(tester);
    await tester.tap(find.text('添加整个文件夹'));
    await tester.pumpAndSettle();
    expect(calls.addFolder, 1);
    expect(find.byType(DrawerMenu), findsNothing);
  });

  headerTest('抽屉宽度收窄', (tester) async {
    await pumpHeader(tester, 1200);

    await tester.tap(find.bySemanticsLabel('更多'));
    await tester.pump();

    final sheet = tester.getRect(find.byType(DrawerMenu));
    expect(sheet.width, lessThanOrEqualTo(320));
    expect(sheet.width, DrawerMenu.width);
  });

  headerTest('与 Web 对齐：288 宽、54px 小卡、抬头是「更多」', (tester) async {
    await pumpHeader(tester, 1200);
    await openMenu(tester);

    // `.drawer__panel--narrow { width: min(288px, 82vw) }`
    expect(tester.getRect(find.byType(DrawerMenu)).width, 288);

    // `.menu-row { min-height: 54px }`：每行是一张 54px 小卡（旧实现平铺 44px）。
    final row = tester.getRect(
      find
          .ancestor(of: find.text('添加音乐'), matching: find.byType(InkWell))
          .first,
    );
    expect(row.height, 54);

    // `.menu-list { gap: 8px }` + `.drawer__body { padding: 4px 12px 16px }`：
    // 行与行之间留 8px，左右各 12px（外加 1px 面板描边）。旧实现行是贴在一起的。
    final row2 = tester.getRect(
      find
          .ancestor(of: find.text('添加整个文件夹'), matching: find.byType(InkWell))
          .first,
    );
    expect(row2.top - row.bottom, 8, reason: '行间距 8px');
    final panel = tester.getRect(find.byType(DrawerMenu));
    expect(
      row.left - panel.left,
      closeTo(13, 0.1),
      reason: '左边距 12px + 描边 1px',
    );
    expect(
      panel.right - row.right,
      closeTo(13, 0.1),
      reason: '右边距 12px + 描边 1px',
    );

    // 抬头标题与 Web 同名「更多」（旧实现写的是小字「菜单」）。
    expect(find.text('更多'), findsNWidgets(2)); // 顶栏胶囊 + 抽屉抬头
    expect(find.text('菜单'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
