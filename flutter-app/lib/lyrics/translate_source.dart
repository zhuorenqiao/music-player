// lib/lyrics/translate_source.dart
//
// 译文源：把 T3 的查询归一、T6 的代理策略、T7 同构的两层缓存与 T10 的认歌纯函数
// 装配成「一次取译文」。对译 React 版 src/lib/translate-source.js:187-271
// （fetchTranslation 客户端流程，含 v2 缓存）与 src/server/music-api.ts:524-622、
// 833-868（代理侧的认歌 + 取 tlyric + 磁盘缓存）。
// 纯 Dart + 注入接缝：网络走 HttpJsonClient，不依赖 Flutter UI，
// 测试不碰真网络。
//
// 与 React 的三处**有意**差异（T1 裁定，见 brief）：
// 1. 不产出 unavailable：没有代理这一层，404/405/非 JSON content-type 三个判据都不存在；
// 2. 不预判 offline：Dart 没有 navigator.onLine 且不引依赖，离线会以真实的 unreachable 表达；
// 3. error 的 message 用代理那套（classifyOutcome(..., '译文库')），不用客户端那句
//    「连不上译文库，请检查本地服务是否在跑」——后者在桌面应用里指向不存在的东西。
//    transNote 只按 reason 分支，用户可见文案不受影响。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见 test/lyrics/translate_source_test.dart）：
// * 关键词是 `[artist, name]` 用单空格连接、**歌手在前**（music-api.ts:572）；
// * 占位歌手集合是 5 项小写含 'unknown' / 'various artists'，判定用
//   `PLACEHOLDER_ARTISTS.has(artistName.trim().toLowerCase())`——与 T3 那份只有 3 项、
//   大小写敏感的集合**不同**，不要共用（T10 里的同名常量也不合并到一处）；
// * 候选顺序：translatePairs 之后**追加** `{name: trackName, artist: '', strict: false}`，
//   追加发生在去重之后，所以 artist 为空时会重复搜一次——照抄原版，别「顺手去掉」；
// * 命中即 break；搜索抛错收进 failures 后**继续试下一个候选**；全部候选跑完仍无歌时
//   有 failure 就抛 worstFailure（把网络问题说成「没收录」会让用户以为功能坏了），
//   没有才 not-found + song-not-matched；
// * 认到歌但 tlyric.lyric 缺失 / 非字符串 / trim 后为空 → not-found + no-translation；
//   lrc.lyric 为空不影响 ok；
// * 译文链路的重试策略与歌词链路不同：单程 8s、尝试 2 次、固定 400ms、
//   只重试 timeout/unreachable（rate-limit 与 upstream 直接抛）、不读 Retry-After
//   ——这些都在 T6 的代理策略里，本层只传对参数；
// * 只把 ok / not-found 写进缓存，网络类错误不写；useCache:false 只跳过「读」，仍然写；
// * 上游抛错先试**过期**磁盘缓存，命中时 source 追加「（离线缓存）」；
// * 取消一律静默穿透：RequestAborted 一路冒到 fetch 外，不写缓存、不给用户看错误。
import 'dart:async';

import 'netease_match.dart';
import 'query.dart';
import 'translate_cache.dart';
import 'upstream.dart';

/// 网易云搜索 / 取译文端点（music-api.ts:41-42）。
const String _searchEndpoint = 'https://music.163.com/api/search/get';
const String _lyricEndpoint = 'https://music.163.com/api/song/lyric';

/// 单程预算（music-api.ts:53 的 TRANSLATE_TIMEOUT）：两条链路都是 8s。
const Duration _stepTimeout = Duration(seconds: 8);

/// 每步尝试次数（music-api.ts:526 / :607 的 `fetchJsonWithRetry(url, timeout, 2)`）。
const int _attempts = 2;

/// 整次调用的总预算：客户端原来的代理超时值（translate-source.js:38）。
/// 代理侧最坏是「搜索 2 次重试 × 3 组候选 + 取译文 2 次重试」，前端预算必须比它长。
const Duration _totalBudget = Duration(seconds: 45);

/// 分类器用的来源名（决定「译文库」四个字与全角括号）。
const String _sourceLabel = '译文库';

/// 成功的 source（music-api.ts:618）。
const String _okSource = '网易云译文库（人工翻译）';

/// 过期磁盘缓存命中时追加的后缀（music-api.ts:860）。
const String _staleSuffix = '（离线缓存）';

/// 一次取译文的结果。永不抛错（主动取消除外），失败一律以 [status] 表达。
class TranslationResult {
  const TranslationResult({
    required this.status,
    this.translatedLyrics = '',
    this.originalLyrics = '',
    this.source = '网易云译文库',
    this.reason = '',
    this.message = '',
  });

  /// `ok | not-found | empty-query | error`。
  final String status;
  final String translatedLyrics;
  final String originalLyrics;
  final String source;

  /// `''` | `'song-not-matched'` | `'no-translation'` | 四类网络失败原因。
  final String reason;
  final String message;
}

/// 双语状态机只认这个接口，不认具体实现（测试注入假源）。
abstract class TranslationFetcher {
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  });
}

/// 译文源：候选认歌 + 取 tlyric + 两层缓存 + 过期回退。
class TranslateSource implements TranslationFetcher {
  TranslateSource({required this.client, required this.disk, this.index});

  final HttpJsonClient client;
  final TranslationDiskCache disk;

  /// 索引层可空：只为「没有 prefs」的场景留门，生产装配总会给。
  final TranslationIndexCache? index;

  /// 本地文件没标签时的占位歌手，拿去当搜索词只会污染结果（music-api.ts:532）。
  ///
  /// 刻意与 T3 `normalizeQuery` 里那份只有 3 项、大小写敏感的集合**分开写**：
  /// 这里含 lowercase 的 'unknown' / 'various artists'，是译文侧独有的口径。
  static const List<String> placeholderArtists = [
    '本地文件',
    '未知歌手',
    '未知',
    'unknown',
    'various artists',
  ];

  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) async {
    final query = normalizeQuery(
      title: title,
      artist: artist,
      duration: duration,
    );
    if (query.trackName.isEmpty) {
      return const TranslationResult(status: 'empty-query');
    }

    // 索引命中直接返回；useCache:false 只跳过「读」，后面的写照旧。
    if (useCache) {
      final cached = await index?.read(query.key);
      if (cached != null) {
        return TranslationResult(
          status: cached.status,
          translatedLyrics: cached.translated,
          originalLyrics: cached.original,
          source: cached.source,
          reason: cached.reason,
        );
      }
    }

    try {
      final record = await _withinBudget(
        () => _fetchTranslation(query, cancel: cancel),
      );
      // 只有 ok / not-found 会走到这里（网络类错误一律抛出去），写两层缓存。
      await _writeCaches(query, record);
      return TranslationResult(
        status: record.status,
        translatedLyrics: record.translated,
        originalLyrics: record.original,
        source: record.isOk ? record.source : '',
        reason: record.reason,
      );
    } on RequestAborted {
      // 取消是静默的：不写缓存、不给用户看错误，原样冒到 fetch 外。
      rethrow;
    } on UpstreamFailure catch (failure) {
      // 上游抛错才试过期磁盘缓存；not-found 是正常结果，走不到这里。
      final stale = await disk.read(_diskKey(query), allowStale: true);
      if (stale != null) {
        return TranslationResult(
          status: stale.status,
          translatedLyrics: stale.translated,
          originalLyrics: stale.original,
          // 原版是 `{...stale, source: `${stale.source}（离线缓存）`}`：追加，不是覆盖。
          source: '${stale.source}$_staleSuffix',
          reason: stale.reason,
        );
      }
      return TranslationResult(
        status: 'error',
        reason: reasonId(failure.reason),
        message: failure.message,
      );
    }
  }

  // -- 内部 ---------------------------------------------------------------

  String _diskKey(LyricsQuery query) => TranslationDiskCache.keyFor(
    title: query.trackName,
    artist: query.artistName,
    duration: query.duration,
  );

  Future<void> _writeCaches(LyricsQuery query, TranslationRecord record) async {
    await index?.write(query.key, record);
    await disk.write(_diskKey(query), record);
  }

  /// 整段候选循环的总预算（translate-source.js:38 的 45000ms）。
  ///
  /// 到点按 timeout 分类，话术与真超时同一句（`_budgetFailure` 已由分类器给出）；
  /// 底层请求仍在跑（Dart 的 http 不支持 abort），但写缓存只发生在正常返回之后，
  /// 所以晚到的结果落不了盘。
  Future<T> _withinBudget<T>(Future<T> Function() body) async {
    try {
      return await body().timeout(_totalBudget);
    } on TimeoutException {
      throw _budgetFailure;
    }
  }

  /// 认歌 + 取译文（music-api.ts:563-622）。只在拿到 ok / not-found 时正常返回。
  Future<TranslationRecord> _fetchTranslation(
    LyricsQuery query, {
    CancelToken? cancel,
  }) async {
    final artist =
        placeholderArtists.contains(query.artistName.trim().toLowerCase())
        ? ''
        : query.artistName.trim();
    // 追加发生在 translatePairs 去重**之后**：artist 为空时这里与首条重复，
    // 于是同一关键词会多搜一次——照抄原版（music-api.ts:567 的注释与代码）。
    final candidates = <TranslateCandidate>[
      ...translatePairs(query.trackName, artist),
      TranslateCandidate(name: query.trackName, artist: '', strict: false),
    ];

    final failures = <UpstreamFailure>[];
    NetEaseSong? matched;
    for (final candidate in candidates) {
      final keyword = candidate.keyword;
      if (keyword.isEmpty) {
        continue;
      }
      try {
        final songs = parseNetEaseSongs(await _search(keyword, cancel));
        matched = pickTranslatableSong(
          songs,
          trackName: candidate.name,
          artistName: candidate.artist,
          duration: query.duration,
          strict: candidate.strict,
        );
      } on RequestAborted {
        // 取消不是「上游失败」：穿透到外层按静默取消处理，不收集、不继续。
        rethrow;
      } on UpstreamFailure catch (failure) {
        // 某个候选搜挂了（超时 / 连不上 / 限流）不放弃整次匹配，试下一个。
        failures.add(failure);
        continue;
      }
      if (matched != null) {
        break;
      }
    }

    final song = matched;
    if (song == null) {
      // 搜索全失败时报错而不是「未收录」：把网络问题说成「这首歌没有译文」，
      // 用户就会以为功能坏了（music-api.ts:594-601）。
      if (failures.isNotEmpty) {
        throw worstFailure(failures);
      }
      return const TranslationRecord(
        status: 'not-found',
        reason: 'song-not-matched',
      );
    }

    final data = await _fetchLyric(song.id, cancel);
    final translated = _lyricOf(data, 'tlyric');
    final original = _lyricOf(data, 'lrc');
    if (translated.trim().isEmpty) {
      return const TranslationRecord(
        status: 'not-found',
        reason: 'no-translation',
      );
    }
    return TranslationRecord(
      status: 'ok',
      translated: translated,
      original: original,
      source: _okSource,
    );
  }

  Future<Object?> _search(String keyword, CancelToken? cancel) =>
      requestJsonProxyPolicy(
        client,
        Uri.parse(
          _searchEndpoint,
        ).replace(queryParameters: {'s': keyword, 'type': '1', 'limit': '20'}),
        timeout: _stepTimeout,
        attempts: _attempts,
        classify: _classify,
        cancel: cancel,
      );

  Future<Object?> _fetchLyric(int id, CancelToken? cancel) =>
      requestJsonProxyPolicy(
        client,
        Uri.parse(_lyricEndpoint)
            .replace(queryParameters: {'id': '$id', 'lv': '1', 'tv': '1'}),
        timeout: _stepTimeout,
        attempts: _attempts,
        classify: _classify,
        cancel: cancel,
      );
}

UpstreamFailure _classify(JsonOutcome outcome) =>
    classifyOutcome(outcome, _sourceLabel);

/// 总预算到点的失败：按 timeout 分类，话术与真超时同一句。
final UpstreamFailure _budgetFailure = _classify(const JsonTimeout());

/// 取 `data[key].lyric`：任一层不是 Map / 不是 String 都给 ''（music-api.ts:609-610）。
String _lyricOf(Object? data, String key) {
  if (data is! Map) return '';
  final section = data[key];
  if (section is! Map) return '';
  final lyric = section['lyric'];
  return lyric is String ? lyric : '';
}
