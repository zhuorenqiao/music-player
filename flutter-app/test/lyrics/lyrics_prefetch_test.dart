// test/lyrics/lyrics_prefetch_test.dart
//
// 后台歌词预取（src/state/lyrics-prefetch.ts:27-68 逐字对译）。
// 350ms 节奏由注入的 fake sleep 断言（不靠真时间）；跳过条件逐条钉住；
// manual 不覆盖、单条异常继续、isOnline=false 短路、not-found 不写回。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lyrics_prefetch.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart' show CancelToken;
import 'package:light_music/playback/track.dart';

/// 按 trackName 返回预设结果或抛异常，并记录每次调用。
class FakeMatcher implements LyricsMatcher {
  FakeMatcher({Map<String, LyricsMatch>? byName, this.throwFor})
  : byName = byName ?? const <String, LyricsMatch>{};

  final Map<String, LyricsMatch> byName;
  final Object? Function(LyricsQuery)? throwFor;
  final List<LyricsQuery> calls = [];

  @override
  Future<LyricsMatch> match(
    LyricsQuery query, {
    CancelToken? cancel,
    bool useCache = true,
  }) async {
    calls.add(query);
    final thrown = throwFor?.call(query);
    if (thrown != null) throw thrown;
    return byName[query.trackName] ?? const LyricsMatch(status: 'not-found');
  }
}

/// 记录每次睡眠时长的假 sleep。
class RecordingSleep {
  final List<Duration> durations = [];

  Future<void> call(Duration duration) async {
    durations.add(duration);
  }
}

Track track(
  String id, {
  String title = '十年',
  String artist = '陈奕迅',
  double? duration = 210.0,
  bool isLocal = true,
  String lyrics = '',
  String lyricsPlain = '',
  String lyricsSource = '',
}) => Track(
  id: id,
  src: '/m/$id.flac',
  title: title,
  artist: artist,
  duration: duration,
  isLocal: isLocal,
  lyrics: lyrics,
  lyricsPlain: lyricsPlain,
  lyricsSource: lyricsSource,
);

const LyricsMatch okSynced = LyricsMatch(
  status: 'ok',
  synced: '[00:01.00] 十年词',
  source: 'LRCLIB',
);

void main() {
  group('LyricsPrefetch.prefetch', () {
    test('两首无歌词曲目：matcher 调 2 次、返回 2、写回 lyrics/lyricsSource，sleep 2 次 350ms', () async {
      final matcher = FakeMatcher(
        byName: {'十年': okSynced, '孤勇者': okSynced},
      );
      final sleep = RecordingSleep();
      final prefetch = LyricsPrefetch(matcher: matcher, sleep: sleep.call);
      final a = track('1', title: '十年');
      final b = track('2', title: '孤勇者');

      final filled = await prefetch.prefetch([a, b]);

      expect(filled, 2);
      expect(matcher.calls.length, 2);
      expect(a.lyrics, '[00:01.00] 十年词');
      expect(a.lyricsPlain, '');
      expect(a.lyricsSource, 'auto');
      expect(b.lyrics, '[00:01.00] 十年词');
      expect(b.lyricsSource, 'auto');
      // sleep 在循环体末尾：每条之后一次，最后一条之后也睡（照抄 React 结构）。
      expect(sleep.durations.length, 2);
      for (final d in sleep.durations) {
        expect(d, const Duration(milliseconds: 350));
      }
    });

    test('跳过条件逐条：currentId / 已有 lyrics / 已有 lyricsPlain / queued 去重 / 本地无时长', () async {
      final matcher = FakeMatcher(byName: {'十年': okSynced});
      final prefetch = LyricsPrefetch(matcher: matcher);
      final candidates = [
        track('cur'), // currentId 跳过
        track('has', lyrics: '[00:01.00] 已有'), // 已有 lyrics 跳过
        track('plain', lyricsPlain: '已有纯文本'), // 已有 lyricsPlain 跳过
        track('1'), // 正常补
        track('1'), // queued 去重：同批重复 id 只调一次
        track('local', isLocal: true, duration: double.nan), // 本地且无时长跳过
      ];

      final filled = await prefetch.prefetch(
        candidates,
        currentId: 'cur',
      );

      expect(filled, 1);
      expect(matcher.calls.length, 1);
      // 已有歌词的两条保持原样。
      expect(candidates[1].lyricsSource, '');
      expect(candidates[2].lyricsPlain, '已有纯文本');
    });

    test('manual 不覆盖：matcher 照调但不写回、不计入 filled', () async {
      final matcher = FakeMatcher(byName: {'十年': okSynced});
      final prefetch = LyricsPrefetch(matcher: matcher);
      final t = track('m', lyricsSource: 'manual');

      final filled = await prefetch.prefetch([t]);

      expect(matcher.calls.length, 1); // React 也调 matcher
      expect(filled, 0);
      expect(t.lyrics, '');
      expect(t.lyricsPlain, '');
      expect(t.lyricsSource, 'manual');
    });

    test('纯文本结果：synced 空 plain 非空 → lyricsPlain 写入、lyrics 保持空', () async {
      final matcher = FakeMatcher(
        byName: {
          '十年': const LyricsMatch(status: 'ok', plain: '十年纯文本', source: 'LRCLIB'),
        },
      );
      final prefetch = LyricsPrefetch(matcher: matcher);
      final t = track('p');

      final filled = await prefetch.prefetch([t]);

      expect(filled, 1);
      expect(t.lyrics, '');
      expect(t.lyricsPlain, '十年纯文本');
      expect(t.lyricsSource, 'auto');
    });

    test('单条抛异常：3 首、第 1 条抛 → 返回 2、不中断', () async {
      final matcher = FakeMatcher(
        byName: {'孤勇者': okSynced, '富士山下': okSynced},
        throwFor: (query) => query.trackName == '十年' ? StateError('boom') : null,
      );
      final prefetch = LyricsPrefetch(matcher: matcher);
      final a = track('1', title: '十年');
      final b = track('2', title: '孤勇者');
      final c = track('3', title: '富士山下');

      final filled = await prefetch.prefetch([a, b, c]);

      expect(filled, 2);
      expect(matcher.calls.length, 3);
      expect(a.lyrics, '');
      expect(b.lyrics, '[00:01.00] 十年词');
      expect(c.lyrics, '[00:01.00] 十年词');
    });

    test('isOnline=false：返回 0、matcher 不被调', () async {
      final matcher = FakeMatcher(byName: {'十年': okSynced});
      final prefetch = LyricsPrefetch(
        matcher: matcher,
        isOnline: () => false,
      );
      final t = track('1');

      final filled = await prefetch.prefetch([t]);

      expect(filled, 0);
      expect(matcher.calls, isEmpty);
    });

    test("status 'not-found'：不写回不计入", () async {
      final matcher = FakeMatcher(); // 缺省返回 not-found
      final prefetch = LyricsPrefetch(matcher: matcher);
      final t = track('nf');

      final filled = await prefetch.prefetch([t]);

      expect(filled, 0);
      expect(matcher.calls.length, 1);
      expect(t.lyrics, '');
      expect(t.lyricsPlain, '');
      expect(t.lyricsSource, '');
    });

    test('默认构造：isOnline 恒 true，默认 sleep 是 Future.delayed（不注入也可跑通）', () async {
      final matcher = FakeMatcher(byName: {'十年': okSynced});
      final prefetch = LyricsPrefetch(matcher: matcher);
      final t = track('d');

      final filled = await prefetch.prefetch([t]);

      expect(filled, 1);
      expect(t.lyricsSource, 'auto');
    });
  });
}
