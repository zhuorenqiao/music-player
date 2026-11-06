// test/metadata/cover_image_test.dart
//
// CoverImageWriter 的内嵌封面落盘用例（无 JS 对应物：原版是浏览器的
// `canvas.toDataURL('image/jpeg', 0.86)`，Dart 侧换成 `dart:ui` 的编解码）。
//
// `dart:ui` 的图像编解码需要引擎绑定，所以在 main 开头初始化
// `TestWidgetsFlutterBinding`；用普通 `test()`（不是 `testWidgets`）调用，
// 避免 FakeAsync 把 `Picture.toImage` 的原生回调卡住。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/cover_image.dart';

/// 真实的 1×1 PNG（签名 + IHDR + IDAT + IEND，CRC 全对；红色不透明像素）。
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cover_image_test');
  });
  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  test('PNG 落盘：返回绝对路径、目录自动创建、内容是 PNG 字节', () async {
    const writer = CoverImageWriter();
    final path = await writer.write(
      onePixelPng,
      'image/png',
      directory: '${root.path}/nested',
      id: 'track-1',
    );

    expect(path, isNotNull);
    final file = File(path!);
    expect(file.existsSync(), isTrue);
    // 文件名沿用原版的 id.jpg —— 内容其实是 PNG（裁定的格式约定）。
    expect(file.path, endsWith('track-1.jpg'));
    expect(file.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
  });

  test('不可解码的字节返回 null，不抛也不落盘', () async {
    const writer = CoverImageWriter();
    final path = await writer.write(
      Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      'image/jpeg',
      directory: root.path,
      id: 'garbage',
    );

    expect(path, isNull);
    expect(root.listSync(), isEmpty);
  });

  test('空字节返回 null，不落盘', () async {
    const writer = CoverImageWriter();
    final path = await writer.write(
      Uint8List(0),
      'image/png',
      directory: root.path,
      id: 'empty',
    );

    expect(path, isNull);
    expect(root.listSync(), isEmpty);
  });
}
