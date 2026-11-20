// test/cover/generated_artwork_test.dart
//
// 生成卡 → 系统封面文件的单测：图要画得出来（真 PNG、方图、不透明），
// 文件名要按派生量稳定（同歌同曲只落一份），落在盘上之后 [pathFor] 才
// 同步命中 —— 媒体会话的 `artUriFor` 是同步回调，这条时序是它的前提。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/cover/generated_artwork.dart';

void main() {
  // `Picture.toImage` 要一个初始化过的 binding（不打网络、不建窗口）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('light-music-artwork-');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  GeneratedArtworkCache cacheOf({int size = kGeneratedArtworkSize}) =>
      GeneratedArtworkCache(directory: '${temp.path}/artwork', size: size);

  test('没预热过时 pathFor 不命中，落盘后才命中', () async {
    final cache = cacheOf();

    expect(cache.pathFor(artist: '周杰伦', title: '说好不哭'), isNull);

    await cache.prime(artist: '周杰伦', title: '说好不哭');

    final path = cache.pathFor(artist: '周杰伦', title: '说好不哭');
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
    expect(cache.pathFor(artist: '周杰伦', title: '说好不哭'), path);
  });

  test('产出的是不透明方图 PNG', () async {
    final cache = cacheOf(size: 128);
    await cache.prime(artist: '周杰伦', title: '说好不哭');
    final path = cache.pathFor(artist: '周杰伦', title: '说好不哭')!;

    final bytes = await File(path).readAsBytes();
    // PNG 魔数 + IHDR 里的宽高（偏移 16 / 20，大端）。
    expect(
      bytes.sublist(0, 8),
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
    );
    final header = ByteData.sublistView(bytes.sublist(16, 24));
    expect(header.getUint32(0), 128);
    expect(header.getUint32(4), 128);

    // 真解一次：像素必须是全不透明的（透明底在系统卡片上会被当黑块）。
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final pixels = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final rgba = pixels!.buffer.asUint8List();
    var opaque = true;
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] != 255) {
        opaque = false;
        break;
      }
    }
    expect(opaque, isTrue);
    frame.image.dispose();
    codec.dispose();
  });

  test('同歌同曲重复预热只落一份，且第二次不重复通知', () async {
    final cache = cacheOf();
    var notified = 0;
    cache.addListener(() => notified++);

    await cache.prime(artist: '周杰伦', title: '说好不哭');
    final first = cache.pathFor(artist: '周杰伦', title: '说好不哭')!;
    expect(notified, 1);

    await cache.prime(artist: '周杰伦', title: '说好不哭');
    expect(cache.pathFor(artist: '周杰伦', title: '说好不哭'), first);
    expect(notified, 1);

    final files = Directory('${temp.path}/artwork')
        .listSync()
        .whereType<File>()
        .toList();
    expect(files.length, 1);
  });

  test('换曲名换一份图（生成卡底部小字不同）', () async {
    final cache = cacheOf();
    await cache.prime(artist: '周杰伦', title: '说好不哭');
    await cache.prime(artist: '周杰伦', title: '晴天');

    final a = cache.pathFor(artist: '周杰伦', title: '说好不哭')!;
    final b = cache.pathFor(artist: '周杰伦', title: '晴天')!;
    expect(a, isNot(b));
    expect(File(a).existsSync(), isTrue);
    expect(File(b).existsSync(), isTrue);
  });

  test('上一轮就画过的图：新实例同步命中，不再画', () async {
    final first = cacheOf();
    await first.prime(artist: '周杰伦', title: '说好不哭');
    final path = first.pathFor(artist: '周杰伦', title: '说好不哭');

    final second = cacheOf();
    expect(second.pathFor(artist: '周杰伦', title: '说好不哭'), path);
  });
}
