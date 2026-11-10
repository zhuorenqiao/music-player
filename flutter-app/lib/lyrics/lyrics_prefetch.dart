// lib/lyrics/lyrics_prefetch.dart
//
// 后台歌词预取：把列表里没歌词的曲目排队补一遍。
// 对译 React 版 src/state/lyrics-prefetch.ts（全文 68 行，核心流程 :27-68）。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见 test/lyrics/lyrics_prefetch_test.dart）：
// * 串行 + 每条间隔 PREFETCH_GAP = 350ms（lyrics-prefetch.ts:16）。歌词库是社区
//   公共服务，并行打过去等于自己造限流；sleep 在循环体末尾，最后一条之后也睡
//   一次 —— 照抄 React 的循环结构，不优化掉；
// * isOnline() 为 false 直接返回 0（:28-30）；默认恒 true，实际离线由上层网络
//   失败自然降级；
// * 跳过条件（:37-43）：当前播放曲目（它由 LyricsProvider 走带状态提示的正常
//   流程）、已有 lyrics 或 lyricsPlain、本进程已排队、本地文件时长没探到
//   （带时长查准率高得多，探到后下一轮会补上）；
// * queued 是**实例字段**而不是 React 的模块级 Set —— 每个 LyricsPrefetch 实例
//   一份；同一批里 id 重复只调一次 matcher，跨批次也不再重复排队；
// * 写回条件再查一次 `lyricsSource != 'manual' && !lyrics && !lyricsPlain`
//   （:49，进循环前已查过一次，期间用户可能手动挂了 .lrc —— 手动优先，不覆盖；
//   保留双重检查防竞态）；synced → lyrics，synced 为空 → lyricsPlain，非空 synced
//   时 lyricsPlain 置 ''；lyricsSource = 'auto'；
// * 单条异常 catch 后继续（:61-63），绝不中断整批；
// * 落库由装配层在 prefetch 完成后统一 persist 一次（M2a 批量落库同款裁定）——
//   React 逐条 `void patchLocalRecord(...)`（:53-57），Flutter 侧没有逐条 patch。
import 'dart:async';

import 'package:light_music/playback/track.dart';

import 'lyrics_source.dart';
import 'query.dart';

/// 相邻两条预取之间的间隔（毫秒）。
const int kLyricsPrefetchGapMs = 350;

/// 后台歌词预取器（对译 lyrics-prefetch.ts 的 prefetchLyrics）。
class LyricsPrefetch {
  LyricsPrefetch({
    required this.matcher,
    Future<void> Function(Duration)? sleep,
    bool Function()? isOnline,
  }) : sleep = sleep ?? _defaultSleep,
       isOnline = isOnline ?? _alwaysOnline;

  final LyricsMatcher matcher;

  /// 每条之后的间隔睡眠；测试注入空实现，免得靠真时间。
  final Future<void> Function(Duration) sleep;

  /// 在线判定；默认恒 true。
  final bool Function() isOnline;

  /// 本实例已发起过预取的曲目 id，避免重复排队。
  final Set<String> queued = <String>{};

  /// 为一批曲目后台补歌词，返回实际补齐的曲目数。
  Future<int> prefetch(List<Track> tracks, {String? currentId}) async {
    if (!isOnline()) {
      return 0;
    }
    var filled = 0;

    for (final track in tracks) {
      if (track.id == currentId ||
          track.lyrics.isNotEmpty ||
          track.lyricsPlain.isNotEmpty ||
          queued.contains(track.id)) {
        continue;
      }
      // 本地文件时长还没探到时先跳过：带时长查准率高得多，探到后下一轮会补上。
      if (track.isLocal && !track.hasDuration) {
        continue;
      }
      queued.add(track.id);
      try {
        final query = normalizeQuery(
          title: track.title,
          artist: track.artist,
          duration: track.duration,
        );
        final match = await matcher.match(query);
        if (match.status == 'ok' &&
            (match.synced.isNotEmpty || match.plain.isNotEmpty) &&
            // 期间用户可能手动挂了 .lrc —— 手动优先，不覆盖（再查一次防竞态）。
            track.lyricsSource != 'manual' &&
            track.lyrics.isEmpty &&
            track.lyricsPlain.isEmpty) {
          track.lyrics = match.synced.isNotEmpty ? match.synced : '';
          track.lyricsPlain = match.synced.isNotEmpty ? '' : match.plain;
          track.lyricsSource = 'auto';
          filled += 1;
        }
      } catch (_) {
        // 单条失败继续（React 打日志后继续），绝不中断整批。
      }
      await sleep(const Duration(milliseconds: kLyricsPrefetchGapMs));
    }

    return filled;
  }
}

Future<void> _defaultSleep(Duration duration) => Future<void>.delayed(duration);

bool _alwaysOnline() => true;
