// test/lyrics/translate_source_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/translate_cache.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';

class FakeNetEase implements HttpJsonClient {
  FakeNetEase({this.search = const {}, this.lyric = const {}});

  /// keyword → 搜索结果里的 songs
  final Map<String, List<Map<String, Object?>>> search;

  /// song id → 译文响应
  final Map<int, Map<String, Object?>> lyric;
  final List<Uri> calls = [];

  /// 每次请求实际带出去的请求头与单程超时：brief 的断言「headers 里有 UA」
  /// 原本写在 getJson 内部，但 `_FlakyClient` 的委托会把 headers 换成空表，
  /// 那条 expect 会在与它无关的用例里炸；改成记录后由专门一条用例断言，
  /// 覆盖面只增不减（还多钉了「无 Referer / Cookie / Origin」与 8000ms）。
  final List<Map<String, String>> headersSeen = [];
  final List<Duration> timeoutsSeen = [];

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async {
    calls.add(url);
    headersSeen.add(Map<String, String>.of(headers));
    timeoutsSeen.add(timeout);
    if (url.path.endsWith('/search/get')) {
      final songs = search[url.queryParameters['s']] ?? const [];
      return JsonOk({
        'result': {'songs': songs},
      });
    }
    if (url.path.endsWith('/song/lyric')) {
      final id = int.parse(url.queryParameters['id']!);
      return JsonOk(lyric[id] ?? <String, Object?>{});
    }
    return const JsonStatus(404);
  }
}

Map<String, Object?> songJson({
  int id = 1,
  String name = 'Yesterday',
  int duration = 125000,
  List<String> artists = const ['The Beatles'],
}) => {
  'id': id,
  'name': name,
  'duration': duration,
  'artists': [
    for (final a in artists) {'name': a},
  ],
};

void main() {
  late Directory dir;
  late TranslationDiskCache disk;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('translate-source-');
    disk = TranslationDiskCache(directory: dir.path);
  });
  tearDown(() => dir.delete(recursive: true));

  TranslateSource sourceWith(HttpJsonClient client, {AppPrefs? prefs}) =>
      TranslateSource(
        client: client,
        disk: disk,
        index: TranslationIndexCache(prefs ?? AppPrefs.inMemory()),
      );

  test('认到歌 → 取 tlyric → ok，source 是「网易云译文库（人工翻译）」', () async {
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'lrc': {'lyric': '[00:01]Yesterday'},
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    final result = await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
    expect(result.translatedLyrics, '[00:01]昨天');
    expect(result.originalLyrics, '[00:01]Yesterday');
    expect(result.source, '网易云译文库（人工翻译）');
  });

  test('关键词是「歌手 曲名」，歌手在前', () async {
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
    );
    await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    final search = client.calls.firstWhere(
      (u) => u.path.endsWith('/search/get'),
    );
    expect(search.queryParameters['s'], 'The Beatles Yesterday');
    expect(search.queryParameters['type'], '1');
    expect(search.queryParameters['limit'], '20');
  });

  test('占位歌手（含大小写差异）不参与关键词', () async {
    // brief 原写只给 search、不给 lyric，那样只会拿到空 tlyric → not-found，
    // 「status 是 ok」这条断言在正确实现上必红。补上译文响应，其余一字不动。
    final client = FakeNetEase(
      search: {
        'Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    final result = await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'Unknown', duration: 125);
    expect(result.status, 'ok');
    // 占位歌手被清空后 keyword 只剩曲名（大小写不敏感是判定口径）
    final keywords = client.calls
        .where((u) => u.path.endsWith('/search/get'))
        .map((u) => u.queryParameters['s'])
        .toList();
    expect(keywords, everyElement('Yesterday'));
  });

  test('tlyric 缺失 / 空白 → not-found + no-translation', () async {
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'lrc': {'lyric': '[00:01]Yesterday'},
          'tlyric': {'lyric': '  '},
        },
      },
    );
    final result = await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'not-found');
    expect(result.reason, 'no-translation');
  });

  test('lrc.lyric 为空不影响 ok', () async {
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    final result = await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
    expect(result.originalLyrics, '');
  });

  test('所有候选都搜不到 → not-found + song-not-matched', () async {
    final client = FakeNetEase();
    final result = await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'not-found');
    expect(result.reason, 'song-not-matched');
    // 原方向 + 对调方向 + 只搜歌名（去重后追加，可能重复一次）
    expect(client.calls.length, greaterThanOrEqualTo(2));
  });

  test('某次搜索抛错但后一个候选命中 → 仍成功', () async {
    var call = 0;
    // brief 只给了 search、没给 lyric，那样命中歌之后取 tlyric 拿到空表
    // → not-found + no-translation，「status 是 ok」必红。补上译文响应，其余不动。
    final client = FakeNetEase(
      search: {
        'Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    final flaky = _FlakyClient((url) {
      call += 1;
      if (call == 1) return const JsonStatus(500);
      return client.getJson(
        url,
        timeout: const Duration(seconds: 1),
        headers: const {
          'Accept': 'application/json',
          'User-Agent': 'light-music-react/1.0 (+vite dev middleware)',
        },
      );
    });
    final result = await TranslateSource(
      client: flaky,
      disk: disk,
      index: TranslationIndexCache(AppPrefs.inMemory()),
    ).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
  });

  test('全部候选都抛错 → error，reason 是四类之一，且不写缓存', () async {
    final prefs = AppPrefs.inMemory();
    final client = _FlakyClient((_) => const JsonStatus(500));
    final result = await TranslateSource(
      client: client,
      disk: disk,
      index: TranslationIndexCache(prefs),
    ).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'error');
    expect(result.reason, 'upstream');
    expect(result.message, '服务暂时不可用（HTTP 500）');
    expect(await prefs.readString(TranslationIndexCache.prefsKey), isNull);
  });

  test('trackName 为空 → empty-query，不发请求', () async {
    final client = FakeNetEase();
    final result = await sourceWith(client)
        .fetch(title: '   ', artist: '', duration: 0);
    expect(result.status, 'empty-query');
    expect(client.calls, isEmpty);
  });

  test('缓存命中直接返回；useCache:false 跳过读但仍写', () async {
    final prefs = AppPrefs.inMemory();
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    final source = sourceWith(client, prefs: prefs);
    await source.fetch(
      title: 'Yesterday',
      artist: 'The Beatles',
      duration: 125,
    );
    final callsAfterFirst = client.calls.length;
    await source.fetch(
      title: 'Yesterday',
      artist: 'The Beatles',
      duration: 125,
    );
    expect(client.calls.length, callsAfterFirst);
    await source.fetch(
      title: 'Yesterday',
      artist: 'The Beatles',
      duration: 125,
      useCache: false,
    );
    expect(client.calls.length, greaterThan(callsAfterFirst));
  });

  test('上游抛错时回退过期磁盘缓存，source 追加「（离线缓存）」', () async {
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    final key = TranslationDiskCache.keyFor(
      title: 'Yesterday',
      artist: 'The Beatles',
      duration: 125,
    );
    File(
      '${dir.path}/$key.json',
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));

    final failing = _FlakyClient((_) => const JsonTimeout());
    final result = await TranslateSource(
      client: failing,
      disk: disk,
      index: TranslationIndexCache(AppPrefs.inMemory()),
    ).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'ok');
    expect(result.translatedLyrics, '[00:01]昨天');
    expect(result.source, '网易云译文库（人工翻译）（离线缓存）');
  });

  test('取消 → 抛 RequestAborted', () async {
    final token = CancelToken()..cancel();
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
    );
    await expectLater(
      sourceWith(client).fetch(
        title: 'Yesterday',
        artist: 'The Beatles',
        duration: 125,
        cancel: token,
      ),
      throwsA(isA<RequestAborted>()),
    );
  });

  // -- brief 之外补的用例（各对应一个能红的变异）----------------------------

  test('请求头：Accept + 本仓库 UA，且无 Referer / Cookie / Origin', () async {
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    await sourceWith(client)
        .fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(client.headersSeen, isNotEmpty);
    for (final headers in client.headersSeen) {
      expect(headers['Accept'], 'application/json');
      expect(
        headers['User-Agent'],
        'light-music-react/1.0 (+vite dev middleware)',
      );
      expect(headers.containsKey('Referer'), isFalse);
      expect(headers.containsKey('Cookie'), isFalse);
      expect(headers.containsKey('Origin'), isFalse);
    }
    // 译文链路单程预算 8000ms（music-api.ts:53），不是歌词的 12s / 26s。
    expect(client.timeoutsSeen.toSet(), {const Duration(seconds: 8)});
  });

  test('磁盘缓存写在 v2 键上（normalize 后的字段），内存层存短字段', () async {
    final prefs = AppPrefs.inMemory();
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'lrc': {'lyric': '[00:01]Yesterday'},
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    await sourceWith(
      client,
      prefs: prefs,
    ).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);

    final key = TranslationDiskCache.keyFor(
      title: 'Yesterday',
      artist: 'The Beatles',
      duration: 125,
    );
    final file = File('${dir.path}/$key.json');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('translatedLyrics'));
    // 索引命中应与磁盘同结论（source 取缓存里那份）
    final cached = await TranslationIndexCache(prefs)
        .read('yesterday|the beatles|125');
    expect(cached!.status, 'ok');
  });

  test('not-found 也写缓存：索引记 reason、磁盘记长字段', () async {
    final prefs = AppPrefs.inMemory();
    final client = FakeNetEase();
    await sourceWith(
      client,
      prefs: prefs,
    ).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    final cached = await TranslationIndexCache(prefs)
        .read('yesterday|the beatles|125');
    expect(cached!.status, 'not-found');
    expect(cached.reason, 'song-not-matched');

    final key = TranslationDiskCache.keyFor(
      title: 'Yesterday',
      artist: 'The Beatles',
      duration: 125,
    );
    final file = File('${dir.path}/$key.json');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('song-not-matched'));
  });

  test('索引里的 not-found 命中时直接返回原因，不再打网络', () async {
    final prefs = AppPrefs.inMemory();
    await TranslationIndexCache(prefs).write(
      'yesterday|the beatles|125',
      const TranslationRecord(status: 'not-found', reason: 'no-translation'),
    );
    final client = FakeNetEase(
      search: {
        'The Beatles Yesterday': [songJson()],
      },
      lyric: {
        1: {
          'tlyric': {'lyric': '[00:01]昨天'},
        },
      },
    );
    final result = await sourceWith(
      client,
      prefs: prefs,
    ).fetch(title: 'Yesterday', artist: 'The Beatles', duration: 125);
    expect(result.status, 'not-found');
    expect(result.reason, 'no-translation');
    // not-found 不带 source —— 与「新结果」那条路径同口径（那里显式给 ''）；
    // 索引记录自己的 source 默认值是 '网易云译文库'，不能漏到结果里。
    expect(result.source, '');
    expect(client.calls, isEmpty);
  });
}

class _FlakyClient implements HttpJsonClient {
  _FlakyClient(this.handler);

  // brief 原写 `Future<JsonOutcome> Function(Uri)`，但三个用例的闭包分别返回
  // 同步的 `JsonStatus(500)` / `JsonTimeout()` / 一个 `Future`（委托给 FakeNetEase），
  // 同步那两处与 `Future<JsonOutcome>` 不兼容，编译期就挂。改成 FutureOr：
  // 三种写法都能原样保留，`Future.sync` 顺带把同步返回也归一成 Future。
  final FutureOr<JsonOutcome> Function(Uri url) handler;

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) => Future<JsonOutcome>.sync(() => handler(url));
}
