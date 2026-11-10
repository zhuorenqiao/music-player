// test/cover/cover_disk_cache_test.dart
//
// M2b T3 闸口：在线封面 prefs 索引层（CoverIndexCache）+ 落盘器
//（CoverDiskStore）+ 取图接缝生产实现（ImageBytesClientImpl）。
//
// 索引层用 inMemory prefs + 注入时钟（同 lyrics_cache_test 的手法）；落盘器用
// 真临时目录 + 真 1×1 PNG 字节（fixture 照抄 test/metadata/cover_image_test.dart
// 的 base64 常量）。`dart:ui` 的图像编解码需要引擎绑定，所以 main 开头初始化
// `TestWidgetsFlutterBinding`、用普通 `test()`（不是 testWidgets），避免
// FakeAsync 把 `Picture.toImage` 的原生回调卡住。ImageBytesClientImpl 的用例
// 走 package:http 的 MockClient（http/testing.dart），绝不打真网络。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:light_music/cover/cover_disk_cache.dart';
import 'package:light_music/cover/cover_source.dart';
import 'package:light_music/core/app_prefs.dart';

/// 真实的 1×1 PNG（签名 + IHDR + IDAT + IEND，CRC 全对；红色不透明像素）。
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

/// 可手推的注入时钟：从 [start] 起，每次 `()` 推进 [stepMs] 毫秒。
class _Clock {
  _Clock(this.start, {this.stepMs = 0});
  DateTime start;
  int stepMs;
  DateTime call() {
    final value = start;
    start = start.add(Duration(milliseconds: stepMs));
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoverIndexCache', () {
    test('write ok → read 回来同 path/source；miss → read 返回 not-found', () async {
      final prefs = AppPrefs.inMemory();
      final cache = CoverIndexCache(prefs, now: () => DateTime(2026, 1, 1));

      await cache.write('k-ok', const CoverRecord(status: 'ok', path: 'C:/covers-net/a.jpg'));
      final ok = await cache.read('k-ok');
      expect(ok, isNotNull);
      expect(ok!.isOk, isTrue);
      expect(ok.status, 'ok');
      expect(ok.path, 'C:/covers-net/a.jpg');
      expect(ok.source, 'iTunes');

      await cache.write('k-miss', const CoverRecord(status: 'not-found'));
      final miss = await cache.read('k-miss');
      expect(miss, isNotNull);
      expect(miss!.isOk, isFalse);
      expect(miss.status, 'not-found');
      expect(miss.path, '');
    });

    test('write 只收 ok / not-found：error / aborted 整笔丢弃', () async {
      final prefs = AppPrefs.inMemory();
      final cache = CoverIndexCache(prefs, now: () => DateTime(2026, 1, 1));

      await cache.write('k-err', const CoverRecord(status: 'error'));
      expect(await cache.read('k-err'), isNull);
      expect(prefs.containsKey(CoverIndexCache.prefsKey), isFalse,
          reason: 'error 不落任何条目，连表都不该出现');
    });

    test('TTL：命中 30 天边界内不过期、30天+1s 过期', () async {
      final clock = _Clock(DateTime(2026, 1, 1));
      final cache = CoverIndexCache(AppPrefs.inMemory(), now: clock.call);
      await cache.write('k', const CoverRecord(status: 'ok', path: 'p'));

      // 边界内：30 天整（age == ttl 不大于 ttl）。
      clock.start = DateTime(2026, 1, 1).add(const Duration(days: 30));
      final fresh = await cache.read('k');
      expect(fresh, isNotNull);

      // 30天+1s：过期返回 null。
      clock.start = DateTime(2026, 1, 1)
          .add(const Duration(days: 30, seconds: 1));
      expect(await cache.read('k'), isNull);
    });

    test('TTL：过期不删条目（键仍在 prefs 表里）', () async {
      final clock = _Clock(DateTime(2026, 1, 1));
      final prefs = AppPrefs.inMemory();
      final cache = CoverIndexCache(prefs, now: clock.call);
      await cache.write('k', const CoverRecord(status: 'ok', path: 'p'));

      clock.start = DateTime(2026, 1, 1)
          .add(const Duration(days: 30, seconds: 1));
      expect(await cache.read('k'), isNull);
      final raw = await prefs.readString(CoverIndexCache.prefsKey);
      expect(raw, contains('"k"'), reason: '过期只返回 null，不删条目');
    });

    test('TTL：未命中 3 天边界内不过期、3天+1s 过期', () async {
      final clock = _Clock(DateTime(2026, 1, 1));
      final cache = CoverIndexCache(AppPrefs.inMemory(), now: clock.call);
      await cache.write('k', const CoverRecord(status: 'not-found'));

      clock.start = DateTime(2026, 1, 1).add(const Duration(days: 3));
      final fresh = await cache.read('k');
      expect(fresh, isNotNull);
      expect(fresh!.status, 'not-found');

      clock.start = DateTime(2026, 1, 1)
          .add(const Duration(days: 3, seconds: 1));
      expect(await cache.read('k'), isNull);
    });

    test('坏 JSON 留原地不删：read 返回 null 且键仍在', () async {
      final prefs = AppPrefs.inMemory();
      prefs.debugSeed(CoverIndexCache.prefsKey, '{not valid json');
      final cache = CoverIndexCache(prefs, now: () => DateTime(2026, 1, 1));

      expect(await cache.read('k'), isNull);
      expect(prefs.containsKey(CoverIndexCache.prefsKey), isTrue,
          reason: '刻意不用 AppPrefs.readJson：脏值留原地，等下一次写入整表覆盖');
    });

    test('不是对象的 JSON（数组）也退化成空表、留原地', () async {
      final prefs = AppPrefs.inMemory();
      prefs.debugSeed(CoverIndexCache.prefsKey, '[1,2,3]');
      final cache = CoverIndexCache(prefs, now: () => DateTime(2026, 1, 1));
      expect(await cache.read('k'), isNull);
      expect(prefs.containsKey(CoverIndexCache.prefsKey), isTrue);
    });

    test('超 150 条淘汰最旧：写入 155 条 at 递增，最旧 5 条消失', () async {
      final clock = _Clock(DateTime(2026, 1, 1), stepMs: 1000);
      final cache = CoverIndexCache(AppPrefs.inMemory(), now: clock.call);

      for (var i = 0; i < 155; i += 1) {
        await cache.write(
          'k$i',
          CoverRecord(status: 'ok', path: 'p$i'),
        );
      }

      for (var i = 0; i < 5; i += 1) {
        expect(await cache.read('k$i'), isNull, reason: '最旧的 k$i 应被淘汰');
      }
      expect(await cache.read('k5'), isNotNull);
      expect((await cache.read('k5'))!.path, 'p5');
      expect(await cache.read('k154'), isNotNull);
    });

    test('淘汰上限正好 150 条', () async {
      final clock = _Clock(DateTime(2026, 1, 1), stepMs: 1000);
      final prefs = AppPrefs.inMemory();
      final cache = CoverIndexCache(prefs, now: clock.call);
      for (var i = 0; i < 155; i += 1) {
        await cache.write('k$i', CoverRecord(status: 'ok', path: 'p$i'));
      }
      final raw = await prefs.readString(CoverIndexCache.prefsKey);
      final table = jsonDecode(raw!) as Map<String, Object?>;
      expect(table.length, 150);
    });

    test('clear 清空整张表', () async {
      final prefs = AppPrefs.inMemory();
      final cache = CoverIndexCache(prefs, now: () => DateTime(2026, 1, 1));
      await cache.write('k', const CoverRecord(status: 'ok', path: 'p'));
      await cache.clear();
      expect(prefs.containsKey(CoverIndexCache.prefsKey), isFalse);
      expect(await cache.read('k'), isNull);
    });
  });

  group('CoverDiskStore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cover_disk_cache_test');
    });
    tearDown(() async {
      if (root.existsSync()) {
        await root.delete(recursive: true);
      }
    });

    test('saveFromUrl：真 PNG 落盘 → 返回存在的绝对路径，fileFor(id) 一致', () async {
      final store = CoverDiskStore(directory: root.path);
      final path = await store.saveFromUrl(
        url: 'https://example.com/a.jpg',
        id: 'abc123',
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
      );
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(path, store.fileFor('abc123'), reason: 'fileFor 与 write 命名一致');
    });

    test('ImageBytesNetwork → null', () async {
      final store = CoverDiskStore(directory: root.path);
      final path = await store.saveFromUrl(
        url: 'https://example.com/a.jpg',
        id: 'id1',
        bytes: _FakeBytes(const ImageBytesNetwork()),
      );
      expect(path, isNull);
    });

    test('ImageBytesStatus(404) → null', () async {
      final store = CoverDiskStore(directory: root.path);
      final path = await store.saveFromUrl(
        url: 'https://example.com/a.jpg',
        id: 'id2',
        bytes: _FakeBytes(const ImageBytesStatus(404)),
      );
      expect(path, isNull);
    });

    test('ImageBytesTimeout → null', () async {
      final store = CoverDiskStore(directory: root.path);
      final path = await store.saveFromUrl(
        url: 'https://example.com/a.jpg',
        id: 'id3',
        bytes: _FakeBytes(const ImageBytesTimeout()),
      );
      expect(path, isNull);
    });

    test('同一 id 重复写覆盖', () async {
      final store = CoverDiskStore(directory: root.path);
      final first = await store.saveFromUrl(
        url: 'https://example.com/a.jpg',
        id: 'same-id',
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
      );
      final second = await store.saveFromUrl(
        url: 'https://example.com/b.jpg',
        id: 'same-id',
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
      );
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second, first, reason: '同一 id 覆盖同一文件（缓存语义）');
    });

    test('坏 URL（解析不出 / 无 scheme）→ null，不发请求', () async {
      var calls = 0;
      final store = CoverDiskStore(directory: root.path);
      final path = await store.saveFromUrl(
        url: '::::not-a-url',
        id: 'id4',
        bytes: _CountingBytes(
          outcome: ImageBytesOk(onePixelPng),
          onCall: () => calls += 1,
        ),
      );
      expect(path, isNull);
      expect(calls, 0, reason: 'URL 无效时不该碰 bytes 客户端');
    });
  });

  group('ImageBytesClientImpl（MockClient，绝不打真网络）', () {
    test('404 → ImageBytesStatus(404)', () async {
      final client = ImageBytesClientImpl(
        inner: MockClient((request) async => http.Response('nope', 404)),
      );
      final outcome = await client.getBytes(
        Uri.parse('https://example.com/a.jpg'),
        timeout: kCoverDownloadTimeout,
      );
      expect(outcome, isA<ImageBytesStatus>());
      expect((outcome as ImageBytesStatus).status, 404);
    });

    test('Content-Length 8MB+1 → ImageBytesNetwork（第一刀，不读体）', () async {
      // 生产实现读 `streamed.contentLength`（真实 IO 客户端下即 wire 头里的
      // Content-Length）。MockClient.streaming 会把 handler 给的 StreamedResponse
      // 的 contentLength 参数原样透传，正好模拟「响应头声明 8MB+1、体还没读」。
      final client = ImageBytesClientImpl(
        inner: MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            Stream.value(utf8.encode('tiny body')),
            200,
            contentLength: kCoverDownloadLimitBytes + 1,
          ),
        ),
      );
      final outcome = await client.getBytes(
        Uri.parse('https://example.com/big.jpg'),
        timeout: kCoverDownloadTimeout,
      );
      expect(outcome, isA<ImageBytesNetwork>());
    });

    test('无 Content-Length 头但实际字节超限 → ImageBytesNetwork（第二刀）', () async {
      // 8MB+1 个字节的体，不带头：第一刀看不见，第二刀按实际长度挡住。
      final big = Uint8List(kCoverDownloadLimitBytes + 1);
      final client = ImageBytesClientImpl(
        inner: MockClient((request) async => http.Response.bytes(big, 200)),
      );
      final outcome = await client.getBytes(
        Uri.parse('https://example.com/big.jpg'),
        timeout: kCoverDownloadTimeout,
      );
      expect(outcome, isA<ImageBytesNetwork>());
    });

    test('正常小图 → ImageBytesOk 且字节一致', () async {
      final client = ImageBytesClientImpl(
        inner: MockClient((request) async => http.Response.bytes(
              onePixelPng,
              200,
              headers: {'content-type': 'image/png'},
            )),
      );
      final outcome = await client.getBytes(
        Uri.parse('https://example.com/a.png'),
        timeout: kCoverDownloadTimeout,
      );
      expect(outcome, isA<ImageBytesOk>());
      expect((outcome as ImageBytesOk).bytes, onePixelPng);
    });

    test('单程超时 → ImageBytesTimeout', () async {
      // 永不完成的请求：timeout 到点抛 TimeoutException（不建 Timer，
      // 不会留下 pending timer）。
      final client = ImageBytesClientImpl(
        inner: MockClient((request) async {
          await Completer<void>().future;
          throw StateError('unreachable');
        }),
      );
      final outcome = await client.getBytes(
        Uri.parse('https://example.com/slow.jpg'),
        timeout: const Duration(milliseconds: 20),
      );
      expect(outcome, isA<ImageBytesTimeout>());
    });

    // 注释裁定（task 3 指令）：
    // * 「构造后不触发任何网络」没有直接断言 —— 真内核懒建（见
    //   cover_source.dart 的注释），单测只测注入 inner 的纯 outcome 路径；
    // * 8MB 上限的「流式累计超限」分支在 MockClient 下测不了真实的流式读，
    //   按指令跳过；Content-Length 那一刀上面已钉住。
  });
}

/// 固定 outcome 的假 bytes 客户端：断言 CoverDiskStore 对每种 outcome 的处置。
class _FakeBytes implements ImageBytesClient {
  _FakeBytes(this.outcome);
  final ImageBytesOutcome outcome;

  @override
  Future<ImageBytesOutcome> getBytes(Uri url, {required Duration timeout}) =>
      Future.value(outcome);
}

/// 会计数的假 bytes 客户端：断言「无效 URL 不发请求」。
class _CountingBytes implements ImageBytesClient {
  _CountingBytes({required this.outcome, required this.onCall});
  final ImageBytesOutcome outcome;
  final void Function() onCall;

  @override
  Future<ImageBytesOutcome> getBytes(Uri url, {required Duration timeout}) {
    onCall();
    return Future.value(outcome);
  }
}
