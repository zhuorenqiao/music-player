import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_cache.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart';

/// 按 URL 特征应答的假上游。
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

const trackName = '十年';
const artistName = '陈奕迅';
final query = normalizeQuery(
  title: trackName,
  artist: artistName,
  duration: 300,
);

void main() {
  late Directory dir;
  late AppPrefs prefs;
  late LyricsDiskCache disk;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lyrics-source-');
    prefs = AppPrefs.inMemory();
    disk = LyricsDiskCache(directory: dir.path);
  });
  tearDown(() => dir.delete(recursive: true));

  LyricsSource sourceWith(
    HttpJsonClient client, {
    RateLimitGate? gate,
    Duration total = const Duration(seconds: 60),
  }) => LyricsSource(
    client: client,
    disk: disk,
    index: LyricsIndexCache(prefs),
    gate: gate ?? RateLimitGate(),
    totalBudget: total,
    sleep: (_) async {},
  );

  test('原方向带时长 get 命中即可，且不写 search', () async {
    final client = RoutingClient([
      (
        match: (u) =>
            u.path.endsWith('/get') &&
            u.queryParameters.containsKey('duration'),
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:01]甲', 'plainLyrics': '甲'}),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]甲');
    expect(result.source, 'LRCLIB');
  });

  test('get 只有纯文本，而 search 有时间轴 → 用 search', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/get'),
        reply: (_) => const JsonOk({'syncedLyrics': '', 'plainLyrics': '纯文本'}),
      ),
      (
        match: (u) => u.path.endsWith('/search'),
        reply: (_) => const JsonOk([
          {
            'trackName': '十年',
            'artistName': '陈奕迅',
            'duration': 300,
            'syncedLyrics': '[00:01]甲',
            'plainLyrics': '甲',
          },
        ]),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.synced, '[00:01]甲');
  });

  test('get 报错而 search 只有纯文本 → 宁可报错（不把限流说成未找到）', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/get'),
        reply: (_) => const JsonStatus(429, retryAfterSeconds: 5),
      ),
      (
        match: (u) => u.path.endsWith('/search'),
        reply: (_) => const JsonOk([
          {
            'trackName': '十年',
            'artistName': '陈奕迅',
            'syncedLyrics': '',
            'plainLyrics': '纯文本',
          },
        ]),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'error');
    expect(result.reason, UpstreamReason.rateLimit);
    expect(result.rateLimited, isTrue);
    expect(result.message, '歌词库正在限流（HTTP 429）');
  });

  test('全部 404 → not-found，写索引与磁盘', () async {
    final client = RoutingClient([]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'not-found');
    expect(await LyricsIndexCache(prefs).read(query.key), isNotNull);
    final again = await sourceWith(client).match(query);
    expect(again.status, 'not-found');
    expect(again.source, '缓存');
  });

  test('冷却期内直接拦截，不发请求', () async {
    final gate = RateLimitGate()..note(60);
    final client = RoutingClient([]);
    final result = await sourceWith(client, gate: gate).match(query);
    expect(result.status, 'error');
    expect(result.rateLimited, isTrue);
    expect(result.message, '歌词服务刚才在限流，请稍后点「重试」');
    expect(client.calls, isEmpty);
  });

  test('useCache: false 绕过冷却与命中，且仍然写缓存', () async {
    final gate = RateLimitGate()..note(60);
    final client = RoutingClient([
      (
        match: (u) =>
            u.path.endsWith('/get') &&
            u.queryParameters.containsKey('duration'),
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:01]甲', 'plainLyrics': '甲'}),
      ),
    ]);
    final result = await sourceWith(
      client,
      gate: gate,
    ).match(query, useCache: false);
    expect(result.status, 'ok');
    expect(await LyricsIndexCache(prefs).read(query.key), isNotNull);
  });

  test('上游抛错时回退过期磁盘缓存，source 覆盖为「LRCLIB（离线缓存）」', () async {
    final client = RoutingClient([
      (
        match: (u) =>
            u.path.endsWith('/get') &&
            u.queryParameters.containsKey('duration'),
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:01]旧', 'plainLyrics': '旧'}),
      ),
    ]);
    await sourceWith(client).match(query);
    // 把磁盘条目改成过期
    final key = LyricsDiskCache.keyFor(
      query.trackName,
      query.artistName,
      '${query.duration}',
    );
    File(
      '${dir.path}/$key.json',
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 400)));

    final failing = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonTimeout()),
    ]);
    final result = await sourceWith(failing).match(query, useCache: false);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]旧');
    expect(result.source, 'LRCLIB（离线缓存）');
  });

  test('上游抛错且没有过期缓存 → error，message 是四类话术之一', () async {
    final client = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonTimeout()),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'error');
    expect(result.reason, UpstreamReason.timeout);
    expect(result.message, '连接歌词库超时（本机到该站点较慢，稍等会自动重试）');
  });

  test('trackName 为空 → empty-query，不发请求', () async {
    final client = RoutingClient([]);
    final result = await sourceWith(client)
        .match(normalizeQuery(title: '', artist: '', duration: 0));
    expect(result.status, 'empty-query');
    expect(result.message, '曲目信息不足，无法匹配歌词');
    expect(client.calls, isEmpty);
  });

  test('取消 → aborted，不写任何缓存', () async {
    final token = CancelToken();
    final client = RoutingClient([]);
    final future = sourceWith(client).match(query, cancel: token);
    token.cancel();
    final result = await future;
    expect(result.status, 'aborted');
    expect(await prefs.readString(LyricsIndexCache.prefsKey), isNull);
  });

  test('对调 key 也写一份（歌手非空时）', () async {
    final client = RoutingClient([
      (
        match: (u) =>
            u.path.endsWith('/get') && u.queryParameters['track_name'] == '陈奕迅',
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:01]乙', 'plainLyrics': '乙'}),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'ok');
    final swapped = LyricsDiskCache.keyFor('陈奕迅', '十年', '300');
    expect(File('${dir.path}/$swapped.json').existsSync(), isTrue);
  });

  test('总预算到点取消，按 timeout 分类', () async {
    // 一个永不返回的上游：只有总预算能结束这次匹配
    final client = RoutingClient([
      (match: (_) => true, reply: (_) => Completer<JsonOutcome>().future),
    ]);
    final result = await sourceWith(
      client,
      total: const Duration(milliseconds: 30),
    ).match(query);
    expect(result.status, 'error');
    expect(result.reason, UpstreamReason.timeout);
  });

  test('search 用 q 参数，不是 track_name', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search'),
        reply: (_) => const JsonOk([]),
      ),
    ]);
    await sourceWith(client).match(query);
    final search = client.calls.firstWhere((u) => u.path.endsWith('/search'));
    expect(search.queryParameters['q'], '十年 陈奕迅');
    expect(search.queryParameters.containsKey('track_name'), isFalse);
  });

  // 以下几条补的是上面用例没覆盖到的生产逻辑（索引 ok 命中 / search 打分 /
  // get 压过 search / 取消时冷却闸原样保留）。
  test('索引命中 ok 时直接用缓存，保留 source 且不发请求', () async {
    final first = RoutingClient([
      (
        match: (u) =>
            u.path.endsWith('/get') &&
            u.queryParameters.containsKey('duration'),
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:01]甲', 'plainLyrics': '甲'}),
      ),
    ]);
    expect((await sourceWith(first).match(query)).status, 'ok');

    final second = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonTimeout()),
    ]);
    final result = await sourceWith(second).match(query);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]甲');
    expect(result.source, 'LRCLIB');
    expect(second.calls, isEmpty);
  });

  test('search 多条结果按打分挑最优（不是取第一条）', () async {
    // 两条都带时间轴：第一条歌名歌手全等但时长差 100s（>25s 罚分），
    // 第二条时长全等。若「取第一条」或忽略时长评分，答案会是「甲」。
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search'),
        reply: (_) => const JsonOk([
          {
            'trackName': '十年',
            'artistName': '陈奕迅',
            'duration': 400,
            'syncedLyrics': '[00:01]甲',
            'plainLyrics': '甲',
          },
          {
            'trackName': '十年',
            'artistName': '陈奕迅',
            'duration': 300,
            'syncedLyrics': '[00:01]乙',
            'plainLyrics': '乙',
          },
        ]),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.synced, '[00:01]乙');
  });

  test('get 与 search 都带时间轴 → get 优先（search 只是兜底）', () async {
    final client = RoutingClient([
      (
        match: (u) =>
            u.path.endsWith('/get') &&
            u.queryParameters.containsKey('duration'),
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:01]get', 'plainLyrics': 'get'}),
      ),
      (
        match: (u) => u.path.endsWith('/search'),
        reply: (_) => const JsonOk([
          {
            'trackName': '十年',
            'artistName': '陈奕迅',
            'duration': 300,
            'syncedLyrics': '[00:01]search',
            'plainLyrics': 'search',
          },
        ]),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]get');
  });

  test('get 全部 404 而 search 报错 → error，不当成未找到', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/search'),
        reply: (_) => const JsonTimeout(),
      ),
    ]);
    final result = await sourceWith(client).match(query);
    expect(result.status, 'error');
    expect(result.reason, UpstreamReason.timeout);
  });

  test('取消时上游已记下的冷却保留下来，结果仍是 aborted', () async {
    // get 一路 429 会先把冷却闸记上（60s），随后 search 那趟把 token 取消。
    // 429 是真实的上游信号：abort 只是不写缓存，冷却要原样留着。清掉它，下一次
    // 自动匹配会再打 2~5 条请求、撞回「歌词库正在限流（HTTP 429）」，而冷却存在
    // 的意义正是让那次匹配安静地跳过（「歌词服务刚才在限流，请稍后点「重试」」）。
    final token = CancelToken();
    final gate = RateLimitGate();
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/get'),
        reply: (_) => const JsonStatus(429),
      ),
      (
        match: (u) => u.path.endsWith('/search'),
        reply: (_) {
          token.cancel();
          return const JsonTimeout();
        },
      ),
    ]);
    final result = await sourceWith(
      client,
      gate: gate,
    ).match(query, cancel: token);
    expect(result.status, 'aborted');
    expect(gate.isLimited, isTrue);
    expect(await prefs.readString(LyricsIndexCache.prefsKey), isNull);
  });

  test('开跑前就取消：不动冷却闸、不发请求、不写索引', () async {
    // abort 绝不碰闸的最纯粹形态：一条请求都没发出去，闸上那个 60s 窗口只可能是
    // 别人（上一轮匹配）记下的。老实现在这条路上 gate.clear() 一次，等于凭空
    // 删掉一个与本次匹配无关的冷却。useCache: false 是为了绕开入口的冷却拦截，
    // 否则这条用例会被闸挡住、走不到取消那一支。
    final token = CancelToken()..cancel();
    final gate = RateLimitGate()..note(60);
    final client = RoutingClient([]);
    final result = await sourceWith(
      client,
      gate: gate,
    ).match(query, cancel: token, useCache: false);
    expect(result.status, 'aborted');
    expect(gate.isLimited, isTrue);
    expect(client.calls, isEmpty);
    expect(await prefs.readString(LyricsIndexCache.prefsKey), isNull);
  });
}
