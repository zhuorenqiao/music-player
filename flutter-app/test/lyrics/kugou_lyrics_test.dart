// test/lyrics/kugou_lyrics_test.dart
//
// 酷狗歌词源的单测：搜歌 → krcs 候选 → download 的 base64 LRC。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/kugou_lyrics.dart';
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

final query = normalizeQuery(title: '十年', artist: '陈奕迅', duration: 300);

JsonOk searchResult(List<Map<String, Object>> songs) => JsonOk({
  'status': 1,
  'data': {'info': songs},
});

JsonOk candidates() => const JsonOk({
  'candidates': [
    {
      'id': '9',
      'accesskey': 'AK',
      'song': '十年',
      'singer': '陈奕迅',
      'duration': 300000,
    },
  ],
});

JsonOk download(String content) => JsonOk({'content': content});

String encodedLrc(String lrc) => base64Encode(utf8.encode(lrc));

void main() {
  KugouLyrics build(HttpJsonClient client) =>
      KugouLyrics(client: client, sleep: (_) async {});

  test('搜到正主 → 下载 LRC，丢掉元信息并剥署名', () async {
    final client = JsonClient([
      (
        match: (u) => u.host == 'mobiles.kugou.com',
        reply: (_) => searchResult([
          {'songname': '十年', 'singername': '陈奕迅', 'duration': 300, 'hash': 'H1'},
          {'songname': '十年', 'singername': '刘若英', 'duration': 300, 'hash': 'H2'},
        ]),
      ),
      (match: (u) => u.host == 'krcs.kugou.com', reply: (_) => candidates()),
      (
        match: (u) => u.host == 'lyrics.kugou.com',
        reply: (_) => download(
          encodedLrc(
            '[id:000]\n[ar:陈奕迅]\n[ti:十年]\n[by:x]\n[hash:H1]\n'
            '[al:x]\n[total:300000]\n[offset:0]\n'
            '[00:00.00]十年 - 陈奕迅\n'
            '[00:00.50]作词 : 甲\n[00:11.25]合声：乙\n[00:13.50]吉他：丙\n'
            '[00:15.54]如果那两个字没有颤抖',
          ),
        ),
      ),
    ]);

    final result = await build(client).lookup(query);
    expect(result, isNotNull);
    expect(result!.source, '酷狗音乐');
    expect(result.synced, '[00:15.54]如果那两个字没有颤抖');
    expect(result.plain, isEmpty);
    // 第一首正主命中，第二首不会再取词。
    expect(
      client.calls.where((u) => u.host == 'krcs.kugou.com'),
      hasLength(1),
    );
  });

  test('歌手对不上 / 时长差太多 → null，不去取词', () async {
    final client = JsonClient([
      (
        match: (u) => u.host == 'mobiles.kugou.com',
        reply: (_) => searchResult([
          {'songname': '十年', 'singername': '刘若英', 'duration': 300, 'hash': 'H2'},
        ]),
      ),
    ]);

    final result = await build(client).lookup(query);
    expect(result, isNull);
    expect(
      client.calls.where((u) => u.host == 'krcs.kugou.com'),
      isEmpty,
    );
  });

  test('候选为空 → null', () async {
    final client = JsonClient([
      (
        match: (u) => u.host == 'mobiles.kugou.com',
        reply: (_) => searchResult([
          {'songname': '十年', 'singername': '陈奕迅', 'duration': 300, 'hash': 'H1'},
        ]),
      ),
      (
        match: (u) => u.host == 'krcs.kugou.com',
        reply: (_) => const JsonOk({'candidates': <Object>[]}),
      ),
    ]);

    final result = await build(client).lookup(query);
    expect(result, isNull);
  });

  test('下载 500 → null', () async {
    final client = JsonClient([
      (
        match: (u) => u.host == 'mobiles.kugou.com',
        reply: (_) => searchResult([
          {'songname': '十年', 'singername': '陈奕迅', 'duration': 300, 'hash': 'H1'},
        ]),
      ),
      (match: (u) => u.host == 'krcs.kugou.com', reply: (_) => candidates()),
      (
        match: (u) => u.host == 'lyrics.kugou.com',
        reply: (_) => const JsonStatus(500),
      ),
    ]);

    final result = await build(client).lookup(query);
    expect(result, isNull);
  });

  test('取消 → RequestAborted 原样上抛', () async {
    final token = CancelToken()..cancel();
    final client = JsonClient([
      (
        match: (u) => u.host == 'mobiles.kugou.com',
        reply: (_) => searchResult([]),
      ),
    ]);
    expect(
      () => build(client).lookup(query, cancel: token),
      throwsA(isA<RequestAborted>()),
    );
  });
}
