// test/ui/header_test.dart
//
// 顶栏与一级抽屉（T25）：品牌区、右侧唯一的「更多」按钮（视觉文案「菜单」，
// 读屏名固定「更多」）、抽屉里的三条一级入口、清空前的二次确认、抽屉宽度。
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
Future<Calls> pumpHeader(WidgetTester tester, double width) async {
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
    // 按钮的视觉文字是「菜单」，读屏名却是「更多」：语义里只能有一套名字，
    // 否则 `菜单` 会作为第二个按钮名冒出来。
    expect(find.text('菜单'), findsOneWidget);
    expect(find.bySemanticsLabel('菜单'), findsNothing);
  });

  headerTest('≤479 隐藏副标题，按钮收成 36×36 图标钮', (tester) async {
    await pumpHeader(tester, 420);

    expect(find.text('流光音乐'), findsOneWidget);
    expect(find.text('LIGHT MUSIC PLAYER'), findsNothing);
    expect(find.text('菜单'), findsNothing);
    expect(tester.getSize(find.bySemanticsLabel('更多')), const Size(36, 36));
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
}
