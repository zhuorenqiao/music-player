// lib/cover/cover_disk_cache.dart
//
// 在线封面双层缓存的「磁盘半边」：prefs 索引层（短字段名，最多 150 条，读时判
// TTL）+ 在线封面落盘器（下载字节 → CoverImageWriter → covers-net/<id>.jpg）。
// 对译 React 版 src/lib/cover-source.js:24-29（缓存键 / 上限 / 双 TTL 常量）、
// :60-81 前后（readCache / writeCache 的条目形状与按 at 淘汰）与
// src/server/music-api.ts:705-720（服务端按 sha1 id 落盘的磁盘层）—— Flutter
// 侧没有服务端，落盘移进客户端，复用 metadata/cover_image.dart 的
// CoverImageWriter（解码 → ≤600px → PNG 字节 → `.jpg` 名，cover_image.dart:13-17
// 的格式约定不变）。索引层的写法与 LyricsIndexCache 同构
//（lyrics_cache.dart:89-178），坏 JSON 裁定也一致。
// 纯 Dart：只依赖 AppPrefs 与 dart:io，时钟从构造注入，方便测试。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见
// test/cover/cover_disk_cache_test.dart）：
// * 索引条目 `at` 不是数字、或条目本身不是对象 → 当没有这条缓存；过期只返回
//   null，**不删**（淘汰只发生在写入时，且只删超出 150 条的那部分）；
// * 索引写只收 ok / not-found，其余状态整笔丢弃（cover-source.js:125「网络错误
//   不缓存，下次还值得一试」—— error / aborted 根本不该走到 write，这里是双保险）；
// * 坏 JSON 读后留原地不删（照 lyrics_cache.dart _readTable 的裁定，刻意不用
//   AppPrefs.readJson —— 那个会顺手删掉脏数据，而原版读失败只忽略、把脏值留在
//   原地，等下一次写入整表覆盖）；
// * 淘汰照抄 LyricsIndexCache._evictOverflow：按 `at` 升序删最旧的溢出部分，
//   同 `at` 时按先来后到保序（Dart 的 List.sort 不稳定，加序号兜底才可复现）；
// * 落盘器沿用 CoverImageWriter 的「永不抛、任何失败返回 null」契约：下载超时 /
//   网络错 / 非 200 / 超 8MB / 解码 / 写盘统统返回 null，调用方静默下沉到下一级
//   兜底，绝不打扰。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/app_prefs.dart';
import '../metadata/cover_image.dart';
import 'cover_source.dart';

/// 条目存活时长（毫秒）：命中 30 天、未命中 3 天（cover-source.js:28-29）。
const int _ttlHitMs = 30 * 24 * 60 * 60 * 1000;
const int _ttlMissMs = 3 * 24 * 60 * 60 * 1000;

/// 索引表上限（cover-source.js:25）。
const int _maxEntries = 150;

/// 一条在线封面结果（命中 / 未命中），索引层与调用方共用同一个表示。
class CoverRecord {
  const CoverRecord({
    required this.status,
    this.path = '',
    this.source = 'iTunes',
  });

  /// 'ok' | 'not-found'。
  final String status;

  /// ok 时：落盘文件绝对路径（`$dataDirectory/covers-net/<sha1>.jpg`）。
  final String path;

  /// ok 时：来源，恒为 'iTunes'。
  final String source;

  bool get isOk => status == 'ok';
}

String _str(Object? value) => value is String ? value : '';

/// 条目时间戳：非对象 / `at` 不是数字都算 0（淘汰排序用，与 LyricsIndexCache 同款）。
num _atOf(Object? entry) {
  if (entry is! Map<String, Object?>) return 0;
  final at = entry['at'];
  return at is num ? at : 0;
}

/// prefs 里的在线封面索引表（对译 cover-source.js 的 readCache / writeCache）。
class CoverIndexCache {
  CoverIndexCache(this._prefs, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 索引键，与 React 版逐字一致（cover-source.js:24）。
  static const String prefsKey = 'light-music.cover-cache.v1';

  final AppPrefs _prefs;
  final DateTime Function() _now;

  /// 查索引：无此条 / 形状不对 / 已过期（**不删**）都返回 null。
  Future<CoverRecord?> read(String key) async {
    final table = await _readTable();
    final entry = table[key];
    if (entry is! Map<String, Object?>) return null;
    final at = entry['at'];
    if (at is! num) return null;
    final isMiss = entry['miss'] == true;
    final ttl = isMiss ? _ttlMissMs : _ttlHitMs;
    if (_now().millisecondsSinceEpoch - at > ttl) return null;
    if (isMiss) {
      return const CoverRecord(status: 'not-found');
    }
    final source = _str(entry['src']);
    return CoverRecord(
      status: 'ok',
      path: _str(entry['p']),
      source: source.isEmpty ? 'iTunes' : source,
    );
  }

  /// 按短字段名落盘；只收 ok / not-found，其它状态整笔丢弃。
  ///
  /// 条目形状（Global Constraints「缓存」节）：ok → `{'p': path, 'src':
  /// 'iTunes', 'at': ms}`；miss → `{'miss': true, 'at': ms}`。
  Future<void> write(String key, CoverRecord record) async {
    final at = _now().millisecondsSinceEpoch;
    final Map<String, Object?> entry;
    if (record.isOk) {
      entry = {'p': record.path, 'src': record.source, 'at': at};
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

  /// 清空整张表（cover-source.js 的 clearCoverCache）。
  Future<void> clear() => _prefs.remove(prefsKey);

  /// 整表读取：无键 / 坏 JSON / 不是对象（数组也算）都退化成空表，不抛。
  ///
  /// 刻意不用 AppPrefs.readJson —— 那个会顺手删掉脏数据，而原版读失败只忽略、
  /// 把脏值留在原地，等下一次写入整表覆盖（与 LyricsIndexCache._readTable 同款）。
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

  /// 超限时按 `at` 升序删掉最旧的溢出部分，结果正好 150 条
  /// （cover-source.js:76-81；实现照抄 LyricsIndexCache._evictOverflow）。
  ///
  /// 同 `at` 时按先来后到保序：Dart 的 List.sort 不保证稳定，原版 V8 的排序
  /// 稳定，加序号兜底才能让淘汰结果可复现。
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

/// 在线封面落盘器：下载字节 → CoverImageWriter → `$directory/<stem>.jpg`。
///
/// 对译 React 服务端 music-api.ts:705-720 的磁盘层（按 sha1 id 写文件），移进
/// 客户端。目录由装配层给（`$dataDirectory/covers-net/`）；id 是缓存键的 sha1
///（hex 小写 40 位，调用方算好传入）；解码 / 缩放 / 写盘全部委托
/// [CoverImageWriter]，沿用「永不抛、任何失败返回 null」的契约。
class CoverDiskStore {
  CoverDiskStore({required this.directory, this.writer = const CoverImageWriter()});

  final String directory;
  final CoverImageWriter writer;

  /// 缓存键 → 落盘 id：`sha1(缓存键)` 的 hex 小写（music-api.ts:711 同规则；
  /// 键由 lyrics/query.dart 的 [normalizeQuery] 产出，`曲名|歌手|时长` 中竖线
  /// 分隔、整串小写）。写真键另用 `sha1(图片 URL)`（music-api.ts:750）。
  static String cacheId(String cacheKey) =>
      sha1.convert(utf8.encode(cacheKey)).toString();

  /// id → 落盘文件路径（供显示层判 existsSync，无需真的写一次）。
  ///
  /// 命名与 [CoverImageWriter.write] 的规则一致：`<净化后的 id>.jpg`，路径
  /// 分隔符也用同一拼接方式，保证「写好的文件显示层找得到」。
  String fileFor(String id) =>
      '$directory${Platform.pathSeparator}${_stemOf(id)}'
      '${CoverImageWriter.fileExtension}';

  /// 下载 [url] 的字节并落盘，返回绝对路径；下载 / 解码 / 写盘任何失败返回
  /// null。同一 id 重复写覆盖（缓存语义，CoverImageWriter.write 同款）。
  Future<String?> saveFromUrl({
    required String url,
    required String id,
    required ImageBytesClient bytes,
  }) async {
    if (url.isEmpty || id.isEmpty || directory.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final outcome = await bytes.getBytes(uri, timeout: kCoverDownloadTimeout);
    // 超时 / 网络错 / 非 200 统统当失败返回 null（Global Constraints「网络与
    // 失败语义」：失败静默下沉，不重试、不打扰）。
    if (outcome is! ImageBytesOk) return null;
    return writer.write(
      outcome.bytes,
      'image/jpeg',
      directory: directory,
      id: id,
    );
  }

  // CoverImageWriter 的文件名净化是私有的，这里按同一规则复刻一份
  //（cover_image.dart:33、121-125）：fileFor 与 write 必须产出同一个文件名，
  // 否则「写好的文件显示层 existsSync 找不到」。sha1 的 hex 小写本就只含
  // [0-9a-f]，净化恒等；这条只为任意 id 时仍与 write 一致兜底。
  static final RegExp _unsafeStem = RegExp(r'[^A-Za-z0-9._-]');

  static String _stemOf(String id) {
    final stem = id.trim().replaceAll(_unsafeStem, '_');
    if (stem.isEmpty || stem.replaceAll('.', '').isEmpty) {
      return CoverImageWriter.fallbackStem;
    }
    return stem;
  }
}
