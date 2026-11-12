// lib/state/cover_state.dart
//
// 封面显示层（M2b T6）：对译 React `src/state/covers.tsx` 的
// CoverProvider + useCover —— resolver（coverForDisplay）、去重（matchFor）、
// 写真表（requestArtistPhoto）与预取（prefetchCovers）全部收进一个
// ChangeNotifier。React 版要靠「context value 换身份 + tick」才能让消费者
// 重画（covers.tsx:107-111 的注释陷阱），ChangeNotifier 的 notifyListeners
// 天然规避。
//
// 四级兜底（covers.tsx:41-53 coverForDisplay 逐字对译，spec §12）：
//   1. 内嵌封面（`track.cover` 非空 = 内嵌落盘路径，M1 语义）；
//   2. 在线匹配（`matchedCovers[trackId]`，iTunes 命中后落盘的文件路径 ——
//      React 把匹配结果直接写进 track.cover 形成等价顺序，Flutter 不写回，
//      改内存表承接，语义红线见下）；
//   3. 歌手写真（`artistPhotos[normalizeArtistKey(artist)]`，内存表，
//      null = 「问过没有」的负缓存，covers.tsx:23）；
//   4. 生成卡（返回 ''：显示层用 GeneratedCoverView 现画，不产生路径 ——
//      生成卡纯显示、每次现算、永不落盘也永不写回，covers.tsx:52）。
//
// **写回纪律（spec §12 红线）**：本层绝不写 `Track.cover`。hasRealCover
//（track.dart:131）、导入回填判重（import_service.dart:311）与自愈谓词
//（import_service.dart:593-611）都依赖「cover == 内嵌封面路径」不变量。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../cover/artist_image.dart';
import '../cover/cover_disk_cache.dart';
import '../cover/cover_source.dart';
import '../lyrics/upstream.dart';

/// 预取限速间隔（cover-source.js:411 的 COVER_PREFETCH_DELAY 逐字）。
const int kCoverPrefetchDelayMs = 400;

/// 一次预取条目：三字段曲目信息 + 显示层去重用的曲目 id。
typedef CoverPrefetchItem = ({
  String title,
  String artist,
  double duration,
  String trackId,
});

class CoverState extends ChangeNotifier {
  CoverState({
    required this.json,
    required this.bytes,
    required this.diskStore,
    required this.artistImageDirectory,
    this.coverIndex,
    this.artistIndex,
    Future<void> Function(Duration)? sleep,
    bool Function()? isOnline,
  }) : _sleep = sleep ?? _defaultSleep,
       _isOnline = isOnline ?? _alwaysOnline;

  /// iTunes 搜索与维基 REST 共用的 JSON 客户端（T5/T4 的接缝）。
  final HttpJsonClient json;

  /// 封面图字节下载通道（T3 的接缝）。
  final ImageBytesClient bytes;

  /// 在线封面落盘器（`$dataDirectory/covers-net/`）。
  final CoverDiskStore diskStore;

  /// 写真落盘目录（与 [diskStore] 同目录即可）。
  final String artistImageDirectory;

  /// 持久索引（T3/T4）；可空 —— 为空时只靠内存表，重启重新匹配。
  final CoverIndexCache? coverIndex;
  final ArtistIndexCache? artistIndex;

  final Future<void> Function(Duration) _sleep;
  final bool Function() _isOnline;

  /// 在线匹配命中的落盘路径，键是曲目 id（内存表；持久化在索引层，
  /// 重启后由 matchCover 的索引命中经 [matchFor] 回填）。
  final Map<String, String> _matched = <String, String>{};

  /// 已拿到的写真（covers.tsx:23 对译）：值 null = 「问过，没有」。
  final Map<String, String?> _photos = <String, String?>{};

  /// matchFor 的去重集（covers.tsx:66 的 pending Set 对译）。
  final Set<String> _pending = <String, String?>{}.keys.toSet();

  /// 写真请求的去重集（covers.tsx:117 的 photoPending 对译）。
  final Set<String> _photoPending = <String>{};

  /// 当前该显示的封面：三级路径或 ''（生成卡）。纯函数、不触发网络。
  String coverForDisplay({
    required String cover,
    required String artist,
    required String title,
    required String trackId,
  }) {
    if (cover.isNotEmpty) return cover;
    final matched = _matched[trackId];
    if (matched != null) return matched;
    final photo = _photos[normalizeArtistKey(artist)];
    if (photo != null) return photo;
    return '';
  }

  /// 是否还需要在线匹配（covers.tsx:33-35 对译）。React 那个
  /// `=== DEFAULT_COVER` 分支是本地静态站特有 —— Flutter 的 cover 只会是
  /// '' 或真实路径，不需要第二档。
  bool needsCoverMatch({required String cover, required String trackId}) =>
      cover.isEmpty && !_matched.containsKey(trackId);

  /// 测试可见：在线匹配的落盘路径（null = 没匹配到过）。
  String? matchedPathFor(String trackId) => _matched[trackId];

  /// 测试可见：写真路径；null 且 [hasPhotoNegativeCache] 为真 = 负缓存。
  String? photoFor(String artistKey) => _photos[artistKey];

  bool hasPhotoNegativeCache(String artistKey) =>
      _photos.containsKey(artistKey) && _photos[artistKey] == null;

  /// 测试钩子：直接注入内存表（绕过网络链路；AppPrefs.debugSeed 同款先例）。
  void debugSeedMatched(String trackId, String path) {
    _matched[trackId] = path;
  }

  /// 测试钩子：注入写真（null = 负缓存）。
  void debugSeedPhoto(String artistKey, String? path) {
    _photos[artistKey] = path;
  }

  /// 当前曲目的在线匹配（covers.tsx:86-104 matchFor 对译）。
  ///
  /// [cover] 是该曲目当前的内嵌封面路径：非空（已有真封面）→ 直接返回
  /// （covers.tsx:88 的 `!needsCoverMatch(track)` 分支）；去重中 / 离线 →
  /// 直接返回；matchCover ok → 记入 `_matched` 并通知；not-found / error /
  /// 异常 → 静默下沉到 [requestArtistPhoto]（专辑图失败降级写真）。
  void matchFor(
    CoverTrackLike track, {
    required String trackId,
    String cover = '',
  }) {
    if (cover.isNotEmpty) return;
    if (_matched.containsKey(trackId)) return;
    if (!_isOnline()) return;
    if (_pending.contains(trackId)) return;
    _pending.add(trackId);
    _matchCoverAsync(track, trackId);
  }

  Future<void> _matchCoverAsync(CoverTrackLike track, String trackId) async {
    try {
      final match = await matchCover(
        track,
        json: json,
        bytes: bytes,
        diskStore: diskStore,
        index: coverIndex,
      );
      if (match.status == 'ok' && (match.url?.isNotEmpty ?? false)) {
        _matched[trackId] = match.url!;
        notifyListeners();
      } else {
        // not-found / error / empty-query：静默下沉到写真级。
        // empty-query 不该出现在这里（调用方已过 needsCoverMatch，且
        // matchFor 的 track 由调用方保证有标题），照 React 的 catch
        // 同样兜底，不写负缓存。
        await requestArtistPhoto(track.artist);
      }
    } catch (_) {
      await requestArtistPhoto(track.artist);
    } finally {
      _pending.remove(trackId);
    }
  }

  /// 同一位歌手的写真只发一次（covers.tsx:119-136 requestArtistPhoto 对译）。
  ///
  /// ok → `_photos[key] = 落盘路径` + 通知；not-found → 负缓存 null；
  /// error → 不记（网络错误不缓存，下次还值得一试 —— React 同款）。
  Future<void> requestArtistPhoto(String artist) async {
    final key = normalizeArtistKey(artist);
    if (key.isEmpty) return;
    if (_photos.containsKey(key) || _photoPending.contains(key)) return;
    if (!_isOnline()) return;
    _photoPending.add(key);
    try {
      final match = await matchArtistImage(
        artist,
        json: json,
        directory: artistImageDirectory,
        index: artistIndex,
        downloadBytes: _downloadBytes,
      );
      if (match.status == 'ok' && (match.url?.isNotEmpty ?? false)) {
        _photos[key] = match.url;
        notifyListeners();
      } else if (match.status == 'not-found') {
        _photos[key] = null;
      }
      // error：不记，留给下次重试。
    } finally {
      _photoPending.remove(key);
    }
  }

  /// 把 [ImageBytesClient] 的四态接缝适配成 [matchArtistImage] 要的
  /// `downloadBytes`：ok → 字节，其余状态抛异常（T4 把下载异常当该语言
  /// 失败继续下一语言）。
  Future<Uint8List> _downloadBytes(Uri url, Duration timeout) async {
    final outcome = await bytes.getBytes(url, timeout: timeout);
    if (outcome is ImageBytesOk) return outcome.bytes;
    throw const _DownloadFailed();
  }

  /// 后台预取（covers.tsx:162-176 prefetchCovers 对译）：needsCoverMatch
  /// 过滤 → 逐首 matchCover → ok 写 `_matched` → 每首之间
  /// [kCoverPrefetchDelayMs] 串行节流。预取允许写 `_matched`（那是真专辑
  /// 图，语义同 React 预取写回 track.cover）；但**不**触发写真下沉 ——
  /// 预取是「切过去时图已就位」的机会主义动作，慢通道留给 matchFor。
  ///
  /// **通知按批合并，不是每命中一首就喊一次**：这条链路在冷启动后立刻对整个
  /// 曲库跑一遍（main.dart 的 unawaited 预取块），而它的订阅者里有 `HomePage`
  /// /`Stage`/`Panel` 这类「一响就重建整棵树」的大块。逐首 notify 等于让一次
  /// 冷启动触发「曲库条数」次整树重建 —— 打开就卡的那几秒正是这个窗口。
  /// 现在写表照旧逐条进行，但只在本批跑完之后统一通知一次。
  Future<void> prefetchCovers(List<CoverPrefetchItem> tracks) async {
    if (!_isOnline()) return;
    var changed = false;
    try {
      for (final track in tracks) {
        if (!needsCoverMatch(cover: '', trackId: track.trackId)) {
          continue;
        }
        // 上面的判据只挡「已在线匹配过」的；预取条目没有内嵌 cover 字段，
        // 调用方构造列表时自行过滤有内嵌封面的曲目（React 同款 ——
        // prefetchCovers 用 needsCoverMatch(track) 查 track.cover）。
        try {
          final match = await matchCover(
            (title: track.title, artist: track.artist, duration: track.duration),
            json: json,
            bytes: bytes,
            diskStore: diskStore,
            index: coverIndex,
          );
          if (match.status == 'ok' && (match.url?.isNotEmpty ?? false)) {
            _matched[track.trackId] = match.url!;
            changed = true;
          }
        } catch (_) {
          // 单条失败继续（预取绝不打扰）。
        }
        await _sleep(const Duration(milliseconds: kCoverPrefetchDelayMs));
      }
    } finally {
      // 中途抛也要把已经写进去的那些通知出去，否则界面停在旧封面上。
      if (changed) notifyListeners();
    }
  }

  /// 曲目被移出列表时清内存表（防泄漏；索引层是 LRU 淘汰，无需清理）。
  void forget(String trackId) {
    if (_matched.remove(trackId) != null) {
      notifyListeners();
    }
  }
}

class _DownloadFailed implements Exception {
  const _DownloadFailed();
}

Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

bool _alwaysOnline() => true;
