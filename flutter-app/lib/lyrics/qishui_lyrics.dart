// lib/lyrics/qishui_lyrics.dart
//
// 汽水音乐歌词源（优先级最高）。两条腿：
// * 认歌：`luna/pc/sug` 搜索建议。这个端点不需要登录 / 签名，匿名可用；
//   `luna/pc/search/all` 匿名会返回 `empty_search`，不要用它。
// * 取词：分享页 `music.douyin.com/qishui/share/track?track_id=` 的
//   `_ROUTER_DATA` 里带 `audioWithLyricsOption`（曲名 / 歌手 / 时长 / 逐句时间轴）。
//   分享页必须用移动端 UA，桌面 UA 拿不到服务端渲染数据（见 page_client.dart）。
//
// 认歌规则不另造一套：把分享页元信息包成 NetEaseSong，直接交给
// pickTranslatableSong（与网易云 / 译文共用同一套门槛）。宁可返回 null 交给
// 酷狗 / 网易云，也不拿一首同名的翻唱凑数。
//
// 分享页一句歌词可能只有 `startMs` 与 `text`（逐字信息在 words 里），这里只要
// 行级 LRC：`[mm:ss.cc]正文`，再复用 lyrics_credits 剥掉开头的制作署名。
import 'dart:async';
import 'dart:convert';

import 'lyrics_cache.dart';
import 'lyrics_credits.dart';
import 'lyrics_provider.dart';
import 'netease_match.dart';
import 'page_client.dart';
import 'query.dart';
import 'upstream.dart';

/// 结果的 source 字面量（界面按它显示来源；缓存 src 也存这一串）。
const String kQishuiLyricsSource = '汽水音乐';

const String _sugEndpoint = 'https://api.qishui.com/luna/pc/sug';
const String _shareEndpoint = 'https://music.douyin.com/qishui/share/track';

/// 单程预算：建议搜索 6s、分享页 10s（一页 ~150KB，移动网络要给足）。
const Duration _sugTimeout = Duration(seconds: 6);
const Duration _pageTimeout = Duration(seconds: 10);

/// 整次汽水尝试的总预算：到点直接放弃，交给酷狗。
const Duration _totalBudget = Duration(seconds: 16);

/// 最多抓几首候选的分享页：抓多了流量吃不消，抓少了翻唱会挤掉正主。
const int _maxCandidates = 3;

/// 汽水歌词源。
class QishuiLyrics implements LyricsProvider {
  QishuiLyrics({
    required this.client,
    required this.pageClient,
    this.sugTimeout = _sugTimeout,
    this.pageTimeout = _pageTimeout,
    this.totalBudget = _totalBudget,
    this.sleep,
  });

  final HttpJsonClient client;
  final LyricsPageClient pageClient;

  final Duration sugTimeout;
  final Duration pageTimeout;
  final Duration totalBudget;

  final Future<void> Function(Duration)? sleep;

  /// 查一首歌的汽水歌词。命中返回 ok 记录；没词 / 认不到 / 上游失败都返回 null。
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
    final candidates = <_QishuiCandidate>[];
    final seen = <String>{};

    // 先用「曲名 + 歌手」搜，再只用曲名补一次：汽水的建议词对歌手写法很敏感。
    final keywords = <String>[
      if (query.artistName.isNotEmpty) '${query.trackName} ${query.artistName}',
      query.trackName,
    ];

    for (final keyword in keywords) {
      if (candidates.length >= _maxCandidates) {
        break;
      }
      List<String> ids;
      try {
        ids = await _suggest(keyword, cancel: cancel);
      } on RequestAborted {
        rethrow;
      } catch (_) {
        continue;
      }
      for (final id in ids) {
        if (candidates.length >= _maxCandidates) {
          break;
        }
        if (!seen.add(id)) {
          continue;
        }
        _QishuiCandidate? candidate;
        try {
          candidate = await _loadCandidate(id, candidates.length + 1, cancel: cancel);
        } on RequestAborted {
          rethrow;
        } catch (_) {
          candidate = null;
        }
        if (candidate != null) {
          candidates.add(candidate);
        }
      }
    }

    if (candidates.isEmpty) {
      return null;
    }

    final picked = pickTranslatableSong(
      [for (final candidate in candidates) candidate.song],
      trackName: query.trackName,
      artistName: query.artistName,
      duration: query.duration,
      // 有歌手就必须对得上：汽水里满是「十年（陈奕迅）」这种翻唱，
      // 只靠时长会把别人的词贴上来。
      strict: query.artistName.isNotEmpty,
    );
    if (picked == null) {
      return null;
    }
    for (final candidate in candidates) {
      if (candidate.song.id == picked.id) {
        // 同名同歌手的翻唱 / DJ 版在汽水里很常见，strict 只校验歌手，
        // 拦不住「孤勇者（陈奕迅 / DJ 阿柯）」这种 175 秒的版本。
        // 时长差超过 20 秒就让给酷狗，别把别人的词贴到当前曲目上。
        final candidateSeconds = candidate.song.durationMs / 1000;
        if (query.duration > 0 &&
            candidateSeconds > 0 &&
            (candidateSeconds - query.duration).abs() > 20) {
          return null;
        }
        return candidate.record;
      }
    }
    return null;
  }

  /// 一次建议搜索，返回候选 track id（去重后最多 [_maxCandidates] 条）。
  Future<List<String>> _suggest(String keyword, {CancelToken? cancel}) async {
    final searchId = '${DateTime.now().microsecondsSinceEpoch}';
    final json = await requestJsonProxyPolicy(
      client,
      Uri.parse(_sugEndpoint).replace(
        queryParameters: {
          'aid': '386088',
          'app_name': 'luna_pc',
          'device_id': '3753066532709850',
          'iid': '3753066532713946',
          'version_name': '3.5.2',
          'version_code': '30050200',
          'device_platform': 'windows',
          'device_type': 'Windows',
          'q': keyword,
          'cursor': '0',
          'search_id': searchId,
          'search_method': 'input',
          'sug_scene': 'main',
          'sug_search_id': searchId,
        },
      ),
      timeout: sugTimeout,
      attempts: 1,
      classify: _classify,
      cancel: cancel,
      sleep: sleep,
    );
    if (json is! Map) {
      return const [];
    }
    final sugs = json['sugs'];
    if (sugs is! List) {
      return const [];
    }
    final ids = <String>[];
    for (final item in sugs) {
      if (item is! Map || item['content_type'] != 'track') {
        continue;
      }
      final entity = item['entity'];
      final track = entity is Map ? entity['track'] : null;
      final id = track is Map ? track['id'] : null;
      if (id is String && id.isNotEmpty && !ids.contains(id)) {
        ids.add(id);
      }
      if (ids.length >= _maxCandidates) {
        break;
      }
    }
    return ids;
  }

  /// 抓分享页 → 元信息 + 行级 LRC；没有歌词数据返回 null。
  Future<_QishuiCandidate?> _loadCandidate(
    String id,
    int songId, {
    CancelToken? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) {
      throw const RequestAborted();
    }
    final html = await pageClient.getPage(
      Uri.parse(_shareEndpoint).replace(queryParameters: {'track_id': id}),
      timeout: pageTimeout,
    );
    if (cancel?.isCancelled ?? false) {
      throw const RequestAborted();
    }
    if (html == null || html.isEmpty) {
      return null;
    }
    final data = _extractRouterData(html);
    if (data == null) {
      return null;
    }
    final option = _findMap(data, 'audioWithLyricsOption');
    if (option == null) {
      return null;
    }
    final name = option['trackName'] is String
        ? (option['trackName'] as String).trim()
        : '';
    if (name.isEmpty) {
      return null;
    }
    final artist = option['artistName'] is String
        ? (option['artistName'] as String).trim()
        : '';
    final seconds = option['duration'] is num
        ? (option['duration'] as num).toDouble()
        : 0.0;
    final lyrics = option['lyrics'];
    final sentences = lyrics is Map ? lyrics['sentences'] : null;
    if (sentences is! List || sentences.isEmpty) {
      return null;
    }

    final body = StringBuffer();
    for (final sentence in sentences) {
      if (sentence is! Map) {
        continue;
      }
      final text = sentence['text'] is String
          ? (sentence['text'] as String).trim()
          : '';
      if (text.isEmpty) {
        continue;
      }
      final startMs = sentence['startMs'] is num
          ? (sentence['startMs'] as num).toInt()
          : 0;
      body.writeln('${_formatTag(startMs)}$text');
    }
    if (body.length == 0) {
      return null;
    }

    final cleaned = stripLeadingCredits(body.toString());
    if (cleaned.trim().isEmpty) {
      return null;
    }

    return _QishuiCandidate(
      song: NetEaseSong(
        id: songId,
        name: name,
        durationMs: seconds * 1000,
        artists: [if (artist.isNotEmpty) artist],
      ),
      record: LyricsRecord(
        status: 'ok',
        synced: cleaned,
        plain: '',
        source: kQishuiLyricsSource,
      ),
    );
  }
}

class _QishuiCandidate {
  const _QishuiCandidate({required this.song, required this.record});

  final NetEaseSong song;
  final LyricsRecord record;
}

UpstreamFailure _classify(JsonOutcome outcome) =>
    classifyOutcome(outcome, '歌词库');

/// 从分享页 HTML 里扣出 `_ROUTER_DATA = {...};` 的 JSON 对象。
///
/// 不能用非贪婪正则：JSON 字符串里可能出现 `};`（样式、文案），会提前截断。
/// 这里从第一个 `{` 开始做括号配对，并正确跳过字符串里的括号与转义。
Map<String, dynamic>? _extractRouterData(String html) {
  final marker = html.indexOf('_ROUTER_DATA');
  if (marker < 0) {
    return null;
  }
  final start = html.indexOf('{', marker);
  if (start < 0) {
    return null;
  }
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = start; index < html.length; index += 1) {
    final char = html[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
      continue;
    }
    if (char == '{') {
      depth += 1;
    } else if (char == '}') {
      depth -= 1;
      if (depth == 0) {
        try {
          final decoded = jsonDecode(html.substring(start, index + 1));
          return decoded is Map<String, dynamic> ? decoded : null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}

Map<String, dynamic>? _findMap(Object? node, String key) {
  if (node is Map) {
    final value = node[key];
    if (value is Map<String, dynamic>) {
      return value;
    }
    for (final child in node.values) {
      final found = _findMap(child, key);
      if (found != null) {
        return found;
      }
    }
  } else if (node is List) {
    for (final child in node) {
      final found = _findMap(child, key);
      if (found != null) {
        return found;
      }
    }
  }
  return null;
}

/// 毫秒 → `[mm:ss.cc]`（两位分钟、两位秒、两位百分秒，与 LRC 常规一致）。
String _formatTag(int milliseconds) {
  final total = milliseconds < 0 ? 0 : milliseconds;
  final minutes = total ~/ 60000;
  final seconds = (total ~/ 1000) % 60;
  final centis = (total % 1000) ~/ 10;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  final cc = centis.toString().padLeft(2, '0');
  return '[$mm:$ss.$cc]';
}
