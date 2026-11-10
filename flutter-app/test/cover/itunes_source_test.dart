// test/cover/itunes_source_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/cover/itunes_source.dart';
import 'package:light_music/lyrics/upstream.dart';

/// 假 HttpJsonClient：按 URL 断言参数并返回预设 JsonOutcome，不打网络。
class FakeJsonClient implements HttpJsonClient {
  FakeJsonClient(this.handler, {this.thrown});

  /// 按请求 URL 挑一个预设结果。
  final JsonOutcome Function(Uri url) handler;

  /// 非空时每次 getJson 直接抛它（模拟 client 抛 RequestAborted）。
  final Object? thrown;

  final List<Uri> requests = <Uri>[];
  final List<Duration> timeouts = <Duration>[];
  final List<Map<String, String>> headerLog = <Map<String, String>>[];

  @override
  Future<JsonOutcome> getJson(
    Uri url, {
    required Duration timeout,
    required Map<String, String> headers,
  }) async {
    requests.add(url);
    timeouts.add(timeout);
    headerLog.add(headers);
    final error = thrown;
    if (error != null) {
      throw error;
    }
    return handler(url);
  }
}

Map<String, Object?> itunesItem({
  String? trackName,
  String? artistName,
  int? millis,
  String? artwork,
}) =>
    <String, Object?>{
      'trackName': trackName,
      'artistName': artistName,
      'trackTimeMillis': millis,
      'artworkUrl100': artwork,
    }..removeWhere((_, value) => value == null);

const artwork100 = 'https://example.com/100x100bb.jpg';

/// CN 区回 [cn]、美区回 [us] 的假客户端。
FakeJsonClient twoRegionClient(JsonOutcome cn, JsonOutcome us) =>
    FakeJsonClient(
      (url) => url.queryParameters['country'] == 'CN' ? cn : us,
    );

void main() {
  group('scoreItem', () {
    const q = (trackName: '十年', artistName: '陈奕迅', duration: 0.0);

    test('歌名相等 +30，titleExact 为真', () {
      // 30(歌名全等) + 25(歌手全等) —— React scoreItem 的歌名与歌手分是
      // 独立累加的，不含歌手字段时用两个条目分别钉单档。
      final r = scoreItem(
        itunesItem(trackName: '十年', artistName: '陈奕迅'),
        q,
      );
      expect(r.titleExact, isTrue);
      expect(r.artistMatch, isTrue);
      expect(r.score, 55);
    });

    test('互相包含 +12：单侧 name.contains(want)', () {
      final r = scoreItem(
        itunesItem(trackName: '十年 (Live)', artistName: '陈奕迅'),
        q,
      );
      expect(r.titleExact, isFalse);
      expect(r.score, 37);
    });

    test('互相包含 +12：另一侧 want.contains(name)', () {
      // 条目无 artistName：artist=''，want.contains('') 恒真 → +10 也在
      // （React cover-source.js:166 无非空守卫，node 核实）；12+10=22。
      expect(scoreItem(itunesItem(trackName: '年'), q).score, 22);
    });

    test('歌手相等 +25，artistMatch 为真', () {
      // 条目无 trackName 字段：JS 的 String(undefined ?? '')=''，而
      // want.contains('') 恒真 —— 所以歌名还有 12 分。这是 React
      // cover-source.js:158 没有非空守卫的原义行为（node 核实）。
      final r = scoreItem(itunesItem(artistName: '陈奕迅'), q);
      expect(r.artistMatch, isTrue);
      expect(r.score, 37);
    });

    test('歌手包含 +10：artist.contains(want) 与 want.contains(artist)', () {
      expect(scoreItem(itunesItem(trackName: '十年X', artistName: '陈奕迅&Eason'), q).score, 22);
      expect(scoreItem(itunesItem(trackName: '十年X', artistName: '陈'), q).score, 22);
    });

    test('全 lowercase 比较：大小写不同也算相等', () {
      const q2 = (
        trackName: 'Light Years Away',
        artistName: 'G.E.M.',
        duration: 0.0,
      );
      final r = scoreItem(
        itunesItem(trackName: 'LIGHT YEARS AWAY', artistName: 'g.e.m.'),
        q2,
      );
      expect(r.titleExact, isTrue);
      expect(r.artistMatch, isTrue);
      expect(r.score, 55);
    });

    test('ScoreResult 的 == / hashCode 按三字段', () {
      // 无 artistName 字段：artist=''，want.contains('') 恒真 → artistMatch
      // 也为真（React cover-source.js:163-166 的原义行为，node 核实）。
      expect(
        scoreItem(itunesItem(trackName: '十年'), q),
        const ScoreResult(score: 40, titleExact: true, artistMatch: true),
      );
      expect(
        const ScoreResult(score: 40, titleExact: true, artistMatch: true)
            .hashCode,
        const ScoreResult(score: 40, titleExact: true, artistMatch: true)
            .hashCode,
      );
    });

    test('时长边界：diff=2 → +20；2.1 → +8（落入 ≤6 档）', () {
      // brief 原写「2.1 → 0」与 cover-source.js:177-183 的 if/else 链不符：
      // diff=2.1 不满足 <=2，但满足 <=6 → +8（node 核实）。源码为准。
      const qd = (trackName: '十年', artistName: '陈奕迅', duration: 200.0);
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 202000),
          qd,
        ).score,
        75,
      );
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 202100),
          qd,
        ).score,
        63,
      );
    });

    test('时长边界：diff=6 → +8；6.1 → 0', () {
      const qd = (trackName: '十年', artistName: '陈奕迅', duration: 200.0);
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 206000),
          qd,
        ).score,
        63,
      );
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 206100),
          qd,
        ).score,
        55,
      );
    });

    test('时长边界：diff=25 → 0；25.1 → −25', () {
      const qd = (trackName: '十年', artistName: '陈奕迅', duration: 200.0);
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 225000),
          qd,
        ).score,
        55,
      );
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 225100),
          qd,
        ).score,
        30,
      );
    });

    test('duration=0 时不计时长分', () {
      const q0 = (trackName: '十年', artistName: '陈奕迅', duration: 0.0);
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 202000),
          q0,
        ).score,
        55,
      );
    });

    test('millis 缺失 / 0 / 负数 / 非数字不计时长分', () {
      const qd = (trackName: '十年', artistName: '陈奕迅', duration: 200.0);
      expect(
        scoreItem(itunesItem(trackName: '十年', artistName: '陈奕迅'), qd).score,
        55,
      );
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: 0),
          qd,
        ).score,
        55,
      );
      expect(
        scoreItem(
          itunesItem(trackName: '十年', artistName: '陈奕迅', millis: -180000),
          qd,
        ).score,
        55,
      );
      expect(
        scoreItem(
          <String, Object?>{
            'trackName': '十年',
            'artistName': '陈奕迅',
            'trackTimeMillis': 'abc',
          },
          qd,
        ).score,
        55,
      );
    });
  });

  group('pickBest', () {
    const q = (trackName: '十年', artistName: '陈奕迅', duration: 205.0);

    test('没有非空字符串 artworkUrl100 的条目被跳过', () {
      final results = <Object?>[
        // 30 分但无图 → 跳过
        itunesItem(trackName: '十年'),
        // 12+10+8=30 分，有图 → 入选
        itunesItem(
          trackName: '十年 (Live)',
          artistName: '陈奕迅&Band',
          millis: 210000,
          artwork: artwork100,
        ),
      ];
      final picked = pickBest(results, q);
      expect(picked?['artworkUrl100'], artwork100);
    });

    test('artworkUrl100 为空字符串同样跳过', () {
      final results = <Object?>[
        itunesItem(trackName: '十年', artwork: ''),
      ];
      expect(pickBest(results, q), isNull);
    });

    test('bestScore < 18 → null', () {
      // 12 分（歌名包含）+ 8 分（时长 6~25 内）= 20？不 —— 歌名包含 +12、
      // 歌手空串包含 +10 已达 22，为了钉「<18 拒」，wantArtist 给非空但
      // 条目歌手互不包含、时长 diff=25 整（0 分档）：12+0=12 < 18。
      const q2 = (trackName: '十年', artistName: '陈奕迅', duration: 200.0);
      final low = itunesItem(
        trackName: '十年 (Live)',
        artistName: '张学友',
        millis: 225000,
        artwork: artwork100,
      );
      expect(pickBest([low], q2), isNull);
    });

    test('=18 收：歌手包含 +10 与时长 +8 凑足门槛', () {
      const q2 = (trackName: '十年', artistName: '陈奕迅', duration: 200.0);
      final hit = itunesItem(
        trackName: '别的歌', // 与曲名互不包含 → 0
        artistName: '陈奕迅&Band', // 包含 → +10
        millis: 206000, // diff=6 → +8，合计 18
        artwork: artwork100,
      );
      expect(pickBest([hit], q2)?['trackName'], '别的歌');
    });

    test('二次校验反例：分数够但 titleExact / artistMatch 都 false → null', () {
      // 「光年之外」原版只有英文名：时长 diff<=2 凑够 20 分（≥18），
      // 但歌名「Light Years Away」与「光年之外」互不包含、wantArtist 为空
      // → 二次校验不过，宁可不返回也不能命中别人的翻唱。
      // 注意 scoreItem 的歌手分是 0（wantArtist 空），20 分全靠歌名 12 +
      // 时长 8？不 —— 20 = 12(包含) + 8(时长)：条目名含 want 之外还差
      // 8 分，millis=206000（diff=6）给 +8，合计 20 ≥ 18。
      const q3 = (trackName: '光年之外', artistName: '', duration: 200.0);
      final cover = itunesItem(
        trackName: 'Light Years Away 光年之外纪念版', // 互相包含 → +12
        millis: 206000, // diff=6 → +8，合计 20
        artwork: artwork100,
      );
      expect(pickBest([cover], q3), isNull);
    });

    test('严格大于才替换：平分取先出现的', () {
      final first = itunesItem(
        trackName: '别的歌',
        artistName: '陈奕迅&Band',
        millis: 206000,
        artwork: 'https://first.example/100x100bb.jpg',
      ); // 10+8=18
      final second = itunesItem(
        trackName: '另一首',
        artistName: '陈奕迅&Live',
        millis: 206000,
        artwork: 'https://second.example/100x100bb.jpg',
      ); // 同为 18
      expect(pickBest([first, second], q)?['artworkUrl100'],
          'https://first.example/100x100bb.jpg');
    });

    test('results 非 List / 空列表 → null', () {
      expect(pickBest(<Object?>[], q), isNull);
    });
  });

  group('artworkBig', () {
    test('100x100bb.jpg → 600x600bb.jpg', () {
      expect(
        artworkBig(
          'https://is1-ssl.mzstatic.com/image/thumb/Music123/abc/100x100bb.jpg',
        ),
        'https://is1-ssl.mzstatic.com/image/thumb/Music123/abc/600x600bb.jpg',
      );
    });

    test('其它后缀同样换算（png）', () {
      expect(artworkBig('https://x.example/a/100x100bb.png'),
          'https://x.example/a/600x600bb.png');
    });

    test('无匹配后缀原样返回', () {
      const raw = 'https://example.com/cover.png';
      expect(artworkBig(raw), raw);
    });
  });

  group('itunesSearch', () {
    const q = (trackName: '十年', artistName: '陈奕迅', duration: 200.0);

    test('trackName 为空 → empty-query，不发请求', () async {
      final client = FakeJsonClient((url) => const JsonNetwork());
      final match = await itunesSearch(
        query: (trackName: '', artistName: '陈奕迅', duration: 0.0),
        client: client,
      );
      expect(match.status, 'empty-query');
      expect(client.requests, isEmpty);
    });

    test('请求参数：term=[artist, track] 拼接、entity/media/limit、'
        'CN 带 country、US 不带 country、单程 10s、Accept 头', () async {
      final client = FakeJsonClient((url) => const JsonNetwork());
      await itunesSearch(query: q, client: client);

      expect(client.requests.length, 2);
      final cn = client.requests[0];
      final us = client.requests[1];

      expect(cn.host, 'itunes.apple.com');
      expect(cn.path, '/search');
      expect(cn.queryParameters['term'], '陈奕迅 十年');
      expect(cn.queryParameters['entity'], 'song');
      expect(cn.queryParameters['media'], 'music');
      expect(cn.queryParameters['limit'], '8');
      expect(cn.queryParameters['country'], 'CN');

      expect(us.queryParameters['term'], '陈奕迅 十年');
      expect(us.queryParameters['entity'], 'song');
      expect(us.queryParameters['media'], 'music');
      expect(us.queryParameters['limit'], '8');
      expect(us.queryParameters.containsKey('country'), isFalse);

      for (final timeout in client.timeouts) {
        expect(timeout, const Duration(seconds: 10));
      }
      for (final headers in client.headerLog) {
        expect(headers, <String, String>{'Accept': 'application/json'});
      }
    });

    test('artistName 为空时 term 只含曲名', () async {
      final client = FakeJsonClient((url) => const JsonNetwork());
      await itunesSearch(
        query: (trackName: '十年', artistName: '', duration: 0.0),
        client: client,
      );
      expect(client.requests.first.queryParameters['term'], '十年');
    });

    test('两区命中：取全局 score 更高的 US 条目（CN 18 分，US 75 分）', () async {
      final cnItem = itunesItem(
        trackName: '别的歌',
        artistName: '陈奕迅&Band',
        millis: 206000,
        artwork: 'https://cn.example/100x100bb.jpg',
      ); // 10+8=18
      final usItem = itunesItem(
        trackName: '十年',
        artistName: '陈奕迅',
        millis: 202000,
        artwork: 'https://us.example/100x100bb.jpg',
      ); // 30+25+20=75
      final client = twoRegionClient(
        JsonOk(<String, Object?>{'results': <Object?>[cnItem]}),
        JsonOk(<String, Object?>{'results': <Object?>[usItem]}),
      );
      final match = await itunesSearch(query: q, client: client);
      expect(match.status, 'ok');
      expect(match.url, 'https://us.example/600x600bb.jpg');
      expect(match.source, 'iTunes');
    });

    test('两区分数持平：取先出现的 CN', () async {
      final cnItem = itunesItem(
        trackName: '别的歌',
        artistName: '陈奕迅&Band',
        millis: 206000,
        artwork: 'https://cn.example/100x100bb.jpg',
      ); // 18
      final usItem = itunesItem(
        trackName: '另一首',
        artistName: '陈奕迅&Live',
        millis: 206000,
        artwork: 'https://us.example/100x100bb.jpg',
      ); // 同为 18
      final client = twoRegionClient(
        JsonOk(<String, Object?>{'results': <Object?>[cnItem]}),
        JsonOk(<String, Object?>{'results': <Object?>[usItem]}),
      );
      final match = await itunesSearch(query: q, client: client);
      expect(match.url, 'https://cn.example/600x600bb.jpg');
    });

    test('CN 网络错 → 该区当 miss，继续用 US 的命中', () async {
      final usItem = itunesItem(
        trackName: '十年',
        artistName: '陈奕迅',
        artwork: 'https://us.example/100x100bb.jpg',
      );
      final client = twoRegionClient(
        const JsonNetwork(),
        JsonOk(<String, Object?>{'results': <Object?>[usItem]}),
      );
      final match = await itunesSearch(query: q, client: client);
      expect(match.status, 'ok');
      expect(match.url, 'https://us.example/600x600bb.jpg');
    });

    test('单区任何失败形态都当 miss：timeout / 非 200 / 坏 payload', () async {
      final usItem = itunesItem(
        trackName: '十年',
        artistName: '陈奕迅',
        artwork: 'https://us.example/100x100bb.jpg',
      );
      for (final cnOutcome in const [
        JsonTimeout(),
        JsonStatus(503),
        JsonBadPayload(),
      ]) {
        final client = twoRegionClient(
          cnOutcome,
          JsonOk(<String, Object?>{'results': <Object?>[usItem]}),
        );
        final match = await itunesSearch(query: q, client: client);
        expect(match.status, 'ok', reason: '$cnOutcome 也该当 miss');
        expect(match.url, 'https://us.example/600x600bb.jpg');
      }
    });

    test('两区都没有可采纳候选 → not-found', () async {
      final client = twoRegionClient(
        JsonOk(<String, Object?>{'results': <Object?>[itunesItem()]}),
        JsonOk(<String, Object?>{'results': <Object?>[]}),
      );
      final match = await itunesSearch(query: q, client: client);
      expect(match.status, 'not-found');
      expect(match.url, isNull);
    });

    test('JsonOk 但 payload 不是 Map / results 不是 List → not-found', () async {
      final client = twoRegionClient(
        const JsonOk('not-a-map'),
        const JsonOk(<String, Object?>{'results': 'not-a-list'}),
      );
      final match = await itunesSearch(query: q, client: client);
      expect(match.status, 'not-found');
    });

    test('预先 cancelled 的 CancelToken → aborted，不发请求', () async {
      final token = CancelToken()..cancel();
      final client = FakeJsonClient(
        (url) => JsonOk(<String, Object?>{'results': <Object?>[]}),
      );
      final match = await itunesSearch(query: q, client: client, cancel: token);
      expect(match.status, 'aborted');
      expect(client.requests, isEmpty);
    });

    test('client.getJson 抛 RequestAborted → aborted', () async {
      final client = FakeJsonClient(
        (url) => JsonOk(<String, Object?>{'results': <Object?>[]}),
        thrown: const RequestAborted(),
      );
      final match = await itunesSearch(query: q, client: client);
      expect(match.status, 'aborted');
    });

    test('假客户端抛任意异常 → error，不外抛', () async {
      final client = FakeJsonClient(
        (url) => JsonOk(<String, Object?>{'results': <Object?>[]}),
        thrown: StateError('boom'),
      );
      final match = await itunesSearch(query: q, client: client);
      expect(match.status, 'error');
      expect(match.message, isNotEmpty);
    });
  });
}
