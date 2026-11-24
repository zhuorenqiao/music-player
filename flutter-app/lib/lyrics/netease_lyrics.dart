// lib/lyrics/netease_lyrics.dart
//
// 网易云歌词源：认歌（netease_match 的纯函数）→ 取 `song/lyric` 的 `lrc.lyric`
// → 归一成 [LyricsRecord]。这是歌词链路的**主源**，LRCLIB 退为兜底
// （见 lyrics_source.dart 的装配与注释）。
//
// 为什么能直接认网易云的歌：`api/search/get` 返回的歌曲 id 就是取词要的 id，
// 与译文链路（translate_source.dart）用的是同一套端点与同一套认歌规则 ——
// 歌词错配和译文错配一样糟，所以这里沿用 pickTranslatableSong 的收紧门槛
// （歌名必须一致 / 去版本后缀后一致，且歌手对得上或时长差 ≤ 6 秒；派生候选
// 还必须有歌手证据），宁可返回 null 交给 LRCLIB，也不给一首错的词。
//
// 几条刻意守住的语义：
// * 完全失败（超时 / 连不上 / 限流）一律吞成 null：网易云只是「优先」，它挂了
//   不该把整体结果改写成网络错误，LRCLIB 还有机会。取消（RequestAborted）
//   例外，原样上抛，由外层按 aborted 静默处理；
// * 重试策略与译文链路一致（requestJsonProxyPolicy：单程 6s、只重试 timeout /
//   unreachable、固定 400ms、限流与 4xx 直接抛），但**不挂冷却闸**：网易云的
//   限流不该连坐 LRCLIB 的冷却窗口；
// * `nolyric` / `uncollected` / `lrc` 缺失 / 正文为空 → null（没有词，不是错误）；
// * 正文有 `[mm:ss(.xx)]` 才算带时间轴，没有就当纯文本（LyricsRecord.plain），
//   与 LRCLIB 的 synced / plain 两栏同构；
// * 网易云的 LRC 开头常带一串带时间轴的制作署名（作曲 / 编曲 / 录音师 …），
//   解析器的署名清理只扫前 4 行（lrc_parser.dart 的 _creditScanLimit），
//   多出来的会在歌词页顶上排成一片，所以在这里先把开头连续的署名行剥掉；
// * 候选顺序：正方向 → 对调 → 只搜曲名（歌手字段写得花哨时只搜曲名才是对的），
//   命中即停；全部跑完仍无词才返回 null。
import 'dart:async';

import '../lyrics/netease_match.dart';
import 'lyrics_cache.dart';
import 'lyrics_credits.dart';
import 'lyrics_provider.dart';
import 'query.dart';
import 'upstream.dart';

/// 结果的 source 字面量（界面按它显示来源；缓存 src 也存这一串）。
const String kNetEaseLyricsSource = '网易云音乐';

/// 网易云搜索 / 取词端点（与 translate_source.dart 同源同路径）。
const String _searchEndpoint = 'https://music.163.com/api/search/get';
const String _lyricEndpoint = 'https://music.163.com/api/song/lyric';

/// 单程预算：搜索 6s、取词 6s（译文链路是 8s；歌词还排在 LRCLIB 前面，
/// 不能在这里把整次匹配的时间预算吃光）。
const Duration _searchTimeout = Duration(seconds: 6);
const Duration _lyricTimeout = Duration(seconds: 6);

/// 整次网易云尝试的总预算：到点直接放弃，交给后面的源。
const Duration _totalBudget = Duration(seconds: 15);

/// 网易云歌词源。
class NetEaseLyrics implements LyricsProvider {
  NetEaseLyrics({
    required this.client,
    this.searchTimeout = _searchTimeout,
    this.lyricTimeout = _lyricTimeout,
    this.totalBudget = _totalBudget,
    this.sleep,
  });

  final HttpJsonClient client;

  final Duration searchTimeout;
  final Duration lyricTimeout;
  final Duration totalBudget;

  /// 退避用的睡眠；测试注入空实现，免得靠真时间。
  final Future<void> Function(Duration)? sleep;

  /// 查一首歌的网易云歌词。命中返回 ok 记录；没词 / 认不到 / 上游失败都返回 null。
  ///
  /// 取消（[RequestAborted]）原样上抛 —— 它不是「没找到」。
  @override
  Future<LyricsRecord?> lookup(LyricsQuery query, {CancelToken? cancel}) async {
    if (query.trackName.isEmpty) {
      return null;
    }
    try {
      return await _lookup(query, cancel).timeout(totalBudget);
    } on TimeoutException {
      // 底层请求仍在跑（Dart 的 http 不支持 abort）；结果直接丢弃，LRCLIB 接手。
      return null;
    } on RequestAborted {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  Future<LyricsRecord?> _lookup(LyricsQuery query, CancelToken? cancel) async {
    final candidates = <TranslateCandidate>[
      ...translatePairs(query.trackName, query.artistName),
      // 歌手字段写成「A / B」「feat. X」时，只搜曲名常常才是对的；
      // 追加发生在去重之后是译文侧的原版语义，歌词侧照抄（重复时多搜一次）。
      if (query.artistName.isNotEmpty)
        TranslateCandidate(name: query.trackName, artist: '', strict: false),
    ];

    // 已经取过词的曲目 id：纯音乐 / 未收录会被多个候选反复认到，别重复请求。
    final tried = <int>{};

    for (final candidate in candidates) {
      final keyword = candidate.keyword;
      if (keyword.isEmpty) {
        continue;
      }
      try {
        final songs = parseNetEaseSongs(
          await _search(keyword, cancel: cancel),
        );
        final song = pickTranslatableSong(
          songs,
          trackName: candidate.name,
          artistName: candidate.artist,
          duration: query.duration,
          strict: candidate.strict,
        );
        if (song == null) {
          continue;
        }
        // 同一首歌被多个候选认出来时只取一次词（纯音乐/未收录会被反复认到）。
        if (!tried.add(song.id)) {
          continue;
        }
        final record = _toRecord(await _fetchLyric(song.id, cancel: cancel));
        if (record != null) {
          return record;
        }
        // 认到歌但没有词（纯音乐 / 未收录 / 空正文）：换下一个候选再试。
      } on RequestAborted {
        // 取消不是「这个候选没戏」，原样上抛。
        rethrow;
      } catch (_) {
        // 某个候选搜挂了（超时 / 连不上 / 限流）不放弃整次尝试，试下一个。
        continue;
      }
    }
    return null;
  }

  Future<Object?> _search(String keyword, {CancelToken? cancel}) =>
      requestJsonProxyPolicy(
        client,
        Uri.parse(
          _searchEndpoint,
        ).replace(queryParameters: {'s': keyword, 'type': '1', 'limit': '20'}),
        timeout: searchTimeout,
        attempts: 1,
        classify: _classify,
        cancel: cancel,
        sleep: sleep,
      );

  Future<Object?> _fetchLyric(int id, {CancelToken? cancel}) =>
      requestJsonProxyPolicy(
        client,
        Uri.parse(
          _lyricEndpoint,
        ).replace(queryParameters: {'id': '$id', 'lv': '1', 'tv': '1'}),
        timeout: lyricTimeout,
        attempts: 1,
        classify: _classify,
        cancel: cancel,
        sleep: sleep,
      );

  /// 上游 JSON → 歌词记录；没有词 / 正文为空 → null。
  LyricsRecord? _toRecord(Object? json) {
    if (json is! Map) {
      return null;
    }
    if (json['nolyric'] == true || json['uncollected'] == true) {
      return null;
    }
    final lrc = json['lrc'];
    final lyric = lrc is Map && lrc['lyric'] is String ? lrc['lyric'] as String : '';
    if (lyric.trim().isEmpty) {
      return null;
    }
    final body = stripLeadingCredits(lyric);
    if (body.trim().isEmpty) {
      return null;
    }
    // 有任意一条时间标签就按带时间轴处理；否则按纯文本（与 LRCLIB 两栏同构）。
    final synced = hasTimeTag(body);
    return LyricsRecord(
      status: 'ok',
      synced: synced ? body : '',
      plain: synced ? '' : body,
      source: kNetEaseLyricsSource,
    );
  }
}

UpstreamFailure _classify(JsonOutcome outcome) =>
    classifyOutcome(outcome, '歌词库');
