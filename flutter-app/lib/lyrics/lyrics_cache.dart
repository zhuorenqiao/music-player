// lib/lyrics/lyrics_cache.dart
//
// 歌词双层缓存：prefs 索引（短字段名，最多 120 条，读时判 TTL）+ 磁盘层（长字段
// 名，sha1 文件名，TTL 按 mtime，无淘汰）。对译 React 版
// src/lib/lyrics-source.js:175-264（readCache / writeCache / readCached /
// writeCached）与 src/server/music-api.ts:174-203（磁盘读写）、801-829（双写）。
// 纯 Dart：只依赖 AppPrefs 与 dart:io，时钟与目录都从构造注入，方便测试。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见 test/lyrics/lyrics_cache_test.dart）：
// * 索引条目 `at` 不是数字、或条目本身不是对象 → 当没有这条缓存；过期只返回 null，
//   **不删**（淘汰只发生在写入时，且只删超出 120 条的那部分）；
// * 索引写只收 ok / not-found，其余状态直接返回（错误结果不写缓存）；
// * 索引未命中的 source 是「缓存」，命中时 src 为空才回落 'LRCLIB'；
// * 磁盘层 TTL 按文件 mtime：命中 30 天、未命中 3 天；allowStale 跳过 TTL 检查，
//   供上游失败时回退过期缓存用；文件不存在 / 解析失败 / 写失败都不抛。
// * 双写：主 key 与对调 key 各写一份，两 key 相同时只写一次。artist 为空时对调
//   key 是 `sha1("|<trackName>|<duration>")`，会多写一条垃圾条目 —— 那是原版行为，
//   不要「顺手修好」，否则对调命中语义与缓存命中率都对不上。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/app_prefs.dart';

/// 条目存活时长（毫秒）：命中 30 天、未命中 3 天（lyrics-source.js:27-28、
/// music-api.ts:46-47，两层同值）。
const int _ttlHitMs = 30 * 24 * 60 * 60 * 1000;
const int _ttlMissMs = 3 * 24 * 60 * 60 * 1000;

/// 索引表上限（lyrics-source.js:24）。
const int _maxEntries = 120;

/// 一条歌词结果（命中 / 未命中），两层缓存共用同一个表示。
class LyricsRecord {
  const LyricsRecord({
    required this.status,
    this.synced = '',
    this.plain = '',
    this.source = 'LRCLIB',
  });

  /// 'ok' | 'not-found'。
  final String status;
  final String synced;
  final String plain;
  final String source;

  bool get isOk => status == 'ok';

  /// 磁盘层用长字段名：React 代理写盘的 `LyricsResult` 就是这一份
  /// （music-api.ts:225-233、241-248）。
  ///
  /// 索引层用短字段名（`s/p/src/at`），两者不同，别混。
  /// 非命中状态只序列化出 `{status}`；写入前已按 ok / not-found 过滤，
  /// error 这类状态不会被落盘。
  Map<String, Object?> toJson() => isOk
      ? {
          'status': 'ok',
          'syncedLyrics': synced,
          'plainLyrics': plain,
          'source': source,
        }
      : {'status': status};
}

String _str(Object? value) => value is String ? value : '';

/// 磁盘 JSON → [LyricsRecord]：只有 status 为 'ok' 才算命中（music-api.ts:179），
/// 其余（含缺 status）一律按未命中处理；命中且缺 source 才回落 'LRCLIB'。
LyricsRecord _recordFromDiskJson(Map<String, Object?> json) {
  final isOk = json['status'] == 'ok';
  final source = _str(json['source']);
  return LyricsRecord(
    status: isOk ? 'ok' : 'not-found',
    synced: _str(json['syncedLyrics']),
    plain: _str(json['plainLyrics']),
    source: isOk && source.isEmpty ? 'LRCLIB' : source,
  );
}

/// 条目时间戳：非对象 / `at` 不是数字都算 0（writeCache 的 `a[1]?.at ?? 0`）。
num _atOf(Object? entry) {
  if (entry is! Map<String, Object?>) return 0;
  final at = entry['at'];
  return at is num ? at : 0;
}

/// prefs 里的歌词索引表（对译 lyrics-source.js:175-264）。
class LyricsIndexCache {
  LyricsIndexCache(this._prefs, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 索引键，与 React 版逐字一致（lyrics-source.js:23）。
  static const String prefsKey = 'light-music.lyrics-cache.v1';

  final AppPrefs _prefs;
  final DateTime Function() _now;

  /// 查索引：无此条 / 形状不对 / 已过期（**不删**）都返回 null。
  Future<LyricsRecord?> read(String key) async {
    final table = await _readTable();
    final entry = table[key];
    if (entry is! Map<String, Object?>) return null;
    final at = entry['at'];
    if (at is! num) return null;
    final isMiss = entry['miss'] == true;
    final ttl = isMiss ? _ttlMissMs : _ttlHitMs;
    if (_now().millisecondsSinceEpoch - at > ttl) return null;
    if (isMiss) {
      return const LyricsRecord(status: 'not-found', source: '缓存');
    }
    final source = _str(entry['src']);
    return LyricsRecord(
      status: 'ok',
      synced: _str(entry['s']),
      plain: _str(entry['p']),
      source: source.isEmpty ? 'LRCLIB' : source,
    );
  }

  /// 按短字段名落盘；只收 ok / not-found，其它状态整笔丢弃。
  Future<void> write(String key, LyricsRecord record) async {
    final at = _now().millisecondsSinceEpoch;
    final Map<String, Object?> entry;
    if (record.isOk) {
      entry = {
        's': record.synced,
        'p': record.plain,
        'src': record.source,
        'at': at,
      };
    } else if (record.status == 'not-found') {
      entry = {'miss': true, 'at': at};
    } else {
      return;
    }
    final table = await _readTable();
    table[key] = entry;
    _evictOverflow(table);
    await _prefs.writeString(prefsKey, jsonEncode(table));
  }

  /// 清空整张表（lyrics-source.js 的 clearLyricsCache）。
  Future<void> clear() => _prefs.remove(prefsKey);

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

  /// 超限时按 `at` 升序删掉最旧的溢出部分，结果正好 120 条（lyrics-source.js:200-206）。
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
/// （对译 music-api.ts:174-203 与 801-829）。
class LyricsDiskCache {
  LyricsDiskCache({required this.directory, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final String directory;
  final DateTime Function() _now;

  /// `sha1("<trackName>|<artistName>|<duration>")`，**不 lowercase**，
  /// duration 用原始字符串（music-api.ts:801）。
  static String keyFor(String trackName, String artistName, String duration) =>
      sha1.convert(utf8.encode('$trackName|$artistName|$duration')).toString();

  /// 读一条：`allowStale` 跳过 TTL 检查，供上游失败时回退过期缓存。
  Future<LyricsRecord?> read(String key, {bool allowStale = false}) async {
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

  Future<void> write(String key, LyricsRecord record) async {
    // 错误结果不写缓存（两层同一条规矩）。
    if (!record.isOk && record.status != 'not-found') return;
    try {
      await Directory(directory).create(recursive: true);
      await File('$directory/$key.json')
          .writeAsString(jsonEncode(record.toJson()));
    } catch (_) {
      // 缓存写失败不影响本次响应（music-api.ts:196-202）
    }
  }

  /// 主 key 与对调 key 各写一份；两 key 相同时只写一次（music-api.ts:824-829）。
  Future<void> writeDual(
    String primaryKey,
    String swappedKey,
    LyricsRecord record,
  ) async {
    await write(primaryKey, record);
    if (swappedKey != primaryKey) {
      await write(swappedKey, record);
    }
  }
}
