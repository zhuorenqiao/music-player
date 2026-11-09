// lib/lyrics/translate_cache.dart
//
// 译文双层缓存：prefs 索引（短字段名，最多 120 条，读时判 TTL）+ 磁盘层（长字段
// 名，sha1 文件名，TTL 按 mtime，无淘汰）。对译 React 版
// src/lib/translate-source.js:108-190（readCacheTable / writeCacheTable /
// readCached / writeCached）与 src/server/music-api.ts:174-203（磁盘读写）、
// 835-867（v2 键与双写下的读写）。
// 与 T7 的歌词缓存同构，只有键前缀、字段名与 TTL 判定点不同：
// * 磁盘键带 `v2|` 前缀并**整体 lowercase**（music-api.ts:845）；
//   歌词磁盘键不带前缀也不 lowercase（music-api.ts:801）——两套口径，不要统一；
// * 索引键是 `light-music.translate-cache.v2`，歌词那边是 `...v1`；
// * 判「命中」看 `status === 'ok'`（translate-source.js:150），不看 miss 标志 ——
//   译文索引没有 miss 字段。
// 纯 Dart：只依赖 AppPrefs 与 dart:io，时钟与目录都从构造注入，方便测试。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见 test/lyrics/translate_cache_test.dart）：
// * 索引条目 `at` 不是数字、或条目本身不是对象 → 当没有这条缓存；过期只返回 null，
//   **不删**（淘汰只发生在写入时，且只删超出 120 条的那部分）；
// * 索引写只收 ok / not-found，其余状态直接返回（网络类错误不写缓存）；
// * 读未命中条目时**丢掉 message**，只留 reason（缺省 song-not-matched）；
//   命中条目的 `src` 为空才回落 '网易云译文库'；
// * 磁盘层 TTL 按文件 mtime：命中 30 天、未命中 3 天；allowStale 跳过 TTL 检查，
//   供上游失败时回退过期缓存用；文件不存在 / 解析失败 / 写失败都不抛。
// * `（离线缓存）` 的追加由调用方（TranslateSource）负责，缓存层不动 source 字符串。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/app_prefs.dart';

/// 条目存活时长（毫秒）：命中 30 天、未命中 3 天（translate-source.js:30-31、
/// music-api.ts:46-47，两层同值）。
const int _ttlHitMs = 30 * 24 * 60 * 60 * 1000;
const int _ttlMissMs = 3 * 24 * 60 * 60 * 1000;

/// 索引表上限（translate-source.js:27）。
const int _maxEntries = 120;

/// 一条译文结果（命中 / 未命中），两层缓存共用同一个表示。
class TranslationRecord {
  const TranslationRecord({
    required this.status,
    this.translated = '',
    this.original = '',
    this.source = '网易云译文库',
    this.reason = '',
  });

  /// 'ok' | 'not-found'。
  final String status;
  final String translated;
  final String original;
  final String source;

  /// 仅 not-found 有意义：'song-not-matched' | 'no-translation'。
  final String reason;

  bool get isOk => status == 'ok';

  /// 磁盘层用长字段名：React 代理写盘的 `TranslateResult` 就是这一份
  /// （music-api.ts:867 直接写 fetchTranslation 的返回值）。
  ///
  /// 索引层用短字段名（`status/t/o/src/at` 与 `status/reason/at`），两者不同，别混。
  /// 写盘恒是这五个字段（brief Step 2 指定的形状）；写入前已按 ok / not-found
  /// 过滤，error 这类状态不会被落盘。
  Map<String, Object?> toJson() => {
    'status': status,
    'translatedLyrics': translated,
    'originalLyrics': original,
    'source': source,
    'reason': reason,
  };
}

String _str(Object? value) => value is String ? value : '';

/// 磁盘 JSON → [TranslationRecord]：只有 status 为 'ok' 才算命中
/// （music-api.ts:179），其余（含缺 status）一律按未命中处理；
/// 命中且缺 source 才回落 '网易云译文库'（对应客户端 `payload.source || …`）。
TranslationRecord _recordFromDiskJson(Map<String, Object?> json) {
  final isOk = json['status'] == 'ok';
  final source = _str(json['source']);
  return TranslationRecord(
    status: isOk ? 'ok' : 'not-found',
    translated: _str(json['translatedLyrics']),
    original: _str(json['originalLyrics']),
    source: isOk && source.isEmpty ? '网易云译文库' : source,
    reason: _str(json['reason']),
  );
}

/// 条目时间戳：非对象 / `at` 不是数字都算 0（writeCacheTable 的 `a[1]?.at ?? 0`）。
num _atOf(Object? entry) {
  if (entry is! Map<String, Object?>) return 0;
  final at = entry['at'];
  return at is num ? at : 0;
}

/// prefs 里的译文索引表（对译 translate-source.js:108-175）。
class TranslationIndexCache {
  TranslationIndexCache(this._prefs, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 索引键，与 React 版逐字一致（translate-source.js:26）。v2 前缀的理由：
  /// 代理补上「曲名/歌手对调」候选之前存下的「查不到」是假结论，整块作废。
  static const String prefsKey = 'light-music.translate-cache.v2';

  final AppPrefs _prefs;
  final DateTime Function() _now;

  /// 查索引：无此条 / 形状不对 / 已过期（**不删**）都返回 null。
  ///
  /// TTL 按 `status === 'ok'` 分支（translate-source.js:150-153）；未命中条目
  /// 只还原 status + reason，**丢掉 message**（原版 readCached 就是这么写的）。
  Future<TranslationRecord?> read(String key) async {
    final table = await _readTable();
    final entry = table[key];
    if (entry is! Map<String, Object?>) return null;
    final at = entry['at'];
    if (at is! num) return null;
    final isHit = entry['status'] == 'ok';
    final ttl = isHit ? _ttlHitMs : _ttlMissMs;
    if (_now().millisecondsSinceEpoch - at > ttl) return null;
    if (!isHit) {
      final reason = _str(entry['reason']);
      return TranslationRecord(
        status: 'not-found',
        reason: reason.isEmpty ? 'song-not-matched' : reason,
      );
    }
    final source = _str(entry['src']);
    return TranslationRecord(
      status: 'ok',
      translated: _str(entry['t']),
      original: _str(entry['o']),
      source: source.isEmpty ? '网易云译文库' : source,
    );
  }

  /// 按短字段名落盘；只收 ok / not-found，其它状态整笔丢弃。
  Future<void> write(String key, TranslationRecord record) async {
    final at = _now().millisecondsSinceEpoch;
    final Map<String, Object?> entry;
    if (record.isOk) {
      entry = {
        'status': 'ok',
        't': record.translated,
        'o': record.original,
        'src': record.source,
        'at': at,
      };
    } else if (record.status == 'not-found') {
      entry = {
        'status': 'not-found',
        'reason': record.reason.isEmpty ? 'song-not-matched' : record.reason,
        'at': at,
      };
    } else {
      return;
    }
    final table = await _readTable();
    table[key] = entry;
    _evictOverflow(table);
    await _prefs.writeString(prefsKey, jsonEncode(table));
  }

  /// 整表读取：无键 / 坏 JSON / 不是对象（数组也算）都退化成空表，不抛。
  ///
  /// 刻意不用 AppPrefs.readJson —— 那个会顺手删掉脏数据，而原版读失败只忽略、
  /// 把脏值留在原地，等下一次写入整表覆盖。
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

  /// 超限时按 `at` 升序删掉最旧的溢出部分，结果正好 120 条
  /// （translate-source.js:126-131）。
  ///
  /// 同 `at` 时按先来后到保序：Dart 的 List.sort 不保证稳定，原版 V8 的排序稳定，
  /// 加序号兜底才能让淘汰结果可复现。
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

/// 磁盘层：每首一个 `<key>.json`，TTL 按文件 mtime，无淘汰
/// （对译 music-api.ts:174-203 与 845-867）。
class TranslationDiskCache {
  TranslationDiskCache({required this.directory, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final String directory;
  final DateTime Function() _now;

  /// `sha1("v2|<title>|<artist>|<duration>".toLowerCase())`——**整体 lowercase**，
  /// 且 duration 是秒级整数（music-api.ts:845）。与歌词磁盘键
  /// `sha1("<trackName>|<artistName>|<duration>")`（不 lowercase）是两套口径。
  static String keyFor({
    required String title,
    required String artist,
    required int duration,
  }) => sha1
      .convert(utf8.encode('v2|$title|$artist|$duration'.toLowerCase()))
      .toString();

  /// 读一条：`allowStale` 跳过 TTL 检查，供上游失败时回退过期缓存。
  Future<TranslationRecord?> read(String key, {bool allowStale = false}) async {
    try {
      final file = File('$directory/$key.json');
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      final record = _recordFromDiskJson(decoded);
      if (!allowStale) {
        final stat = await file.stat();
        final ttl = record.isOk ? _ttlHitMs : _ttlMissMs;
        final ageMs =
            _now().millisecondsSinceEpoch -
            stat.modified.millisecondsSinceEpoch;
        if (ageMs > ttl) return null;
      }
      return record;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, TranslationRecord record) async {
    // 网络类错误不写缓存（两层同一条规矩）。
    if (!record.isOk && record.status != 'not-found') return;
    try {
      await Directory(directory).create(recursive: true);
      await File('$directory/$key.json')
          .writeAsString(jsonEncode(record.toJson()));
    } catch (_) {
      // 缓存写失败不影响本次响应（music-api.ts:196-202）
    }
  }
}
