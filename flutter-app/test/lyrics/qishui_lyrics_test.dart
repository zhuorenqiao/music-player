// test/lyrics/qishui_lyrics_test.dart
//
// 汽水歌词源的单测：建议搜索 → 分享页 _ROUTER_DATA → 行级 LRC。
// 分享页 HTML 用 jsonEncode 拼一个最小 `_ROUTER_DATA`，不碰真网络。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/page_client.dart';
import 'package:light_music/lyrics/qishui_lyrics.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart';

class JsonClient implements HttpJsonClient {
  JsonClient(this.routes);

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
      if (route.match(url)) {
        return route.reply(url);
      }
    }
    return const JsonStatus(404);
  }
}

class FakePageClient implements LyricsPageClient {
  FakePageClient(this.pages);

  final Map<String, String?> pages;
  final List<Uri> calls = [];

  @override
  Future<String?> getPage(Uri url, {required Duration timeout}) async {
    calls.add(url);
    return pages[url.queryParameters['track_id']];
  }
}

final query = normalizeQuery(title: '十年', artist: '陈奕迅', duration: 300);

String shareHtml({
  required String name,
  required String artist,
  required double duration,
  required List<(int, String)> lines,
}) {
  final data = {
    'loaderData': {
      'track_page': {
        'audioWithLyricsOption': {
          'trackName': name,
          'artistName': artist,
          'duration': duration,
          'lyrics': {
            'sentences': [
              for (final line in lines)
                {'startMs': line.$1, 'text': line.$2},
            ],
          },
        },
      },
    },
  };
  return '<html><script>window._ROUTER_DATA = ${jsonEncode(data)};</script></html>';
}

JsonOk suggestions(List<String> ids) => JsonOk({
  'sugs': [
    for (final id in ids)
      {
        'content_type': 'track',
        'entity': {
          'track': {'id': id},
        },
      },
  ],
});

void main() {
  QishuiLyrics build(
    HttpJsonClient client,
    LyricsPageClient pageClient,
  ) => QishuiLyrics(client: client, pageClient: pageClient, sleep: (_) async {});

  test('搜到正主 → 取分享页歌词，剥掉开头署名', () async {
    final client = JsonClient([
      (
        match: (u) => u.path.endsWith('/pc/sug'),
        reply: (_) => suggestions(['111', '222']),
      ),
    ]);
    final page = FakePageClient({
      '111': shareHtml(
        name: '十年',
        artist: '大头针MrLuo',
        duration: 333,
        lines: [(0, '作词 : 甲'), (15540, '翻唱版')],
      ),
      '222': shareHtml(
        name: '十年',
        artist: '陈奕迅',
        duration: 300,
        lines: [(0, '作词 : 甲'), (500, '作曲 : 乙'), (15540, '如果那两个字没有颤抖')],
      ),
    });

    final result = await build(client, page).lookup(query);
    expect(result, isNotNull);
    expect(result!.source, '汽水音乐');
    expect(result.synced, '[00:15.54]如果那两个字没有颤抖');
    expect(result.plain, isEmpty);
    // 两首候选都抓了页，但认歌规则把翻唱排除了。
    expect(page.calls, hasLength(2));
  });

  test('只有翻唱候选 → null，不拿错词', () async {
    final client = JsonClient([
      (match: (u) => u.path.endsWith('/pc/sug'), reply: (_) => suggestions(['111'])),
    ]);
    final page = FakePageClient({
      '111': shareHtml(
        name: '十年',
        artist: '大头针MrLuo',
        duration: 333,
        lines: [(15540, '翻唱版')],
      ),
    });

    final result = await build(client, page).lookup(query);
    expect(result, isNull);
  });

  test('分享页没有 sentences → null', () async {
    final client = JsonClient([
      (match: (u) => u.path.endsWith('/pc/sug'), reply: (_) => suggestions(['111'])),
    ]);
    final page = FakePageClient({
      '111': '<html><script>window._ROUTER_DATA = {"loaderData":{"track_page":'
          '{"audioWithLyricsOption":{"trackName":"十年","artistName":"陈奕迅",'
          '"duration":300,"lyrics":{"sentences":[]}}}};</script></html>',
    });

    final result = await build(client, page).lookup(query);
    expect(result, isNull);
  });

  test('建议搜索 500 → null（下一家接手）', () async {
    final client = JsonClient([
      (
        match: (u) => u.path.endsWith('/pc/sug'),
        reply: (_) => const JsonStatus(500),
      ),
    ]);
    final result = await build(client, FakePageClient({})).lookup(query);
    expect(result, isNull);
  });

  test('取消 → RequestAborted 原样上抛', () async {
    final token = CancelToken()..cancel();
    final client = JsonClient([
      (
        match: (u) => u.path.endsWith('/pc/sug'),
        reply: (_) => const JsonOk({'sugs': <Object>[]}),
      ),
    ]);
    expect(
      () => build(client, FakePageClient({})).lookup(query, cancel: token),
      throwsA(isA<RequestAborted>()),
    );
  });
}
