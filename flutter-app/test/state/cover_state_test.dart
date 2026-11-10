// test/state/cover_state_test.dart
//
// M2b T6：CoverState 显示层——四级兜底顺序、去重、写真负缓存、预取节奏。
// 替身全注入（假 json / 假 bytes / 真临时目录落盘），绝不打网络。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/cover/cover_disk_cache.dart';
import 'package:light_music/cover/cover_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/state/cover_state.dart';

final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
  'iZk9HQAAAABJRU5ErkJggg==',
);

JsonOutcome _searchOk({
  String trackName = '十年',
  String artistName = '陈奕迅',
  String artwork = 'https://is.example/100x100bb.jpg',
}) => JsonOk(<String, Object?>{
  'results': <Object?>[
    <String, Object?>{
      'trackName': trackName,
      'artistName': artistName,
      'trackTimeMillis': 226000,
      'artworkUrl100': artwork,
    },
  ],
});

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

/// 维基按 404 拒绝（写真链路走 not-found），iTunes 按 [_searchOk] 命中。
JsonOutcome _wikiNotFound(Uri url) =>
    url.host.contains('wikipedia') ? const JsonStatus(404) : _searchOk();

/// 反复泵事件队列直到 [done] 为真（或超时断言失败）。
///
/// matchFor 是 void 同步入口 + 内部 async，且 ok 链路的落盘（CoverImageWriter
/// → dart:ui 解码 / 编码）要等原生图像回调，泵的次数没法静态数 ——
/// pumpEventQueue 固定次数会偶发早退（写真落盘还没落完测试就过了或 tearDown
/// 撞上文件句柄）。这里按谓词轮询，天然对齐「该到的都到了」再断言。
Future<void> _settleUntil(bool Function() done, {int limit = 100}) async {
  for (var i = 0; i < limit; i++) {
    if (done()) return;
    await pumpEventQueue();
  }
  fail('_settleUntil: 条件迟迟不满足（泵了 $limit 轮）');
}

CoverState _state({
  required _FakeJson json,
  required _FakeBytes bytes,
  required String directory,
  Future<void> Function(Duration)? sleep,
}) {
  return CoverState(
    json: json,
    bytes: bytes,
    diskStore: CoverDiskStore(directory: directory),
    artistImageDirectory: directory,
    sleep: sleep ?? (_) async {},
  );
}

void main() {
  // 与 cover_disk_cache_test.dart 同一条裁定：`dart:ui` 的图像编解码（真
  // 落盘走 CoverImageWriter）需要引擎绑定，main 开头初始化
  // `TestWidgetsFlutterBinding`、用普通 `test()`（不是 testWidgets），避免
  // FakeAsync 把 `Picture.toImage` 的原生回调卡住。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cover_state-');
  });
  tearDown(() async {
    // 写盘的句柄可能比最后一个 await 晚一拍关掉（Windows 上删除会撞
    // errno 32）：先泵两轮事件队列再删，删不掉也不把本组 tearDown 炸掉。
    await pumpEventQueue();
    await pumpEventQueue();
    try {
      if (root.existsSync()) await root.delete(recursive: true);
    } on FileSystemException {
      // 留给系统临时目录清理；下轮 setUp 建的是新目录，不影响后续用例。
    }
  });

  group('coverForDisplay 四级顺序', () {
    test('cover 非空 → 直接返回内嵌路径', () {
      final state = _state(
        json: _FakeJson((url) => _searchOk()),
        bytes: _FakeBytes(const ImageBytesNetwork()),
        directory: root.path,
      );
      expect(
        state.coverForDisplay(
          cover: '/embedded/a.jpg',
          artist: '陈奕迅',
          title: '十年',
          trackId: 't1',
        ),
        '/embedded/a.jpg',
      );
    });

    test('cover 空 + matched 有 → matched 路径', () {
      final state = _state(
        json: _FakeJson((url) => _searchOk()),
        bytes: _FakeBytes(const ImageBytesNetwork()),
        directory: root.path,
      );
      state.debugSeedMatched('t1', '/net/a.jpg');
      expect(
        state.coverForDisplay(
          cover: '',
          artist: '陈奕迅',
          title: '十年',
          trackId: 't1',
        ),
        '/net/a.jpg',
      );
    });

    test('matched 无 + photo 有 → photo 路径', () {
      final state = _state(
        json: _FakeJson((url) => _searchOk()),
        bytes: _FakeBytes(const ImageBytesNetwork()),
        directory: root.path,
      );
      state.debugSeedPhoto('陈奕迅', '/wiki/p.jpg');
      expect(
        state.coverForDisplay(
          cover: '',
          artist: '陈奕迅',
          title: '十年',
          trackId: 't1',
        ),
        '/wiki/p.jpg',
      );
    });

    test('全无 → \'\'（生成卡由显示层现画）', () {
      final state = _state(
        json: _FakeJson((url) => _searchOk()),
        bytes: _FakeBytes(const ImageBytesNetwork()),
        directory: root.path,
      );
      expect(
        state.coverForDisplay(
          cover: '',
          artist: '陈奕迅',
          title: '十年',
          trackId: 't1',
        ),
        '',
      );
    });

    test('photo 负缓存不挡生成卡', () {
      final state = _state(
        json: _FakeJson((url) => _searchOk()),
        bytes: _FakeBytes(const ImageBytesNetwork()),
        directory: root.path,
      );
      state.debugSeedPhoto('陈奕迅', null);
      expect(
        state.coverForDisplay(
          cover: '',
          artist: '陈奕迅',
          title: '十年',
          trackId: 't1',
        ),
        '',
      );
    });
  });

  group('matchFor', () {
    test('ok → matched 记录 + 通知一次，绝不写 track 层', () async {
      var notified = 0;
      final json = _FakeJson(_wikiNotFound);
      final bytes = _FakeBytes(ImageBytesOk(onePixelPng));
      final state = CoverState(
        json: json,
        bytes: bytes,
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      state.addListener(() => notified++);
      state.matchFor((
        title: '十年',
        artist: '陈奕迅',
        duration: 226,
      ), trackId: 't1');
      // matchFor 是 void 同步入口 + 内部 async：按谓词泵到落盘路径到位。
      await _settleUntil(() => state.matchedPathFor('t1') != null);
      expect(state.matchedPathFor('t1'), isNotNull);
      expect(notified, greaterThanOrEqualTo(1));
    });

    test('needsCoverMatch 为假（已 matched）→ 跳过，不发请求', () async {
      final json = _FakeJson(_wikiNotFound);
      final state = CoverState(
        json: json,
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      state.debugSeedMatched('t1', '/net/a.jpg');
      state.matchFor((
        title: '十年',
        artist: '陈奕迅',
        duration: 226,
      ), trackId: 't1');
      await pumpEventQueue();
      expect(json.requests, isEmpty);
    });

    test('同步连调两次同 trackId → 去重只发一轮', () async {
      final json = _FakeJson(_wikiNotFound);
      final state = CoverState(
        json: json,
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      state.matchFor((
        title: '十年',
        artist: '陈奕迅',
        duration: 226,
      ), trackId: 't1');
      state.matchFor((
        title: '十年',
        artist: '陈奕迅',
        duration: 226,
      ), trackId: 't1');
      await _settleUntil(() => json.requests.length >= 2);
      expect(json.requests.length, 2, reason: 'iTunes 两区各一次，去重挡掉第二轮');
    });

    test('not-found → 静默下沉写真：维基命中则 photo 到位', () async {
      final json = _FakeJson((url) {
        if (url.host.contains('wikipedia')) {
          return JsonOk(<String, Object?>{
            'originalimage': <String, Object?>{
              'source': 'https://wiki.example/p.jpg',
            },
          });
        }
        return const JsonOk(<String, Object?>{'results': <Object?>[]});
      });
      final bytes = _FakeBytes(ImageBytesOk(onePixelPng));
      final state = CoverState(
        json: json,
        bytes: bytes,
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      state.matchFor((
        title: '十年',
        artist: '陈奕迅',
        duration: 226,
      ), trackId: 't1');
      await _settleUntil(() => state.photoFor('陈奕迅') != null);
      expect(state.matchedPathFor('t1'), isNull, reason: 'iTunes 未命中');
      expect(state.photoFor('陈奕迅'), isNotNull, reason: '写真落盘到位');
      expect(File(state.photoFor('陈奕迅')!).existsSync(), isTrue);
    });

    test('not-found 且维基也 404 → photo 负缓存', () async {
      // iTunes 空 results → not-found；维基 zh/en 都 404 → not-found。
      final json = _FakeJson((url) {
        if (url.host.contains('wikipedia')) return const JsonStatus(404);
        return const JsonOk(<String, Object?>{'results': <Object?>[]});
      });
      final state = CoverState(
        json: json,
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      state.matchFor((
        title: '十年',
        artist: '陈奕迅',
        duration: 226,
      ), trackId: 't1');
      await _settleUntil(() => state.hasPhotoNegativeCache('陈奕迅'));
      expect(state.matchedPathFor('t1'), isNull);
      expect(state.hasPhotoNegativeCache('陈奕迅'), isTrue);
    });
  });

  group('requestArtistPhoto', () {
    test('同歌手第二次不再发（内存负缓存挡住）', () async {
      final json = _FakeJson(_wikiNotFound);
      final state = CoverState(
        json: json,
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      await state.requestArtistPhoto('陈奕迅');
      final calls = json.requests.length;
      await state.requestArtistPhoto('陈奕迅');
      expect(json.requests.length, calls);
      expect(state.hasPhotoNegativeCache('陈奕迅'), isTrue);
    });

    test('bytes 全失败 → 维基两语言都算失败 → not-found 负缓存', () async {
      // T4 语义：网络类失败在 requestDirect 内归 not-found（写负缓存），
      // error(unreachable) 只有「有图可下但没接下载通道」才产出 —— 而
      // CoverState 恒接 downloadBytes，该档经本层不可达（对齐 React：
      // matchArtistImage 的 catch-all 也只在直连整体异常时触发）。
      final state = CoverState(
        json: _FakeJson(
          (url) => url.host.contains('wikipedia')
              ? JsonOk(<String, Object?>{
                  'originalimage': <String, Object?>{
                    'source': 'https://wiki.example/p.jpg',
                  },
                })
              : const JsonOk(<String, Object?>{'results': <Object?>[]}),
        ),
        bytes: _FakeBytes(const ImageBytesNetwork()),
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      await state.requestArtistPhoto('陈奕迅');
      expect(state.hasPhotoNegativeCache('陈奕迅'), isTrue);
      expect(state.photoFor('陈奕迅'), isNull);
    });
  });

  group('prefetchCovers', () {
    test('跳过已 matched 的；其余逐首 400ms 串行；ok 补齐 matched', () async {
      final durations = <Duration>[];
      // 按请求 term 回显：iTunes 对每首歌都命中（term 含歌名，打分拿
      // 歌名全等 30 + 歌手全等 25 = 55 分 > 18 门槛）。
      final json = _FakeJson((url) {
        final term = url.queryParameters['term'] ?? '';
        return _searchOk(
          trackName: term.contains('十年')
              ? '十年'
              : term.contains('富士山下')
              ? '富士山下'
              : '浮夸',
        );
      });
      final state = CoverState(
        json: json,
        bytes: _FakeBytes(ImageBytesOk(onePixelPng)),
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (d) async => durations.add(d),
      );
      state.debugSeedMatched('t0', '/already.jpg');
      await state.prefetchCovers(const [
        (title: '十年', artist: '陈奕迅', duration: 226.0, trackId: 't0'),
        (title: '富士山下', artist: '陈奕迅', duration: 258.0, trackId: 't1'),
        (title: '浮夸', artist: '陈奕迅', duration: 260.0, trackId: 't2'),
      ]);
      expect(
        durations.length,
        2,
        reason: '已 matched 的 continue 在 sleep 之前（covers.tsx:164-166 对译）',
      );
      for (final d in durations) {
        expect(d, const Duration(milliseconds: 400));
      }
      expect(
        state.matchedPathFor('t0'),
        '/already.jpg',
        reason: '已 matched 的跳过，不被覆盖',
      );
      expect(state.matchedPathFor('t1'), isNotNull);
      expect(state.matchedPathFor('t2'), isNotNull);
    });
  });

  group('forget', () {
    test('清 matched 并通知', () {
      var notified = 0;
      final state = CoverState(
        json: _FakeJson((url) => _searchOk()),
        bytes: _FakeBytes(const ImageBytesNetwork()),
        diskStore: CoverDiskStore(directory: root.path),
        artistImageDirectory: root.path,
        sleep: (_) async {},
      );
      state.addListener(() => notified++);
      state.debugSeedMatched('t1', '/net/a.jpg');
      state.forget('t1');
      expect(state.matchedPathFor('t1'), isNull);
      expect(notified, 1);
      state.forget('t1');
      expect(notified, 1, reason: '已空时 forget 不通知');
    });
  });
}
