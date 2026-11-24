import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/netease_lyrics.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart';

/// 按 URL 特征应答的假上游（与 lyrics_source_test 的 RoutingClient 同款）。
class RoutingClient implements HttpJsonClient {
  RoutingClient(this.routes);
  final List<
    ({bool Function(Uri) match, FutureOr<JsonOutcome> Function(Uri) reply})
  >
  routes;
  final List<Uri> calls = [];

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async {
    calls.add(url);
    for (final route in routes) {
      if (route.match(url)) return route.reply(url);
    }
    return const JsonStatus(404);
  }
}

Map<String, Object?> song({
  int id = 1,
  String name = '十年',
  int durationMs = 300000,
  List<String> artists = const ['陈奕迅'],
  List<String> alias = const [],
}) => {
  'id': id,
  'name': name,
  'duration': durationMs,
  'artists': [for (final artist in artists) {'name': artist}],
  'alias': alias,
};

Object searchResult(List<Map<String, Object?>> songs) => {
  'code': 200,
  'result': {'songs': songs},
};

Object lyricResult(String lyric, {bool nolyric = false, bool uncollected = false}) => {
  'code': 200,
  if (nolyric) 'nolyric': true,
  if (uncollected) 'uncollected': true,
  'lrc': {'lyric': lyric},
};

final query = normalizeQuery(title: '十年', artist: '陈奕迅', duration: 300);

NetEaseLyrics build(RoutingClient client) =>
    NetEaseLyrics(client: client, sleep: (_) async {});

void main() {
  test('认歌 → 取词 → synced 去掉开头署名，source 是网易云音乐', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(searchResult([song()])),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => const JsonOk({
          'code': 200,
          'lrc': {
            'lyric':
                '[00:00.00] 作词 : 林夕\n[00:00.60] 作曲 : 陈小霞\n[00:01.10] 编曲 : 陈辉阳\n[00:15.54]如果那两个字没有颤抖\n[00:19.26]我不会发现 我难受',
          },
        }),
      ),
    ]);

    final result = await build(client).lookup(query);
    expect(result, isNotNull);
    expect(result!.status, 'ok');
    expect(result.source, '网易云音乐');
    expect(result.synced, startsWith('[00:15.54]如果那两个字没有颤抖'));
    expect(result.synced, isNot(contains('作词')));
    expect(result.synced, isNot(contains('编曲')));
    expect(result.plain, '');

    // 先按「歌手 曲名」搜，命中就停：一次 search + 一次 lyric。
    expect(client.calls.map((u) => u.path).toList(), [
      '/api/search/get',
      '/api/song/lyric',
    ]);
    expect(client.calls.first.queryParameters['s'], '陈奕迅 十年');
    expect(client.calls.last.queryParameters['id'], '1');
    expect(client.calls.last.queryParameters['lv'], '1');
  });

  test('像署名的正文不误删（Open your eyes: 不是 OP 署名）', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(searchResult([song()])),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => JsonOk(
          lyricResult('[00:01.00]Open your eyes: the sky is bright\n[00:04.00]And the world wakes up'),
        ),
      ),
    ]);

    final result = await build(client).lookup(query);
    expect(result, isNotNull);
    expect(result!.synced, contains('Open your eyes: the sky is bright'));
    expect(result.synced, contains('And the world wakes up'));
  });

  test('没有时间轴 → 放 plain，synced 留空', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(searchResult([song()])),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => const JsonOk({
          'lrc': {'lyric': '第一行\n第二行'},
        }),
      ),
    ]);

    final result = await build(client).lookup(query);
    expect(result!.status, 'ok');
    expect(result.synced, '');
    expect(result.plain, '第一行\n第二行');
  });

  test('nolyric → null，同一首不重复取词，会换候选继续搜', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(searchResult([song()])),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => const JsonOk({'nolyric': true}),
      ),
    ]);

    expect(await build(client).lookup(query), isNull);
    expect(
      client.calls.where((u) => u.path.endsWith('/song/lyric')),
      hasLength(1),
    );
    // 三个候选（正方向 / 对调 / 只搜曲名）都搜过，但词只取一次。
    expect(
      client.calls.where((u) => u.path.endsWith('/search/get')),
      hasLength(3),
    );
  });

  test('认不到（歌名对不上 / 时长差太多）→ null，且不请求取词', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(
          searchResult([
            song(name: '十年之后', durationMs: 200000),
            // 歌名全等但歌手、时长都对不上：只能靠「只搜曲名」那一路的时长证据，
            // 这里把时长也写歪，确保整次认歌失败。
            song(id: 2, name: '十年', artists: ['别人'], durationMs: 240000),
          ]),
        ),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => const JsonOk({
          'lrc': {'lyric': '[00:01]不该被取到'},
        }),
      ),
    ]);

    expect(await build(client).lookup(query), isNull);
    expect(
      client.calls.where((u) => u.path.endsWith('/song/lyric')),
      isEmpty,
    );
  });

  test('上游 500 → null（不抛给调用方，交给 LRCLIB）', () async {
    final client = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonStatus(500)),
    ]);
    expect(await build(client).lookup(query), isNull);
  });

  test('取消 → 抛 RequestAborted', () async {
    final token = CancelToken()..cancel();
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(searchResult([song()])),
      ),
    ]);
    expect(
      () => build(client).lookup(query, cancel: token),
      throwsA(isA<RequestAborted>()),
    );
    expect(client.calls, isEmpty);
  });

  test('搜不到时退到「只搜曲名」：歌手字段写成 A / B 也能认到', () async {
    final fancy = normalizeQuery(
      title: '十年',
      artist: '陈奕迅 / 杨千嬅',
      duration: 300,
    );
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (u) => u.queryParameters['s'] == '十年'
            ? JsonOk(searchResult([song()]))
            : const JsonStatus(404),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => const JsonOk({
          'lrc': {'lyric': '[00:15.54]如果那两个字没有颤抖'},
        }),
      ),
    ]);

    final result = await build(client).lookup(fancy);
    expect(result!.synced, '[00:15.54]如果那两个字没有颤抖');
    expect(
      client.calls
          .where((u) => u.path.endsWith('/search/get'))
          .last
          .queryParameters['s'],
      '十年',
    );
  });

  test('别名命中：网易云的歌名是繁体/别名，alias 里才有我们认识的写法', () async {
    final english = normalizeQuery(
      title: 'Yellow',
      artist: 'Coldplay',
      duration: 266,
    );
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(
          searchResult([
            song(
              id: 7,
              name: '黄色',
              durationMs: 266000,
              artists: ['Coldplay'],
              alias: ['Yellow'],
            ),
          ]),
        ),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => const JsonOk({
          'lrc': {'lyric': '[00:01]Look at the stars'},
        }),
      ),
    ]);

    final result = await build(client).lookup(english);
    expect(result, isNotNull);
    expect(result!.synced, '[00:01]Look at the stars');
  });

  test('署名全被剥掉（只剩制作名单）→ null，不把名单当歌词', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search/get'),
        reply: (_) => JsonOk(searchResult([song()])),
      ),
      (
        match: (u) => u.path.endsWith('/song/lyric'),
        reply: (_) => const JsonOk({
          'lrc': {'lyric': '[00:00.00] 作词 : 甲\n[00:00.50] 作曲 : 乙'},
        }),
      ),
    ]);

    expect(await build(client).lookup(query), isNull);
  });

  test('空正文 / lrc 缺失 → null', () async {
    for (final payload in <Object?>[
      lyricResult('   '),
      const {'code': 200},
      const {'code': 200, 'lrc': <String, Object?>{}},
    ]) {
      final client = RoutingClient([
        (
          match: (u) => u.path.endsWith('/search/get'),
          reply: (_) => JsonOk(searchResult([song()])),
        ),
        (match: (u) => u.path.endsWith('/song/lyric'), reply: (_) => JsonOk(payload)),
      ]);
      expect(await build(client).lookup(query), isNull);
    }
  });
}
