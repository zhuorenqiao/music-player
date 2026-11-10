// lib/lyrics/lyrics_source.dart
//
// 歌词匹配源：把 T3 的查询归一、T6 的客户端策略与 T7 的两层缓存装配成「一次匹配」。
// 对译 React 版 src/lib/lyrics-source.js:590-627（matchLyrics 外层流程）与
// src/server/music-api.ts:249-391（job 构造 + pickBestLyrics + 裁决）。
// 纯 Dart + 注入接缝：网络走 HttpJsonClient、退避走注入的 sleep、冷却闸可注入，
// 不依赖 Flutter UI，测试不碰真网络也不靠真时间。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见 test/lyrics/lyrics_source_test.dart）：
// * job 顺序即优先级：原方向（带时长 get → 不带时长 get）→ 对调方向（同）→ 1 条 search，
//   全部并行、全部等完再裁决，绝不短路（eagerError: false 的语义）；
// * 裁决顺序 synced getHit → synced searchHit → 任意 getHit → worstFailure(getErrors)
//   → searchHit → worstFailure(errors) → not-found：get 是权威那一路，它一次都没跑通时
//   宁可报错，也不把限流 / 超时说成「未找到」；
// * search 的打分基准永远是「原方向」(trackName, artistName)，与那一趟用哪个方向发请求无关；
// * 打分用双向 contains（`name.includes(want) || want.includes(name)`），歌手权重只在
//   wantArtist 非空时参与；时长评分只在拿到有限数值时参与（React 里 Number(undefined)
//   是 NaN，此处 null / 非数字同样视作「不参与」）；
// * 「索引命中」优先于一切网络，且命中时不碰冷却闸；未命中命中（miss）的 source 是「缓存」，
//   ok 命中的 source 取条目自己的（默认 'LRCLIB'）；
// * 只有真正发请求的那条路才动冷却（T6 的策略函数内部 note / clear），
//   上游失败结果**不写**缓存；
// * 上游抛错才回退过期磁盘缓存，且 source 硬编码「LRCLIB（离线缓存）」；
//   not-found 是正常结果、不回退（与 React 代理侧一致）；
// * useCache: false（手动重试 / 重开双语）只跳过「读」，仍然写；
// * 取消一律静默：aborted 不写缓存、不动冷却闸、不给用户看错误（controller R16）。
//   abort 绝不碰闸（React lyrics-source.js:617-619 的 aborted 分支也不碰）：冷却即便
//   是本轮某条请求记下的，也是真实的上游信号，留着让下一次匹配安静跳过而不是再打
//   2~5 条请求回来换一句「歌词库正在限流（HTTP 429）」。
import 'dart:async';

import 'lyrics_cache.dart';
import 'query.dart';
import 'upstream.dart';

/// 上游根（music-api.ts:39）。
final Uri _upstream = Uri.parse('https://lrclib.net/api');

/// 单路超时与尝试次数（music-api.ts:50-52）。
const Duration _getTimeout = Duration(seconds: 12);
const Duration _searchTimeout = Duration(seconds: 26);

/// 整次匹配的总预算：到点取消并按 timeout 分类。
const Duration _totalBudget = Duration(seconds: 60);

const int _getAttempts = 2;
const int _searchAttempts = 1;

/// 分类器用的来源名（决定「歌词库」四个字与全角括号）。
const String _sourceLabel = '歌词库';

/// 过期磁盘缓存的 source（music-api.ts:817 硬编码）。
const String _staleSource = 'LRCLIB（离线缓存）';

/// 索引命中「未找到」时的 source（lyrics-source.js 的 readCached）。
const String _cacheMissSource = '缓存';

const String _kindGet = 'get';
const String _kindSearch = 'search';

/// 一次匹配的结果。永不抛错，失败一律以 [status] 表达。
class LyricsMatch {
  const LyricsMatch({
    required this.status,
    this.synced = '',
    this.plain = '',
    this.source = '',
    this.reason,
    this.message = '',
    this.rateLimited = false,
  });

  /// `ok | not-found | error | aborted | empty-query`。
  final String status;
  final String synced;
  final String plain;
  final String source;

  /// 仅 error 有值：四类失败原因之一。
  final UpstreamReason? reason;
  final String message;
  final bool rateLimited;
}

/// 状态机只认这个接口，不认具体实现（测试注入假源）。
abstract class LyricsMatcher {
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  });
}

/// 歌词匹配源：并行 job + 顺序裁决 + 冷却闸 + 两层缓存 + 过期回退。
class LyricsSource implements LyricsMatcher {
  LyricsSource({
    required this.client,
    required this.disk,
    this.index,
    RateLimitGate? gate,
    this.getTimeout = _getTimeout,
    this.searchTimeout = _searchTimeout,
    this.totalBudget = _totalBudget,
    this.sleep,
  }) : gate = gate ?? RateLimitGate();

  final HttpJsonClient client;
  final LyricsDiskCache disk;

  /// 索引层可空：只为「没有 prefs」的场景留门，生产装配总会给。
  final LyricsIndexCache? index;

  /// 限流冷却闸；不注入时自建一个（单实例装配，等价于 React 的模块级状态）。
  final RateLimitGate gate;

  final Duration getTimeout;
  final Duration searchTimeout;

  /// 整次匹配的总预算：到点按 timeout 分类、放弃写缓存。
  final Duration totalBudget;

  /// 退避用的睡眠；测试注入空实现，免得靠真时间。
  final Future<void> Function(Duration)? sleep;

  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async {
    if (query.trackName.isEmpty) {
      return const LyricsMatch(status: 'empty-query', message: '曲目信息不足，无法匹配歌词');
    }

    // 已取消的匹配不碰网络、不写缓存，也不改动冷却闸：一个 abort 从不碰闸。
    // 这里什么请求都没发，闸上若有关着的窗口，那一定是别人记下的，删不得。
    if (cancel?.isCancelled ?? false) {
      return const LyricsMatch(status: 'aborted');
    }

    // 索引优先于一切网络；命中不改冷却（与 React 一致：只有真正发请求才清）。
    if (useCache) {
      final cached = await index?.read(query.key);
      if (cached != null) {
        return LyricsMatch(
          status: cached.status,
          synced: cached.synced,
          plain: cached.plain,
          source: cached.isOk ? cached.source : _cacheMissSource,
        );
      }
    }

    // 冷却期内不再自动发请求；手动重试（useCache: false）旁路。
    if (useCache && gate.isLimited) {
      return const LyricsMatch(
        status: 'error',
        rateLimited: true,
        message: '歌词服务刚才在限流，请稍后点「重试」',
      );
    }

    final abandoned = _AbandonGuard();
    try {
      final record = await _fetch(query, cancel: cancel, abandoned: abandoned);
      if (cancel?.isCancelled ?? false) {
        throw const RequestAborted();
      }
      // 总预算到点后 _fetch 会抛 UpstreamFailure，写缓存只发生在这里，
      // 所以「晚到的结果」本来落不了盘；这道判断把约束显式钉住，
      // 将来若有人把写缓存挪进 job，它会立刻拦住。
      if (!abandoned.isAbandoned) {
        await _writeCaches(query, record);
      }
      return LyricsMatch(
        status: record.status,
        synced: record.synced,
        plain: record.plain,
        source: record.isOk ? record.source : '',
      );
    } on RequestAborted {
      // R16：取消是静默的 —— 不写缓存、不给用户看错误，且不动冷却闸。
      // 闸上的窗口（包括本轮某条请求因 429 / 503 记下的）是真实的上游信号：
      // 清掉它会让下一次匹配再打 2~5 条请求，并换回一句「歌词库正在限流（HTTP 429）」，
      // 而不是冷却本来要产生的安静跳过。React 的 aborted 分支同样不碰闸
      // （src/lib/lyrics-source.js:617-619）。
      return const LyricsMatch(status: 'aborted');
    } on UpstreamFailure catch (failure) {
      // 上游抛错才试过期缓存；not-found 是正常结果，走不到这里。
      final stale = await disk.read(_primaryKey(query), allowStale: true);
      if (stale != null) {
        return LyricsMatch(
          status: stale.status,
          synced: stale.synced,
          plain: stale.plain,
          // 原版是 `{...stale, source: 'LRCLIB（离线缓存）'}`：无条件覆盖。
          source: _staleSource,
        );
      }
      return LyricsMatch(
        status: 'error',
        reason: failure.reason,
        message: failure.message,
        rateLimited: failure.reason == UpstreamReason.rateLimit,
      );
    } catch (_) {
      return const LyricsMatch(status: 'error', message: '歌词匹配失败，请稍后点「重试」');
    }
  }

  /// 清掉限流冷却（设置页 / 调试用）。
  void clearCooldown() => gate.clear();

  // -- 内部 ---------------------------------------------------------------

  String _primaryKey(LyricsQuery query) => LyricsDiskCache.keyFor(
    query.trackName,
    query.artistName,
    '${query.duration}',
  );

  Future<void> _writeCaches(LyricsQuery query, LyricsRecord record) async {
    await index?.write(query.key, record);
    await disk.writeDual(
      _primaryKey(query),
      LyricsDiskCache.keyFor(
        query.artistName,
        query.trackName,
        '${query.duration}',
      ),
      record,
    );
  }

  /// 构造全部 job（顺序即优先级），然后等它们**全部**结束。
  Future<LyricsRecord> _fetch(
    LyricsQuery query, {
    CancelToken? cancel,
    required _AbandonGuard abandoned,
  }) async {
    final jobs = _buildJobs(query, cancel);
    final settled = await _settleAll(jobs, abandoned);

    // R16：T6 的重试循环只在尝试开头查取消，最后一次在途请求被取消时
    // 会抛成 timeout 之类的失败。裁决之前补一次，取消就不许再往下走。
    if (cancel?.isCancelled ?? false) {
      throw const RequestAborted();
    }

    LyricsRecord? getHit;
    LyricsRecord? searchHit;
    final errors = <UpstreamFailure>[];
    final getErrors = <UpstreamFailure>[];

    for (var i = 0; i < settled.length; i += 1) {
      final entry = settled[i];
      final error = entry.error;
      if (error != null) {
        // 取消不是「上游失败」，穿透到外层按 aborted 处理。
        if (error is RequestAborted) throw error;
        final failure = _classifyThrown(error);
        errors.add(failure);
        if (jobs[i].kind == _kindGet) getErrors.add(failure);
        continue;
      }
      final record = entry.record!;
      // toLyricsResult：not-found 不算 hit（get 命中但两个字段都空也是）。
      if (!record.isOk) continue;
      if (jobs[i].kind == _kindGet) {
        getHit ??= record;
      } else {
        searchHit ??= record;
      }
    }

    if (getHit != null && _hasSynced(getHit)) return getHit;
    if (searchHit != null && _hasSynced(searchHit)) return searchHit;
    if (getHit != null) return getHit;
    if (getErrors.isNotEmpty) throw worstFailure(getErrors);
    if (searchHit != null) return searchHit;
    if (errors.isNotEmpty) throw worstFailure(errors);
    return const LyricsRecord(status: 'not-found');
  }

  List<_Job> _buildJobs(LyricsQuery query, CancelToken? cancel) {
    final jobs = <_Job>[];
    for (final (name, artist) in _pairs(query.trackName, query.artistName)) {
      final base = <String, String>{'track_name': name};
      if (artist.isNotEmpty) base['artist_name'] = artist;
      // 带时长的那一路命中率最高，排在前面。
      if (query.duration != 0) {
        final withDuration = <String, String>{
          ...base,
          'duration': '${query.duration}',
        };
        jobs.add((kind: _kindGet, run: () => _runGet(withDuration, cancel)));
      }
      jobs.add((kind: _kindGet, run: () => _runGet(base, cancel)));
    }
    // 口袋查询：曲名与歌手拼成一段（music-api.ts:323）。
    final loose = [
      query.trackName,
      query.artistName,
    ].where((part) => part.isNotEmpty).join(' ');
    jobs.add((kind: _kindSearch, run: () => _runSearch(loose, query, cancel)));
    return jobs;
  }

  Future<LyricsRecord> _runGet(
    Map<String, String> params,
    CancelToken? cancel,
  ) async {
    final json = await requestJsonClientPolicy(
      client,
      _apiUri('get', params),
      timeout: getTimeout,
      attempts: _getAttempts,
      classify: _classify,
      gate: gate,
      cancel: cancel,
      sleep: sleep,
    );
    return _toLyricsRecord(json);
  }

  Future<LyricsRecord> _runSearch(
    String loose,
    LyricsQuery query,
    CancelToken? cancel,
  ) async {
    final json = await requestJsonClientPolicy(
      client,
      _apiUri('search', {'q': loose}),
      timeout: searchTimeout,
      attempts: _searchAttempts,
      classify: _classify,
      gate: gate,
      cancel: cancel,
      sleep: sleep,
    );
    // 打分基准永远是原方向，不是这一趟用的方向（music-api.ts:328）。
    final want = _pairs(query.trackName, query.artistName).first;
    return _toLyricsRecord(
      _pickBestLyrics(json, want.$1, want.$2, query.duration),
    );
  }

  /// 等全部 job（`eagerError: false` 语义）：每条的成败与顺序都留住。
  Future<List<_Settled>> _settleAll(
    List<_Job> jobs,
    _AbandonGuard abandoned,
  ) async {
    final futures = <Future<_Settled>>[
      for (final job in jobs)
        () async {
          try {
            return _Settled.record(await job.run());
          } catch (error) {
            return _Settled.error(error);
          }
        }(),
    ];
    try {
      return await Future.wait(futures).timeout(totalBudget);
    } on TimeoutException {
      // 底层请求仍在跑（Dart 的 http 不支持 abort），标记作废，晚到结果不许落盘。
      abandoned.abandon();
      throw _budgetFailure;
    }
  }
}

UpstreamFailure _classify(JsonOutcome outcome) =>
    classifyOutcome(outcome, _sourceLabel);

/// `https://lrclib.net/api/<segment>?<params>`。
///
/// 空格由 `Uri.replace(queryParameters:)` 编成 `+`，与 React 的 URLSearchParams
/// 一致；两边服务端都接受，`queryParameters` 读回来就是原文。
Uri _apiUri(String segment, Map<String, String> params) =>
    Uri.parse('$_upstream/$segment').replace(queryParameters: params);

/// 总预算到点的失败：按 timeout 分类，话术与真超时同一句。
final UpstreamFailure _budgetFailure = _classify(const JsonTimeout());

/// 一条 job：`kind` 决定它在裁决里的角色，`run` 是那一趟请求。
typedef _Job = ({String kind, Future<LyricsRecord> Function() run});

/// 一条 job 的结局：成功给记录，失败给捕获到的异常（保留顺序）。
class _Settled {
  const _Settled.record(this.record) : error = null;
  const _Settled.error(this.error) : record = null;

  final LyricsRecord? record;
  final Object? error;
}

/// 总预算到点后的作废标记。
class _AbandonGuard {
  bool _abandoned = false;

  void abandon() => _abandoned = true;

  bool get isAbandoned => _abandoned;
}

/// `(歌名, 歌手)` 候选，顺序即优先级：原方向 → 对调方向
/// （music-api.ts:294-300：文件名拆反时查询参数是反的，对调再试几乎零成本）。
List<(String, String)> _pairs(String trackName, String artistName) {
  final pairs = <(String, String)>[(trackName, artistName)];
  if (artistName.isNotEmpty && artistName != trackName) {
    pairs.add((artistName, trackName));
  }
  return pairs;
}

String _str(Object? value) => value is String ? value : '';

/// 上游 JSON → 缓存记录（`toLyricsResult`，music-api.ts:235-250）。
///
/// 非 Map → not-found；`syncedLyrics` / `plainLyrics` 不是字符串 → ''；
/// 两者都空 → not-found。
LyricsRecord _toLyricsRecord(Object? json) {
  final record = json is Map ? json : null;
  final synced = _str(record?['syncedLyrics']);
  final plain = _str(record?['plainLyrics']);
  if (record == null || (synced.isEmpty && plain.isEmpty)) {
    return const LyricsRecord(status: 'not-found');
  }
  return LyricsRecord(
    status: 'ok',
    synced: synced,
    plain: plain,
    source: 'LRCLIB',
  );
}

/// 从搜索结果里挑最合适的一条（逐字对译 music-api.ts:253-286）。
///
/// 打分：有时间轴 50 / 歌名全等 30 / 歌名包含 12 / 歌手全等 25 / 歌手包含 10 /
/// 时长差 ≤2s 30、≤6s 12、>25s −25；只在 `score > bestScore` 时替换，
/// `bestScore` 初值 0（所以全场非正的候选一条都不选）。
Object? _pickBestLyrics(
  Object? items,
  String wantName,
  String wantArtist,
  int duration,
) {
  if (items is! List || items.isEmpty) return null;
  final wantTitle = wantName.toLowerCase();
  final wantArtistName = wantArtist.toLowerCase();
  final wantDuration = duration > 0 ? duration : 0;

  Map<Object?, Object?>? best;
  var bestScore = 0;
  for (final raw in items) {
    final item = raw is Map ? raw : const <Object?, Object?>{};
    var score = 0;
    if (_str(item['syncedLyrics']).trim().isNotEmpty) score += 50;
    final name = _str(item['trackName'] ?? item['name']).toLowerCase();
    if (name.isNotEmpty && name == wantTitle) {
      score += 30;
    } else if (name.isNotEmpty &&
        (name.contains(wantTitle) || wantTitle.contains(name))) {
      score += 12;
    }
    final artist = _str(item['artistName']).toLowerCase();
    if (wantArtistName.isNotEmpty && artist == wantArtistName) {
      score += 25;
    } else if (wantArtistName.isNotEmpty && artist.contains(wantArtistName)) {
      score += 10;
    }
    final itemDuration = _finiteNumber(item['duration']);
    if (wantDuration > 0 && itemDuration != null) {
      final diff = (itemDuration - wantDuration).abs();
      if (diff <= 2) {
        score += 30;
      } else if (diff <= 6) {
        score += 12;
      } else if (diff > 25) {
        score -= 25;
      }
    }
    if (score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  return best;
}

/// 时长的数值侧（React 的 `Number()` + `Number.isFinite()`）：数字与数字串可用，
/// 其余（缺字段 / null / 非数字串）视作「不参与评分」。
double? _finiteNumber(Object? value) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}

bool _hasSynced(LyricsRecord record) => record.synced.trim().isNotEmpty;

/// 抛出来的东西统一成四类失败：T6 的策略已分类的照抄，
/// 其余按 React 的 `classifyError` 兜底成 unreachable（music-api.ts:93）。
UpstreamFailure _classifyThrown(Object error) {
  if (error is UpstreamFailure) return error;
  return UpstreamFailure(
    UpstreamReason.unreachable,
    '连不上$_sourceLabel，请检查网络或代理设置',
  );
}
