// 把「左上角 logo」按 ui/header.dart 的规格以 1024px 渲染成 PNG，供
// tool/make_app_icons.py 切各平台图标。它不在 `test/` 下，所以不会混进
// `flutter test` 的常规用例（golden 基线就是母版本身，只在换 logo 时才重跑）。
//
// 跑法：flutter test --update-goldens tool/brand/render_brand_master_test.dart
// 产出：tool/brand/app_icon_master.png（整块 logo：底色 + 圆角渐变块 + 均衡器图标）、
//       tool/brand/app_icon_glyph.png（透明底，只有均衡器图标）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_tokens.dart';

const double kArtSize = 1024;

/// 测试环境不会自动挂 MaterialIcons，图标字会画成空白方块 —— 手动装一次。
Future<void> loadMaterialIcons() async {
  final file = File(
    r'D:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
  );
  final bytes = file.readAsBytesSync();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// 对译 ui/header.dart 里 `_Brand` 的 40×40 logo（半径 13、1px 描边、
/// 左上→右下 accentSoft→cardB 渐变、18px 的 graphic_eq 图标）。
Widget brandTile({required bool withBackground}) {
  const tokens = AppTokens.dark;
  const s = 40.0;
  final k = kArtSize / s;
  return Container(
    width: kArtSize,
    height: kArtSize,
    color: withBackground ? tokens.bg : null,
    alignment: Alignment.center,
    child: Container(
      width: kArtSize,
      height: kArtSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13 * k / 1),
        border: Border.all(color: tokens.accentLine, width: 1 * k),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.accentSoft, tokens.cardB],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.graphic_eq,
        size: 18 * k,
        color: tokens.accent,
      ),
    ),
  );
}

Widget glyphOnly() {
  const tokens = AppTokens.dark;
  return Container(
    width: kArtSize,
    height: kArtSize,
    alignment: Alignment.center,
    child: Icon(
      Icons.graphic_eq,
      size: kArtSize * 0.42,
      color: tokens.accent,
    ),
  );
}

Future<void> pumpArt(WidgetTester tester, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(kArtSize, kArtSize);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: RepaintBoundary(key: const Key('art'), child: child)),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadMaterialIcons);

  testWidgets('渲染 logo 整块', (tester) async {
    await pumpArt(tester, brandTile(withBackground: true));
    await expectLater(
      find.byKey(const Key('art')),
      matchesGoldenFile('app_icon_master.png'),
    );
  });

  testWidgets('渲染 logo 里的图标（透明底）', (tester) async {
    await pumpArt(tester, glyphOnly());
    await expectLater(
      find.byKey(const Key('art')),
      matchesGoldenFile('app_icon_glyph.png'),
    );
  });
}
