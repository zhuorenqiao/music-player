// lib/cover/artist_image.dart
//
// 维基写真源：按歌手名直连维基 REST（zh 优先、en 兜底）拿条目配图，下载落盘到
// $dataDirectory/covers-net/，返回**文件绝对路径**。对译 React 版
// src/lib/artist-image.js —— React 的「同源代理 + 浏览器直连」两级通道在
// Flutter 侧合并成一级直连（同 M2a/iTunes 裁定）；下载与落盘在本文件内做
// （CoverImageWriter），不依赖 T3 的 ImageBytesClient / CoverDiskStore，用
// 独立的 downloadBytes 接缝注入（null = 生产装配层漏接），T3/T4 完全解耦，
// 由 Task 5 的装配层把两边接起来。
// 纯 Dart + HttpJsonClient 接缝（复用 lyrics/upstream.dart），测试不碰真网络。
//
// 移植时守住的非显而易见 JS 语义（每条都有用例钉，见 test/cover/artist_image_test.dart）：
// * 占位歌手（key 空 / '本地文件' / '未知歌手'）→ not-found，一个请求都不发
//   （artist-image.js:193-195）；
// * 404 是「条目不存在」：换下一语言；超时 / 网络错 / 非 404 状态 / 坏 payload
//   也都换下一语言（:170-171「这一级连不上就换下一个语言」）。全语言失败返回
//   **not-found** 而不是 error（requestDirect :181 的语义）—— 本机 DNS 污染
//   连不上 wikipedia.org 是常态（spec §18）：稳定 miss，界面落到生成卡，
//   绝不打扰、不弹 Toast；
// * pickImage 优先 originalimage.source、退 thumbnail.source，取第一个
//   ^https?://（大小写不敏感）的字符串（:146-150 逐字）；JsonOk 但两处都没有
//   合法图 → 同样换下一语言；
// * 下载超时 15s（对齐 React 服务端 IMAGE_TIMEOUT，music-api.ts），下载失败按
//   该语言失败继续下一语言；落盘 id = sha1(imageUrl) hex（music-api.ts:750），
//   CoverImageWriter 永不抛、失败返回 null 同样按该语言失败处理；
// * 索引层：prefs 键 'light-music.artist-image.v1'（:26 逐字），最多 80 条
//   （:27），命中 30 天、未命中 1 天（:30-31，维基条目随时可能补图）；坏 JSON
//   留原地不删，淘汰只发生在写入时（同 LyricsIndexCache 模式）；error 绝不写
//   缓存（Global Constraints「网络错误不写缓存」）；
// * downloadBytes 为 null（生产装配层漏接）→ 有图可下时返回
//   error(reason: 'unreachable')，不写缓存（若全语言都没找到图，仍按 not-found
//   走正常 miss 路径）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/app_prefs.dart';
import '../lyrics/upstream.dart' show HttpJsonClient, JsonOk;
import '../metadata/cover_image.dart';

/// 维基语言顺序：zh 优先、en 兜底（artist-image.js:23 逐字）。
const List<String> _wikiLangs = <String>['zh', 'en'];

/// 维基 REST 请求头（artist-image.js:126 逐字）：不发 Cookie / Referer。
const Map<String, String> _wikiHeaders = <String, String>{
  'Accept': 'application/json',
  'Api-User-Agent': 'light-music-player/1.0 (local dev)',
};

/// 图片下载超时：对齐 React 服务端 IMAGE_TIMEOUT（music-api.ts）。
const Duration _downloadTimeout = Duration(seconds: 15);

/// 索引 TTL（毫秒）：命中 30 天、未命中 1 天（artist-image.js:30-31）。
const int _ttlHitMs = 30 * 24 * 60 * 60 * 1000;
const int _ttlMissMs = 24 * 60 * 60 * 1000;

/// 索引表上限（artist-image.js:27）。
const int _maxEntries = 80;

/// 歌手名归一成缓存键（artist-image.js:42-48 逐字）：trim → 小写 → 连续空白
/// 折叠成单空格 → U+3000 折叠。JS 的 `\s` 本身就含 U+3000，第二个 replace 是
/// 原版写法的冗余兜底，逐字保留。
String normalizeArtistKey(String artist) => artist
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('\u3000', ' ');

/// 从维基 REST 的页面摘要里挑一张能用的配图（优先原图，退回缩略图）
/// （artist-image.js:146-150 逐字）；没有合法候选返回空串。
String pickImage(Object? page) {
  final map = page is Map ? page : null;
  final candidates = <Object?>[
    _sourceOf(map, 'originalimage'),
    _sourceOf(map, 'thumbnail'),
  ];
  for (final candidate in candidates) {
    if (candidate is String &&
        RegExp(r'^https?://', caseSensitive: false).hasMatch(candidate)) {
      return candidate;
    }
  }
  return '';
}

/// 摘要 JSON 里 `{originalimage|thumbnail}.source` 的取值；节点缺失 / 不是
/// 对象都按没有处理（JS 的 `page?.originalimage?.source`）。jsonDecode 的产物
/// 是 `Map<dynamic, dynamic>`，这里按 Map 宽接再读字段。
Object? _sourceOf(Map? page, String key) {
  final node = page?[key];
  return node is Map ? node['source'] : null;
}

/// 一次写真匹配的结果。永不抛错，失败一律以 [status] 表达。
class ArtistImageMatch {
  const ArtistImageMatch({
    required this.status,
    this.url,
    this.source = '',
    this.reason = '',
    this.message = '',
  });

  /// `ok | not-found | error | aborted`（本任务不传取消令牌，aborted 仅保留
  /// 枚举位，与 React 的结果形状对齐）。
  final String status;

  /// ok 时：落盘文件绝对路径。
  final String? url;

  /// ok 时：'Wikipedia（zh）' 或 'Wikipedia（en）'。React 的「，直连」后缀是
  /// 通道区分用的，Flutter 只有一条通道，去掉（Task 4 裁定）。
  final String source;

  /// error 时：'offline' | 'unreachable' | 'upstream'。
  final String reason;

  /// 给人看的中文消息（ok / not-found 为空，与 React 的裸形状一致）。
  final String message;
}

/// 条目时间戳：非对象 / `at` 不是数字都算 0（淘汰排序的兜底，同
/// LyricsIndexCache 的写法）。
num _atOf(Object? entry) {
  if (entry is! Map<String, Object?>) return 0;
  final at = entry['at'];
  return at is num ? at : 0;
}

/// 写真索引层：prefs 键 [prefsKey]，最多 80 条，命中 30 天 / 未命中 1 天
/// （对译 artist-image.js:26-31、54-110 readCache/readCached 与 74-90 writeCache）。
///
/// 索引层模式与 [LyricsIndexCache] 同构：读时判 TTL、过期只返回 null **不删**
/// （淘汰只发生在写入时，且只删超出 80 条的那部分）、坏 JSON 留原地等下一次
/// 写入整表覆盖。
class ArtistIndexCache {
  ArtistIndexCache(this._prefs, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 索引键，与 React 版逐字一致（artist-image.js:26）。
  static const String prefsKey = 'light-music.artist-image.v1';

  final AppPrefs _prefs;
  final DateTime Function() _now;

  /// 查索引：无此条 / 形状不对 / 已过期（**不删**）都返回 null。
  ///
  /// React readCached（:97-110）的分支顺序逐字：先看 `url`（命中，TTL 30 天），
  /// 再看 `miss`（未命中，TTL 1 天），两者皆无 → 没有这条缓存。
  Future<ArtistImageMatch?> read(String key) async {
    final entry = (await _readTable())[key];
    if (entry is! Map<String, Object?>) return null;
    final at = entry['at'];
    if (at is! num) return null;
    final ageMs = _now().millisecondsSinceEpoch - at.toInt();
    final url = entry['u'];
    if (url is String && url.isNotEmpty) {
      if (ageMs > _ttlHitMs) return null;
      final source = entry['source'];
      return ArtistImageMatch(
        status: 'ok',
        url: url,
        source: source is String ? source : '',
      );
    }
    if (entry['miss'] == true) {
      if (ageMs > _ttlMissMs) return null;
      return const ArtistImageMatch(status: 'not-found');
    }
    return null;
  }

  /// 按短字段名落盘：ok → `{'u': 路径, 'source': 来源, 'at': ms}`，miss →
  /// `{'miss': true, 'at': ms}`（React writeCache 的条目形状）；只收
  /// ok / not-found，其余状态整笔丢弃（错误结果不写缓存）。
  Future<void> write(String key, ArtistImageMatch match) async {
    final Map<String, Object?> entry;
    if (match.status == 'ok' && (match.url?.isNotEmpty ?? false)) {
      entry = <String, Object?>{
        'u': match.url,
        'source': match.source,
        'at': _now().millisecondsSinceEpoch,
      };
    } else if (match.status == 'not-found') {
      entry = <String, Object?>{
        'miss': true,
        'at': _now().millisecondsSinceEpoch,
      };
    } else {
      return;
    }
    final table = await _readTable();
    table[key] = entry;
    _evictOverflow(table);
    await _prefs.writeString(prefsKey, jsonEncode(table));
  }

  /// 清空整张表（artist-image.js:255-261 clearArtistImageCache）。
  Future<void> clear() => _prefs.remove(prefsKey);

  /// 整表读取：无键 / 坏 JSON / 不是对象（数组也算）都退化成空表，不抛。
  ///
  /// 刻意不用 AppPrefs.readJson —— 那个会顺手删掉脏数据，而原版读失败只忽略、
  /// 把脏值留在原地，等下一次写入整表覆盖（与 LyricsIndexCache 同一条裁定）。
  Future<Map<String, Object?>> _readTable() async {
    try {
      final raw = await _prefs.readString(prefsKey);
      if (raw == null) return {};
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  /// 超限时按 `at` 升序删掉最旧的溢出部分，结果正好 80 条（React :79-85 按
  /// `at` 降序留前 80，等价于删最旧的溢出部分）。
  ///
  /// 同 `at` 时按先来后到保序：Dart 的 List.sort 不保证稳定，原版 V8 的排序
  /// 稳定，加序号兜底才能让淘汰结果可复现（同 LyricsIndexCache 模式）。
  void _evictOverflow(Map<String, Object?> table) {
    if (table.length <= _maxEntries) return;
    final keys = table.keys.toList();
    final order = List<int>.generate(keys.length, (i) => i)
      ..sort((a, b) {
        final byAt = _atOf(table[keys[a]]).compareTo(_atOf(table[keys[b]]));
        return byAt != 0 ? byAt : a.compareTo(b);
      });
    for (final index in order.take(keys.length - _maxEntries)) {
      table.remove(keys[index]);
    }
  }
}

/// 按歌手名匹配写真图（对译 artist-image.js:190-249 matchArtistImage 的直连
/// 分支 + requestDirect :158-182；React 的同源代理通道与 navigator.onLine
/// 离线判定不移植 —— Flutter 直连维基，网络失败走 JsonNetwork 分类）。
///
/// * 占位歌手（key 空 / '本地文件' / '未知歌手'）→ not-found，一个请求都不发；
/// * [useCache] 且给了 [index]：先查持久索引，TTL 内命中直接返回（含 miss 条目
///   → not-found）；[index] 为 null 时不走持久索引（仅测试 / 内存层接管）；
/// * langs 顺序 ['zh','en']，每语言 [perLangTimeout]；404 → 换下一语言；
///   超时 / 网络错 / 非 404 状态 / 坏 payload → 同样换下一语言；JsonOk 但
///   pickImage 没有合法图 → 也换下一语言；
/// * 拿到图 URL → [downloadBytes] 下载（15s）→ [writer] 落盘（id =
///   sha1(imageUrl)）→ ok + 写索引；下载 / 落盘失败按该语言失败继续下一语言；
/// * 全语言失败 → not-found + 写索引 miss（本机 DNS 污染时稳定 miss，界面落到
///   生成卡）；[downloadBytes] 为 null 且有图可下 → error(unreachable) 不写
///   缓存；其它未预期异常 → error(unreachable) 不写缓存。永不抛错。
Future<ArtistImageMatch> matchArtistImage(
  String artist, {
  required HttpJsonClient json,
  required String directory,
  CoverImageWriter writer = const CoverImageWriter(),
  ArtistIndexCache? index,
  bool useCache = true,
  Duration perLangTimeout = const Duration(seconds: 8),
  Future<Uint8List> Function(Uri url, Duration timeout)? downloadBytes,
}) async {
  final key = normalizeArtistKey(artist);
  // 占位歌手直接拒绝（artist-image.js:193-195）：一个请求都不发。
  if (key.isEmpty || key == '本地文件' || key == '未知歌手') {
    return const ArtistImageMatch(status: 'not-found');
  }
  if (useCache && index != null) {
    final cached = await index.read(key);
    if (cached != null) return cached;
  }
  try {
    final name = artist.trim();
    for (final lang in _wikiLangs) {
      final url = Uri.parse(
        'https://$lang.wikipedia.org/api/rest_v1/page/summary/'
        '${Uri.encodeComponent(name)}',
      );
      final outcome = await json.getJson(
        url,
        timeout: perLangTimeout,
        headers: _wikiHeaders,
      );
      // 404 = 条目不存在；超时 / 网络错 / 非 404 状态 / 坏 payload =
      // 「这一级连不上就换下一个语言」（artist-image.js:170-171）——
      // 归一成同一条 continue。
      if (outcome is! JsonOk) continue;
      final imageUrl = pickImage(outcome.json);
      if (imageUrl.isEmpty) continue;
      // 有图可下但装配层没接下载通道：error(unreachable)，不写缓存。
      final download = downloadBytes;
      if (download == null) {
        return const ArtistImageMatch(
          status: 'error',
          reason: 'unreachable',
          message: '未接入图片下载通道',
        );
      }
      // 下载失败按该语言失败继续下一语言（下载超时 15s 对齐 React 服务端）。
      Uint8List? bytes;
      try {
        bytes = await download(Uri.parse(imageUrl), _downloadTimeout);
      } catch (_) {
        continue;
      }
      // 落盘 id = sha1(imageUrl) hex（music-api.ts:750）；writer 永不抛，
      // 失败返回 null 同样按该语言失败处理。
      final path = await writer.write(
        bytes,
        'image/jpeg',
        directory: directory,
        id: sha1.convert(utf8.encode(imageUrl)).toString(),
      );
      if (path == null) continue;
      final match = ArtistImageMatch(
        status: 'ok',
        url: path,
        source: 'Wikipedia（$lang）',
      );
      await index?.write(key, match);
      return match;
    }
    // 全语言失败 → not-found（requestDirect :181 的语义）。本机 DNS 污染连不上
    // wikipedia.org 是常态（spec §18）：稳定 miss，界面落到生成卡，绝不打扰。
    const miss = ArtistImageMatch(status: 'not-found');
    await index?.write(key, miss);
    return miss;
  } catch (_) {
    // 未预期异常：error(unreachable)，不写缓存（错误结果不写缓存）。
    return const ArtistImageMatch(
      status: 'error',
      reason: 'unreachable',
      message: '获取歌手图片失败',
    );
  }
}
