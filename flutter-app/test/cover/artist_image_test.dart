// test/cover/artist_image_test.dart
//
// 维基写真源的用例（对译 src/lib/artist-image.js 的语义，见
// lib/cover/artist_image.dart 头注）。json / 下载 / 时钟 / prefs 全部注入假件，
// 不碰真网络；落盘走 CoverImageWriter 真写临时目录（1×1 PNG 夹具）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/cover/artist_image.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/upstream.dart';

/// 真实的 1×1 PNG（同 test/metadata/cover_image_test.dart 的夹具）。
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

/// 假 json client：按语言（URL host 的 zh/en 前缀）回脚本结果，记录请求数
/// 与 URL / 头，供「占位歌手零请求」「缓存后不再发请求」「请求头逐字」断言。
class FakeJsonClient implements HttpJsonClient {
  FakeJsonClient(this.responses);

  /// 语言 → 该语言的 JsonOutcome；脚本里没配的语言默认 JsonStatus(404)。
  final Map<String, JsonOutcome> responses;

  int calls = 0;
  final List<Uri> urls = [];
  final List<Map<String, String>> headersSeen = [];

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async {
    calls += 1;
    urls.add(url);
    headersSeen.add(headers);
    final lang = url.host.split('.').first;
    return responses[lang] ?? const JsonStatus(404);
  }
}

/// 假下载接缝：默认回 1×1 PNG；脚本化的异常 / 自定义字节走 [failures] / [bytesFor]。
typedef FakeDownload =
    Future<Uint8List> Function(Uri url, Duration timeout);

FakeDownload fakeDownload({Map<String, Object>? failures}) {
  return (Uri url, Duration timeout) async {
    final key = '${url.host}${url.path}';
    final failure = failures?[key];
    if (failure is Exception) throw failure;
    return onePixelPng;
  };
}

/// 可推进的假时钟（TTL 用例用）。
class FakeClock {
  FakeClock(this.start);
  DateTime start;
  DateTime call() => start;
  void advance(Duration d) => start = start.add(d);
}

/// 维基 summary 的 JsonOk（带原图 / 缩略图）。
JsonOk wikiOk({String? original, String? thumb}) => JsonOk(<String, Object?>{
  if (original != null)
    'originalimage': <String, Object?>{'source': original},
  if (thumb != null) 'thumbnail': <String, Object?>{'source': thumb},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('artist_image_test');
  });
  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  group('normalizeArtistKey', () {
    test('全角空格 / 连续空格折叠成单空格，大小写归一，首尾 trim', () {
      expect(normalizeArtistKey('  Jay   Chou '), 'jay chou');
      expect(normalizeArtistKey('周\u3000杰\u3000伦'), '周 杰 伦');
      expect(normalizeArtistKey('Jay\u3000\u3000 Chou'), 'jay chou');
      expect(normalizeArtistKey('MISIA'), 'misia');
      expect(normalizeArtistKey(''), '');
    });
  });

  group('占位歌手拒绝', () {
    for (final name in <String>['', '   ', '本地文件', '未知歌手']) {
      test('"$name" → not-found 且不发任何请求', () async {
        final client = FakeJsonClient({});
        final match = await matchArtistImage(
          name,
          json: client,
          directory: root.path,
        );
        expect(match.status, 'not-found');
        expect(client.calls, 0);
      });
    }
  });

  group('pickImage', () {
    test('originalimage 优先于 thumbnail；缺原图退缩略图', () {
      expect(
        pickImage(<String, Object?>{
          'originalimage': <String, Object?>{'source': 'https://a/or.jpg'},
          'thumbnail': <String, Object?>{'source': 'https://a/th.jpg'},
        }),
        'https://a/or.jpg',
      );
      expect(
        pickImage(<String, Object?>{
          'thumbnail': <String, Object?>{'source': 'https://a/th.jpg'},
        }),
        'https://a/th.jpg',
      );
    });

    test('非法 URL（非 http）跳过，两者皆无合法图返回空串', () {
      expect(
        pickImage(<String, Object?>{
          'originalimage': <String, Object?>{'source': 'ftp://a/x.jpg'},
          'thumbnail': <String, Object?>{'source': 'https://a/th.jpg'},
        }),
        'https://a/th.jpg',
      );
      expect(
        pickImage(<String, Object?>{
          'originalimage': <String, Object?>{'source': 'data:image/png;base64,x'},
          'thumbnail': <String, Object?>{'source': 'not a url'},
        }),
        '',
      );
      expect(pickImage(null), '');
      expect(
        pickImage(<String, Object?>{
          'originalimage': 'not-a-map',
          'thumbnail': <String, Object?>{'source': 'https://a/th.jpg'},
        }),
        'https://a/th.jpg',
      );
    });
  });

  group('直连维基：语言回退与 source 文案', () {
    test('zh 命中 → ok，source=Wikipedia（zh）', () async {
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        downloadBytes: fakeDownload(),
      );
      expect(match.status, 'ok');
      expect(match.source, 'Wikipedia（zh）');
      expect(match.url, isNotNull);
      expect(client.calls, 1);
      // 端点与请求头逐字（artist-image.js:126）。
      expect(
        client.urls.single.toString(),
        'https://zh.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent('周杰伦')}',
      );
      expect(client.headersSeen.single['Api-User-Agent'],
          'light-music-player/1.0 (local dev)');
      expect(client.headersSeen.single['Accept'], 'application/json');
    });

    test('zh 404 → en 命中 → ok，source=Wikipedia（en）', () async {
      final client = FakeJsonClient({
        'zh': const JsonStatus(404),
        'en': wikiOk(original: 'https://upload.wikimedia.org/en.jpg'),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        downloadBytes: fakeDownload(),
      );
      expect(match.status, 'ok');
      expect(match.source, 'Wikipedia（en）');
      expect(client.calls, 2);
      expect(client.urls[0].host, 'zh.wikipedia.org');
      expect(client.urls[1].host, 'en.wikipedia.org');
    });

    test('两语言全 404 → not-found', () async {
      final client = FakeJsonClient({});
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        downloadBytes: fakeDownload(),
      );
      expect(match.status, 'not-found');
      expect(client.calls, 2);
    });

    test('两语言全 JsonNetwork → not-found（requestDirect :181 语义；'
        '本机 DNS 污染时稳定 miss，界面落到生成卡）', () async {
      final client = FakeJsonClient({
        'zh': const JsonNetwork(),
        'en': const JsonTimeout(),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        downloadBytes: fakeDownload(),
      );
      expect(match.status, 'not-found');
      expect(client.calls, 2);
    });

    test('JsonOk 但 originalimage/thumbnail 都缺或非法 → 换下一语言', () async {
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'ftp://x/1.jpg'),
        'en': wikiOk(original: 'https://upload.wikimedia.org/en.jpg'),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        downloadBytes: fakeDownload(),
      );
      expect(match.status, 'ok');
      expect(match.source, 'Wikipedia（en）');
      expect(client.calls, 2);
    });
  });

  group('下载与落盘', () {
    test('下载成功 → 文件落在临时目录且索引可读回', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final prefs = AppPrefs.inMemory();
      final index = ArtistIndexCache(prefs, now: clock.call);
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: '${root.path}/covers-net',
        index: index,
        downloadBytes: fakeDownload(),
      );
      expect(match.status, 'ok');
      final file = File(match.url!);
      expect(file.existsSync(), isTrue);
      expect(file.parent.path, '${root.path}/covers-net');
      // 1×1 PNG 进、PNG 字节出（CoverImageWriter 的格式约定）。
      expect(file.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      final cached = await index.read('周杰伦');
      expect(cached?.status, 'ok');
      expect(cached?.url, match.url);
      expect(cached?.source, 'Wikipedia（zh）');
    });

    test('下载失败（downloadBytes 抛异常）→ zh 失败换 en；全失败 not-found', () async {
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
        'en': wikiOk(original: 'https://upload.wikimedia.org/en.jpg'),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        downloadBytes: fakeDownload(
          failures: {
            'upload.wikimedia.org/zh.jpg': Exception('boom'),
          },
        ),
      );
      expect(match.status, 'ok');
      expect(match.source, 'Wikipedia（en）');

      final allFail = await matchArtistImage(
        '陈奕迅',
        json: FakeJsonClient({
          'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
          'en': wikiOk(original: 'https://upload.wikimedia.org/en.jpg'),
        }),
        directory: root.path,
        downloadBytes: (url, timeout) async {
          throw const SocketException('offline');
        },
      );
      expect(allFail.status, 'not-found');
    });

    test('落盘失败（writer 解不出字节）→ 换下一语言', () async {
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
        'en': wikiOk(original: 'https://upload.wikimedia.org/en.jpg'),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        // zh 的下载回不可解码字节 → writer 返回 null → 换 en。
        downloadBytes: (url, timeout) async =>
            url.path.contains('zh') ? Uint8List.fromList([1, 2, 3]) : onePixelPng,
      );
      expect(match.status, 'ok');
      expect(match.source, 'Wikipedia（en）');
    });

    test('downloadBytes 为 null（生产装配漏接）→ error(unreachable) 不写缓存', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final index = ArtistIndexCache(AppPrefs.inMemory(), now: clock.call);
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
      });
      final match = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        index: index,
      );
      expect(match.status, 'error');
      expect(match.reason, 'unreachable');
      // 错误不写缓存：索引里查不到。
      expect(await index.read('周杰伦'), isNull);
    });
  });

  group('缓存（ArtistIndexCache）', () {
    test('useCache=true：第二次命中不再发 json 请求（计数仍 1）', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final prefs = AppPrefs.inMemory();
      final index = ArtistIndexCache(prefs, now: clock.call);
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
      });
      final dir = root.path;
      final first = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: dir,
        index: index,
        downloadBytes: fakeDownload(),
      );
      expect(first.status, 'ok');
      expect(client.calls, 1);
      final second = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: dir,
        index: index,
        downloadBytes: fakeDownload(),
      );
      expect(second.status, 'ok');
      expect(second.url, first.url);
      expect(second.source, 'Wikipedia（zh）');
      expect(client.calls, 1);
    });

    test('useCache=false：跳过读仍写（第二次仍发请求，但索引已有值）', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final index = ArtistIndexCache(AppPrefs.inMemory(), now: clock.call);
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
      });
      final dir = root.path;
      await matchArtistImage(
        '周杰伦',
        json: client,
        directory: dir,
        index: index,
        downloadBytes: fakeDownload(),
        useCache: false,
      );
      expect(client.calls, 1);
      await matchArtistImage(
        '周杰伦',
        json: client,
        directory: dir,
        index: index,
        downloadBytes: fakeDownload(),
        useCache: false,
      );
      expect(client.calls, 2);
      expect((await index.read('周杰伦'))?.status, 'ok');
    });

    test('miss 条目返回 not-found；TTL 1 天，推钟过期后重新发请求并重写 miss', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final index = ArtistIndexCache(AppPrefs.inMemory(), now: clock.call);
      final client = FakeJsonClient({});
      final match1 = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        index: index,
      );
      expect(match1.status, 'not-found');
      expect(client.calls, 2);
      // TTL 内命中 miss：零请求直接 not-found。
      final cached = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        index: index,
      );
      expect(cached.status, 'not-found');
      expect(client.calls, 2);
      // 推进 1 天 + 1ms：过期，重新发请求。
      clock.advance(const Duration(days: 1, milliseconds: 1));
      final match2 = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: root.path,
        index: index,
      );
      expect(match2.status, 'not-found');
      expect(client.calls, 4);
    });

    test('命中 TTL 30 天：推 29 天仍命中，推 31 天过期', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final index = ArtistIndexCache(AppPrefs.inMemory(), now: clock.call);
      final client = FakeJsonClient({
        'zh': wikiOk(original: 'https://upload.wikimedia.org/zh.jpg'),
      });
      final dir = root.path;
      await matchArtistImage(
        '周杰伦',
        json: client,
        directory: dir,
        index: index,
        downloadBytes: fakeDownload(),
      );
      clock.advance(const Duration(days: 29));
      final fresh = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: dir,
        index: index,
        downloadBytes: fakeDownload(),
      );
      expect(fresh.status, 'ok');
      expect(client.calls, 1);
      clock.advance(const Duration(days: 2));
      final stale = await matchArtistImage(
        '周杰伦',
        json: client,
        directory: dir,
        index: index,
        downloadBytes: fakeDownload(),
      );
      expect(stale.status, 'ok');
      expect(client.calls, 2);
    });

    test('索引淘汰：超过 80 条时删最旧的溢出部分', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final prefs = AppPrefs.inMemory();
      final index = ArtistIndexCache(prefs, now: clock.call);
      // 写 81 条，每条推进 1ms：第一条（at 最小）应被淘汰。
      for (var i = 0; i < 81; i += 1) {
        await index.write(
          'artist-$i',
          ArtistImageMatch(status: 'ok', url: '/x/$i.jpg', source: 'Wikipedia（zh）'),
        );
        clock.advance(const Duration(milliseconds: 1));
      }
      expect(await index.read('artist-0'), isNull);
      final kept = await index.read('artist-1');
      expect(kept?.status, 'ok');
      expect(kept?.url, '/x/1.jpg');
      final last = await index.read('artist-80');
      expect(last?.status, 'ok');
      // 表里正好剩 80 条。
      final raw = jsonDecode(
        (await prefs.readString(ArtistIndexCache.prefsKey))!,
      ) as Map<String, Object?>;
      expect(raw.length, 80);
    });

    test('坏 JSON 留原地：读返回空表不抛，写入后整表覆盖', () async {
      final clock = FakeClock(DateTime(2026, 1, 1));
      final prefs = AppPrefs.inMemory();
      prefs.debugSeed(ArtistIndexCache.prefsKey, 'not-json{{');
      final index = ArtistIndexCache(prefs, now: clock.call);
      expect(await index.read('周杰伦'), isNull);
      await index.write(
        '周杰伦',
        const ArtistImageMatch(status: 'not-found'),
      );
      expect((await index.read('周杰伦'))?.status, 'not-found');
    });
  });
}
