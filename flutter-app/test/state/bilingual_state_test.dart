import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/lyrics/lyrics_source.dart';
import 'package:light_music/lyrics/query.dart';
import 'package:light_music/lyrics/translate_source.dart';
import 'package:light_music/lyrics/upstream.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/state/bilingual_state.dart';
import 'package:light_music/state/lyrics_state.dart';

class FakeMatcher implements LyricsMatcher {
  LyricsMatch result = const LyricsMatch(status: 'not-found');
  @override
  Future<LyricsMatch> match(LyricsQuery query, {CancelToken? cancel, bool useCache = true}) async => result;
}

class FakeFetcher implements TranslationFetcher {
  final List<bool> useCacheCalls = [];
  Future<TranslationResult> Function(bool useCache)? handler;
  int calls = 0;

  @override
  Future<TranslationResult> fetch({
    required String title,
    required String artist,
    required double duration,
    CancelToken? cancel,
    bool useCache = true,
  }) {
    calls += 1;
    useCacheCalls.add(useCache);
    return handler!(useCache);
  }
}

Track track({String id = 't1', String lyrics = '[00:01]Hello\n[00:05]Darkness'}) => Track(
  id: id, src: '/m/$id.flac', title: 'Yesterday', artist: 'The Beatles',
  duration: 125, isLocal: true, lyrics: lyrics, lyricsSource: 'auto',
);

const okTranslation = TranslationResult(
  status: 'ok',
  translatedLyrics: '[00:01]你好\n[00:05]黑暗',
  originalLyrics: '[00:01]Hello\n[00:05]Darkness',
  source: '网易云译文库（人工翻译）',
);

/// 另一首歌的译文：用来区分「新歌的译文」与「上一首留下的译文」。
const otherTranslation = TranslationResult(
  status: 'ok',
  translatedLyrics: '[00:01]另一\n[00:05]首歌',
  originalLyrics: '[00:01]Another\n[00:05]Song',
  source: '网易云译文库（人工翻译）',
);

void main() {
  late FakeMatcher matcher;
  late FakeFetcher fetcher;
  late LyricsState lyrics;
  late List<bool> persisted;

  setUp(() {
    matcher = FakeMatcher();
    fetcher = FakeFetcher()..handler = (_) async => okTranslation;
    persisted = [];
    lyrics = LyricsState(source: matcher);
  });

  BilingualState build({bool enabled = true}) => BilingualState(
    lyrics: lyrics,
    source: fetcher,
    enabled: enabled,
    persistEnabled: persisted.add,
  );

  test('非中文歌词 → translatable 为真，自动取译文并对齐', () async {
    final t = track();
    lyrics.attach(t);
    final state = build();
    await state.settle();
    expect(state.translatable, isTrue);
    expect(state.state, TranslationState.ready);
    expect(state.trans, ['你好', '黑暗']);
  });

  test('中文歌词 → 不请求，trans 全空', () async {
    lyrics.attach(track(lyrics: '[00:01]我们一起看月亮'));
    final state = build();
    await state.settle();
    expect(state.translatable, isFalse);
    expect(fetcher.calls, 0);
    expect(state.state, TranslationState.idle);
  });

  test('规则 1：关掉只停显示，数据还在；再打开立刻恢复且不打网络', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.trans.first, '你好');

    state.setEnabled(false);
    expect(state.state, TranslationState.off);
    expect(state.trans, ['', '']);
    expect(persisted.last, isFalse);

    final callsBefore = fetcher.calls;
    state.setEnabled(true);
    // 立刻恢复（同一帧），不需要等网络
    expect(state.trans.first, '你好');
    await state.settle();
    // 规则 3：重开会在后台刷新一次（useCache:false）
    expect(fetcher.calls, greaterThan(callsBefore));
    expect(fetcher.useCacheCalls.last, isFalse);
    expect(state.state, TranslationState.ready);
  });

  test('规则 2：换歌清掉上一首的译文', () async {
    final t1 = track(id: 'a');
    lyrics.attach(t1);
    final state = build();
    await state.settle();
    expect(state.trans.first, '你好');

    lyrics.attach(track(id: 'b', lyrics: '[00:01]Another\n[00:05]Song'));
    await state.settle();
    // 新歌的译文由 fake 返回同一份，但对齐用的是新行 → 仍应重算
    expect(state.trans.length, 2);
  });

  test('规则 2 续：同一首歌歌词从纯文本升级成带时间轴时沿用译文', () async {
    final t = track(lyrics: '[00:01]Hello\n[00:05]Darkness');
    lyrics.attach(t);
    final state = build();
    await state.settle();
    final callsBefore = fetcher.calls;

    t.lyrics = '[00:01]Hello\n[00:03]Darkness'; // 文本变了 → 指纹变 → 会再问一次（符合 React）
    lyrics.attach(t);
    await state.settle();
    expect(fetcher.calls, greaterThan(callsBefore));
  });

  test('规则 3：后台刷新失败不覆盖手上这份', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.trans.first, '你好');

    var call = 0;
    fetcher.handler = (useCache) async {
      call += 1;
      return call == 1 ? okTranslation : const TranslationResult(status: 'error', reason: 'timeout', message: '超时');
    };
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(state.state, TranslationState.ready);
    expect(state.trans.first, '你好');
    expect(state.note, '');
  });

  test('规则 3：后台刷新查不到（not-found）同样不覆盖', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    var call = 0;
    fetcher.handler = (useCache) async {
      call += 1;
      return call == 1 ? okTranslation : const TranslationResult(status: 'not-found', reason: 'no-translation');
    };
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(state.state, TranslationState.ready);
    expect(state.trans.first, '你好');
  });

  test('没有译文：not-found + song-not-matched → none + 对应文案', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'not-found', reason: 'song-not-matched');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.none);
    expect(state.note, '译文库没匹配到这首歌（曲名/歌手对不上）');
  });

  test('没有译文：no-translation → 另一句文案', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'not-found', reason: 'no-translation');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.note, '这首歌还没有中文译文');
  });

  test('网络失败 → error + 文案，且结论不进会话缓存（再打开会重试）', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'error', reason: 'timeout', message: '超时');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.error);
    expect(state.note, '中文译文获取失败，关掉再打开「双语」可重试');
    final callsBefore = fetcher.calls;
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(fetcher.calls, greaterThan(callsBefore));
  });

  test('none 结论进会话缓存：关掉再开不重复问（除非 force）', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'not-found', reason: 'no-translation');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    final callsBefore = fetcher.calls;
    // 同一首歌重新 attach（模拟 view 抖动），不应重复请求
    lyrics.attach(track());
    await state.settle();
    expect(fetcher.calls, callsBefore);
  });

  test('loading 文案', () async {
    final completer = Completer<TranslationResult>();
    fetcher.handler = (_) => completer.future;
    lyrics.attach(track());
    final state = build();
    expect(state.state, TranslationState.loading);
    expect(state.note, '正在匹配中文译文…');
    completer.complete(okTranslation);
    await state.settle();
  });

  test('enabled=false 时不请求', () async {
    lyrics.attach(track());
    final state = build(enabled: false);
    await state.settle();
    expect(fetcher.calls, 0);
    expect(state.state, TranslationState.off);
    expect(state.trans, ['', '']);
  });

  test('指纹包含长度与首尾 24 字符', () async {
    // 两段文本长度相同、首尾相同、中间不同 → 指纹相同 → 命中同一份缓存
    //
    // 填充字符用拉丁字母而不是 brief 原稿的「甲」：`needsTranslation` 判「甲」这种
    // 纯汉字正文为中文歌（translate_lang.dart:38-53），于是 translatable 恒为 false、
    // 一次请求都不会发，`callsBefore` 永远是 0，这条断言对**任何**正确实现都不可达。
    // 意图（指纹在长文本上不崩、换 id 后 key 变了要重问）与断言强度原样保留。
    final a = '[00:01]${'a' * 40}X';
    final b = '[00:01]${'a' * 40}Y';
    lyrics.attach(track(id: 'a', lyrics: a));
    final state = build();
    await state.settle();
    final callsBefore = fetcher.calls;
    expect(callsBefore, greaterThan(0));
    lyrics.attach(track(id: 'b', lyrics: b));
    await state.settle();
    // id 变了 → key 变了，仍会重问；这里只验证不会崩
    expect(fetcher.calls, greaterThan(callsBefore));
  });

  test('短文本（长度 < 24）也不抛 RangeError：末段钳到 0', () async {
    // fingerprint 的末段必须是 substring(max(0, len - 24))——直接 substring(len - 24)
    // 在 11 个字符的文本上会抛 RangeError（JS 的 slice(-24) 对短串取整串）。
    // 断言只看「跑通了 + 没有崩」：唯一一行会拿到整份译文（T9 的 joinFragments）。
    lyrics.attach(track(lyrics: '[00:01]Hi'));
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.ready);
    expect(state.trans.length, 1);
    expect(state.trans.single, isNotEmpty);
  });

  // ---- 以下为实现者补充的用例（只增不减，全部针对 brief 骨架覆盖不到的边）----

  test('没有曲目 → idle，trans 为空，不请求', () async {
    final state = build();
    await state.settle();
    expect(fetcher.calls, 0);
    expect(state.state, TranslationState.idle);
    expect(state.note, '');
    expect(state.trans, isEmpty);
    expect(state.translatable, isFalse);
  });

  test('规则 3 的另一半：重开时没有缓存才进 loading', () async {
    lyrics.attach(track());
    final state = build(enabled: false);
    await state.settle();
    expect(state.state, TranslationState.off);
    expect(fetcher.calls, 0);

    final completer = Completer<TranslationResult>();
    fetcher.handler = (_) => completer.future;
    state.setEnabled(true);
    // 没有缓存 → 同步进 loading（有缓存时是「先把旧译文摆出来」）
    expect(state.state, TranslationState.loading);
    expect(state.note, '正在匹配中文译文…');
    completer.complete(okTranslation);
    await state.settle();
    expect(state.state, TranslationState.ready);
    expect(state.trans, ['你好', '黑暗']);
  });

  test('规则 3 补强：重开的后台刷新**真**失败时不覆盖手上这份', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.ready);

    // 初始取译文那一次已经过去；之后每一次（重开触发的后台刷新）都失败
    var refresh = 0;
    fetcher.handler = (_) async {
      refresh += 1;
      return const TranslationResult(status: 'error', reason: 'timeout', message: '超时');
    };
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(refresh, 1);
    expect(state.state, TranslationState.ready);
    expect(state.trans, ['你好', '黑暗']);
    expect(state.note, '');
  });

  test('规则 3 补强：后台刷新查不到时不覆盖，也不把「没有」写进缓存', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();

    var refresh = 0;
    fetcher.handler = (_) async {
      refresh += 1;
      return const TranslationResult(status: 'not-found', reason: 'no-translation');
    };
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(refresh, 1);
    expect(state.state, TranslationState.ready);
    expect(state.trans, ['你好', '黑暗']);

    // 「没有」没被写进缓存：再关开一次仍然会刷新（而不是命中 none 直接返回）
    state.setEnabled(false);
    state.setEnabled(true);
    await state.settle();
    expect(refresh, 2);
  });

  test('关掉双语时在途请求作废：RequestAborted 静默丢弃，不崩不改状态', () async {
    final completer = Completer<TranslationResult>();
    fetcher.handler = (_) => completer.future;
    lyrics.attach(track());
    final state = build();
    expect(state.state, TranslationState.loading);

    state.setEnabled(false);
    expect(state.state, TranslationState.off);
    // T11 的取消语义是**抛异常**（不是返回 aborted 状态）：必须被吞掉
    completer.completeError(const RequestAborted());
    await Future<void>.delayed(Duration.zero);
    expect(state.state, TranslationState.off);
    expect(state.trans, ['', '']);
  });

  test('切歌后旧请求晚到：不写到新歌上（世代丢弃）', () async {
    final first = Completer<TranslationResult>();
    final second = Completer<TranslationResult>();
    var call = 0;
    fetcher.handler = (_) => (call++ == 0) ? first.future : second.future;

    lyrics.attach(track(id: 'a'));
    final state = build();
    expect(state.state, TranslationState.loading);
    expect(fetcher.calls, 1);

    lyrics.attach(track(id: 'b', lyrics: '[00:01]Another\n[00:05]Song'));
    // 读 getter 补一次对账，起新一轮（旧令牌被取消、世代推进）
    expect(state.trans, ['', '']);
    expect(call, 2);

    first.complete(okTranslation); // 旧歌的译文晚到
    await Future<void>.delayed(Duration.zero);
    expect(state.trans, ['', '']); // 不能挂到新歌上

    second.complete(otherTranslation);
    await state.settle();
    expect(state.trans, ['另一', '首歌']);
  });

  test('指纹只由长度与首尾 24 字符决定：中段变了也命中同一份缓存', () async {
    final head = '[00:01]${'p' * 17}'; // 前 24 字符
    final tail = 's' * 24; // 末 24 字符
    final a = '${head}MMMMMM$tail';
    final b = '${head}NNNNNN$tail'; // 长度、首 24、末 24 全同，只有中段不同
    lyrics.attach(track(id: 'a', lyrics: a));
    final state = build();
    await state.settle();
    expect(state.trans.length, 1);
    expect(state.trans.first, isNotEmpty);
    final callsBefore = fetcher.calls;

    lyrics.attach(track(id: 'a', lyrics: b));
    await state.settle();
    expect(fetcher.calls, callsBefore); // 指纹相同 → 会话缓存命中，不再问
    expect(state.state, TranslationState.ready);
    expect(state.trans.length, 1);
    expect(state.trans.first, isNotEmpty);
  });

  test('unavailable 档的文案与缓存（T11 直连不产出，映射仍要钉住）', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'unavailable');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.unavailable);
    expect(state.note, '中文译文需要本地代理服务（npm run dev）');

    // unavailable 记进会话缓存：同一首歌再 attach 不再问
    final callsBefore = fetcher.calls;
    lyrics.attach(track());
    await state.settle();
    expect(fetcher.calls, callsBefore);
  });

  test('none 但 reason 缺失 → 通用文案', () async {
    fetcher.handler = (_) async => const TranslationResult(status: 'not-found');
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.state, TranslationState.none);
    expect(state.note, '译文库里没有这首歌的中文译文');
  });

  test('切到中文歌：清空译文回 idle，不再请求', () async {
    lyrics.attach(track(id: 'a'));
    final state = build();
    await state.settle();
    expect(state.trans.first, '你好');
    final callsBefore = fetcher.calls;

    lyrics.attach(track(id: 'zh', lyrics: '[00:01]我们一起看月亮'));
    await state.settle();
    expect(state.translatable, isFalse);
    expect(state.state, TranslationState.idle);
    expect(state.note, '');
    expect(state.trans, ['']); // 一个显示行 → 一个空串
    expect(fetcher.calls, callsBefore);
  });

  test('T15 的真实装配顺序：先建双语状态、后 attach 曲目，照样跟随', () async {
    // buildBootstrap 里 bilingual 紧随 lyrics 建，而 lyrics.attach(player.current)
    // 发生在 library.restore() 之后 —— 构造时手上还没有曲目。
    final state = build();
    expect(state.state, TranslationState.idle);
    expect(fetcher.calls, 0);

    lyrics.attach(track());
    await state.settle();
    expect(state.state, TranslationState.ready);
    expect(state.trans, ['你好', '黑暗']);
    expect(fetcher.calls, 1);
  });

  test('LyricsState 不通知的换歌路径：读 getter 会补一次对账', () async {
    lyrics.attach(track(id: 'a'));
    final state = build();
    await state.settle();
    final callsBefore = fetcher.calls;

    // 第二首同样自带带时间轴的歌词 → LyricsState 的状态行完全没变，
    // 它的 _apply 判定「无变化」就不会 notify。
    lyrics.attach(track(id: 'b', lyrics: '[00:01]Another\n[00:05]Song'));
    expect(fetcher.calls, callsBefore);
    // 但读时已不显示上一首的译文（规则 2 的读时归属断言）
    expect(state.trans, ['', '']);

    await Future<void>.delayed(Duration.zero); // 让读时排的那次对账跑起来
    await state.settle();
    expect(fetcher.calls, greaterThan(callsBefore));
    expect(state.trans, ['你好', '黑暗']);
  });

  test('trans 长度恒等于 displayLines：没有译文 / 关掉 / 不可译都等长', () async {
    lyrics.attach(track());
    final state = build();
    await state.settle();
    expect(state.trans.length, lyrics.displayLines.length);

    state.setEnabled(false);
    expect(state.trans.length, lyrics.displayLines.length);

    state.setEnabled(true);
    await state.settle();
    lyrics.attach(track(lyrics: '[00:01]一起\n[00:05]看月亮'));
    await state.settle();
    expect(state.trans.length, lyrics.displayLines.length);
    expect(state.trans.every((line) => line.isEmpty), isTrue);
  });
}
