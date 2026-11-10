// lib/cover/itunes_source.dart
//
// iTunes 封面匹配源：打分 + 两区（CN → 美区默认）直连搜索 + 结果类型。
// 对译 React 版 src/lib/cover-source.js:139-224（artworkBig / scoreItem /
// pickBest）与 src/server/music-api.ts:635-690（服务端 pickCover + fetchCover
// 两区参数）。React 的「代理 + JSONP」两级通道在 Flutter 侧合并成一级直连
//（iTunes 原生 HTTP 不受浏览器 CORS 限制，不需要 JSONP），两区串行、单区
// 10s、结果全局取 score 最高（music-api.ts:687-690 的裁决移进客户端）。
// 纯 Dart + HttpJsonClient 接缝（复用 lyrics/upstream.dart），测试不碰真网络。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉，见 test/cover/itunes_source_test.dart）：
// * scoreItem 全 lowercase 比较；歌名相等 +30、互相包含 +12（want 非空才参与）；
//   歌手相等 +25、否则 artistMatch（三连或：相等 / 互相包含）+10；
// * 时长分只在 query.duration > 0 且 millis 是正有限数时参与：
//   diff<=2 +20 / diff<=6 +8 / diff>25 −25，夹在中间（6,25] 不加不减；
// * pickBest 跳过没有非空字符串 artworkUrl100 的条目；严格大于才替换
//   （平分取先出现的）；bestScore < 18 放弃；二次校验用 covers 侧自己的
//   artistMatch 三连或定义（:219-222），「光年之外」这类原版只有英文名的歌
//   即便时长凑够分数也不许命中别人的翻唱 —— 宁可不返回也不给错图；
// * artworkBig 用锚定 $ 的非全局替换：没有 /100x100bb.<ext> 后缀就原样返回；
// * itunesSearch 两区串行 CN → 默认美区，单区 10s、失败当 miss 继续另一区，
//   绝不外抛；两区都 miss 才 not-found；请求头只有 Accept: application/json
//   （不发 Cookie / Referer / 浏览器 UA）；URLSearchParams 编码语义由
//   Uri.replace(queryParameters:) 等价提供（空格成 +，服务端两侧都接受）。
import '../lyrics/upstream.dart'
    show HttpJsonClient, JsonOk, CancelToken, RequestAborted;

/// 上游根（music-api.ts 的 ITUNES_SEARCH）。
final Uri _upstream = Uri.parse('https://itunes.apple.com/search');

/// 单区超时：对齐 React 服务端 COVER_TIMEOUT = 10_000（music-api.ts:54）。
const Duration _regionTimeout = Duration(seconds: 10);

/// iTunes 请求头（Global Constraints：只发 Accept，不发 Cookie / Referer）。
const Map<String, String> _itunesHeaders = <String, String>{
  'Accept': 'application/json',
};

/// 一次封面匹配的结果。永不抛错，失败一律以 [status] 表达。
class CoverMatch {
  const CoverMatch({
    required this.status,
    this.url,
    this.source = 'iTunes',
    this.message = '',
  });

  /// `ok | not-found | error | aborted | empty-query`。
  final String status;

  /// ok 时：600px 大图的远程地址（下载由上层做）。
  final String? url;
  final String source;
  final String message;
}

/// 一条结果的打分（对译 cover-source.js scoreItem 的返回值）。
class ScoreResult {
  const ScoreResult({
    required this.score,
    required this.titleExact,
    required this.artistMatch,
  });

  final int score;
  final bool titleExact;
  final bool artistMatch;

  @override
  bool operator ==(Object other) =>
      other is ScoreResult &&
      other.score == score &&
      other.titleExact == titleExact &&
      other.artistMatch == artistMatch;

  @override
  int get hashCode => Object.hash(score, titleExact, artistMatch);
}

/// 封面查询参数：曲名 / 歌手 / 时长（秒，未知 0）。调用方用
/// lyrics/query.dart 的 normalizeQuery 产出（duration 为 int 秒）直接传。
typedef CoverQuery = ({String trackName, String artistName, double duration});

String _str(Object? value) => value is String ? value : '';

/// 时长的数值侧（React 的 `Number.isFinite(millis) && millis > 0`）：
/// 只有有限正数参与，缺字段 / 0 / 负数 / 非数字一律「不参与评分」。
double? _positiveFinite(Object? value) {
  if (value is num) {
    final d = value.toDouble();
    return d.isFinite && d > 0 ? d : null;
  }
  return null;
}

/// 给一条搜索结果打相似度分（cover-source.js:149-186 逐字）。
ScoreResult scoreItem(Map<String, Object?> item, CoverQuery query) {
  final wantTitle = query.trackName.toLowerCase();
  final wantArtist = query.artistName.toLowerCase();
  var score = 0;

  final name = _str(item['trackName']).toLowerCase();
  final titleExact = wantTitle.isNotEmpty && name == wantTitle;
  if (titleExact) {
    score += 30;
  } else if (wantTitle.isNotEmpty &&
      (name.contains(wantTitle) || wantTitle.contains(name))) {
    score += 12;
  }

  final artist = _str(item['artistName']).toLowerCase();
  final artistMatch = wantArtist.isNotEmpty &&
      (wantArtist == artist ||
          artist.contains(wantArtist) ||
          wantArtist.contains(artist));
  if (wantArtist.isNotEmpty && artist == wantArtist) {
    score += 25;
  } else if (artistMatch) {
    score += 10;
  }

  final millis = _positiveFinite(item['trackTimeMillis']);
  if (query.duration > 0 && millis != null) {
    final diff = (millis / 1000 - query.duration).abs();
    if (diff <= 2) {
      score += 20;
    } else if (diff <= 6) {
      score += 8;
    } else if (diff > 25) {
      score -= 25;
    }
  }
  return ScoreResult(score: score, titleExact: titleExact, artistMatch: artistMatch);
}

/// pickBest 的内部形态：连分数一起返回，供两区裁决用（music-api.ts:635-680
/// 的 pickCover 返回 {item, score}）。[pickBest] 委托它。
({Map<String, Object?> item, int score})? pickBestScored(
  List<Object?> results,
  CoverQuery query,
) {
  ({Map<String, Object?> item, int score})? best;
  for (final raw in results) {
    final item = raw is Map<String, Object?> ? raw : null;
    if (item == null) {
      continue;
    }
    final artwork = item['artworkUrl100'];
    if (artwork is! String || artwork.isEmpty) {
      continue;
    }
    final result = scoreItem(item, query);
    // 严格大于才替换：平分取先出现的（React 的 `score > bestScore`）。
    if (best == null || result.score > best.score) {
      best = (item: item, score: result.score);
    }
  }
  if (best == null || best.score < 18) {
    return null;
  }
  // 二次校验（cover-source.js:216-222 逐字）：歌名完全一致，或歌手对得上
  // （covers 侧的 artistMatch 是三连或，与 scoreItem 内一致）。
  // 否则「光年之外」这类原版只有英文名的歌会命中别人的翻唱 Live 版。
  final name = _str(best.item['trackName']).toLowerCase();
  final artist = _str(best.item['artistName']).toLowerCase();
  final wantTitle = query.trackName.toLowerCase();
  final wantArtist = query.artistName.toLowerCase();
  final titleExact = wantTitle.isNotEmpty && name == wantTitle;
  final artistMatch = wantArtist.isNotEmpty &&
      (artist.contains(wantArtist) || wantArtist.contains(artist));
  if (!(titleExact || artistMatch)) {
    return null;
  }
  return best;
}

/// 从结果列表里挑最合适的一条（cover-source.js:197-224）；歌名对不上
/// （得分太低或二次校验不过）宁可放弃也不给错图。
Map<String, Object?>? pickBest(List<Object?> results, CoverQuery query) =>
    pickBestScored(results, query)?.item;

/// 把 iTunes 的 100x100 缩略图地址换成 600x600 大图
/// （cover-source.js:139-141 逐字；锚定 $ 的非全局替换 —— Dart 的
/// replaceFirst 不展开 `$1`，须用 replaceFirstMapped 显式回引捕获组）。
String artworkBig(String artworkUrl) => artworkUrl.replaceFirstMapped(
      RegExp(r'/\d+x\d+bb\.(\w+)$'),
      (match) => '/600x600bb.${match[1]}',
    );

/// 组一区请求的 URL。CN 区带 `country=CN`，美区默认不带 country 参数
///（music-api.ts:687-690 的两组 URLSearchParams 逐字）。
Uri _regionUri(String term, {required bool cn}) {
  final params = <String, String>{
    'term': term,
    'entity': 'song',
    'media': 'music',
    'limit': '8',
    if (cn) 'country': 'CN',
  };
  return _upstream.replace(queryParameters: params);
}

/// 一区的结果：命中带 (item, score)，未命中为 null —— 单区失败不影响另一区。
///
/// 「当 miss」的只有 outcome 形态的失败（timeout / network / 非 200 / 坏
/// payload / 无可采纳候选）；client 抛出的异常不在这里吞 —— 与 React
/// matchCover 的 catch-all（cover-source.js:389-395）一致，穿透到
/// [itunesSearch] 顶层归成 error（RequestAborted 则归成 aborted）。
Future<({Map<String, Object?> item, int score})?> _searchOneRegion(
  Uri url,
  CoverQuery query,
  HttpJsonClient client,
) async {
  final outcome = await client.getJson(
    url,
    timeout: _regionTimeout,
    headers: _itunesHeaders,
  );
  // 只有 JsonOk 才可能出候选；timeout / network / status / bad payload
  // 一律当 miss（Global Constraints：单区失败静默下沉，错误不打扰）。
  if (outcome is! JsonOk) {
    return null;
  }
  final payload = outcome.json;
  final results = payload is Map ? payload['results'] : null;
  if (results is! List) {
    return null;
  }
  return pickBestScored(results, query);
}

/// iTunes 两区搜索（对译 music-api.ts:685-690 fetchCover 的两区循环 +
/// cover-source.js 的 matchCover 裁决；JSONP 通道不移植，改一级直连）。
///
/// 顺序 CN（带 country=CN）→ 默认美区（不带 country），两区串行、单区 10s；
/// 每区拿到候选后**不立即返回**，两区结果全局取 score 更高者（持平取先出现
/// 的 CN）。任何失败（网络错 / 非 200 / 坏 payload / 无候选）都当该区 miss，
/// 绝不外抛；预先取消或请求中途取消 → aborted；两区都 miss → not-found。
Future<CoverMatch> itunesSearch({
  required CoverQuery query,
  required HttpJsonClient client,
  CancelToken? cancel,
}) async {
  if (query.trackName.isEmpty) {
    return const CoverMatch(status: 'empty-query', message: '曲目信息不足，无法匹配封面');
  }
  if (cancel?.isCancelled ?? false) {
    return const CoverMatch(status: 'aborted');
  }

  // term = [artistName, trackName].filter(Boolean).join(' ')（music-api.ts:686）。
  final term = [query.artistName, query.trackName]
      .where((part) => part.isNotEmpty)
      .join(' ');

  try {
    ({Map<String, Object?> item, int score})? best;
    for (final cn in const [true, false]) {
      final candidate = await _searchOneRegion(
        _regionUri(term, cn: cn),
        query,
        client,
      );
      if (candidate != null && (best == null || candidate.score > best.score)) {
        best = candidate;
      }
      if (cancel?.isCancelled ?? false) {
        return const CoverMatch(status: 'aborted');
      }
    }
    if (best == null) {
      return const CoverMatch(status: 'not-found');
    }
    final url = best.item['artworkUrl100'];
    if (url is! String || url.isEmpty) {
      // pickBestScored 只收非空 artworkUrl100，这条守卫照 React 的
      // `result.status === 'ok' && result.url` 双保险写死，实际到不了。
      return const CoverMatch(status: 'not-found');
    }
    return CoverMatch(status: 'ok', url: artworkBig(url), source: 'iTunes');
  } on RequestAborted {
    return const CoverMatch(status: 'aborted');
  } catch (_) {
    return const CoverMatch(status: 'error', message: '封面匹配失败');
  }
}
