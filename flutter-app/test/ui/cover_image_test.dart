// test/ui/cover_image_test.dart
//
// M2b T10：统一封面件与生成卡碟面的 widget 用例 —— 路径失效不抛、退生成卡。
// 封面一律用空串或不存在路径（stage_test.dart 同款取舍），真文件用临时目录。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/ui/cover_image.dart';
import 'package:light_music/ui/generated_cover_view.dart';
import 'package:light_music/ui/vinyl_deck.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cover_image_test-');
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('CoverImage', () {
    testWidgets('path 为空 → 生成卡', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(300, 300);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(const CoverImage(
          path: '',
          artist: '陈奕迅',
          title: '十年',
          size: 120,
        )),
      );
      expect(find.byType(GeneratedCoverView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('path 指向真文件 → Image.file 分支', (tester) async {
      // 真图由「写一个非法字节文件」承担不了 —— Image.file 解码失败会走
      // errorBuilder 退生成卡。要测「有文件」分支，写一个最小合法 PNG。
      final png = File('${root.path}/a.jpg')
        ..writeAsBytesSync(_onePixelPng);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(300, 300);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(CoverImage(
          path: png.path,
          artist: '陈奕迅',
          title: '十年',
          size: 120,
        )),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('path 指向不存在的文件 → 生成卡（同步判存退卡）', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(300, 300);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(const CoverImage(
          path: 'C:/__no_such_dir__/nope.jpg',
          artist: '陈奕迅',
          title: '十年',
          size: 120,
        )),
      );
      expect(find.byType(GeneratedCoverView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // 「解码失败 → errorBuilder 退生成卡」在 widget 测试环境不可测：
    // flutter_test 的 FakeAsync 里原生图像解码回调（成功或失败）都不触发
    //（frameBuilder 的 frame 恒 null，errorBuilder 不被调，已探测钉死）。
    // 该路径的保险由两处既有机制承担：existsSync 同步判存（上方用例）
    // 与 metadata 层 cover_image_test.dart 的字节级契约。生产里 errorBuilder
    // 的行为与 CoverThumb 的 errorBuilder 同构（M1 已上线）。
  });

  group('CoverDisc 生成卡碟面', () {
    testWidgets('无路径 + 有歌手 → 生成卡碟面', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(const CoverDisc(
          coverPath: '',
          size: 200,
          spinning: false,
          fallbackArtist: '陈奕迅',
          fallbackTitle: '十年',
        )),
      );
      expect(find.byType(GeneratedCoverView), findsOneWidget);
      expect(find.byKey(const Key('cover-placeholder')), findsNothing);
    });

    testWidgets('无路径 + 无歌手（空态）→ 音符占位碟', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(const CoverDisc(coverPath: '', size: 200, spinning: false)),
      );
      expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
      expect(find.byType(GeneratedCoverView), findsNothing);
    });
  });
}

/// 真实的 1×1 PNG（同 test/metadata/cover_image_test.dart 的夹具）。
final List<int> _onePixelPng = UriData.parse(
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
).contentAsBytes();
