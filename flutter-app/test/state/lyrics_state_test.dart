import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/lyrics_state.dart';

class FakeMatcher implements LyricsMatcher {
  final List<({LyricsQuery query, bool useCache})> calls = [];
  Future<LyricsMatch> Function(LyricsQuery query, bool useCache)? handler;

  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) {
    calls.add((query: query, useCache: useCache));
    // 显式炸而不是 `handler!` 的 NPE：状态机的 `catch (_)` 会把任何异常吞成
    // `LyricsLoad.error`，忘了设 handler 的用例就会以「状态像 error」的样子静默
    // 通过（复审 M5）。抛一个说得清的错误，让这种笔误立刻暴露。
    final h = handler;
    if (h == null) {
      throw StateError('FakeMatcher.handler 未设置：这个用例忘了编排匹配结果');
    }
    return h(query, useCache);
  }
}

class FakeDelay {
  final List<(Duration, Completer<void>)> pending = [];
  Future<void> call(Duration d) {
    final c = Completer<void>();
    pending.add((d, c));
    return c.future;
  }

  // 返回 Future 而不是 void：本文件的用例写的是 `await delay.fire(...)`。
  // 完成 Completer 只是把续体排进微任务队列，`await` 一个 event-loop 轮次
  // 才能保证「定时回调跑完、状态已更新」，也才能让随后的 settle() 看见新一轮。
  Future<void> fire(Duration d) async {
    for (final entry in pending.where((e) => e.$1 == d).toList()) {
      if (!entry.$2.isCompleted) entry.$2.complete();
    }
    pending.removeWhere((e) => e.$1 == d);
    await Future<void>.delayed(Duration.zero);
  }
}

Track track({
  String id = 't1',
  String title = 'Yesterday',
  String artist = 'The Beatles',
  double duration = 125,
  bool isLocal = true,
  String lyrics = '',
  String lyricsPlain = '',
  String lyricsSource = '',
}) => Track(
  id: id, src: '/m/$id.flac', title: title, artist: artist,
  duration: duration, isLocal: isLocal,
  lyrics: lyrics, lyricsPlain: lyricsPlain, lyricsSource: lyricsSource,
);

const okSynced = LyricsMatch(status: 'ok', synced: '[00:01]甲\n[00:05]乙', plain: '甲\n乙');

void main() {
  late FakeMatcher matcher;
  late FakeDelay delay;
  late int changed;

  setUp(() {
    matcher = FakeMatcher();
    delay = FakeDelay();
    changed = 0;
  });

  LyricsState build({bool online = true}) => LyricsState(
    source: matcher,
    isOnline: () => online,
    delay: delay.call,
    onChanged: () async => changed++,
  );

  test('无曲目 → idle，不联网', () async {
    final state = build()..attach(null);
    expect(state.state, LyricsLoad.idle);
    expect(state.status, '');
    expect(state.showRetry, isFalse);
    expect(matcher.calls, isEmpty);
  });

  test('手动歌词 → ready + 手动文案，不联网，且不转简体', () async {
    final t = track(lyrics: '[00:01]妳好', lyricsSource: 'manual');
    final state = build()..attach(t);
    expect(state.state, LyricsLoad.ready);
    expect(state.status, '已使用手动指定的歌词');
    expect(state.isManual, isTrue);
    expect(state.cues.single.text, '妳好');
    expect(matcher.calls, isEmpty);
  });

  test('自动匹配的歌词 → ready，且显示时转简体', () async {
    final t = track(lyrics: '[00:01]妳好', lyricsSource: 'auto');
    final state = build()..attach(t);
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
    expect(state.cues.single.text, '你好');
    expect(matcher.calls, isEmpty);
  });

  test('纯文本歌词 → ready + 静态说明；displayLines 长度与行数一致', () async {
    final t = track(lyricsPlain: '甲\n乙', lyricsSource: 'auto');
    final state = build()..attach(t);
    expect(state.status, '歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示');
    expect(state.displayLines.length, 2);
    expect(state.displayLines.first.time.isNaN, isTrue);
  });

  test('纯文本后台升级：先查缓存，再绕过缓存问一次，成功后替换并清 plain', () async {
    final t = track(lyricsPlain: '甲', lyricsSource: 'auto');
    matcher.handler = (q, useCache) async => useCache
        ? const LyricsMatch(status: 'not-found')
        : okSynced;
    final state = build()..attach(t);
    await state.settle();
    expect(matcher.calls.length, 2);
    expect(matcher.calls.first.useCache, isTrue);
    expect(matcher.calls.last.useCache, isFalse);
    expect(t.lyrics, '[00:01]甲\n[00:05]乙');
    expect(t.lyricsPlain, '');
    expect(t.lyricsSource, 'auto');
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
    expect(changed, 1);
  });

  test('纯文本升级每首每会话只试一次', () async {
    final t = track(lyricsPlain: '甲', lyricsSource: 'auto');
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'not-found');
    final state = build()..attach(t);
    await state.settle();
    final afterFirst = matcher.calls.length;
    state.attach(t); // 同一个对象再来一次（真实装配里会重复触发）
    await state.settle();
    expect(matcher.calls.length, afterFirst);
  });

  test('本地曲目时长未知 → 先等元数据，不联网', () async {
    final state = build()..attach(track(duration: double.nan));
    expect(state.state, LyricsLoad.loading);
    expect(state.status, '正在读取音频信息…');
    expect(matcher.calls, isEmpty);
  });

  test('离线且无歌词 → missing + 离线文案', () async {
    final state = build(online: false)..attach(track());
    expect(state.state, LyricsLoad.missing);
    expect(state.status, '当前离线，且这首歌还没有歌词');
  });

  test('匹配成功 → 写回活对象、标 auto、ready、落库一次', () async {
    final t = track();
    matcher.handler = (q, useCache) async => okSynced;
    final state = build()..attach(t);
    expect(state.state, LyricsLoad.loading);
    expect(state.status, '正在按曲名与歌手匹配歌词…');
    await state.settle();
    expect(t.lyrics, '[00:01]甲\n[00:05]乙');
    expect(t.lyricsSource, 'auto');
    expect(state.state, LyricsLoad.ready);
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
    expect(state.showRetry, isFalse);
    expect(changed, 1);
    expect(matcher.calls.single.useCache, isTrue);
  });

  test('只拿到纯文本 → 写 lyricsPlain，状态是静态说明', () async {
    final t = track();
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'ok', plain: '甲\n乙');
    final state = build()..attach(t);
    await state.settle();
    expect(t.lyrics, '');
    expect(t.lyricsPlain, '甲\n乙');
    expect(state.status, '歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示');
  });

  test('未找到 → missing + 带曲名的文案 + 显示重试', () async {
    final state = build()..attach(track(title: 'Yesterday'));
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'not-found');
    await state.settle();
    expect(state.state, LyricsLoad.missing);
    expect(state.status, '未找到「Yesterday」的歌词');
    expect(state.showRetry, isTrue);
  });

  test('超时错误 → error + 自动重试文案，25s 后重跑一次', () async {
    var attempt = 0;
    matcher.handler = (q, useCache) async {
      attempt += 1;
      return attempt == 1
          ? const LyricsMatch(status: 'error', reason: UpstreamReason.timeout, message: '连接歌词库超时（本机到该站点较慢，稍等会自动重试）')
          : okSynced;
    };
    final t = track();
    final state = build()..attach(t);
    await state.settle();
    expect(state.state, LyricsLoad.error);
    expect(state.status, '连接歌词库超时（本机到该站点较慢，稍等会自动重试）（25 秒后自动重试）');
    expect(state.showRetry, isTrue);
    await delay.fire(const Duration(seconds: 25));
    await state.settle();
    expect(attempt, 2);
    expect(state.state, LyricsLoad.ready);
  });

  test('自动重试每首只补一次：第二次仍失败则不再排', () async {
    matcher.handler = (q, useCache) async => const LyricsMatch(
      status: 'error', reason: UpstreamReason.unreachable, message: '连不上歌词服务，请检查网络或代理设置',
    );
    final state = build()..attach(track());
    await state.settle();
    expect(state.status, endsWith('（25 秒后自动重试）'));
    await delay.fire(const Duration(seconds: 25));
    await state.settle();
    expect(state.status.endsWith('（25 秒后自动重试）'), isFalse);
    expect(matcher.calls.length, 2);
  });

  test('message 命中「限流」也能触发自动重试（reason 缺失时）', () async {
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'error', message: '歌词服务正在限流，请稍后点「重试」');
    final state = build()..attach(track());
    await state.settle();
    expect(state.status, endsWith('（25 秒后自动重试）'));
  });

  test('retry() 绕过缓存并允许再自动补一次', () async {
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'error', reason: UpstreamReason.timeout, message: '超时');
    final state = build()..attach(track());
    await state.settle();
    state.retry();
    await state.settle();
    expect(matcher.calls.last.useCache, isFalse);
  });

  test('切歌丢弃旧结果（旧请求晚到也不写新曲目）', () async {
    final first = Completer<LyricsMatch>();
    final t1 = track(id: 'a');
    final t2 = track(id: 'b');
    matcher.handler = (q, useCache) => first.future;
    final state = build()..attach(t1);
    state.attach(t2);
    first.complete(okSynced);
    await state.settle();
    expect(t1.lyrics, '');
  });

  test('4 秒慢提示只对最新请求生效', () async {
    final completer = Completer<LyricsMatch>();
    matcher.handler = (q, useCache) => completer.future;
    final state = build()..attach(track());
    await delay.fire(const Duration(seconds: 4));
    await Future<void>.delayed(Duration.zero);
    expect(state.status, '正在匹配歌词…首次查询较慢，成功后会缓存在本地');
    completer.complete(okSynced);
    await state.settle();
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
  });

  test('translatable：非中文且 displayLines 非空才为真', () async {
    final zh = build()..attach(track(lyrics: '[00:01]我们一起看月亮'));
    expect(zh.translatable, isFalse);
    final en = build()..attach(track(lyrics: '[00:01]Hello darkness'));
    expect(en.translatable, isTrue);
    final empty = build()..attach(track());
    expect(empty.translatable, isFalse);
  });

  // ---- fix round 1（复审 I1 / M2 / M3 的回归用例） ----------------------

  test('匹配成功后推进 4 秒，状态行仍是最终文案（慢提示必须已作废）', () async {
    matcher.handler = (q, useCache) async => okSynced;
    final t = track();
    final state = build()..attach(t);
    await state.settle();
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');

    // 匹配几十毫秒就落地、世代没变；慢提示若只按世代判定，这里必然被覆盖。
    await delay.fire(const Duration(seconds: 4));
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
    expect(state.state, LyricsLoad.ready);
  });

  test('未找到落地后推进 4 秒，仍是「未找到…」而不是慢提示', () async {
    matcher.handler = (q, useCache) async => const LyricsMatch(status: 'not-found');
    final state = build()..attach(track(title: 'Yesterday'));
    await state.settle();
    expect(state.status, '未找到「Yesterday」的歌词');

    await delay.fire(const Duration(seconds: 4));
    expect(state.status, '未找到「Yesterday」的歌词');
    expect(state.showRetry, isTrue);
  });

  test('首次匹配只拿到纯文本 → 写回后立刻走一次后台升级', () async {
    final t = track();
    var call = 0;
    matcher.handler = (q, useCache) async {
      call += 1;
      // 1 = 主匹配；2 = 升级的查缓存段；3 = 升级的绕缓存段。
      // 前两段都只给纯文本，逼它走到第二段，两段升级路径才都被钉住。
      return call < 3 ? const LyricsMatch(status: 'ok', plain: '甲') : okSynced;
    };
    final state = build()..attach(t);
    await state.settle();

    expect(matcher.calls.length, 3);
    expect(matcher.calls[1].useCache, isTrue);
    expect(matcher.calls[2].useCache, isFalse);
    expect(t.lyrics, '[00:01]甲\n[00:05]乙');
    expect(t.lyricsPlain, '');
    expect(state.state, LyricsLoad.ready);
    expect(state.status, '歌词自动匹配自 LRCLIB线上库');
  });

  test('先有曲目再 attach(null)：真的走回 idle 分支', () async {
    final t = track(lyrics: '[00:01]甲', lyricsSource: 'auto');
    final state = build()..attach(t);
    expect(state.state, LyricsLoad.ready);

    // 先挂一首再清空 —— 否则首次 attach(null) 会被幂等早退吃掉，
    // `_run` 里 track == null 那条分支就没人验了（复审 M2）。
    state.attach(null);
    expect(state.state, LyricsLoad.idle);
    expect(state.status, '');
    expect(state.showRetry, isFalse);
    expect(state.track, isNull);
    expect(state.cues, isEmpty);
  });
}
