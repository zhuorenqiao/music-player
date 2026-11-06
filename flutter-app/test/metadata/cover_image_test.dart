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
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/metadata/cover_image.dart';

/// 真实的 1×1 PNG（签名 + IHDR + IDAT + IEND，CRC 全对；红色不透明像素）。
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

/// 源图尺寸：长边 1200 超出 600 一倍，等比缩放后正好是 600×400。
const int sourceWidth = 1200;
const int sourceHeight = 800;

/// 用引擎现画一张 [sourceWidth]×[sourceHeight] 的 PNG（仓库里不放二进制夹具）。
///
/// 刻意画成非均匀：整张铺蓝，左上四分之一再盖纯红。这样「通道顺序被打乱」
/// （红蓝互换）或「输出被刷成一色 / 全黑」都会让下面按像素的断言失败 ——
/// 纯色图或 1×1 图做不到这件事。
Future<Uint8List> drawSourcePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, sourceWidth.toDouble(), sourceHeight.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF0000FF),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(
      0,
      0,
      sourceWidth / 2,
      sourceHeight / 2,
    ),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(sourceWidth, sourceHeight);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// 取 rawRgba 缓冲里 (x, y) 处的 (r, g, b, a)。
List<int> pixelAt(Uint8List rgba, int imageWidth, int x, int y) {
  final offset = (y * imageWidth + x) * 4;
  return rgba.sublist(offset, offset + 4);
}

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

  test('1200×800 原图按长边 ≤600 缩到 600×400，像素颜色不错乱', () async {
    final source = await drawSourcePng();
    const writer = CoverImageWriter();
    final path = await writer.write(
      source,
      'image/png',
      directory: root.path,
      id: 'big',
    );

    expect(path, isNotNull);
    // 读回落盘文件重新解码：断言的是真正写进磁盘的那份字节，不是内存里的中间态。
    final written = await File(path!).readAsBytes();
    final codec = await ui.instantiateImageCodec(written);
    final frame = await codec.getNextFrame();
    try {
      expect(CoverImageWriter.maxEdge, 600);
      // 长边规则：max(宽, 高) 收到 600，短边按 1200:800 = 3:2 等比得 400。
      expect(frame.image.width, 600);
      expect(frame.image.height, 400);

      final raw = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final rgba = raw!.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
      // 左上角来自画的红块：R 高、G/B 低。红蓝通道互换（B 高 R 低）、
      // 输出全黑或整张被刷成一色都会在这里挂掉。
      final topLeft = pixelAt(rgba, frame.image.width, 0, 0);
      expect(topLeft[0], greaterThan(200), reason: '左上角应为红：R 分量 $topLeft');
      expect(topLeft[1], lessThan(60), reason: '左上角应为红：G 分量 $topLeft');
      expect(topLeft[2], lessThan(60), reason: '左上角应为红：B 分量 $topLeft');
      expect(topLeft[3], 255, reason: '应保持不透明：A 分量 $topLeft');
      // 右下角仍是蓝块：确认缩放没有把整张图裁成左上角那一块。
      final bottomRight = pixelAt(
        rgba,
        frame.image.width,
        frame.image.width - 1,
        frame.image.height - 1,
      );
      expect(
        bottomRight[2],
        greaterThan(200),
        reason: '右下角应为蓝：$bottomRight',
      );
      expect(bottomRight[0], lessThan(60), reason: '右下角应为蓝：$bottomRight');
    } finally {
      frame.image.dispose();
      codec.dispose();
    }
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
