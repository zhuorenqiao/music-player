// test/cover/cover_match_test.dart
//
// M2b T5：matchCover 编排——索引命中 / 两区搜索 / 落盘 / 降级语义。
// 替身全注入，绝不打网络；落盘用真临时目录 + 真 1×1 PNG。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/cover/cover_disk_cache.dart';
import 'package:light_music/cover/cover_source.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/upstream.dart';

final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

class _FakeJson implements HttpJsonClient {
  _FakeJson(this.handler);

  final JsonOutcome Function(Uri url) handler;
  final List<Uri> requests = <Uri>[];

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async {
    requests.add(url);
    return handler(url);
  }
}

class _FakeBytes implements ImageBytesClient {
  _FakeBytes(this.outcome);

  final ImageBytesOutcome outcome;
  int calls = 0;

  @override
  Future<ImageBytesOutcome> getBytes(
    Uri url, {
    required Duration timeout,
  }) async {
    calls += 1;
    return outcome;
  }
}

JsonOutcome _searchOk({
  String trackName = '十年',
  String artistName = '陈奕迅',
  String artwork = 'https://is.example/100x100bb.jpg',
  int millis = 226000,
}) =>
    JsonOk(<String, Object?>{
      'results': <Object?>[
        <String, Object?>{
          'trackName': trackName,
          'artistName': artistName,
          'trackTimeMillis': millis,
          'artworkUrl100': artwork,
        },
      ],
    });

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cover_match-');
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  const track = (
    title: '十年',
    artist: '陈奕迅',
    duration: 226.0,
  );

  test('ok 全链路：两区搜索 → 下载落盘 → 索引可读回', () async {
    final prefs = AppPrefs.inMemory();
    final index = CoverIndexCache(prefs);
    final json = _FakeJson((url) => _searchOk());
    final bytes = _FakeBytes(ImageBytesOk(onePixelPng));
    final match = await matchCover(
      track,
      json: json,
      bytes: bytes,
      diskStore: CoverDiskStore(directory: root.path),
      index: index,
    );
    expect(match.status, 'ok');
    expect(match.source, 'iTunes');
    expect(match.url, isNotNull);
    expect(File(match.url!).existsSync(), isTrue);
    // 索引读回同一路径。
    final cached = await index.read('十年|陈奕迅|226');
    expect(cached, isNotNull);
    expect(cached!.path, match.url);
  });

  test('第二次同曲目：索引命中，不再发 json 请求', () async {
    final index = CoverIndexCache(AppPrefs.inMemory());
    final json = _FakeJson((url) => _searchOk());
    final bytes = _FakeBytes(ImageBytesOk(onePixelPng));
    final common = (
      json: json,
      bytes: bytes,
      diskStore: CoverDiskStore(directory: root.path),
      index: index,
    );
    final first = await matchCover(track, json: common.json, bytes: common.bytes, diskStore: common.diskStore, index: common.index);
    final calls = json.requests.length;
    final second = await matchCover(track, json: common.json, bytes: common.bytes, diskStore: common.diskStore, index: common.index);
    expect(second.status, 'ok');
    expect(second.url, first.url);
    expect(json.requests.length, calls, reason: '索引命中不再打搜索');
  });

  test('搜索 not-found → 返回 not-found 且索引写 miss', () async {
    final prefs = AppPrefs.inMemory();
    final index = CoverIndexCache(prefs);
    final match = await matchCover(
      track,
      json: _FakeJson((url) => const JsonOk(<String, Object?>{'results': <Object?>[]})),
      bytes: _FakeBytes(const ImageBytesNetwork()),
      diskStore: CoverDiskStore(directory: root.path),
      index: index,
    );
    expect(match.status, 'not-found');
    final cached = await index.read('十年|陈奕迅|226');
    expect(cached, isNotNull);
    expect(cached!.isOk, isFalse);
  });

  test('搜索命中但下载失败 → not-found（不返回半成品）且索引写 miss', () async {
    final index = CoverIndexCache(AppPrefs.inMemory());
    final match = await matchCover(
      track,
      json: _FakeJson((url) => _searchOk()),
      bytes: _FakeBytes(const ImageBytesNetwork()),
      diskStore: CoverDiskStore(directory: root.path),
      index: index,
    );
    expect(match.status, 'not-found');
    final cached = await index.read('十年|陈奕迅|226');
    expect(cached!.isOk, isFalse);
  });

  test('搜索全 miss（JsonNetwork 当 miss）→ not-found 且不写缓存', () async {
    final prefs = AppPrefs.inMemory();
    final index = CoverIndexCache(prefs);
    final match = await matchCover(
      track,
      json: _FakeJson((url) => const JsonNetwork()),
      bytes: _FakeBytes(const ImageBytesNetwork()),
      diskStore: CoverDiskStore(directory: root.path),
      index: index,
    );
    // itunesSearch 的语义：单区失败当 miss 继续另一区，两区全 miss →
    // not-found（T2 裁定，对齐 React jsonpSearch 把网络错解析为 null）。
    // not-found 属于「问过没有」，写索引 miss。
    expect(match.status, 'not-found');
    final cached = await index.read('十年|陈奕迅|226');
    expect(cached, isNotNull);
    expect(cached!.isOk, isFalse);
  });

  test('useCache:false 跳过读仍写', () async {
    final index = CoverIndexCache(AppPrefs.inMemory());
    final bytes = _FakeBytes(ImageBytesOk(onePixelPng));
    final json = _FakeJson((url) => _searchOk());
    final first = await matchCover(
      track,
      json: json,
      bytes: bytes,
      diskStore: CoverDiskStore(directory: root.path),
      index: index,
    );
    final callsAfterFirst = json.requests.length;
    final second = await matchCover(
      track,
      json: json,
      bytes: bytes,
      diskStore: CoverDiskStore(directory: root.path),
      index: index,
      useCache: false,
    );
    expect(second.status, 'ok');
    expect(json.requests.length, greaterThan(callsAfterFirst),
        reason: '绕过索引重新搜索');
    expect(second.url, first.url, reason: '同 id 覆盖同一文件');
  });

  test('空查询 → empty-query，不发请求', () async {
    final json = _FakeJson((url) => _searchOk());
    final match = await matchCover(
      (title: '  ', artist: '', duration: 0),
      json: json,
      bytes: _FakeBytes(const ImageBytesNetwork()),
      diskStore: CoverDiskStore(directory: root.path),
    );
    expect(match.status, 'empty-query');
    expect(json.requests, isEmpty);
  });
}
