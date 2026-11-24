// lib/lyrics/kugou_lyrics.dart
//
// 酷狗音乐歌词源（排在汽水之后、网易云之前）。
//
// 三条腿都在 HTTPS 上（Android 9+ 默认禁明文，别换回 http）：
// * 搜歌：`mobiles.kugou.com/api/v3/search/song`（返回 songname / singername /
//   duration 秒 / hash）；
// * 找词：`krcs.kugou.com/search`（用歌名 + 时长 + hash 换候选 id / accesskey）；
// * 下载：`lyrics.kugou.com/download?fmt=lrc&charset=utf8`，返回 base64 LRC。
//
// 认歌同样复用 pickTranslatableSong：把搜索结果包成 NetEaseSong，按同一套
// 「歌名 + 歌手 / 时长」门槛排序；某首同名歌没词时再试下一首，不一把梭。
//
// 取回来的 LRC 开头有一串 `[id:] [ar:] [ti:] [by:] [hash:] …` 元信息，
// 先丢掉这些纯元信息行，再交给 lyrics_credits 剥制作署名；否则署名清理会
// 卡在第一行 `[id:]` 上，后面的作曲 / 录音师全留在歌词页顶上。
import 'dart:async';
import 'dart:convert';

import 'lyrics_cache.dart';
import 'lyrics_credits.dart';
import 'lyrics_provider.dart';
import 'netease_match.dart';
import 'query.dart';
import 'upstream.dart';

/// 结果的 source 字面量（界面按它显示来源；缓存 src 也存这一串）。
const String kKugouLyricsSource = '酷狗音乐';

const String _searchEndpoint = 'https://mobiles.kugou.com/api/v3/search/song';
const String _candidateEndpoint = 'https://krcs.kugou.com/search';
const String _downloadEndpoint = 'https://lyrics.kugou.com/download';

/// 单程预算：搜索 6s、候选 6s、下载 6s。
const Duration _searchTimeout = Duration(seconds: 6);
const Duration _candidateTimeout = Duration(seconds: 6);
const Duration _downloadTimeout = Duration(seconds: 6);

/// 整次酷狗尝试的总预算：到点直接放弃，交给网易云。
const Duration _totalBudget = Duration(seconds: 12);

/// 最多试几首同名歌（搜索结果里翻唱很多，但真正有词的通常前两三首）。
const int _maxSongs = 3;

/// 酷狗歌词源。
class KugouLyrics implements LyricsProvider {
  KugouLyrics({
    required this.client,
    this.searchTimeout = _searchTimeout,
    this.candidateTimeout = _candidateTimeout,
    this.downloadTimeout = _downloadTimeout,
    this.totalBudget = _totalBudget,
    this.sleep,
  });

  final HttpJsonClient client;

  final Duration searchTimeout;
  final Duration candidateTimeout;
  final Duration downloadTimeout;
  final Duration totalBudget;

  final Future<void> Function(Duration)? sleep;

  /// 查一首歌的酷狗歌词。命中返回 ok 记录；没词 / 认不到 / 上游失败都返回 null。
  @override
  Future<LyricsRecord?> lookup(LyricsQuery query, {CancelToken? cancel}) async {
    if (query.trackName.isEmpty) {
      return null;
    }
    try {
      return await _lookup(query, cancel).timeout(totalBudget);
    } on TimeoutException {
      return null;
    } on RequestAborted {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  Future<LyricsRecord?> _lookup(LyricsQuery query, CancelToken? cancel) async {
    final keyword = [query.trackName, query.artistName]
        .where((part) => part.isNotEmpty)
        .join(' ');
    final songs = await _search(keyword, cancel: cancel);
    if (songs.isEmpty) {
      return null;
    }

    // 同一套认歌规则排优先级；被认过的歌从列表里删掉，下一轮再取次优。
    final remaining = List<_KugouSong>.of(songs);
    var attempts = 0;
    while (remaining.isNotEmpty && attempts < _maxSongs) {
      final picked = pickTranslatableSong(
        remaining,
        trackName: query.trackName,
        artistName: query.artistName,
        duration: query.duration,
        // 有歌手就必须对得上：酷狗同名翻唱极多，只靠时长会拿错词。
        strict: query.artistName.isNotEmpty,
      );
      if (picked == null) {
        break;
      }
      remaining.removeWhere((song) => song.id == picked.id);
      final song = songs.firstWhere((item) => item.id == picked.id);
      attempts += 1;
      final record = await _lyricFor(song, cancel: cancel);
      if (record != null) {
        return record;
      }
    }
    return null;
  }

  /// 搜索并归一成 [_KugouSong]（hash 随歌曲一起带回来）。
  Future<List<_KugouSong>> _search(
    String keyword, {
    CancelToken? cancel,
  }) async {
    final json = await requestJsonProxyPolicy(
      client,
      Uri.parse(_searchEndpoint).replace(
        queryParameters: {
          'format': 'json',
          'keyword': keyword,
          'page': '1',
          'pagesize': '20',
          'showtype': '1',
        },
      ),
      timeout: searchTimeout,
      attempts: 1,
      classify: _classify,
      cancel: cancel,
      sleep: sleep,
    );
    if (json is! Map) {
      return const [];
    }
    final data = json['data'];
    final info = data is Map ? data['info'] : null;
    if (info is! List) {
      return const [];
    }
    final songs = <_KugouSong>[];
    for (final item in info) {
      if (item is! Map) {
        continue;
      }
      final name = item['songname'] is String
          ? (item['songname'] as String).trim()
          : '';
      final artist = item['singername'] is String
          ? (item['singername'] as String).trim()
          : '';
      final duration = _number(item['duration']);
      final hash = item['hash'] is String ? item['hash'] as String : '';
      if (name.isEmpty || hash.isEmpty) {
        continue;
      }
      songs.add(
        _KugouSong(
          id: songs.length + 1,
          name: name,
          durationMs: duration * 1000,
          artists: [if (artist.isNotEmpty) artist],
          hash: hash,
        ),
      );
    }
    return songs;
  }

  Future<LyricsRecord?> _lyricFor(
    _KugouSong song, {
    CancelToken? cancel,
  }) async {
    final candidates = await _candidateSongs(song, cancel: cancel);
    if (candidates.isEmpty) {
      return null;
    }

    final remaining = List<_KugouCandidate>.of(candidates);
    var attempts = 0;
    while (remaining.isNotEmpty && attempts < 2) {
      final picked = pickTranslatableSong(
        [for (final candidate in remaining) candidate.song],
        trackName: song.name,
        artistName: song.artists.isEmpty ? '' : song.artists.first,
        duration: (song.durationMs / 1000).round(),
        strict: song.artists.isNotEmpty,
      );
      if (picked == null) {
        break;
      }
      final candidate = remaining.firstWhere((item) => item.song.id == picked.id);
      remaining.removeWhere((item) => item.song.id == picked.id);
      attempts += 1;
      final record = await _download(candidate, cancel: cancel);
      if (record != null) {
        return record;
      }
    }
    return null;
  }

  Future<List<_KugouCandidate>> _candidateSongs(
    _KugouSong song, {
    CancelToken? cancel,
  }) async {
    final json = await requestJsonProxyPolicy(
      client,
      Uri.parse(_candidateEndpoint).replace(
        queryParameters: {
          'ver': '1',
          'man': 'yes',
          'client': 'mobi',
          'keyword': song.name,
          'duration': '${(song.durationMs / 1000).round()}',
          'hash': song.hash,
        },
      ),
      timeout: candidateTimeout,
      attempts: 1,
      classify: _classify,
      cancel: cancel,
      sleep: sleep,
    );
    if (json is! Map) {
      return const [];
    }
    final items = json['candidates'];
    if (items is! List) {
      return const [];
    }
    final candidates = <_KugouCandidate>[];
    for (final item in items) {
      if (item is! Map) {
        continue;
      }
      final id = item['id']?.toString() ?? '';
      final accesskey = item['accesskey'] is String
          ? item['accesskey'] as String
          : '';
      final name = item['song'] is String ? (item['song'] as String).trim() : '';
      final singer = item['singer'] is String
          ? (item['singer'] as String).trim()
          : '';
      final durationMs = _number(item['duration']);
      if (id.isEmpty || accesskey.isEmpty || name.isEmpty) {
        continue;
      }
      candidates.add(
        _KugouCandidate(
          id: id,
          accessKey: accesskey,
          song: _KugouSong(
            id: candidates.length + 1,
            name: name,
            durationMs: durationMs,
            artists: [if (singer.isNotEmpty) singer],
            hash: song.hash,
          ),
        ),
      );
    }
    return candidates;
  }

  Future<LyricsRecord?> _download(
    _KugouCandidate candidate, {
    CancelToken? cancel,
  }) async {
    final json = await requestJsonProxyPolicy(
      client,
      Uri.parse(_downloadEndpoint).replace(
        queryParameters: {
          'ver': '1',
          'client': 'pc',
          'fmt': 'lrc',
          'charset': 'utf8',
          'id': candidate.id,
          'accesskey': candidate.accessKey,
        },
      ),
      timeout: downloadTimeout,
      attempts: 1,
      classify: _classify,
      cancel: cancel,
      sleep: sleep,
    );
    if (json is! Map) {
      return null;
    }
    final content = json['content'];
    if (content is! String || content.isEmpty) {
      return null;
    }
    String raw;
    try {
      raw = utf8.decode(base64Decode(content), allowMalformed: true);
    } catch (_) {
      return null;
    }
    final body = stripLeadingCredits(
      stripLeadingTitleLine(
        _dropMetaLines(raw),
        trackName: candidate.song.name,
        artistName: candidate.song.artists.isEmpty
            ? ''
            : candidate.song.artists.first,
      ),
    );
    if (body.trim().isEmpty) {
      return null;
    }
    final synced = hasTimeTag(body);
    return LyricsRecord(
      status: 'ok',
      synced: synced ? body : '',
      plain: synced ? '' : body,
      source: kKugouLyricsSource,
    );
  }
}

/// 酷狗搜索 / 候选结果：在 [NetEaseSong] 上多带一个取词用的 hash。
class _KugouSong extends NetEaseSong {
  const _KugouSong({
    required super.id,
    required super.name,
    super.durationMs,
    super.artists,
    required this.hash,
  });

  final String hash;
}

class _KugouCandidate {
  const _KugouCandidate({
    required this.id,
    required this.accessKey,
    required this.song,
  });

  final String id;
  final String accessKey;
  final _KugouSong song;
}

UpstreamFailure _classify(JsonOutcome outcome) =>
    classifyOutcome(outcome, '歌词库');

/// JSON 里的数字可能是 num / String；拿不到就按 0（未知）处理。
double _number(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

/// 丢掉纯元信息行（`[id:] [ar:] [ti:] [by:] [hash:] [al:] [offset:] …`）。
/// offset 一并丢掉：酷狗这份 LRC 的 offset 基本是 0，留着反而会挡住后面的署名清理。
String _dropMetaLines(String raw) {
  final lines = raw.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'));
  final meta = RegExp(
    r'^\[(?:id|ar|ti|by|hash|al|sign|qq|total|offset|length)\s*:',
    caseSensitive: false,
  );
  final kept = <String>[];
  for (final line in lines) {
    if (meta.hasMatch(line.trim())) {
      continue;
    }
    kept.add(line);
  }
  return kept.join('\n');
}
