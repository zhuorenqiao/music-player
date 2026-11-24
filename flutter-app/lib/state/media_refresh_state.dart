// lib/state/media_refresh_state.dart
//
// 「重新获取全部封面与歌词」的状态机（播放列表面板表头那颗刷新按钮）。
//
// 与后台预取的区别：
//   * 用户主动动作 → **强制**绕过缓存（歌词 match(useCache:false)、封面
//     matchCover(useCache:false)），失败不清掉现有结果；
//   * 歌词与封面两条上游互不相关 → **并行**跑，各自串行节流
//       - 歌词 350ms（kLyricsPrefetchGapMs，同 lyrics_prefetch.dart）
//       - 封面 400ms（kCoverPrefetchDelayMs，同 cover_state.dart）
//   * 手动挂的 `.lrc`（lyricsSource == 'manual'）只统计、不覆盖；
//   * 跑完统一落库一次，并把当前曲目重新 attach 给 LyricsState（当前歌词
//     若被刷新，歌词页/播放卡立刻拿到新内容）。
//
// 按钮只读 [busy] / [progress]；状态机自己保证同一时刻只有一批在跑。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../lyrics/lyrics_prefetch.dart' show kLyricsPrefetchGapMs;
import '../lyrics/lyrics_source.dart';
import '../lyrics/query.dart';
import '../playback/track.dart';
import '../playback/transport_controller.dart' show ToastSink;
import 'cover_state.dart';
import 'library_state.dart';
import 'lyrics_state.dart';

/// 一次全量刷新的结果。
class MediaRefreshResult {
  MediaRefreshResult({required this.total});

  /// 参与本次刷新的曲目数。
  final int total;

  /// 成功拿到并写回的歌词条数。
  int lyrics = 0;

  /// 成功拿到并写回的封面张数。
  int covers = 0;

  /// 因手动歌词而跳过的条数。
  int manual = 0;
}

/// 全量刷新封面 / 歌词的状态机。
class MediaRefreshState extends ChangeNotifier {
  MediaRefreshState({
    required this.library,
    required this.cover,
    required this.matcher,
    required this.toasts,
    this.lyrics,
    Future<void> Function(Duration)? sleep,
    bool Function()? isOnline,
  }) : _sleep = sleep ?? _defaultSleep,
       _isOnline = isOnline ?? _alwaysOnline;

  final LibraryState library;
  final CoverState cover;
  final LyricsMatcher matcher;
  final ToastSink toasts;

  /// 刷新完要把当前曲目重新走一遍歌词状态机；测试可不传。
  final LyricsState? lyrics;

  final Future<void> Function(Duration) _sleep;
  final bool Function() _isOnline;

  bool _busy = false;
  MediaRefreshResult? _lastResult;
  String _progress = '';
  Future<MediaRefreshResult?>? _active;

  /// 是否有刷新在进行。
  bool get busy => _busy;

  /// 进行中的简短进度（没有在跑时为空串）。
  String get progress => _progress;

  /// 上一批的结果（从未跑过或正在跑时为 null）。
  MediaRefreshResult? get lastResult => _lastResult;

  /// 重新获取全部曲目的歌词与封面。连点 / 多处入口共用同一批。
  Future<MediaRefreshResult?> refreshAll() async {
    final running = _active;
    if (running != null) {
      return running;
    }
    final job = _run();
    _active = job;
    try {
      return await job;
    } finally {
      _active = null;
    }
  }

  Future<MediaRefreshResult?> _run() async {
    final tracks = <Track>[...library.tracks];
    if (!_isOnline()) {
      toasts.error('当前处于离线状态，无法重新获取封面与歌词');
      return null;
    }
    if (tracks.isEmpty) {
      toasts.info('播放列表是空的，先添加歌曲');
      return null;
    }

    _busy = true;
    _lastResult = null;
    _progress = '正在重新获取…';
    _notify();

    final result = MediaRefreshResult(total: tracks.length);
    try {
      // 封面用户主动要的就是「换一张」，所以照样对已有内嵌封面的歌跳过
      //（内嵌是文件自带的权威图，在线图抢不过它）。
      final coverItems = <CoverPrefetchItem>[
        for (final track in tracks)
          if (track.cover.isEmpty)
            (
              title: track.title,
              artist: track.artist,
              duration: track.duration,
              trackId: track.id,
            ),
      ];
      await Future.wait<void>([
        _refreshLyrics(tracks, result),
        cover.refreshAllCovers(
          coverItems,
          onMatched: (done) {
            result.covers = done;
            _progress = _progressText(result);
            _notify();
          },
        ),
      ]);
      await library.persist();
      lyrics?.attach(library.playlist.current);
      _lastResult = result;
      if (result.lyrics == 0 && result.covers == 0) {
        toasts.error(
          result.manual > 0 ? '仅保留了手动歌词，没有获取到封面或新歌词' : '没有获取到新的歌词或封面，请检查网络后重试',
        );
      } else {
        final manual = result.manual > 0 ? '（保留手动歌词 ${result.manual} 首）' : '';
        toasts.show(
          '已重新获取：歌词 ${result.lyrics} 首 · 封面 ${result.covers} 张$manual',
          key: 'media-refresh',
        );
      }
      return result;
    } catch (_) {
      // 单条失败由两条循环自己吞掉；能到这里的只有落库 / 装配层异常。
      toasts.error('重新获取失败，请稍后重试');
      return null;
    } finally {
      _busy = false;
      _progress = '';
      _notify();
    }
  }

  /// 强制重查一批曲目的歌词（手动歌词跳过）。
  Future<void> _refreshLyrics(
    List<Track> tracks,
    MediaRefreshResult result,
  ) async {
    for (final track in tracks) {
      if (track.lyricsSource == 'manual') {
        result.manual += 1;
        continue;
      }
      try {
        final query = normalizeQuery(
          title: track.title,
          artist: track.artist,
          duration: track.duration,
        );
        final match = await matcher.match(query, useCache: false);
        if (match.status == 'ok' &&
            (match.synced.isNotEmpty || match.plain.isNotEmpty)) {
          // 强制刷新：旧的自动歌词可以被覆盖；手动歌词在上一步已整个跳过。
          track.lyrics = match.synced.isNotEmpty ? match.synced : '';
          track.lyricsPlain = match.synced.isNotEmpty ? '' : match.plain;
          track.lyricsSource = 'auto';
          track.lyricsOrigin = lyricsOriginOf(match.source);
          result.lyrics += 1;
          _progress = _progressText(result);
          _notify();
        }
      } catch (_) {
        // 单条失败继续，不中断整批。
      }
      await _sleep(const Duration(milliseconds: kLyricsPrefetchGapMs));
    }
  }

  String _progressText(MediaRefreshResult result) =>
      '正在重新获取 · 歌词 ${result.lyrics} · 封面 ${result.covers}';

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // 不取消在途批次：它的结果照常写回曲目，只是不再通知界面（dispose 后
    // notifyListeners 会断言）。装配层把本状态与 App 生命周期同长，正常
    // 不会走到这里；测试里提前 dispose 时要保证 refreshAll 已收尾。
    super.dispose();
  }
}

Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

bool _alwaysOnline() => true;
