// lib/state/bilingual_state.dart
//
// 双语（中文译文）状态机：对译 React 版 `src/state/lyrics.tsx` 的译文那一路 ——
//   * 字段与两个 useRef：`:151-163`（bilingual / translation / transState /
//     transReason / transAbortRef / transForceRef / transCacheRef /
//     translationTrackRef）；
//   * `trans` 派生值：`:165-170`；
//   * `setBilingual`：`:172-183`；
//   * 主 effect：`:185-278`（三条生命周期规则全在这段里）；
//   * `transNote`：`:280-300`（逐字文案）；
//   * `fingerprint`：`:41-43`。
// 界面只订阅一个 ChangeNotifier，`trans` / `state` / `note` 一起读。
// 纯状态层：不碰 UI、不碰 prefs（持久化走注入的 persistEnabled）。
//
// spec §11 的三条生命周期规则（一条都不能走样）：
//
// 1. **关掉只停显示、不丢数据**（lyrics.tsx:204-211）。`enabled = false` 只把
//    状态置成 off，`translation` 与 `reason` 原样留着；再打开立刻恢复显示，
//    不重新等一次网络 —— 否则源站慢或失败时会变成「怎么都切不回来」。
//
// 2. **换歌才清**（lyrics.tsx:199-203）。手上这份译文记着归属曲目 id
//    （`_translationTrackId` ↔ translationTrackRef）：id 变了才清空并清归属；
//    同一首歌只是歌词文本升级（纯文本 → 带时间轴）**沿用**已有译文，因为对齐
//    是拿「整份译文 LRC」现算的，不需要重新联网。曲目为空或 `!translatable`
//    时一并清空（`:192-198`）。
//
// 3. **重开是「先显示、后台刷新」**（lyrics.tsx:215-232 + `:251-258`）。
//    `setEnabled(true)` 置 force：命中会话缓存就先把旧译文摆出来、状态照旧，
//    同时带 `useCache: false` 在后台再问一次；**后台刷新失败或查不到都不覆盖
//    手上这份**，状态保持 ready。没有缓存才进 loading。结论写缓存的分寸：
//    `none` / `unavailable` 记（短期不再问），网络类 `error` 不记（留给下次重试）。
//
// 与 React 的两处**有意**差异（都不是疏忽，改之前先读这两段）：
//
// A. **不靠 addListener 就够了**。React 的 effect 依赖里有 `track` 对象身份，
//    而 Dart 这边唯一的触发源是 `LyricsState`（ChangeNotifier）。T13 的
//    `_apply` 只在 state/status/showRetry 三项有变化时才 notify
//    （lyrics_state.dart:620-632）：两首**都自带歌词**的曲目之间切换时这三项
//    完全一样（都是 ready + 「自动匹配」），于是**一次通知都不会发**。真实装配
//    里那一次重绘由播放层（track 变化）触发，所以 BilingualState 必须能自己发
//    现「曲目/歌词已经变了」—— 这里让 `state` / `note` / `trans` 三个 getter 在
//    读取时补一次对账（[_syncFromGetter]），并保留 addListener 作常规通路
//    （歌词从纯文本升级成带时间轴、匹配结果写回这些**会**通知的路径）。
//    对账是幂等的（签名 + 曲目对象同一性），重复读不会重复打网络。
//
// B. **构建期不直接 notifyListeners**。A 的 getter 对账可能发生在 `build()`
//    里（界面 `context.watch<BilingualState>()` 读 getter），同步 notify 会让
//    Provider 在构建期 markNeedsBuild，Flutter 直接断言失败。所以 getter 触发
//    的那次对账把通知排进微任务（build 是同步的，微任务一定在它之后）；
//    网络回来的通知不受影响（那时不在构建期）。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见
// test/state/bilingual_state_test.dart）：
// * 会话缓存 key = `'${track.id}|${fingerprint(lyricsText)}'`，命中项**连「没有
//   译文」这个结论一起记**；命中的恢复要还原 translation / state / reason 三者；
// * fingerprint 末段是 `substring(max(0, len - 24))` —— 短文本必须钳到 0，
//   直接 `len - 24` 会抛 RangeError（`:42` 的 `slice(-24)` 在 JS 里对短串是
//   「整串」，Dart 没有这个语义，必须自己钳）；
// * `trans` 每次都重算：`!enabled || translation == null || displayLines.isEmpty`
//   → 全空串；否则 `alignTranslation(displayLines, translatedLrc, originalLrc)`。
//   长度恒等于 `lyrics.displayLines.length`（T17 有等长要求）；
// * `translatable` **直接转发** `lyrics.translatable`，不重算 —— T13 已经用
//   原始未转简体文本算好了（lyrics_state.dart:604-606）；
// * 取消**是抛异常**不是返回值：T11 的 `TranslateSource.fetch` 在取消时抛
//   `RequestAborted`（translate_source.dart:166-168，与 T8 `LyricsMatch` 的
//   `status == 'aborted'` 语义**不同**），所以这里必须 try/catch，否则切歌 / 关
//   开关时会崩；捕获后按「静默丢弃这一轮结果」处理（React 的 `.catch(() => {})`
//   同样只吞不报，:272-274）；
// * `duration` 传给 `fetch` 的是 `double` 秒（T11 的签名），**不是**
//   `LyricsQuery.duration` 的 int；未知时长是 `double.nan`，由 T11 的
//   `normalizeQuery` 自己退成 0（query.dart:95）。
import 'dart:async';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart';

import '../lyrics/translate_align.dart';
import '../lyrics/translate_source.dart';
import '../lyrics/upstream.dart';
import '../playback/track.dart';
import 'lyrics_state.dart';

/// 译文这一路的进度（lyrics.tsx:38）。
///
/// 界面只在 loading / none / unavailable / error 时给提示；off 是「用户关了开关」
/// ——与 idle（没有曲目 / 不需要译文）不同，off 时数据还在（规则 1）。
enum TranslationState { idle, loading, ready, none, unavailable, error, off }

/// 一份译文：原文 + 译文都留着（原文行用来估时间轴偏移，见 T9 的 alignTranslation）。
typedef _Translation = ({String translatedLrc, String originalLrc, String source});

/// 会话缓存条目：**连「没有译文」这个结论一起记**（lyrics.tsx:161）。
typedef _CacheEntry = ({
  _Translation? translation,
  TranslationState state,
  String reason,
});

/// 一次状态转移前后的快照：值真有变化才 notify（避免同值重复重建渲染树）。
typedef _Snapshot = ({
  TranslationState state,
  _Translation? translation,
  String reason,
});

/// 状态行 / tooltip 文案，逐字对译 lyrics.tsx:280-300（不要顺手改标点：
/// `（曲名/歌手对不上）` 用全角括号、`…` 是全角省略号、`「双语」` 是全角引号）。
const String _kNoteLoading = '正在匹配中文译文…';
const String _kNoteSongNotMatched = '译文库没匹配到这首歌（曲名/歌手对不上）';
const String _kNoteNoTranslation = '这首歌还没有中文译文';
const String _kNoteNoneGeneric = '译文库里没有这首歌的中文译文';
const String _kNoteUnavailable = '中文译文需要本地代理服务（npm run dev）';
const String _kNoteError = '中文译文获取失败，关掉再打开「双语」可重试';

/// 结果没带 source 时的兜底（lyrics.tsx:243）。
const String _kDefaultSource = '网易云译文库';

/// 双语状态机。装配层持有一个实例，喂给它一个 [LyricsState] 就自动跟随当前曲目。
///
/// 生命周期：构造即开始对账（对应 React mount 时 effect 首跑），之后靠
/// [LyricsState] 的通知 + getter 读时对账两条通路跟进；见文件头差异 A。
class BilingualState extends ChangeNotifier {
  BilingualState({
    // 私有字段的命名初始化形参：对外参数名仍是 `lyrics` / `source` / `enabled` /
    // `persistEnabled`（私有名前缀在参数名里被剥掉），所以调用方写的就是 brief
    // 里那套签名。与 T13 `LyricsState` 同一写法。
    required this._lyrics,
    required this._source,
    // 类型由字段自身给出，不必在形参上重复标注（analysis_options 的 lint）。
    this._enabled = true,
    this._persistEnabled,
  }) {
    _lyrics.addListener(_onLyricsChanged);
    // 对应 React 的 mount effect（lyrics.tsx:185）：先摆 loading，再挂请求。
    _run();
  }

  final LyricsState _lyrics;
  final TranslationFetcher _source;

  /// 开关落盘回调（装配层写 `StorageKeys.bilingual`，'1' / '0'）。状态机自己不碰 prefs。
  final void Function(bool value)? _persistEnabled;

  bool _enabled;

  TranslationState _state = TranslationState.idle;

  /// 手上这份译文（规则 1 的「不丢数据」就是不清它）。
  _Translation? _translation;

  /// 查不到译文的具体原因（`song-not-matched` / `no-translation`），决定 none 的话术。
  String _reason = '';

  /// 手上这份译文**属于哪首曲目**（规则 2 的判据，lyrics.tsx:163 的 translationTrackRef）。
  ///
  /// 换歌才清；同一首只是歌词文本变化不清。曲目为空 / 不可译时一并清。
  String? _translationTrackId;

  /// 本次会话内每首歌词只问一次译文，连「没有」也记住（lyrics.tsx:161）。
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// 用户手动打开开关时绕过缓存再要一次（lyrics.tsx:159 的 transForceRef）。
  bool _force = false;

  /// 当前这轮的取消令牌：重跑前 cancel 上一次（lyrics.tsx:186-188 的 controller）。
  CancelToken? _cancel;

  /// 世代计数器：切歌 / 重跑 / dispose 都让旧世代作废，晚到的结果整段丢弃。
  ///
  /// React 比的是 `controller.signal.aborted`（lyrics.tsx:236）；Dart 的取消是
  /// 令牌 + 世代的组合（同 T13 的做法）。
  int _generation = 0;

  /// 本轮请求的 Future，供 [settle] 等测试收尾。
  Future<void>? _pending;

  /// 幂等签名：`id|lyricsText|translatable|enabled`；配合曲目对象同一性判断要不要重跑。
  ///
  /// 曲目对象同一性那一半是 React effect 依赖里 `track` 的直接对译（:278）：
  /// 同一个 id 的另一个 Track 对象也会触发一次 effect 重跑，然后命中会话缓存
  /// 直接返回（不打网络）—— 少了它，「缓存命中不重复问」这条根本没有可达路径。
  String? _signature;
  Track? _lastTrack;

  bool _disposed = false;

  /// getter 触发的对账期间为真：通知改排微任务（见文件头差异 B）。
  bool _deferNotify = false;
  bool _notifyScheduled = false;

  /// 开关当前是否打开（与持久化无关，落盘由 [setEnabled] 交回装配层）。
  bool get enabled => _enabled;

  /// 译文这一路的进度。读的时候顺手对账一次（文件头差异 A）。
  TranslationState get state {
    _syncFromGetter();
    return _state;
  }

  /// 显示在状态行里的译文说明；没有要说明的就是空串（逐字对译 lyrics.tsx:280-300）。
  String get note {
    _syncFromGetter();
    switch (_state) {
      case TranslationState.loading:
        return _kNoteLoading;
      case TranslationState.none:
        if (_reason == 'song-not-matched') return _kNoteSongNotMatched;
        if (_reason == 'no-translation') return _kNoteNoTranslation;
        return _kNoteNoneGeneric;
      case TranslationState.unavailable:
        return _kNoteUnavailable;
      case TranslationState.error:
        return _kNoteError;
      case TranslationState.idle:
      case TranslationState.ready:
      case TranslationState.off:
        return '';
    }
  }

  /// 与 [LyricsState.displayLines] 一一对齐的中文译文；关双语、无需翻译或还没
  /// 取到 → 全空串。**长度恒等于 `lyrics.displayLines.length`**（T17 要求）。
  ///
  /// 每次都重算：对齐是纯函数、行数少（lyrics.tsx:165-170 的 useMemo）；而且
  /// displayLines 可能在两次对账之间变（纯文本升级），现算才不会拿到过期行。
  List<String> get trans {
    _syncFromGetter();
    final lines = _lyrics.displayLines;
    if (!_enabled || _translation == null || lines.isEmpty) {
      return List<String>.filled(lines.length, '');
    }
    final translation = _translation!;
    return alignTranslation(
      lines,
      translation.translatedLrc,
      translation.originalLrc,
    );
  }

  /// 这首歌要不要中文译文 —— **直接转发** T13 的结果，不在这里重算。
  ///
  /// T13 用的是**原始**歌词文本（未转简体，lyrics_state.dart:604-606），这里要是
  /// 自己去判语种就会拿到转简体之后的文本，繁体歌会被误判。
  bool get translatable => _lyrics.translatable;

  /// 开关切换。对译 lyrics.tsx:172-183 的 setBilingual。
  ///
  /// 关掉走规则 1（只停显示），打开走规则 3（先显示、后台刷新）。
  void setEnabled(bool value) {
    // 原版无论值是否变化都写一遍 localStorage（:174-178），这里同样如实交回装配层。
    _persistEnabled?.call(value);
    final changed = value != _enabled;
    _enabled = value;
    if (value) {
      // 规则 3（lyrics.tsx:179-182）：打开即「重新获取」——置 force 并重跑。
      _force = true;
      _run();
      return;
    }
    // 值没变且本来就是关：不必重跑（状态已经是 off，数据也还在）。
    if (changed) _run();
  }

  /// 等当前这一批异步收尾（测试用）。
  ///
  /// 顺带补一次对账：T13 在「两首都自带歌词」的换歌路径上不发通知（文件头差异 A），
  /// 只看通知会漏掉整整一类切换。对账幂等，无事发生时不产生任何副作用。
  Future<void> settle() {
    _syncNow();
    return _pending ?? Future<void>.value();
  }

  @override
  void dispose() {
    _disposed = true;
    _lyrics.removeListener(_onLyricsChanged);
    _cancel?.cancel();
    _cancel = null;
    _pending = null;
    super.dispose();
  }

  // -- 内部 ---------------------------------------------------------------

  /// [LyricsState] 的常规通知通路：签名（或曲目对象）变了才重跑。
  void _onLyricsChanged() {
    if (_disposed) return;
    _syncNow();
  }

  /// 不在构建期读 getter 的调用方（settle / setEnabled）走这里：直接通知。
  void _syncNow() {
    if (_disposed || !_needsRun()) return;
    _run();
  }

  /// getter 里的对账：可能发生在 build 中，通知必须排到微任务（差异 B）。
  void _syncFromGetter() {
    if (_disposed || !_needsRun()) return;
    final previous = _deferNotify;
    _deferNotify = true;
    try {
      _run();
    } finally {
      _deferNotify = previous;
    }
  }

  /// 幂等判定：签名变了，或者换成了另一个曲目对象（React 依赖了 `track` 身份）。
  bool _needsRun() {
    if (_signature != _signatureOf()) return true;
    return !identical(_lyrics.track, _lastTrack);
  }

  /// 幂等签名（brief Step 3 逐字）：`'${track?.id}|${lyricsText}|${translatable}|$enabled'`。
  String _signatureOf() =>
      '${_lyrics.track?.id}|${_lyrics.lyricsText}|${_lyrics.translatable}|$_enabled';

  /// 开新一轮：取走并清掉 force，按 React effect 的顺序转移状态（lyrics.tsx:185-232）。
  void _run() {
    final before = _snapshot();
    _runBody();
    if (_changed(before)) _notify();
  }

  void _runBody() {
    // 1) 先取消上一轮（lyrics.tsx:186-188），再取走并清掉 force（:189-190）。
    _cancel?.cancel();
    final cancel = CancelToken();
    _cancel = cancel;
    final generation = ++_generation;
    final force = _force;
    _force = false;
    _signature = _signatureOf();
    _lastTrack = _lyrics.track;

    final track = _lyrics.track;

    // 2) 没有曲目 / 不需要译文 → 一并清空（lyrics.tsx:192-198）。规则 2 的末句。
    if (track == null || !_lyrics.translatable) {
      _pending = null;
      _translation = null;
      _translationTrackId = null;
      _state = TranslationState.idle;
      _reason = '';
      return;
    }

    // 3) 规则 2（lyrics.tsx:199-203）：换歌才清；同一首只是歌词文本升级要沿用。
    if (_translationTrackId != null && _translationTrackId != track.id) {
      _translation = null;
      _translationTrackId = null;
    }

    // 4) 规则 1（lyrics.tsx:204-211）：关掉只停显示、不丢数据。
    if (!_enabled) {
      _pending = null;
      _state = TranslationState.off;
      return;
    }

    // 5) 会话缓存（lyrics.tsx:213-232）。
    final cacheKey = '${track.id}|${_fingerprint(_lyrics.lyricsText)}';
    final hit = _cache[cacheKey];
    // 「手上已经有一份能用的译文」只在命中项带译文时成立（:216）。
    final reusable = hit?.translation;
    if (hit != null) {
      // 三者都还原（:218-223）：translation / state / reason。
      _translation = hit.translation;
      // 归属只在真有译文时记（:219-221 的 if (hit.translation) 守卫）。
      if (hit.translation != null) _translationTrackId = track.id;
      _state = hit.state;
      _reason = hit.reason;
      // 没有 force 就直接返回，不打网络（:224-226）。
      if (!force) {
        _pending = null;
        return;
      }
    } else {
      _translation = null;
      _translationTrackId = null;
      _state = TranslationState.loading;
      _reason = '';
    }

    // 6) 请求（lyrics.tsx:233-274）。force 决定 useCache：**注意**传的是
    //    `!force` ——「重开开关」要绕过缓存读，仍然写缓存（T11 的内部口径）。
    _pending = _request(
      track: track,
      cacheKey: cacheKey,
      cancel: cancel,
      generation: generation,
      force: force,
      reusable: reusable,
    );
  }

  Future<void> _request({
    required Track track,
    required String cacheKey,
    required CancelToken cancel,
    required int generation,
    required bool force,
    required _Translation? reusable,
  }) async {
    final TranslationResult result;
    try {
      result = await _source.fetch(
        title: track.title,
        artist: track.artist,
        // T11 要的是 double 秒（不是 LyricsQuery.duration 的 int）；未知时长是 NaN。
        duration: track.duration,
        cancel: cancel,
        useCache: !force,
      );
    } catch (_) {
      // T11 在取消时**抛** RequestAborted（translate_source.dart:166-168），
      // 不是返回 `aborted` 状态（那是 T8 `LyricsMatch` 的语义）。这里连同其它
      // 异常一起静默丢弃这一轮：界面已经切到别的歌 / 开关已关，没有任何东西
      // 该给用户看（React 的 `.catch(() => {})` 同样只吞不报，lyrics.tsx:272-274）。
      return;
    }
    // 晚到的结果一律作废（lyrics.tsx:236-238 的 `controller.signal.aborted`）。
    if (_isStale(generation)) return;

    final before = _snapshot();
    _applyResult(
      result: result,
      cacheKey: cacheKey,
      trackId: track.id,
      reusable: reusable,
    );
    if (_changed(before)) _notify();
  }

  /// 结果 → 状态（lyrics.tsx:239-271）。
  void _applyResult({
    required TranslationResult result,
    required String cacheKey,
    required String trackId,
    required _Translation? reusable,
  }) {
    if (result.status == 'ok' && result.translatedLyrics.isNotEmpty) {
      final value = (
        translatedLrc: result.translatedLyrics,
        originalLrc: result.originalLyrics,
        source: result.source.isEmpty ? _kDefaultSource : result.source,
      );
      // 成功结论进缓存（:245）。
      _cache[cacheKey] = (
        translation: value,
        state: TranslationState.ready,
        reason: '',
      );
      _translation = value;
      _translationTrackId = trackId;
      _state = TranslationState.ready;
      _reason = '';
      return;
    }

    // 规则 3（lyrics.tsx:251-258）：手上已经有一份能用的译文（重开开关触发的
    // 后台刷新）——刷新失败 / 查不到都**不覆盖**，状态保持 ready。
    if (reusable != null) {
      _state = TranslationState.ready;
      return;
    }

    // 「没有译文」与「静态部署」记进会话缓存，短期内不再问；网络类失败不记，
    // 留给下一次（或用户重开开关）重试（lyrics.tsx:259-269）。
    final TranslationState state = switch (result.status) {
      'not-found' => TranslationState.none,
      'unavailable' => TranslationState.unavailable,
      _ => TranslationState.error,
    };
    final reason = result.reason;
    if (state != TranslationState.error) {
      _cache[cacheKey] = (
        translation: null,
        state: state,
        reason: reason,
      );
    }
    _state = state;
    _reason = reason;
  }

  /// 歌词文本指纹：同一首歌词在本次会话里只取一次译文（lyrics.tsx:41-43）。
  ///
  /// 逐字对译 `'${text.length}:${text.slice(0, 24)}:${text.slice(-24)}'`。
  /// 末段是 `max(0, len - 24)` —— JS 的 `slice(-24)` 对短串取「整串」，Dart 的
  /// `substring` 直接传 `len - 24` 在 len < 24 时会抛 RangeError，必须自己钳。
  String _fingerprint(String text) {
    final length = text.length;
    final head = text.substring(0, min(24, length));
    final tail = text.substring(max(0, length - 24));
    return '$length:$head:$tail';
  }

  /// 世代是否过期（切歌 / 重跑 / dispose 都让旧世代作废）。
  bool _isStale(int generation) => _disposed || generation != _generation;

  _Snapshot _snapshot() => (
    state: _state,
    translation: _translation,
    reason: _reason,
  );

  bool _changed(_Snapshot before) =>
      before.state != _state ||
      !identical(before.translation, _translation) ||
      before.reason != _reason;

  /// 通知订阅者。构建期（getter 触发的对账）排微任务，见文件头差异 B。
  void _notify() {
    if (_disposed) return;
    if (!_deferNotify) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }
}
