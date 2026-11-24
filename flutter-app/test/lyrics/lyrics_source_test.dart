import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/lyrics/lyrics_cache.dart';
import 'package:light_music/lyrics/lyrics_provider.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/netease_lyrics.dart';
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

/// 与 LyricsSource 的缓存纪元一致：v4 起主源链是 LRCLIB → 汽水 → 酷狗 → 网易云，
/// 新结果都写在 `v4|` 前缀下。这里只用来「验尸」缓存有没有落盘，不参与生产逻辑。
String epochIndexKey(String key) => 'v4|$key';

/// 上一纪元（v3 四源时代）的索引键，只读兜底。
String legacyIndexKey(String key) => 'v3|$key';

/// 更早纪元（v2 网易云时代）的索引键，只读兜底。
String legacy2IndexKey(String key) => 'v2|$key';

String epochDiskKey(String track, String artist, String duration) =>
    LyricsDiskCache.keyFor('v4|$track', artist, duration);

String legacyDiskKey(String track, String artist, String duration) =>
    LyricsDiskCache.keyFor('v3|$track', artist, duration);

String legacy2DiskKey(String track, String artist, String duration) =>
    LyricsDiskCache.keyFor('v2|$track', artist, duration);

/// 固定返回一个结果的假歌词源；calls 用来钉「优先级高的命中后，低的绝不该被调用」。
class FakeProvider implements LyricsProvider {
  FakeProvider(this.record);

  final LyricsRecord? record;
  int calls = 0;

  @override
  Future<LyricsRecord?> lookup(LyricsQuery query, {CancelToken? cancel}) async {
    calls += 1;
    return record;
  }
}

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

  /// 带网易云补位的装配：LRCLIB 走 client，网易云走 NetEaseLyrics。
  LyricsSource sourceWithNetease(
    HttpJsonClient client, {
    RateLimitGate? gate,
    Duration total = const Duration(seconds: 60),
  }) => LyricsSource(
    client: client,
    disk: disk,
    index: LyricsIndexCache(prefs),
    netease: NetEaseLyrics(client: client, sleep: (_) async {}),
    gate: gate ?? RateLimitGate(),
    totalBudget: total,
    sleep: (_) async {},
  );

  /// 带三家补位的装配：LRCLIB → 汽水 → 酷狗 → 网易云。
  LyricsSource sourceWithProviders(
    HttpJsonClient client, {
    LyricsProvider? qishui,
    LyricsProvider? kugou,
    LyricsProvider? netease,
    RateLimitGate? gate,
    Duration total = const Duration(seconds: 60),
  }) => LyricsSource(
    client: client,
    disk: disk,
    index: LyricsIndexCache(prefs),
    qishui: qishui,
    kugou: kugou,
    netease: netease,
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
    expect(await LyricsIndexCache(prefs).read(epochIndexKey(query.key)), isNotNull);
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
    expect(await LyricsIndexCache(prefs).read(epochIndexKey(query.key)), isNotNull);
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
    final key = epochDiskKey(
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
    final swapped = epochDiskKey('陈奕迅', '十年', '300');
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

  // 繁→简折叠的回归用例（2026-11-21《完美主义》案例）：
  // 标签写成「完美主義 / 周杰倫」时，上游那条简体记录 get 404、search 0 条。
  test('繁体曲名/歌手先折到简体再查，缓存键也跟着折', () async {
    final traditional = normalizeQuery(
      title: '完美主義',
      artist: '周杰倫',
      duration: 244,
    );
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/get'),
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:29]甲', 'plainLyrics': '甲'}),
      ),
    ]);
    final result = await sourceWith(client).match(traditional);
    expect(result.status, 'ok');

    // 每一条请求都必须带简体：繁体请求在上游一律 404 / 0 条
    for (final uri in client.calls) {
      final values = uri.queryParameters.values.toList();
      expect(
        values.any((v) => v.contains('周杰倫') || v.contains('完美主義')),
        isFalse,
        reason: '不应再发繁体查询：$uri',
      );
      expect(
        values.any((v) => v.contains('周杰伦') || v.contains('完美主义')),
        isTrue,
        reason: '应该发简体查询：$uri',
      );
    }

    // 缓存键按折叠后的字段算，旧的繁体「未找到」自然被绕开
    final folded = normalizeQuery(
      title: '完美主义',
      artist: '周杰伦',
      duration: 244,
    );
    expect(
      await LyricsIndexCache(prefs).read(epochIndexKey(folded.key)),
      isNotNull,
    );
  });

  test('简体全没命中 → 用原字形补一次 search，命中只在繁体条目里的歌', () async {
    final traditional = normalizeQuery(
      title: '完美主義',
      artist: '周杰倫',
      duration: 244,
    );
    final client = RoutingClient([
      (
        match: (u) =>
            u.path.endsWith('/search') &&
            u.queryParameters['q'] == '完美主義 周杰倫',
        reply: (_) => const JsonOk([
          {
            'trackName': '完美主義',
            'artistName': '周杰倫',
            'duration': 244,
            'syncedLyrics': '[00:29]甲',
            'plainLyrics': '甲',
          },
        ]),
      ),
    ]);
    final result = await sourceWith(client).match(traditional);
    expect(result.status, 'ok');
    expect(result.synced, '[00:29]甲');
    // 简体那几路（含简体 search）都 404，只有原字形那一次命中
    final rawCalls = client.calls.where(
      (u) => u.queryParameters['q'] == '完美主義 周杰倫',
    );
    expect(rawCalls, hasLength(1));
  });

  // ---- LRCLIB 优先（2026-11-23） ---------------------------------------

  final netEaseSearch = (
    match: (Uri u) => u.path.endsWith('/search/get'),
    reply: (Uri _) => const JsonOk({
      'result': {
        'songs': [
          {
            'id': 1,
            'name': '十年',
            'duration': 300000,
            'artists': [
              {'name': '陈奕迅'},
            ],
          },
        ],
      },
    }),
  );
  final netEaseSong = (
    match: (Uri u) => u.path.endsWith('/song/lyric'),
    reply: (Uri _) => const JsonOk({
      'lrc': {'lyric': '[00:15.54]如果那两个字没有颤抖'},
    }),
  );

  test('LRCLIB 没词 → 网易云命中', () async {
    final client = RoutingClient([netEaseSearch, netEaseSong]);
    final result = await sourceWithNetease(client).match(query);
    expect(result.status, 'ok');
    expect(result.source, '网易云音乐');
    expect(result.synced, '[00:15.54]如果那两个字没有颤抖');
    // LRCLIB 先被问，404 后才轮到网易云；后者只负责搜歌 + 取词。
    expect(client.calls.first.host, 'lrclib.net');
    expect(client.calls.where((u) => u.host == 'music.163.com').length, 2);

    // 结果落进 v4：同一首歌再匹配一次，网络一声不吭。
    final quiet = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonTimeout()),
    ]);
    final again = await sourceWithNetease(quiet).match(query);
    expect(again.status, 'ok');
    expect(again.source, '网易云音乐');
    expect(again.synced, '[00:15.54]如果那两个字没有颤抖');
    expect(quiet.calls, isEmpty);

    final cached = await LyricsIndexCache(
      prefs,
    ).read(epochIndexKey(query.key));
    expect(cached?.source, '网易云音乐');
  });

  test('LRCLIB 首命中：即使网易云会失败，也一次都不碰它', () async {
    for (final failure in <JsonOutcome>[
      const JsonOk({'nolyric': true}),
      const JsonStatus(500),
    ]) {
      prefs = AppPrefs.inMemory();
      await dir.delete(recursive: true);
      dir = await Directory.systemTemp.createTemp('lyrics-source-');
      disk = LyricsDiskCache(directory: dir.path);

      final client = RoutingClient([
        netEaseSearch,
        (match: (u) => u.path.endsWith('/song/lyric'), reply: (_) => failure),
        (
          match: (u) =>
              u.path.endsWith('/get') &&
              u.queryParameters.containsKey('duration'),
          reply: (_) =>
              const JsonOk({'syncedLyrics': '[00:15.54]LRCLIB 的词', 'plainLyrics': ''}),
        ),
      ]);
      final result = await sourceWithNetease(client).match(query);
      expect(result.status, 'ok');
      expect(result.source, 'LRCLIB');
      expect(result.synced, '[00:15.54]LRCLIB 的词');
      expect(client.calls.every((u) => u.host == 'lrclib.net'), isTrue);
    }
  });

  test('旧纪元的 LRCLIB 命中不再直接返回：网易云有词就换掉', () async {
    await LyricsIndexCache(prefs).write(
      query.key,
      const LyricsRecord(
        status: 'ok',
        synced: '[00:01]旧词',
        plain: '旧词',
        source: 'LRCLIB',
      ),
    );

    final client = RoutingClient([netEaseSearch, netEaseSong]);
    final result = await sourceWithNetease(client).match(query);
    expect(result.synced, '[00:15.54]如果那两个字没有颤抖');
    expect(result.source, '网易云音乐');

    // 新纪元已经写成网易云的词：再进来直接命中，不会退回旧词。
    final again = await sourceWithNetease(
      RoutingClient([(match: (_) => true, reply: (_) => const JsonTimeout())]),
    ).match(query);
    expect(again.synced, '[00:15.54]如果那两个字没有颤抖');
    expect(again.source, '网易云音乐');
  });

  test('旧纪元的 LRCLIB 命中 + 四源都没词 → 拿旧词兜底，并转正到新纪元', () async {
    await LyricsIndexCache(prefs).write(
      query.key,
      const LyricsRecord(
        status: 'ok',
        synced: '[00:01]旧词',
        plain: '旧词',
        source: 'LRCLIB',
      ),
    );

    final client = RoutingClient([]); // 全部 404
    final result = await sourceWithNetease(client).match(query);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]旧词');
    expect(result.source, 'LRCLIB');

    // 已转写到 v4：下次播放不再为同一首歌反复问上游。
    final again = await sourceWithNetease(
      RoutingClient([(match: (_) => true, reply: (_) => const JsonTimeout())]),
    ).match(query);
    expect(again.synced, '[00:01]旧词');
  });

  test('旧纪元的「未找到」不挡路：网易云能翻案', () async {
    await LyricsIndexCache(prefs).write(
      query.key,
      const LyricsRecord(status: 'not-found', source: '缓存'),
    );

    final client = RoutingClient([netEaseSearch, netEaseSong]);
    final result = await sourceWithNetease(client).match(query);
    expect(result.status, 'ok');
    expect(result.source, '网易云音乐');
  });

  // ---- 汽水 / 酷狗优先（2026-11-23） -----------------------------------

  const qishuiRecord = LyricsRecord(
    status: 'ok',
    synced: '[00:01]汽水的词',
    plain: '',
    source: '汽水音乐',
  );
  const kugouRecord = LyricsRecord(
    status: 'ok',
    synced: '[00:01]酷狗的词',
    plain: '',
    source: '酷狗音乐',
  );
  const neteaseRecord = LyricsRecord(
    status: 'ok',
    synced: '[00:01]网易云的词',
    plain: '',
    source: '网易云音乐',
  );

  test('LRCLIB 没词 → 汽水命中，酷狗 / 网易云不碰', () async {
    final client = RoutingClient([]);
    final qishui = FakeProvider(qishuiRecord);
    final kugou = FakeProvider(null);
    final netease = FakeProvider(null);
    final result = await sourceWithProviders(
      client,
      qishui: qishui,
      kugou: kugou,
      netease: netease,
    ).match(query);
    expect(result.status, 'ok');
    expect(result.source, '汽水音乐');
    expect(client.calls.first.host, 'lrclib.net');
    expect(qishui.calls, 1);
    expect(kugou.calls, 0);
    expect(netease.calls, 0);
  });

  test('LRCLIB / 汽水都没词 → 酷狗命中，网易云不碰', () async {
    final client = RoutingClient([]);
    final qishui = FakeProvider(null);
    final kugou = FakeProvider(kugouRecord);
    final netease = FakeProvider(null);
    final result = await sourceWithProviders(
      client,
      qishui: qishui,
      kugou: kugou,
      netease: netease,
    ).match(query);
    expect(result.status, 'ok');
    expect(result.source, '酷狗音乐');
    expect(client.calls.first.host, 'lrclib.net');
    expect(qishui.calls, 1);
    expect(kugou.calls, 1);
    expect(netease.calls, 0);
  });

  test('LRCLIB / 汽水 / 酷狗都没词 → 网易云命中', () async {
    final client = RoutingClient([]);
    final qishui = FakeProvider(null);
    final kugou = FakeProvider(null);
    final netease = FakeProvider(neteaseRecord);
    final result = await sourceWithProviders(
      client,
      qishui: qishui,
      kugou: kugou,
      netease: netease,
    ).match(query);
    expect(result.status, 'ok');
    expect(result.source, '网易云音乐');
    expect(client.calls.first.host, 'lrclib.net');
    expect(qishui.calls, 1);
    expect(kugou.calls, 1);
    expect(netease.calls, 1);
  });

  test('LRCLIB 优先：命中就不碰汽水 / 酷狗 / 网易云', () async {
    final client = RoutingClient([
      (
        match: (u) => u.path.endsWith('/get'),
        reply: (_) =>
            const JsonOk({'syncedLyrics': '[00:01]LRCLIB 的词', 'plainLyrics': ''}),
      ),
    ]);
    final qishui = FakeProvider(qishuiRecord);
    final kugou = FakeProvider(kugouRecord);
    final netease = FakeProvider(neteaseRecord);
    final result = await sourceWithProviders(
      client,
      qishui: qishui,
      kugou: kugou,
      netease: netease,
    ).match(query);
    expect(result.status, 'ok');
    expect(result.source, 'LRCLIB');
    expect(result.synced, '[00:01]LRCLIB 的词');
    expect(client.calls, isNotEmpty);
    expect(qishui.calls, 0);
    expect(kugou.calls, 0);
    expect(netease.calls, 0);
  });

  test('LRCLIB 没词且三家都没词 → not-found', () async {
    final client = RoutingClient([]);
    final qishui = FakeProvider(null);
    final kugou = FakeProvider(null);
    final netease = FakeProvider(null);
    final result = await sourceWithProviders(
      client,
      qishui: qishui,
      kugou: kugou,
      netease: netease,
    ).match(query);
    expect(result.status, 'not-found');
    expect(client.calls.first.host, 'lrclib.net');
    expect(qishui.calls, 1);
    expect(kugou.calls, 1);
    expect(netease.calls, 1);
  });

  test('LRCLIB 报错但汽水命中 → 用汽水，错误不吞掉命中', () async {
    final client = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonStatus(500)),
    ]);
    final qishui = FakeProvider(qishuiRecord);
    final kugou = FakeProvider(null);
    final netease = FakeProvider(null);
    final result = await sourceWithProviders(
      client,
      qishui: qishui,
      kugou: kugou,
      netease: netease,
    ).match(query);
    expect(result.status, 'ok');
    expect(result.source, '汽水音乐');
    expect(qishui.calls, 1);
    expect(kugou.calls, 0);
    expect(netease.calls, 0);
  });

  test('LRCLIB 报错且三家都没词 → error，不是 not-found', () async {
    final client = RoutingClient([
      (match: (_) => true, reply: (_) => const JsonStatus(500)),
    ]);
    final qishui = FakeProvider(null);
    final kugou = FakeProvider(null);
    final netease = FakeProvider(null);
    final result = await sourceWithProviders(
      client,
      qishui: qishui,
      kugou: kugou,
      netease: netease,
    ).match(query);
    expect(result.status, 'error');
    expect(result.message, isNotEmpty);
    expect(qishui.calls, 1);
    expect(kugou.calls, 1);
    expect(netease.calls, 1);
  });

  test('v3 旧词只兜底：四源都没词才拿出来，并转正到 v4', () async {
    await LyricsIndexCache(prefs).write(
      legacyIndexKey(query.key),
      const LyricsRecord(
        status: 'ok',
        synced: '[00:01]v3 旧词',
        plain: 'v3 旧词',
        source: '酷狗音乐',
      ),
    );
    await LyricsIndexCache(prefs).write(
      legacy2IndexKey(query.key),
      const LyricsRecord(
        status: 'ok',
        synced: '[00:01]v2 旧词',
        plain: 'v2 旧词',
        source: '网易云音乐',
      ),
    );

    final result = await sourceWithProviders(
      RoutingClient([]),
      qishui: FakeProvider(null),
      kugou: FakeProvider(null),
      netease: FakeProvider(null),
    ).match(query);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]v3 旧词');
    expect(result.source, '酷狗音乐');
    expect(
      await LyricsIndexCache(prefs).read(epochIndexKey(query.key)),
      isNotNull,
    );
  });

  test('只有 v2 旧词也能兜底，并转正到 v4', () async {
    await LyricsIndexCache(prefs).write(
      legacy2IndexKey(query.key),
      const LyricsRecord(
        status: 'ok',
        synced: '[00:01]v2 旧词',
        plain: 'v2 旧词',
        source: '网易云音乐',
      ),
    );

    final result = await sourceWithProviders(
      RoutingClient([]),
      qishui: FakeProvider(null),
      kugou: FakeProvider(null),
      netease: FakeProvider(null),
    ).match(query);
    expect(result.status, 'ok');
    expect(result.synced, '[00:01]v2 旧词');
    expect(result.source, '网易云音乐');
    expect(
      await LyricsIndexCache(prefs).read(epochIndexKey(query.key)),
      isNotNull,
    );
  });

  test('v3 旧词遇到汽水命中 → 换汽水的词，不返回旧词', () async {
    await LyricsIndexCache(prefs).write(
      legacyIndexKey(query.key),
      const LyricsRecord(
        status: 'ok',
        synced: '[00:01]v3 旧词',
        plain: 'v3 旧词',
        source: '酷狗音乐',
      ),
    );

    final result = await sourceWithProviders(
      RoutingClient([]),
      qishui: FakeProvider(qishuiRecord),
      kugou: FakeProvider(null),
      netease: FakeProvider(null),
    ).match(query);
    expect(result.synced, '[00:01]汽水的词');
    expect(result.source, '汽水音乐');
  });

  test('v3 的「未找到」不挡汽水：仍会去问新源', () async {
    await LyricsIndexCache(prefs).write(
      legacyIndexKey(query.key),
      const LyricsRecord(status: 'not-found', source: '缓存'),
    );

    final result = await sourceWithProviders(
      RoutingClient([]),
      qishui: FakeProvider(qishuiRecord),
      kugou: FakeProvider(null),
      netease: FakeProvider(null),
    ).match(query);
    expect(result.status, 'ok');
    expect(result.source, '汽水音乐');
  });
}
