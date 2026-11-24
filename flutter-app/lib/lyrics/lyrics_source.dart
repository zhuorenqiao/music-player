// lib/lyrics/lyrics_source.dart
//
// 歌词匹配源：把 T3 的查询归一、T6 的客户端策略与 T7 的两层缓存装配成「一次匹配」。
// 对译 React 版 src/lib/lyrics-source.js:590-627（matchLyrics 外层流程）与
// src/server/music-api.ts:249-391（job 构造 + pickBestLyrics + 裁决）。
// 纯 Dart + 注入接缝：网络走 HttpJsonClient、退避走注入的 sleep、冷却闸可注入，
// 不依赖 Flutter UI，测试不碰真网络也不靠真时间。
//
// 2026-11-23 起是**四源**：LRCLIB 优先，汽水次之，酷狗第三，网易云兜底。
// qishui / kugou / netease 都可空 —— 为空时只剩 LRCLIB（单测都按这个形态钉），
// 生产装配（main.dart）总会给。LRCLIB 没词 / 上游失败时静默落到后三家：它们只是
// 「补位」，挂了不该把整体结论改写成网络错误；但 LRCLIB 若是明确失败且三家都没词，
// 最终仍报那条失败（限流 / 超时不能说成「未找到」）。
//
// 缓存纪元：新结果写在 `v4|` 前缀的键下（索引键与磁盘 sha1 的输入都带前缀）。
// v3（四源时代）、v2（网易云时代）与 v1（LRCLIB 时代）的键仍然读，但只当**兜底**：
// 命中后不会立刻返回，而是先问一遍新源；新源有词就用新词，没有才把老结果拿出来。
// 这样「LRCLIB 优先」对已经缓存过的歌也生效，离线时又不会因为换了源而丢掉手里的歌词。
// 旧的「未找到」缓存（miss）不再挡路 —— 它们正是前几个时代留下的负结论，必须让新源有机会翻案。
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
// * 「v4 索引命中」优先于一切网络，且命中时不碰冷却闸；旧纪元（v3/v2/v1）的命中
//   只当兜底，先让新源说话；miss 的 source 是「缓存」，ok 命中的 source 取条目自己的；
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
import 'lyrics_provider.dart';
import 'opencc/converter.dart';
import 'query.dart';
import 'script_fold.dart';
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

/// 过期磁盘缓存的 source 后缀（music-api.ts:817 硬编码的是「LRCLIB（离线缓存）」；
/// 这里改成「条目自己的 source + 后缀」，LRCLIB 条目结果仍逐字相同）。
const String _staleSuffix = '（离线缓存）';

/// 缓存纪元前缀：v4 起 LRCLIB 是第一优先（LRCLIB → 汽水 → 酷狗 → 网易云），
/// 旧键只读不写（见文件头的说明）。
const String _cacheEpoch = 'v4';

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

/// 结果 source → 持久化的来源 id（`'qishui'` / `'kugou'` / `'netease'` / `'lrclib'` / `''`）。
///
/// 缓存里的 source 是给人看的字面量（「汽水音乐」「酷狗音乐」「网易云音乐」「LRCLIB」），
/// 落进 Track 的是稳定 id，界面文案以后者的映射为准。
String lyricsOriginOf(String source) {
  if (source.contains('汽水')) return 'qishui';
  if (source.contains('酷狗')) return 'kugou';
  if (source.contains('网易云')) return 'netease';
  if (source.contains('LRCLIB')) return 'lrclib';
  return '';
}

/// 来源 id → 状态行里的名称。
String lyricsOriginLabel(String origin) => switch (origin) {
  'qishui' => '汽水音乐',
  'kugou' => '酷狗音乐',
  'netease' => '网易云音乐',
  'lrclib' => 'LRCLIB线上库',
  // 老档案没有来源字段：只敢说「线上歌词库」，不冒充某一家。
  _ => '线上歌词库',
};

/// 状态机只认这个接口，不认具体实现（测试注入假源）。
abstract class LyricsMatcher {
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  });
}

/// 单个歌词源的接口见 lyrics_provider.dart（避免循环 import）。

/// 歌词匹配源：并行 job + 顺序裁决 + 冷却闸 + 两层缓存 + 过期回退。
class LyricsSource implements LyricsMatcher {
  LyricsSource({
    required this.client,
    required this.disk,
    this.index,
    this.qishui,
    this.kugou,
    this.netease,
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

  /// 汽水音乐（第二优先）。可空：单测按「只有 LRCLIB」的老形态钉行为。
  final LyricsProvider? qishui;

  /// 酷狗音乐（第三优先）。可空。
  final LyricsProvider? kugou;

  /// 网易云歌词源（第四优先 / 兜底）。可空：单测按「只有 LRCLIB」的老形态钉行为。
  final LyricsProvider? netease;

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
    // 查询参数先折到简体（繁体标签对不上 LRCLIB 的简体记录，见 script_fold.dart）。
    // 原字形留在 rawQuery 里，简体全没命中时补一次原字形搜索。
    final rawQuery = query;
    final effectiveQuery = foldQuery(query);

    // 已取消的匹配不碰网络、不写缓存，也不改动冷却闸：一个 abort 从不碰闸。
    // 这里什么请求都没发，闸上若有关着的窗口，那一定是别人记下的，删不得。
    if (cancel?.isCancelled ?? false) {
      return const LyricsMatch(status: 'aborted');
    }

    // 索引优先于一切网络；命中不改冷却（与 React 一致：只有真正发请求才清）。
    // 新纪元命中直接返回；旧纪元的命中只留作兜底，先让新源有机会说话。
    LyricsRecord? legacy;
    if (useCache) {
      final cached = await index?.read(_indexKey(effectiveQuery));
      if (cached != null) {
        return LyricsMatch(
          status: cached.status,
          synced: cached.synced,
          plain: cached.plain,
          source: cached.isOk ? cached.source : _cacheMissSource,
        );
      }
      // 旧纪元（v3 → v2 → v1）的命中只留作兜底，先让新源有机会说话。
      // 旧的「未找到」不兜底：那是换源前的负结论，会挡住新源。
      legacy = await _readLegacyIndex(effectiveQuery);
    }

    final abandoned = _AbandonGuard();
    UpstreamFailure? lrclibFailure;
    final lrclibSkipped = useCache && gate.isLimited;
    try {
      // 1) LRCLIB 第一优先。冷却期内不自动发请求，手动重试（useCache: false）旁路。
      if (!lrclibSkipped) {
        try {
          final record = await _fetch(
            effectiveQuery,
            rawQuery: rawQuery,
            cancel: cancel,
            abandoned: abandoned,
          );
          if (cancel?.isCancelled ?? false) {
            throw const RequestAborted();
          }
          if (record.isOk) {
            return await _accept(effectiveQuery, record, abandoned);
          }
          // not-found 是正常结果：继续往下问汽水 / 酷狗 / 网易云。
        } on UpstreamFailure catch (failure) {
          lrclibFailure = failure;
          // 总预算到点：后三家也不再继续，交给外层做过期缓存 / 报错。
          if (abandoned.isAbandoned) {
            rethrow;
          }
        }
      }

      // 2) 补位链：汽水 → 酷狗 → 网易云。命中就停，前一家不受后一家限流影响。
      final qishuiHit = await qishui?.lookup(effectiveQuery, cancel: cancel);
      if (cancel?.isCancelled ?? false) {
        throw const RequestAborted();
      }
      if (qishuiHit != null) {
        return await _accept(effectiveQuery, qishuiHit, abandoned);
      }

      final kugouHit = await kugou?.lookup(effectiveQuery, cancel: cancel);
      if (cancel?.isCancelled ?? false) {
        throw const RequestAborted();
      }
      if (kugouHit != null) {
        return await _accept(effectiveQuery, kugouHit, abandoned);
      }

      final netEaseHit = await netease?.lookup(effectiveQuery, cancel: cancel);
      if (cancel?.isCancelled ?? false) {
        throw const RequestAborted();
      }
      if (netEaseHit != null) {
        return await _accept(effectiveQuery, netEaseHit, abandoned);
      }

      // 3) 全都跑完仍没词 / LRCLIB 明确失败：
      // LRCLIB 的失败原因更接近「这次为什么没拿到」，优先于冷却闸的泛化文案。
      if (lrclibFailure != null) {
        throw lrclibFailure;
      }
      if (lrclibSkipped) {
        if (legacy != null) {
          return _fromRecord(legacy);
        }
        return const LyricsMatch(
          status: 'error',
          rateLimited: true,
          message: '歌词服务刚才在限流，请稍后点「重试」',
        );
      }
      // 总预算到点后 _fetch 会抛 UpstreamFailure，写缓存只发生在这里，
      // 所以「晚到的结果」本来落不了盘；这道判断把约束显式钉住，
      // 将来若有人把写缓存挪进 job，它会立刻拦住。
      if (!abandoned.isAbandoned) {
        // 兜底的老结果只在「新源确实没词」时才拿出来，并顺手写成新纪元：
        // 否则每次播放都要再问一遍上游。有老词就不写 miss，
        // 避免一次网络抖动把兜底歌词永久压成「未找到」。
        await _writeCaches(
          effectiveQuery,
          legacy ?? const LyricsRecord(status: 'not-found'),
        );
      }
      if (legacy != null) {
        return _fromRecord(legacy);
      }
      return const LyricsMatch(status: 'not-found');
    } on RequestAborted {
      // R16：取消是静默的 —— 不写缓存、不给用户看错误，且不动冷却闸。
      // 闸上的窗口（包括本轮某条请求因 429 / 503 记下的）是真实的上游信号：
      // 清掉它会让下一次匹配再打 2~5 条请求，并换回一句「歌词库正在限流（HTTP 429）」，
      // 而不是冷却本来要产生的安静跳过。React 的 aborted 分支同样不碰闸
      // （src/lib/lyrics-source.js:617-619）。
      return const LyricsMatch(status: 'aborted');
    } on UpstreamFailure catch (failure) {
      // 上游抛错才试过期缓存；not-found 是正常结果，走不到这里。
      // 新纪元没有就试旧纪元（换源前缓存下来的词），再没有才报错。
      final stale =
          await disk.read(_primaryKey(effectiveQuery), allowStale: true) ??
          await disk.read(_legacyDiskKey(effectiveQuery), allowStale: true) ??
          await disk.read(_legacy2DiskKey(effectiveQuery), allowStale: true) ??
          await disk.read(_oldestDiskKey(effectiveQuery), allowStale: true);
      if (stale != null) {
        return LyricsMatch(
          status: stale.status,
          synced: stale.synced,
          plain: stale.plain,
          // 原版是 `{...stale, source: 'LRCLIB（离线缓存）'}`：无条件覆盖。
          // 这里改成在条目自己的 source 后追加，LRCLIB 的输出逐字相同。
          source: '${stale.isOk ? stale.source : ''}$_staleSuffix',
        );
      }
      if (legacy != null) {
        return _fromRecord(legacy);
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

  /// 新纪元的索引键（`v4|曲名|歌手|时长`，检索前已折简体）。
  String _indexKey(LyricsQuery query) => '$_cacheEpoch|${query.key}';

  /// 上一纪元的索引键（v3 四源时代）：只读，供换源后的兜底。
  String _legacyIndexKey(LyricsQuery query) => 'v3|${query.key}';

  /// 更早纪元的索引键（v2 网易云时代）：同样只读。
  String _legacy2IndexKey(LyricsQuery query) => 'v2|${query.key}';

  /// 最老纪元的索引键（v1 LRCLIB 时代）：同样只读。
  String _oldestIndexKey(LyricsQuery query) => query.key;

  /// 依次读 v3 → v2 → v1，只接受有词的旧条目。
  Future<LyricsRecord?> _readLegacyIndex(LyricsQuery query) async {
    for (final key in [
      _legacyIndexKey(query),
      _legacy2IndexKey(query),
      _oldestIndexKey(query),
    ]) {
      final record = await index?.read(key);
      if (record != null && record.isOk) {
        return record;
      }
    }
    return null;
  }

  /// 新纪元的磁盘键：sha1 的输入同样带纪元前缀，旧文件原样留在盘上。
  String _primaryKey(LyricsQuery query) => LyricsDiskCache.keyFor(
    '$_cacheEpoch|${query.trackName}',
    query.artistName,
    '${query.duration}',
  );

  /// 上一纪元的磁盘键（v3；对调方向的旧键不单独试：主方向的旧条目最常用）。
  String _legacyDiskKey(LyricsQuery query) => LyricsDiskCache.keyFor(
    'v3|${query.trackName}',
    query.artistName,
    '${query.duration}',
  );

  /// 更早纪元的磁盘键（v2）。
  String _legacy2DiskKey(LyricsQuery query) => LyricsDiskCache.keyFor(
    'v2|${query.trackName}',
    query.artistName,
    '${query.duration}',
  );

  /// 最老纪元的磁盘键。
  String _oldestDiskKey(LyricsQuery query) => LyricsDiskCache.keyFor(
    query.trackName,
    query.artistName,
    '${query.duration}',
  );

  /// 主源命中：写缓存（被预算放弃的结果不落盘）并转成对外结果。
  Future<LyricsMatch> _accept(
    LyricsQuery query,
    LyricsRecord record,
    _AbandonGuard abandoned,
  ) async {
    if (!abandoned.isAbandoned) {
      await _writeCaches(query, record);
    }
    return LyricsMatch(
      status: record.status,
      synced: record.synced,
      plain: record.plain,
      source: record.source,
    );
  }

  LyricsMatch _fromRecord(LyricsRecord record) => LyricsMatch(
    status: record.status,
    synced: record.synced,
    plain: record.plain,
    source: record.isOk ? record.source : '',
  );

  Future<void> _writeCaches(LyricsQuery query, LyricsRecord record) async {
    await index?.write(_indexKey(query), record);
    await disk.writeDual(
      _primaryKey(query),
      LyricsDiskCache.keyFor(
        '$_cacheEpoch|${query.artistName}',
        query.trackName,
        '${query.duration}',
      ),
      record,
    );
  }

  /// 构造全部 job（顺序即优先级），然后等它们**全部**结束。
  Future<LyricsRecord> _fetch(
    LyricsQuery query, {
    required LyricsQuery rawQuery,
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
    // 简体那几路都没命中、而标签本来是繁体时，按原字形再搜一次：
    // 上游偶尔只收了繁体条目（折叠后 get 404、search 也是 0 条）。
    // 只补 search、失败不改写结论 —— 主路径已经正常判定 not-found。
    if (foldChangedByScript(rawQuery, query)) {
      final fallback = await _runRawScriptSearch(rawQuery, query, cancel);
      if (fallback.isOk) return fallback;
    }
    return const LyricsRecord(status: 'not-found');
  }

  /// 原字形回退：一次 search，按折叠后的 (曲名, 歌手) 打分。
  ///
  /// 超时 / 网络失败一律吞成 not-found：主路径已经确认「简体查不到」，
  /// 这条只是补救，不该把界面从「未找到」改写成一条误导性的网络错误。
  Future<LyricsRecord> _runRawScriptSearch(
    LyricsQuery rawQuery,
    LyricsQuery query,
    CancelToken? cancel,
  ) async {
    final loose = [
      rawQuery.trackName,
      rawQuery.artistName,
    ].where((part) => part.isNotEmpty).join(' ');
    if (loose.isEmpty) {
      return const LyricsRecord(status: 'not-found');
    }
    try {
      final json = await requestJsonClientPolicy(
        client,
        _apiUri('search', {'q': loose}),
        timeout: getTimeout,
        attempts: 1,
        classify: _classify,
        gate: gate,
        cancel: cancel,
        sleep: sleep,
      );
      final want = _pairs(query.trackName, query.artistName).first;
      return _toLyricsRecord(
        _pickBestLyrics(json, want.$1, want.$2, query.duration),
      );
    } on RequestAborted {
      rethrow;
    } catch (_) {
      return const LyricsRecord(status: 'not-found');
    }
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
  // 曲名/歌手折到简体再比：上游候选可能写成繁体，逐字比会白丢分
  final wantTitle = toSimplified(wantName).toLowerCase();
  final wantArtistName = toSimplified(wantArtist).toLowerCase();
  final wantDuration = duration > 0 ? duration : 0;

  Map<Object?, Object?>? best;
  var bestScore = 0;
  for (final raw in items) {
    final item = raw is Map ? raw : const <Object?, Object?>{};
    var score = 0;
    if (_str(item['syncedLyrics']).trim().isNotEmpty) score += 50;
    final name = toSimplified(_str(item['trackName'] ?? item['name'])).toLowerCase();
    if (name.isNotEmpty && name == wantTitle) {
      score += 30;
    } else if (name.isNotEmpty &&
        (name.contains(wantTitle) || wantTitle.contains(name))) {
      score += 12;
    }
    final artist = toSimplified(_str(item['artistName'])).toLowerCase();
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

