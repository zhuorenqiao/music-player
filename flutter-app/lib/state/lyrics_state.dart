// lib/state/lyrics_state.dart
//
// 当前曲目的歌词状态机：对译 React 版 src/state/lyrics.tsx:303-473 的那个
// useEffect（状态行、自动匹配、纯文本升级、一次性自动重试、4 秒慢提示）与
// 111-149 的派生值（cues / plain / plainLines / displayLines / translatable）。
//
// 界面订阅一个 ChangeNotifier：状态、文案、显示行一起变，一次 notify。
// 「当前第几行」不在这里算 —— 和原版一样由渲染层拿播放时间自己二分
// （findActiveCue，lyrics.tsx:79-95），否则 timeupdate 会把整棵树带着重绘。
//
// 三处**有意**与 React 不同（都不是疏忽，改之前先读这一段）：
//
// 1. isOnline 默认恒 true。React 版读 navigator.onLine（lyrics-source.js:580），
//    Flutter 没有不引依赖就能用的等价 API，本工程也不许新增依赖。离线分支
//    保留且可注入：生产上真离线时匹配会以 unreachable 返回，落到 error 那句
//    「连不上歌词库，请检查网络或代理设置」，一样说得通。注入点留给测试与将来
//    接入 connectivity 的实现。
//
// 2. 写入活对象后直接重算 + notifyListeners()，不等 effect 重跑。React 把
//    track.lyrics / track.lyricsPlain 写进可变对象后靠 setTick 触发 effect 重跑，
//    再由 effect 依赖里的 track?.lyrics 让它看见新值（lyrics.tsx:425 / :473 的
//    依赖数组）；Dart 没有 effect 生命周期，这里在写回的那一刻重算派生值并通知，
//    等价于「重新跑一遍 effect」且少一次中间态。**写入后必须同步刷新幂等键**
//    （_syncKey），否则下一次 attach 会把这次自己的写回误判成「歌词变了」而重跑。
//
// 3. 定时器用注入的 delay（默认 Future.delayed），不是 window.setTimeout。
//    React 的 retryTimer 是 window.setTimeout（lyrics.tsx:452），慢提示同理
//    （:403）。这里统一走 delay，测试才能把 4s / 25s 拨快，不必真等 29 秒；
//    真实实现是 Future.delayed，取消不了，所以两个定时回调都必须先验世代。
//
// 移植时守住的非显而易见语义（每条都有用例钉，见
// test/state/lyrics_state_test.dart）：
// * 每次「重新开始一轮」（attach / retry / 自动重试到点）都 ++_generation，并
//   cancel 旧 CancelToken；异步结果回来先比世代，不等就整段丢弃 —— 慢提示与
//   自动重试这两个 detached 定时器同样要验，「4 秒慢提示只对最新请求生效」
//   「旧请求晚到也不写新曲目」两条用例钉的就是这里；
// * aborted 结果什么都不做：不改状态、不通知、不弹错（lyrics.tsx:438-440）；
// * 自动重试每会话每首只补一次；retry() 清掉「已自动重试」「已升级」两条记录并
//   置 force，让下一次匹配绕过缓存（:302-309 / :446-457）；
// * 纯文本升级只在「无 lyrics、有 plain、非 manual、本会话未升级过、在线」时走，
//   且**必须**先 useCache:true，拿不到带时间轴的结果才 useCache:false 再问一次；
//   失败静默 —— 继续静态显示、不打扰用户（:330-377）；
// * 升级「试过」的记录只在没被打断时写（:371-374）：被切歌打断的那一次不算试过，
//   下次进来还要再试；
// * 匹配回来的 ok 只有「当前不是 manual 且两个字段都空」才写回活对象（:418）——
//   请求期间用户可能手动导入了 .lrc，手动优先级最高；
// * cues / plain 是转简体后的（manual 不转，:116 / :121）；lyricsText 是**原始**
//   文本（判语种与做译文指纹用，:145），translatable = displayLines 非空 &&
//   needsTranslation(原始文本)；
// * 落库走注入的 onChanged —— 状态机自己不碰 DB / prefs（原版由外层 store 落盘）。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../lyrics/lrc_parser.dart';
import '../lyrics/lyrics_source.dart';
import '../lyrics/opencc/converter.dart';
import '../lyrics/query.dart';
import '../lyrics/translate_lang.dart';
import '../lyrics/upstream.dart';
import '../playback/track.dart';

/// 与 React 的 `LyricsState`（src/state/types.ts:45）同构的五态。
enum LyricsLoad { idle, loading, ready, missing, error }

/// 匹配失败后自动补一次的间隔（lyrics.tsx:20 的 AUTO_RETRY_DELAY）。
const Duration _kDefaultAutoRetryDelay = Duration(seconds: 25);

/// 首次查询的慢提示延迟（lyrics.tsx:407 的 4000ms）。
const Duration _kDefaultSlowHintDelay = Duration(seconds: 4);

// 状态行文案，逐字对译 lyrics.tsx（不要顺手改标点 / 空格：「LRCLIB线上库」中间
// 没有空格、「…」是全角省略号，都是原版的字面量）。
const String _kStatusManual = '已使用手动指定的歌词';
const String _kStatusSynced = '歌词自动匹配自 LRCLIB线上库';
const String _kStatusPlain = '歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示';
const String _kStatusOffline = '当前离线，且这首歌还没有歌词';
const String _kStatusReadingMeta = '正在读取音频信息…';
const String _kStatusMatching = '正在按曲名与歌手匹配歌词…';
const String _kStatusSlow = '正在匹配歌词…首次查询较慢，成功后会缓存在本地';
const String _kStatusFailed = '歌词匹配失败';

/// 自动重试的追加后缀；秒数从注入的间隔现算（lyrics.tsx:450 的
/// `Math.round(AUTO_RETRY_DELAY / 1000)`）。
String _autoRetrySuffix(Duration autoRetryDelay) =>
    '（${(autoRetryDelay.inMilliseconds / 1000).round()} 秒后自动重试）';

/// 触发自动重试的 message 特征（lyrics.tsx:447 的 `/限流|超时|暂时不可用/`）。
final RegExp _retryableMessage = RegExp('限流|超时|暂时不可用');

/// 触发自动重试的 reason 集合（lyrics.tsx:446 的四个字符串）。
///
/// 原版是 `['timeout', 'unreachable', 'rate-limit', 'upstream'].includes(...)`；
/// Dart 侧 [UpstreamReason] 正好四项一一对应，用枚举比字符串更不会写错。
const Set<UpstreamReason> _retryableReasons = {
  UpstreamReason.timeout,
  UpstreamReason.unreachable,
  UpstreamReason.rateLimit,
  UpstreamReason.upstream,
};

/// 歌词状态机。构造后调 [attach] 接手一首曲目；切歌就再调一次。
///
/// 生命周期：装配层持有一个实例，在播放视图变化时把当前 [Track]（可空）喂进来。
/// 同一首歌重复 attach 是幂等的（内部比对曲目对象同一性与歌词指纹）。
class LyricsState extends ChangeNotifier {
  LyricsState({
    // 私有字段的命名初始化形参：对外参数名仍是 `source` / `onChanged` 等
    // （私有名前缀在参数名里被剥掉），所以调用方写的就是 brief 里那套签名。
    required this._source,
    bool Function()? isOnline,
    this._slowHintDelay = _kDefaultSlowHintDelay,
    this._autoRetryDelay = _kDefaultAutoRetryDelay,
    Future<void> Function(Duration)? delay,
    this._onChanged,
  }) : // 差异 1（见文件头）：默认恒 true。
       _isOnline = isOnline ?? (() => true),
       // 差异 3（见文件头）：默认 Future.delayed，测试注入可控的假延时。
       _delay = delay ?? _defaultDelay;

  static Future<void> _defaultDelay(Duration d) => Future<void>.delayed(d);

  final LyricsMatcher _source;
  final bool Function() _isOnline;
  final Duration _slowHintDelay;
  final Duration _autoRetryDelay;
  final Future<void> Function(Duration) _delay;

  /// 匹配成功后的落库回调（装配层给）。状态机自己不碰 DB。
  final Future<void> Function()? _onChanged;

  Track? _track;
  LyricsLoad _state = LyricsLoad.idle;
  String _status = '';
  bool _showRetry = false;

  // 派生值：只在 attach 与写回活对象后由 [_recomputeLyrics] 算一次。不放进
  // getter —— toSimplified 有缓存，parseLrc 不便宜，而渲染层每帧都会读 getter。
  List<LyricLine> _cues = const [];
  String _plain = '';
  List<String> _plainLines = const [];
  List<LyricLine> _displayLines = const [];
  String _lyricsText = '';
  bool _translatable = false;

  /// 世代计数器：每次「重新开始一轮」都 +1。
  ///
  /// 所有异步结果（匹配返回、慢提示、自动重试到点）回来先比它，不等就整段丢弃。
  /// 对译 React 的 requestId（lyrics.tsx:109 的 useRef，:394 / :404 / :413 三处比对）。
  int _generation = 0;

  /// 当前这轮的取消令牌：重跑前 cancel 上一次。
  CancelToken? _cancel;

  /// 本轮匹配的 Future，供 [settle] 等测试收尾。慢提示与自动重试是 detached 的
  /// 定时器，不进这里（它们不该让 settle() 卡住 4s / 25s）。
  Future<void>? _pending;

  /// attach 的幂等键：`id|lyrics|lyricsPlain|lyricsSource`，配对象同一性。
  ///
  /// 真实装配里 view 每次变化都会调 attach，同一首歌会反复进来几十次；没有它
  /// 就会重跑匹配、重复落库。写回活对象后由 [_syncKey] 同步刷新。
  String? _attachKey;
  Track? _attachedTrack;

  /// 本会话「已自动重试」过的曲目 id（lyrics.tsx:103 的 retriedRef）。
  final Set<String> _retried = <String>{};

  /// 本会话「已尝试升级纯文本」的曲目 id（lyrics.tsx:105 的 upgradedRef）。
  final Set<String> _upgraded = <String>{};

  /// 用户点过「重试」：下一次匹配绕过本地缓存（lyrics.tsx:107 的 forceNextRef）。
  bool _force = false;

  bool _disposed = false;

  /// 当前接手的曲目；null 表示没有正在播的歌。
  Track? get track => _track;

  LyricsLoad get state => _state;
  String get status => _status;
  bool get showRetry => _showRetry;
  bool get isManual => _track?.lyricsSource == 'manual';

  /// 已解析的带时间轴行（已转简体；manual 不转）。
  List<LyricLine> get cues => _cues;

  /// 无时间轴时的纯文本（已转简体；manual 不转）。
  String get plain => _plain;

  /// 纯文本按行拆开（去首尾空行、逐行 trim），与译文按行对齐。
  List<String> get plainLines => _plainLines;

  /// 当前真正显示的行：有时间轴用 [cues]，否则用纯文本行。
  ///
  /// 纯文本行的 `time` 是 `double.nan` —— 下游判「有没有时间轴」只能看
  /// `time.isNaN`，不能拿它比大小或排序（NaN 的比较恒 false）。
  List<LyricLine> get displayLines => _displayLines;

  /// **原始**歌词文本（未转简体），判语种与做译文指纹用（lyrics.tsx:145）。
  String get lyricsText => _lyricsText;

  /// 这首歌要不要中文译文：displayLines 非空 && 原文不是中文（lyrics.tsx:146）。
  bool get translatable => _translatable;

  /// 切歌入口（装配层在播放视图变化时调用；同值重复调用无副作用）。
  void attach(Track? track) {
    // 幂等：同一个对象 + 同样的歌词字段，说明这次触发没带来任何新信息。
    // 真实装配里 view 变化（进度、音量…）都会走到这里。
    if (track != null &&
        identical(track, _attachedTrack) &&
        _trackKey(track) == _attachKey) {
      return;
    }
    _attachedTrack = track;
    _attachKey = track == null ? null : _trackKey(track);
    _track = track;
    _restart();
  }

  /// 用户点「重试」：清掉该曲目的「已自动重试」「已升级」记录，绕过缓存重跑。
  void retry() {
    final track = _track;
    if (track != null) {
      _retried.remove(track.id);
      _upgraded.remove(track.id);
    }
    _force = true;
    _restart();
  }

  /// 等当前这批异步收尾（测试用）。detached 的慢提示与自动重试不在其中。
  Future<void> settle() => _pending ?? Future<void>.value();

  @override
  void dispose() {
    _disposed = true;
    // 在途请求靠取消令牌与世代一起作废；真实实现是 Future.delayed，取消不了，
    // 所以两个定时回调用 _isStale 兜底（FakeDelay 里未完成的 Completer 不必清）。
    _cancel?.cancel();
    _cancel = null;
    _pending = null;
    super.dispose();
  }

  // -- 内部 ---------------------------------------------------------------

  /// 开新一轮：++世代、取消旧请求、按状态转移表重算，需要联网的挂上 [_pending]。
  ///
  /// 对译 lyrics.tsx:311-317 的 effect 开头（abort 旧请求、clearTimeout、
  /// 取走 force 并清掉）。
  void _restart() {
    _cancel?.cancel();
    final cancel = CancelToken();
    _cancel = cancel;
    final generation = ++_generation;
    final force = _force;
    _force = false;
    _run(generation: generation, cancel: cancel, force: force);
  }

  /// 状态转移表的同步部分；需要联网的分支把异步那一半挂到 [_pending]。
  void _run({
    required int generation,
    required CancelToken cancel,
    required bool force,
  }) {
    final track = _track;

    // 1) 没有曲目 → idle。
    if (track == null) {
      _pending = null;
      _recomputeLyrics();
      _apply(state: LyricsLoad.idle, status: '', showRetry: false);
      return;
    }

    // 2) 已有歌词（内置 / 手动 / 之前匹配过）就不再联网。
    if (track.lyrics.isNotEmpty || track.lyricsPlain.isNotEmpty) {
      _pending = null;
      _recomputeLyrics();
      _apply(
        state: LyricsLoad.ready,
        status: track.lyricsSource == 'manual'
            ? _kStatusManual
            : (track.lyrics.isNotEmpty ? _kStatusSynced : _kStatusPlain),
        showRetry: false,
      );
      // 纯文本后台升级（文件头第 4 条）。
      _pending = _maybeUpgrade(
        track: track,
        generation: generation,
        cancel: cancel,
      );
      return;
    }

    // 3) 离线且没有任何歌词。
    if (!_isOnline()) {
      _pending = null;
      _recomputeLyrics();
      _apply(
        state: LyricsLoad.missing,
        status: _kStatusOffline,
        showRetry: false,
      );
      return;
    }

    // 4) 本地文件时长还没探到：先等元数据，带时长查准得多（lyrics.tsx:387-392）。
    if (track.isLocal && !track.duration.isFinite) {
      _pending = null;
      _recomputeLyrics();
      _apply(
        state: LyricsLoad.loading,
        status: _kStatusReadingMeta,
        showRetry: false,
      );
      return;
    }

    // 5) 其余：先把 loading 摆出去，再挂慢提示与请求。
    _recomputeLyrics();
    _apply(
      state: LyricsLoad.loading,
      status: _kStatusMatching,
      showRetry: false,
    );
    _pending = _match(
      track: track,
      generation: generation,
      cancel: cancel,
      force: force,
    );
  }

  /// 发起一次匹配，并按状态转移表的后四行处理结果（lyrics.tsx:409-467）。
  Future<void> _match({
    required Track track,
    required int generation,
    required CancelToken cancel,
    required bool force,
  }) async {
    // 慢提示：4 秒后仍是最新请求才换说法（lyrics.tsx:402-407）。detached ——
    // 它不阻塞 settle()，也不影响匹配本身。**必须同步起算**：它是「匹配已经
    // 开始」的计时，不该等到下一个微任务。
    unawaited(_slowHint(generation: generation));

    // 真正发请求前先让出一个微任务：React 那边整个 effect 体（含 matchLyrics
    // 调用）是在 render commit **之后**才跑的，从来不在调用方的同步栈里发请求。
    // Dart 侧 attach 是同步调用，少了这一让，「attach 之后才注入的假源 / 才接好
    // 的落库回调」就全都赶不上第一轮匹配。代价只是晚一个微任务，且世代已在
    // _restart 里推进，让出期间切歌照样作废旧这一轮。
    await Future<void>.value();
    if (_isStale(generation)) return;

    final LyricsMatch result;
    try {
      result = await _source.match(
        _query(track),
        cancel: cancel,
        // 普通匹配走缓存，手动 retry 才绕过（lyrics.tsx:409 的 useCache: !force）。
        useCache: !force,
      );
    } catch (_) {
      // 原版 .catch（:458-467）：只有真抛错才走这里；aborted 是正常返回值、不进 catch。
      if (_isStale(generation)) return;
      _recomputeLyrics();
      _apply(state: LyricsLoad.error, status: _kStatusFailed, showRetry: true);
      return;
    }
    if (_isStale(generation)) return;
    final upgrade = _applyMatchResult(
      track: track,
      result: result,
      generation: generation,
      cancel: cancel,
    );
    // 匹配只拿到纯文本时，React 的 effect 会因为 track.lyricsPlain 变了而重跑，
    // 重跑正好满足升级条件、紧接着发起升级（lyrics.tsx:324-336，依赖数组见 :473）。
    // 差异 2 说「写回后直接重算、等价于重跑 effect」，那就得把整段 effect 体重新
    // 求值 —— 不只是派生值。这里把升级接在本轮 Future 上，settle() 才等得到它。
    if (upgrade != null) await upgrade;
  }

  /// 匹配结果 → 状态（表里「→ ok / not-found / aborted / 其它」四行）。
  ///
  /// 返回写回纯文本后要做的后台升级（没有就返回 null）—— 由 [_match] await，
  /// 好让 [settle] 覆盖它。
  Future<void>? _applyMatchResult({
    required Track track,
    required LyricsMatch result,
    required int generation,
    required CancelToken cancel,
  }) {
    Future<void>? upgrade;
    if (result.status == 'ok' &&
        (result.synced.isNotEmpty || result.plain.isNotEmpty)) {
      // 请求期间用户可能手动导入了 .lrc：手动优先级最高，绝不覆盖
      // （lyrics.tsx:417-418）。
      if (track.lyricsSource != 'manual' &&
          track.lyrics.isEmpty &&
          track.lyricsPlain.isEmpty) {
        if (result.synced.isNotEmpty) {
          track.lyrics = result.synced;
        } else {
          track.lyricsPlain = result.plain;
        }
        track.lyricsSource = 'auto';
        // 写入活对象后立刻重算 + 落库 + 通知（差异 2）。_syncKey 必须同步刷新，
        // 否则下一次 attach 会把这次写回当成「歌词变了」再匹配一遍。
        _syncKey(track);
        _recomputeLyrics();
        _notifyChanged();
        // 等价于 effect 重跑：写回的是纯文本才会命中升级分支。
        upgrade = _maybeUpgrade(
          track: track,
          generation: generation,
          cancel: cancel,
        );
      } else {
        // 没写回（manual / 已有歌词）：派生值仍重算一次，以反映请求期间的变化。
        _recomputeLyrics();
      }
      _apply(
        state: LyricsLoad.ready,
        // 原版这一行读的是**写回之后**的 track.lyrics（lyrics.tsx:428）。
        status: track.lyrics.isNotEmpty ? _kStatusSynced : _kStatusPlain,
        showRetry: false,
      );
      return upgrade;
    }

    if (result.status == 'not-found') {
      _recomputeLyrics();
      _apply(
        state: LyricsLoad.missing,
        status: '未找到「${track.title}」的歌词',
        showRetry: true,
      );
      return null;
    }

    // aborted：什么都不做 —— 不改状态、不通知、不弹错（lyrics.tsx:438-440）。
    if (result.status == 'aborted') return null;

    // 其它一律按失败处理。
    final message = result.message.isNotEmpty ? result.message : _kStatusFailed;
    _recomputeLyrics();
    _apply(state: LyricsLoad.error, status: message, showRetry: true);

    // 网络 / 限流类失败自动补一次，每首只补一次（lyrics.tsx:445-457）。
    final reason = result.reason;
    final retryable =
        (reason != null && _retryableReasons.contains(reason)) ||
        _retryableMessage.hasMatch(message);
    if (retryable && !_retried.contains(track.id)) {
      _retried.add(track.id);
      _setStatus('$message${_autoRetrySuffix(_autoRetryDelay)}');
      unawaited(_scheduleAutoRetry(generation: generation));
    }
    return null;
  }

  /// 25 秒后若仍是最新请求就重跑一轮（lyrics.tsx:452-456）。detached。
  Future<void> _scheduleAutoRetry({required int generation}) async {
    await _delay(_autoRetryDelay);
    if (_isStale(generation)) return;
    // 定时器到点 = 新一轮：++世代、换新取消令牌；_force 此时是 false（走缓存）。
    _restart();
  }

  /// 4 秒慢提示（lyrics.tsx:403-406）。detached。
  Future<void> _slowHint({required int generation}) async {
    await _delay(_slowHintDelay);
    if (_isStale(generation)) return;
    _setStatus(_kStatusSlow);
  }

  /// 纯文本 → 带时间轴的后台升级的入口守卫；不该升级就返回 null。
  ///
  /// 条件逐条对译 lyrics.tsx:335-336：无 lyrics、有 plain、非 manual、本会话未
  /// 升级过、在线。**没有 force**：原版这条分支在用户点过「重试」后也照样受
  /// upgradedRef 约束 —— retry() 已经把该 id 从集合里删掉，那就是「重试要再试
  /// 一次升级」，与 force 无关。
  Future<void>? _maybeUpgrade({
    required Track track,
    required int generation,
    required CancelToken cancel,
  }) {
    if (track.lyrics.isNotEmpty) return null;
    if (track.lyricsPlain.isEmpty) return null;
    if (track.lyricsSource == 'manual') return null;
    if (_upgraded.contains(track.id)) return null;
    if (!_isOnline()) return null;
    return _upgradePlain(
      track: track,
      generation: generation,
      cancel: cancel,
    );
  }

  /// 纯文本 → 带时间轴的后台升级（lyrics.tsx:330-377）。
  ///
  /// 两段式：先 useCache:true（之前升级成功过的话这里瞬间完成），缓存里仍是纯文本
  /// 才 useCache:false 绕过缓存再问一次。失败静默 —— 继续静态显示、不打扰用户。
  Future<void> _upgradePlain({
    required Track track,
    required int generation,
    required CancelToken cancel,
  }) async {
    try {
      // 第一段：查缓存。
      final cached = await _source.match(
        _query(track),
        cancel: cancel,
        useCache: true,
      );
      if (_isStale(generation)) return;
      // 缓存里已经带时间轴（之前升级成功过）→ 直接收工。
      if (_applyUpgrade(track: track, result: cached)) return;
      // 第二段：绕过缓存再问一次（老结果没有同步版本的情况，lyrics.tsx:367）。
      final fresh = await _source.match(
        _query(track),
        cancel: cancel,
        useCache: false,
      );
      if (_isStale(generation)) return;
      _applyUpgrade(track: track, result: fresh);
    } catch (_) {
      // 升级失败继续用纯文本，不影响当前显示（lyrics.tsx:368-370）。
      return;
    } finally {
      // 被切歌打断的不算试过，下次进来还要再试（lyrics.tsx:371-374）。
      if (!_isStale(generation)) _upgraded.add(track.id);
    }
  }

  /// 升级结果若有带时间轴的就写入活对象；返回是否写入。
  ///
  /// 两道守卫都是原版的：结果得是 ok 且带 synced（lyrics.tsx:343），写入前再确认
  /// 一次「不是 manual、当前仍无 lyrics」（:346）—— 升级在途时用户可能已经手动
  /// 导入，或别的路径已经写好了歌词。
  bool _applyUpgrade({required Track track, required LyricsMatch result}) {
    if (result.status != 'ok' || result.synced.isEmpty) return false;
    if (track.lyricsSource == 'manual' || track.lyrics.isNotEmpty) return false;
    track.lyrics = result.synced;
    track.lyricsPlain = '';
    track.lyricsSource = 'auto';
    _syncKey(track);
    _recomputeLyrics();
    _apply(state: LyricsLoad.ready, status: _kStatusSynced, showRetry: false);
    _notifyChanged();
    return true;
  }

  /// 重算派生值（lyrics.tsx:111-149 的四个 useMemo）。
  ///
  /// 只在 attach 与写回活对象后调用 —— 渲染层每帧 build 都会读 getter，那里不能
  /// 有解析成本。
  void _recomputeLyrics() {
    final track = _track;
    if (track == null) {
      _cues = const [];
      _plain = '';
      _plainLines = const [];
      _displayLines = const [];
      _lyricsText = '';
      _translatable = false;
      return;
    }

    // cues：在线歌词多为繁体，显示前转简体；手动导入的 .lrc 保持原样
    // （lyrics.tsx:111-118）。
    if (track.lyrics.isEmpty) {
      _cues = const [];
    } else {
      final text = track.lyricsSource == 'manual'
          ? track.lyrics
          : toSimplified(track.lyrics);
      _cues = parseLrc(text, title: track.title, artist: track.artist).lines;
    }

    // plain：同上，manual 不转（lyrics.tsx:119-122）。
    final raw = track.lyricsPlain;
    _plain = raw.isNotEmpty && track.lyricsSource != 'manual'
        ? toSimplified(raw)
        : raw;

    _plainLines = plainLyricLines(_plain);

    // displayLines：有时间轴用 cues，否则用纯文本行（time = NaN）。
    _displayLines = _cues.isNotEmpty
        ? _cues
        : [
            for (final text in _plainLines)
              LyricLine(time: double.nan, text: text),
          ];

    // lyricsText 取**原始**文本（不转简体），判语种与做指纹用（lyrics.tsx:145）。
    _lyricsText = track.lyrics.isNotEmpty ? track.lyrics : track.lyricsPlain;
    _translatable = _displayLines.isNotEmpty && needsTranslation(_lyricsText);
  }

  /// 归一化查询参数。track.duration 未知时是 NaN，normalizeQuery 自己会退成 0。
  LyricsQuery _query(Track track) => normalizeQuery(
    title: track.title,
    artist: track.artist,
    duration: track.duration,
  );

  /// 世代是否已过期（切歌 / 重试 / 自动重试重跑 / dispose 都让旧世代作废）。
  bool _isStale(int generation) => _disposed || generation != _generation;

  /// 一次状态覆写：值有变化才通知（避免同值重复重建渲染树）。
  void _apply({
    required LyricsLoad state,
    required String status,
    required bool showRetry,
  }) {
    if (_disposed) return;
    final changed =
        _state != state || _status != status || _showRetry != showRetry;
    _state = state;
    _status = status;
    _showRetry = showRetry;
    if (changed) notifyListeners();
  }

  /// 只改文案（自动重试后缀 / 慢提示）。
  void _setStatus(String status) {
    if (_disposed || _status == status) return;
    _status = status;
    notifyListeners();
  }

  /// 活对象被写过之后刷新幂等键，避免下一次 attach 误判成「歌词变了」。
  void _syncKey(Track track) {
    _attachedTrack = track;
    _attachKey = _trackKey(track);
  }

  /// 落库回调（装配层给）。不 await —— 落盘失败不该影响显示。
  void _notifyChanged() {
    final onChanged = _onChanged;
    if (onChanged == null) return;
    unawaited(onChanged());
  }

  static String _trackKey(Track track) =>
      '${track.id}|${track.lyrics}|${track.lyricsPlain}|${track.lyricsSource}';
}
